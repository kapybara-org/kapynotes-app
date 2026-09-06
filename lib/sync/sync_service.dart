import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/tombstone.dart';
import 'live_channel.dart';
import 'note_payload.dart';
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
/// Order is pull, then push. Pulling first means a conflict is usually
/// resolved before it reaches the server at all, which turns most of them into
/// an ordinary merge instead of a rejected push and a conflicted copy.
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
       _vault = vault,
       _now = now ?? DateTime.now;

  final NotesStore _notes;
  final SyncState _state;
  final SyncApi _api;
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
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(syncNow()));
  }

  /// Runs a pass now, or joins the one already running.
  ///
  /// Single-flight on purpose: two passes at once would push the same dirty
  /// notes twice and interleave two cursors over the same list.
  Future<void> syncNow() {
    if (_inFlight != null) return _inFlight!;
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

    _timer?.cancel();
    _timer = null;
    _setStatus(SyncStatus.syncing);

    try {
      await _pull(vault);
      await _push(vault);
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
    } on SyncTransientException catch (error) {
      _lastError = error.message;
      _setStatus(SyncStatus.offline);
      _scheduleRetry();
    } on SyncException catch (error) {
      _lastError = error.message;
      _setStatus(SyncStatus.failed);
    }
  }

  Future<void> _pull(Vault vault) async {
    for (var page = 0; page < _maxPagesPerPass; page++) {
      final result = await _api.pull(cursor: _state.cursor);
      if (result.notes.isNotEmpty) {
        await _applyPage(vault, result.notes);
      }
      // Recorded after applying, so a crash between the two re-reads the page
      // rather than skipping it. Applying twice is harmless; skipping is not.
      _state.recordPull(result.cursor);
      if (!result.hasMore) return;
    }
    debugPrint('KapyNotes: pull stopped after $_maxPagesPerPass pages');
  }

  /// Decrypts a page and merges it. The whole page is opened in one call so
  /// the isolate is paid for once rather than per note.
  Future<void> _applyPage(Vault vault, List<WireNote> wire) async {
    final tombstones = <Tombstone>[];
    final sealed = <WireNote>[];
    for (final note in wire) {
      if (note.isTombstone) {
        tombstones.add(Tombstone(id: note.id, deletedAt: note.deletedAt!));
      } else if (note.payload != null) {
        sealed.add(note);
      }
    }

    final opened = await vault.openAll([
      for (final note in sealed) note.payload!,
    ]);

    final notes = <Note>[];
    for (var i = 0; i < sealed.length; i++) {
      final payload = opened[i];
      if (payload == null) {
        // Sealed under a key this account no longer holds. Skipping keeps the
        // rest of the page usable; the note stays on the server untouched.
        debugPrint('KapyNotes: could not open note ${sealed[i].id}');
        continue;
      }
      notes.add(payload.toNote(id: sealed[i].id, updatedAt: sealed[i].updatedAt));
    }

    _notes.applyRemote(notes: notes, tombstones: tombstones);
  }

  Future<void> _push(Vault vault) async {
    final dirtyNotes = _notes.dirtyNotes;
    final dirtyTombstones = _notes.dirtyTombstones;
    if (dirtyNotes.isEmpty && dirtyTombstones.isEmpty) return;

    // One isolate hop for every note being pushed, not one per note.
    final payloads = await vault.sealAll([
      for (final note in dirtyNotes) NotePayload.fromNote(note),
    ]);

    final wire = <WireNote>[
      for (var i = 0; i < dirtyNotes.length; i++)
        WireNote(
          id: dirtyNotes[i].id,
          updatedAt: dirtyNotes[i].updatedAt,
          payload: payloads[i],
        ),
      for (final stone in dirtyTombstones)
        // A tombstone's deletion time is its `updatedAt`: that is the value the
        // server compares, so a delete beats every edit older than it.
        WireNote(
          id: stone.id,
          updatedAt: stone.deletedAt,
          deletedAt: stone.deletedAt,
        ),
    ];

    for (var start = 0; start < wire.length; start += pushMaxNotes) {
      final chunk = wire.sublist(
        start,
        min(start + pushMaxNotes, wire.length),
      );
      final result = await _api.push(chunk);

      _notes.markSynced(
        notes: [
          for (final note in dirtyNotes)
            if (result.applied.contains(note.id)) note,
        ],
        tombstones: [
          for (final stone in dirtyTombstones)
            if (result.applied.contains(stone.id)) stone,
        ],
      );

      if (result.conflicts.isNotEmpty) {
        await _applyPage(vault, result.conflicts);
      }
    }
  }

  void _attachLive() {
    if (_disposed || !_foreground || _vault == null || _live != null) return;
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
    switch (signal) {
      case LiveSignal.wake:
        requestSync();
      case LiveSignal.connected:
        _stopPolling();
        // A reconnect is the one moment we know a wake-up may have gone to a
        // socket that was no longer there. But coming back to the app
        // reconnects and syncs at the same instant, and a launch does both
        // too — so a pass that is already running, or one that has only just
        // finished, is taken as covering it.
        if (_inFlight != null) return;
        final last = _state.lastSyncedAt;
        if (last == null || _now().difference(last) > liveGrace) requestSync();
      case LiveSignal.disconnected:
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
