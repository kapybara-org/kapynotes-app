import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/tombstone.dart';
import 'aead.dart';
import 'key_wrap.dart';
import 'live_channel.dart';
import 'note_payload.dart';
import 'space_keyring.dart';
import 'spaces.dart';
import 'sync_api.dart';
import 'sync_state.dart';
import 'vault.dart';

enum SyncStatus {
  /// Nothing to do, and the last attempt succeeded.
  idle,
  syncing,

  /// The network or the server is unavailable. A retry is already scheduled.
  offline,

  /// No session, or the server rejected the one we have.
  signedOut,

  /// Signed in, but this device has not unlocked the notes yet.
  locked,

  /// This build speaks a protocol the server no longer serves. Nothing is
  /// wrong with the notes; the connection needs a newer app. No retry is
  /// scheduled — the next launch tries once more.
  outdated,

  /// Something the server refused outright. Retrying would send the same bad
  /// request again, so it waits for a human.
  failed,
}

/// Drives one sync pass, and decides when to run the next one.
///
/// A pass runs on a local edit (debounced), on unlock, on app resume, on a
/// wake-up from the server, and on a retry after a failure. The wake-up is
/// what makes a device that is sitting open current: without one, an idle
/// window has no reason to ever look, and shows yesterday's notes until
/// somebody touches it. Polling for that would mean a handshake, a session
/// lookup and a query every interval on every device, almost always to be
/// told nothing happened — so it is the fallback, running only while the
/// channel is down, and not the mechanism.
///
/// A pass is: refresh the list of spaces and their keys; do whatever duties
/// that list reveals — grant a key to a member waiting for one, rotate a
/// space key after a removal, bring a lonely space's notes home; then pull
/// every space this device holds a key for, then push. Pulling first means a
/// conflict is usually resolved before it reaches the server at all, which
/// turns most of them into an ordinary merge instead of a rejected push and a
/// conflicted copy.
///
/// Everything expensive is batched: a page of pulled notes is decrypted in one
/// isolate hop, and the dirty set is sealed in one more. The alternative —
/// per-note crypto on the main isolate — is what makes sync visible to
/// somebody who is typing.
class SyncService extends ChangeNotifier {
  SyncService({
    required NotesStore notes,
    required SyncState state,
    required SyncApi api,
    required SpaceKeyring keyring,
    Vault? vault,
    DateTime Function()? now,
    this.debounce = const Duration(seconds: 2),
    this.minRetry = const Duration(seconds: 5),
    this.maxRetry = const Duration(minutes: 5),
    this.pollInterval = const Duration(seconds: 60),
    this.liveGrace = const Duration(seconds: 10),
  }) : _notes = notes,
       _state = state,
       _api = api,
       _keyring = keyring,
       _vault = vault,
       _now = now ?? DateTime.now;

  final NotesStore _notes;
  final SyncState _state;
  final SyncApi _api;
  final SpaceKeyring _keyring;
  final DateTime Function() _now;

  /// How long to wait after an edit before syncing, so a burst of typing
  /// produces one sync rather than one per keystroke.
  final Duration debounce;
  final Duration minRetry;
  final Duration maxRetry;

  /// How often to sync when there is no wake-up channel to sync on instead.
  ///
  /// Only runs while the channel is down — a captive portal, a corporate
  /// proxy that will not carry an event stream, a server too old to offer
  /// one. A minute is slow enough to cost almost nothing and fast enough that
  /// nobody watching two windows notices.
  final Duration pollInterval;

  /// How recent a sync has to be for a reconnect to leave it alone.
  ///
  /// Coming back to the app reconnects the channel and syncs at the same
  /// instant, and both of those want a pull. This is what keeps that at one.
  final Duration liveGrace;

  /// A server that keeps claiming there is more is a bug we should not follow
  /// forever. The cursor is saved as we go, so stopping early costs nothing
  /// but a wait until the next pass.
  static const int _maxPagesPerPass = 100;

  Vault? _vault;
  Timer? _timer;
  Timer? _poll;
  StreamSubscription<LiveSignal>? _live;
  bool _foreground = false;
  Future<void>? _inFlight;
  int _failures = 0;
  SyncStatus _status = SyncStatus.idle;
  String? _lastError;
  bool _disposed = false;

  SyncStatus get status => _status;
  String? get lastError => _lastError;
  DateTime? get lastSyncedAt => _state.lastSyncedAt;
  bool get isUnlocked => _vault != null;
  SpaceKeyring get keyring => _keyring;

  /// True while the server can reach this device without being asked.
  bool get isLive => _live != null;

  /// Hands the service the master key. Called after an unlock, or at launch
  /// with the key read back from the platform keystore.
  void unlock(Vault vault) {
    _vault = vault;
    if (_status == SyncStatus.locked) _setStatus(SyncStatus.idle);
    _attachLive();
  }

  /// Opens the wake-up channel and keeps it open.
  ///
  /// Called when the app is in the foreground — which on desktop includes a
  /// window that has merely lost focus or been minimised, because a stale
  /// open window is exactly the case this exists for.
  void resume() {
    _foreground = true;
    _attachLive();
  }

  /// Closes it again. Worth doing only for a real backgrounding: a phone that
  /// has been swapped away from will have the socket killed by the OS anyway,
  /// and a radio held awake for it is battery nobody agreed to spend.
  void pause() {
    _foreground = false;
    _detachLive();
    _stopPolling();
  }

  /// Signing out. Sync stops; the notes stay exactly where they are.
  void lock() {
    _vault = null;
    _timer?.cancel();
    _timer = null;
    _detachLive();
    _stopPolling();
    _setStatus(SyncStatus.locked);
  }

  /// Asks for a sync soon. Repeated calls inside [debounce] collapse into one.
  void requestSync() {
    if (_disposed || _vault == null) return;
    // A build the server no longer serves stops asking. The next launch is
    // the next attempt, by which time it may be a newer build.
    if (_status == SyncStatus.outdated) return;
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(syncNow()));
  }

  /// Runs a pass now, or one straight after the pass already running.
  ///
  /// Single-flight on purpose: two passes at once would push the same dirty
  /// notes twice and interleave two cursors over the same list. A call that
  /// lands mid-pass is not simply joined to it, though: whatever it was asked
  /// for — a note just moved, a membership just changed — may have happened
  /// after that pass read its inputs, so one more pass follows, shared by
  /// every caller that asked during the first.
  Future<void> syncNow() {
    final current = _inFlight;
    if (current != null) {
      return _queued ??= current
          .whenComplete(() {})
          .then((_) => _startPass())
          .whenComplete(() => _queued = null);
    }
    return _startPass();
  }

  Future<void>? _queued;

  Future<void> _startPass() {
    final pass = _run().whenComplete(() => _inFlight = null);
    _inFlight = pass;
    return pass;
  }

  Future<void> _run() async {
    final vault = _vault;
    if (vault == null) {
      _setStatus(SyncStatus.locked);
      return;
    }
    if (_status == SyncStatus.outdated) return;

    _timer?.cancel();
    _timer = null;
    _setStatus(SyncStatus.syncing);

    try {
      await _keyring.refresh(_api, vault);
      final personal = _keyring.personal;
      if (personal != null) _state.adoptPersonalSpace(personal.id);
      await _duties(vault);
      _forgetDepartedSpaces();
      await _pullAll(vault);
      await _pushWithRecovery(vault);
      _failures = 0;
      _lastError = null;
      _state.recordSync(_now());
      _setStatus(SyncStatus.idle);
      // A push that resolved a conflict leaves a conflicted copy behind, and
      // that copy is itself unsynced. Come back for it.
      if (_notes.hasPendingChanges) requestSync();
    } on SyncAuthException catch (error) {
      _lastError = error.message;
      _setStatus(SyncStatus.signedOut);
    } on SyncOutdatedException catch (error) {
      _lastError = error.message;
      _stopPolling();
      _detachLive();
      _setStatus(SyncStatus.outdated);
    } on SyncTransientException catch (error) {
      _lastError = error.message;
      _setStatus(SyncStatus.offline);
      _scheduleRetry();
    } on SyncException catch (error) {
      _lastError = error.message;
      _setStatus(SyncStatus.failed);
    }
  }

  // -------------------------------------------------------------------------
  // Duties: what the list of spaces asks this device to do
  // -------------------------------------------------------------------------

  /// Grants, rotations and trips home. Each is best-effort and independent:
  /// a refusal on one — another device got there first — must not stop the
  /// pull that follows, so refusals are logged and the next pass sees the
  /// updated list.
  Future<void> _duties(Vault vault) async {
    var changed = false;
    for (final space in _keyring.teams) {
      final key = _keyring.keyFor(space.id);
      if (key == null) continue;
      try {
        if (await _grantWaiting(space, key)) changed = true;
        if (space.rotationPending && await _rotate(space, key)) changed = true;
        if (space.owedTripHome &&
            space.isOwner &&
            await _bringHome(vault, space, key)) {
          changed = true;
        }
      } on SyncRefusedException catch (error) {
        debugPrint('KapyNotes: duty on ${space.id} refused: ${error.code}');
        changed = true;
      }
    }
    if (changed) await _keyring.refresh(_api, vault);
  }

  /// Any member holding the key wraps it for a member who has none.
  Future<bool> _grantWaiting(Space space, Uint8List key) async {
    var granted = false;
    for (final member in space.members) {
      if (!member.awaitsGrant) continue;
      await _api.grantKey(
        spaceId: space.id,
        userId: member.userId,
        keyGeneration: space.keyGeneration,
        spaceKey: await sealToPublicKey(key, member.x25519Public!),
      );
      granted = true;
    }
    return granted;
  }

  /// The rotation batch: a new space key wrapped once per remaining member
  /// who held the old one, and every live note's content key re-wrapped
  /// under it, in one request. Content keys are unchanged — they rotate
  /// lazily on each note's next write — so no note content is touched.
  Future<bool> _rotate(Space space, Uint8List oldKey) async {
    final newKey = randomKey();
    final spaceKeys = <String, SealedToPublicKey>{};
    for (final member in space.members) {
      final public = member.x25519Public;
      if (!member.hasKey || public == null) continue;
      spaceKeys[member.userId] = await sealToPublicKey(newKey, public);
    }
    if (!spaceKeys.containsKey(_keyring.userId)) return false;

    final noteKeys = <String, ({WrappedKey key, int fromEpoch})>{};
    for (final wire in await _api.fetchNoteKeys(space.id)) {
      final noteId = wire.noteId;
      if (noteId == null) continue;
      final content = await unwrapKey(wire.wrapped, oldKey);
      if (content == null) {
        // A key this device cannot open is one wrapped under a generation it
        // does not hold. The refresh that follows sorts out which.
        return false;
      }
      noteKeys[noteId] = (
        key: await wrapKey(content, newKey),
        fromEpoch: wire.contentKeyEpoch,
      );
    }

    await _api.rotate(
      spaceId: space.id,
      expectedGeneration: space.keyGeneration,
      spaceKeys: spaceKeys,
      noteKeys: noteKeys,
    );
    _keyring.remember(space.id, newKey);
    return true;
  }

  /// A team space whose only member is its owner, with notes still in it, is
  /// owed a trip home. Every note is re-sealed under the master key for the
  /// personal space and the space ends; nothing is deleted.
  Future<bool> _bringHome(Vault vault, Space space, Uint8List key) async {
    final personal = _keyring.personal;
    if (personal == null) return false;
    // Anything this device holds that is not yet on the server goes up
    // first, so that the set the server expects and the set sent agree.
    final mine = _notes.notesIn(space.id);
    if (mine.any((note) => note.isDirty)) return false;

    final at = _now();
    final payloads = [for (final note in mine) NotePayload.fromNote(note)];
    final sealed = await vault.sealAll(payloads);
    final wire = <WireNote>[
      for (var i = 0; i < mine.length; i++)
        WireNote(
          id: mine[i].id,
          spaceId: personal.id,
          updatedAt: at,
          payload: sealed[i],
        ),
    ];
    await _api.stopSharing(space.id, wire);
    _notes.bringHome(mine.map((note) => note.id), at: at);
    _state.forgetSpace(space.id);
    return true;
  }

  /// Notes from spaces this account is no longer in. Clean ones go; ones
  /// with unsynced edits come home as the user's own notes.
  void _forgetDepartedSpaces() {
    final live = {for (final space in _keyring.spaces) space.id};
    for (final spaceId in _notes.spaceIds) {
      if (live.contains(spaceId)) continue;
      final kept = _notes.forgetSpace(spaceId);
      _state.forgetSpace(spaceId);
      if (kept.isNotEmpty) {
        debugPrint(
          'KapyNotes: kept ${kept.length} unsynced note(s) from a space '
          'this account left',
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Pull
  // -------------------------------------------------------------------------

  Future<void> _pullAll(Vault vault) async {
    for (final space in _keyring.spaces) {
      // A member waiting on a grant can read nothing yet; pulling would
      // only advance a cursor past notes it cannot open.
      if (space.isTeam && !_keyring.holdsKey(space.id)) continue;
      await _pull(vault, space);
    }
  }

  Future<void> _pull(Vault vault, Space space) async {
    for (var page = 0; page < _maxPagesPerPass; page++) {
      final result = await _api.pull(
        space: space.id,
        cursor: _state.cursorFor(space.id),
      );
      if (result.notes.isNotEmpty) {
        await _applyPage(vault, space, result.notes);
      }
      // Recorded after applying, so a crash between the two re-reads the page
      // rather than skipping it. Applying twice is harmless; skipping is not.
      _state.recordPull(space.id, result.cursor);
      if (!result.hasMore) return;
    }
    debugPrint('KapyNotes: pull stopped after $_maxPagesPerPass pages');
  }

  /// Decrypts a page and merges it. The whole page is opened in one call so
  /// the isolate is paid for once rather than per note.
  ///
  /// A team note's content key is unwrapped with the space key first; a key
  /// that does not open is one wrapped under a generation this device has
  /// not caught up with, and the page is retried after a refresh rather than
  /// skipped past.
  Future<void> _applyPage(Vault vault, Space space, List<WireNote> wire) async {
    final tombstones = <Tombstone>[];
    final sealed = <WireNote>[];
    final keys = <Uint8List?>[];
    final storedSpaceId = space.isPersonal ? null : space.id;
    final spaceKey = _keyring.keyFor(space.id);

    for (final note in wire) {
      if (note.isTombstone) {
        tombstones.add(
          Tombstone(
            id: note.id,
            deletedAt: note.deletedAt!,
            spaceId: storedSpaceId,
          ),
        );
        continue;
      }
      if (note.payload == null) continue;
      if (space.isPersonal) {
        sealed.add(note);
        keys.add(null);
        continue;
      }
      final wrapped = note.key;
      if (wrapped == null || spaceKey == null) {
        debugPrint('KapyNotes: shared note ${note.id} arrived without a key');
        continue;
      }
      final content = await unwrapKey(wrapped.wrapped, spaceKey);
      if (content == null) {
        throw const SyncTransientException('the space key has moved on');
      }
      sealed.add(note);
      keys.add(content);
    }

    final opened = await vault.openAllWith([
      for (final note in sealed) note.payload!,
    ], keys);

    final notes = <Note>[];
    for (var i = 0; i < sealed.length; i++) {
      final payload = opened[i];
      if (payload == null) {
        // Sealed under a key this account no longer holds. Skipping keeps the
        // rest of the page usable; the note stays on the server untouched.
        debugPrint('KapyNotes: could not open note ${sealed[i].id}');
        continue;
      }
      final key = sealed[i].key;
      notes.add(
        payload.toNote(
          id: sealed[i].id,
          updatedAt: sealed[i].updatedAt,
          spaceId: storedSpaceId,
          contentKey: keys[i],
          contentKeyEpoch: key?.contentKeyEpoch ?? 1,
          contentKeyGeneration:
              key?.contentKeyGeneration ?? key?.keyGeneration ?? 1,
        ),
      );
    }

    _notes.applyRemote(notes: notes, tombstones: tombstones);
  }

  // -------------------------------------------------------------------------
  // Push
  // -------------------------------------------------------------------------

  /// Pushes, and answers the refusals a push can earn — a key generation that
  /// moved on, an epoch behind the stored one, a space this device is no
  /// longer in — by refreshing what it knows and trying once more.
  Future<void> _pushWithRecovery(Vault vault) async {
    try {
      await _push(vault);
    } on SyncRefusedException catch (error) {
      switch (error.code) {
        case 'stale-key-generation':
        case 'move-raced':
        case 'not a member of this space':
          await _keyring.refresh(_api, vault);
          _forgetDepartedSpaces();
        case 'content-key-epoch':
          await _adoptServerKey(vault, error);
        default:
          rethrow;
      }
      await _push(vault);
    }
  }

  /// The server holds a newer content key for a note this device is about
  /// to write. Take it, keep the local text, and let the write go up under it.
  Future<void> _adoptServerKey(Vault vault, SyncRefusedException error) async {
    final spaceId = error.body['spaceId'];
    final noteId = error.body['noteId'];
    if (spaceId is! String || noteId is! String) rethrow_(error);
    await _keyring.refresh(_api, vault);
    final space = _keyring.byId(spaceId);
    final spaceKey = _keyring.keyFor(spaceId);
    if (space == null || spaceKey == null) rethrow_(error);
    for (final wire in await _api.fetchNoteKeys(spaceId)) {
      if (wire.noteId != noteId) continue;
      final content = await unwrapKey(wire.wrapped, spaceKey);
      if (content == null) rethrow_(error);
      _notes.adoptKey(
        noteId,
        contentKey: content,
        contentKeyEpoch: wire.contentKeyEpoch,
        contentKeyGeneration: wire.contentKeyGeneration ?? wire.keyGeneration,
      );
      return;
    }
    // No row at all: the server expects a fresh key at epoch one.
    final local = _notes.byId(noteId);
    if (local == null) rethrow_(error);
    _notes.adoptKey(
      noteId,
      contentKey: local.contentKey ?? randomKey(),
      contentKeyEpoch: 1,
      contentKeyGeneration: space.keyGeneration,
    );
  }

  static Never rethrow_(SyncRefusedException error) => throw error;

  Future<void> _push(Vault vault) async {
    final personal = _keyring.personal;
    var dirtyNotes = _notes.dirtyNotes;
    final dirtyTombstones = _notes.dirtyTombstones;
    if (dirtyNotes.isEmpty && dirtyTombstones.isEmpty) return;

    // Shared notes first: any whose key predates a removal, or that is in a
    // space still waiting on its rotation, gets a fresh key now — the write
    // that rotates must seal under a key the removed person never had.
    final skipped = <String>{};
    for (final note in dirtyNotes) {
      final spaceId = note.spaceId;
      if (spaceId == null) continue;
      final space = _keyring.byId(spaceId);
      if (space == null || !_keyring.holdsKey(spaceId)) {
        // Not ours to write right now: the space is gone, or the key has not
        // arrived. The note stays dirty and waits.
        skipped.add(note.id);
        continue;
      }
      final stale =
          note.contentKey == null ||
          note.contentKeyGeneration < space.keyGeneration ||
          space.rotationPending;
      if (stale) {
        _notes.adoptKey(
          note.id,
          contentKey: randomKey(),
          contentKeyEpoch: note.contentKey == null ? 1 : note.contentKeyEpoch + 1,
          contentKeyGeneration: space.keyGeneration,
        );
      }
    }
    dirtyNotes = _notes.dirtyNotes
        .where((note) => !skipped.contains(note.id))
        .toList(growable: false);
    final stones = dirtyTombstones
        .where(
          (stone) =>
              stone.spaceId == null || _keyring.byId(stone.spaceId) != null,
        )
        .toList(growable: false);
    if (dirtyNotes.isEmpty && stones.isEmpty) return;

    // One isolate hop for every note being pushed, not one per note.
    final payloads = await vault.sealAllWith(
      [for (final note in dirtyNotes) NotePayload.fromNote(note)],
      [for (final note in dirtyNotes) note.contentKey],
    );

    final wire = <WireNote>[];
    for (var i = 0; i < dirtyNotes.length; i++) {
      final note = dirtyNotes[i];
      final spaceId = note.spaceId;
      WireNoteKey? key;
      if (spaceId != null) {
        final space = _keyring.byId(spaceId)!;
        key = WireNoteKey(
          wrapped: await wrapKey(note.contentKey!, _keyring.keyFor(spaceId)!),
          keyGeneration: space.keyGeneration,
          contentKeyEpoch: note.contentKeyEpoch,
        );
      }
      wire.add(
        WireNote(
          id: note.id,
          spaceId: spaceId ?? personal?.id,
          updatedAt: note.updatedAt,
          payload: payloads[i],
          key: key,
        ),
      );
    }
    for (final stone in stones) {
      // A tombstone's deletion time is its `updatedAt`: that is the value the
      // server compares, so a delete beats every edit older than it.
      wire.add(
        WireNote(
          id: stone.id,
          spaceId: stone.spaceId ?? personal?.id,
          updatedAt: stone.deletedAt,
          deletedAt: stone.deletedAt,
        ),
      );
    }

    // A move is a tombstone and a live note under one id, and the server
    // applies both or neither — so they must travel in the same request.
    // Sorting by id keeps the pair adjacent before chunking.
    wire.sort((a, b) => a.id.compareTo(b.id));

    for (var start = 0; start < wire.length; start += pushMaxNotes) {
      var end = min(start + pushMaxNotes, wire.length);
      // Never split a pair across the boundary.
      while (end < wire.length && end > start && wire[end].id == wire[end - 1].id) {
        end--;
      }
      final chunk = wire.sublist(start, end);
      final result = await _api.push(chunk);

      _notes.markSynced(
        notes: [
          for (final note in dirtyNotes)
            if (result.applied.contains(note.id)) note,
        ],
        tombstones: [
          for (final stone in stones)
            if (result.applied.contains(stone.id)) stone,
        ],
      );

      if (result.conflicts.isNotEmpty) await _applyConflicts(vault, result);
    }
  }

  /// Winning copies come back grouped by whichever space they are in.
  Future<void> _applyConflicts(Vault vault, PushResult result) async {
    final bySpace = <String, List<WireNote>>{};
    for (final note in result.conflicts) {
      final id = note.spaceId ?? _keyring.personal?.id;
      if (id == null) continue;
      bySpace.putIfAbsent(id, () => []).add(note);
    }
    for (final entry in bySpace.entries) {
      final space = _keyring.byId(entry.key);
      if (space == null) continue;
      await _applyPage(vault, space, entry.value);
    }
  }

  // -------------------------------------------------------------------------
  // Wake-ups
  // -------------------------------------------------------------------------

  void _attachLive() {
    if (_disposed || !_foreground || _vault == null || _live != null) return;
    if (_status == SyncStatus.outdated) return;
    // Listening is what opens the socket; cancelling is what closes it. There
    // is no separate connect to forget to call.
    _live = _api.live().listen(_onLive);
  }

  void _detachLive() {
    unawaited(_live?.cancel());
    _live = null;
  }

  void _onLive(LiveSignal signal) {
    if (_disposed) return;
    switch (signal.kind) {
      case LiveSignalKind.wake:
        requestSync();
      case LiveSignalKind.connected:
        _stopPolling();
        // A reconnect is the one moment we know a wake-up may have gone to a
        // socket that was no longer there. But coming back to the app
        // reconnects and syncs at the same instant, and a launch does both
        // too — so a pass that is already running, or one that has only just
        // finished, is taken as covering it.
        if (_inFlight != null) return;
        final last = _state.lastSyncedAt;
        if (last == null || _now().difference(last) > liveGrace) requestSync();
      case LiveSignalKind.disconnected:
        _startPolling();
    }
  }

  /// The fallback, and only ever that: it runs while the channel is down and
  /// stops the moment it comes back.
  void _startPolling() {
    if (_disposed || _poll != null) return;
    _poll = Timer.periodic(pollInterval, (_) => unawaited(syncNow()));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _failures++;
    // Exponential, capped, with jitter so every device that lost the same
    // network does not come back at the same instant.
    final backoff = minRetry * pow(2, min(_failures - 1, 10)).toDouble();
    final capped = backoff > maxRetry ? maxRetry : backoff;
    final jitter = Random().nextDouble() * 0.3 + 0.85;
    _timer?.cancel();
    _timer = Timer(
      Duration(milliseconds: (capped.inMilliseconds * jitter).round()),
      () => unawaited(syncNow()),
    );
  }

  void _setStatus(SyncStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _stopPolling();
    _detachLive();
    super.dispose();
  }
}
