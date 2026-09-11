import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../crdt/crdt.dart';
import '../data/note_attachment.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/tombstone.dart';
import 'aead.dart';
import 'doc_store.dart';
import 'image_sync.dart';
import 'key_wrap.dart';
import 'sealed_box.dart';
import 'space_keyring.dart';
import 'spaces.dart';
import 'sync_api.dart';
import 'sync_socket.dart';
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

/// The merge engine this build writes. Matches `ENGINE_FUGUE`.
const String fugueEngine = 'fugue1';

/// Keeps every device's copy of every note the same, as it is typed.
///
/// A note is not a blob any more. Each keystroke becomes an op in a CRDT
/// document ([NoteDoc]) that merges on the device — the server holds only
/// ciphertext and cannot — and each op goes to the server sealed, takes a
/// place in its space's log, and reaches every other device over one socket
/// the moment it lands. Two people typing in one note converge to one text.
/// Nothing is ever resolved by timestamp, and nothing is forked off to the
/// side as a "conflicted copy".
///
/// Three loops, and only three:
///
/// 1. **Reconcile.** The note list changes — a keystroke, a delete, a move —
///    and every dirty note is diffed against its document. The diff becomes
///    ops, the ops go to the note's outbox, and the note is marked absorbed.
///    Runs in a microtask after each change, so it is done before any remote
///    op can be applied on top.
/// 2. **Send.** The outbox drains over the socket, one push per note in
///    flight at a time, sealed at send time under the note's current key.
///    An acknowledgement clears the entry; a disconnect puts it back; a
///    refusal is answered — a key that moved, a note somebody else seeded
///    first — and the entry goes again. With the socket down, the same
///    pushes go over HTTP on the poll.
/// 3. **Apply.** Ops arrive in seq order per space, are opened, applied to
///    the document, and the document is rendered back into the note list.
///    The editor holding that note learns of it through the list, and keeps
///    its caret. The cursor moves once per batch, after the batch is applied.
///
/// The keyring, the duties a space list reveals — grants, rotations, trips
/// home — and the attachment uploads are unchanged from the blob protocol and
/// run over HTTP as they did.
class SyncService extends ChangeNotifier {
  SyncService({
    required NotesStore notes,
    required SyncState state,
    required SyncApi api,
    required SpaceKeyring keyring,
    required DocStore docs,
    ImageSync? images,
    Vault? vault,
    DateTime Function()? now,
    this.sendDelay = const Duration(milliseconds: 60),
    this.minRetry = const Duration(seconds: 5),
    this.maxRetry = const Duration(minutes: 5),
    this.pollInterval = const Duration(seconds: 60),
    this.snapshotEvery = 150,
  }) : _notes = notes,
       _state = state,
       _api = api,
       _keyring = keyring,
       _docs = docs,
       _images = images,
       _vault = vault,
       _now = now ?? DateTime.now {
    _notes.addListener(_onNotesChanged);
  }

  final NotesStore _notes;
  final SyncState _state;
  final SyncApi _api;
  final SpaceKeyring _keyring;
  final DocStore _docs;
  final ImageSync? _images;
  final DateTime Function() _now;

  /// How long after an edit the outbox drains. Short: this is the whole
  /// difference between "live" and "laggy", and a burst of typing inside it
  /// still becomes one op rather than one per key.
  final Duration sendDelay;
  final Duration minRetry;
  final Duration maxRetry;

  /// How often to pull and push over HTTP while the socket is down. Only
  /// then: a captive portal, a proxy that will not upgrade.
  final Duration pollInterval;

  /// After this many ops on a note since its last snapshot, the next device
  /// to write it also writes a snapshot, so a device that has been away can
  /// take one document instead of replaying a year of keystrokes.
  final int snapshotEvery;

  Vault? _vault;
  SyncSocket? _socket;
  StreamSubscription<SocketEvent>? _socketEvents;
  Timer? _sendTimer;
  Timer? _retryTimer;
  Timer? _poll;
  bool _foreground = false;
  bool _reconcileScheduled = false;
  bool _live = false;

  /// True once the socket has reported itself down on this foreground
  /// stretch. Until then a socket that exists is merely connecting, and the
  /// HTTP path waits for it rather than racing it.
  bool _socketDown = false;

  /// Notes whose pictures are on their way up, so a burst of typing does not
  /// start a second upload per keystroke.
  final Set<String> _uploading = {};
  Future<void>? _inFlight;
  Future<void>? _queued;
  int _failures = 0;
  int _requestCounter = 0;
  SyncStatus _status = SyncStatus.idle;
  String? _lastError;
  bool _disposed = false;

  /// Spaces the socket has subscribed to on this connection.
  final Set<String> _subscribed = {};

  /// Spaces whose log this device has read to the end at least once. A note
  /// with no history here is not seeded before that: the history may be on
  /// the server already, and the seed would be refused.
  final Set<String> _caughtUp = {};

  /// Spaces the server will not sync until somebody in them has Pro, as it
  /// last said.
  ///
  /// Per space, because that is how the server answers: a free account in a
  /// space somebody Pro owns syncs that space and not its own. Nothing in one
  /// of these is subscribed to, pulled, reconciled or pushed. Its notes stay
  /// dirty, and one diff takes them up once it is covered again, instead of a
  /// month of keystrokes queued against a refusal. A space leaves only when
  /// the server serves it again, so what the UI shows never flickers.
  final Set<String> _needsPro = {};

  /// Whether the next pass asks about [_needsPro] again. Set only by something
  /// that could have changed the answer: a purchase or a trial ending, the
  /// server saying the spaces changed, a new connection. Asking on every pass
  /// is what the builds before this one did, as fast as the network allowed.
  bool _askAboutPro = false;

  /// Pushes awaiting an acknowledgement, by request id.
  final Map<String, ({DocRecord record, OutboxEntry entry})> _awaiting = {};

  /// Presence is deliberately bounded and ephemeral. One local frame is
  /// refreshed while keys are arriving, and at most one remote frame per
  /// device is kept until its short expiry.
  static const _typingIdle = Duration(milliseconds: 1500);
  static const _presenceTtl = Duration(seconds: 30);
  static const _presenceRefresh = Duration(seconds: 10);
  static const _maxRemotePresence = 128;
  final Map<String, _RemotePresence> _remotePresence = {};
  final Map<String, int> _presenceMessageVersions = {};
  int _presenceMessageSerial = 0;
  _OutgoingPresence? _outgoingPresence;
  String? _requestedTypingNoteId;
  int _outgoingPresenceVersion = 0;
  Timer? _presenceIdleTimer;
  Timer? _presenceRefreshTimer;
  Timer? _presenceExpiryTimer;

  SyncStatus get status => _status;
  String? get lastError => _lastError;
  DateTime? get lastSyncedAt => _state.lastSyncedAt;
  bool get isUnlocked => _vault != null;
  SpaceKeyring get keyring => _keyring;

  /// True while the socket is up: changes elsewhere reach this device
  /// without being asked for.
  bool get isLive => _live;

  /// Spaces held back until somebody in them has Pro.
  Set<String> get spacesNeedingPro => Set.unmodifiable(_needsPro);

  /// Whether this account's own notes are held back for want of Pro — the
  /// personal space refused, whatever happens to the shared ones.
  bool get personalNeedsPro {
    final personal = _keyring.personal;
    return personal != null && _needsPro.contains(personal.id);
  }

  /// Something that decides what the server covers may have changed — a
  /// purchase, a refund, a trial ending — so the spaces held back are asked
  /// about once more. The only way they are, besides the server's own notice.
  void recheckCoverage() {
    if (_disposed || _vault == null || _needsPro.isEmpty) return;
    _askAboutPro = true;
    unawaited(syncNow());
  }

  /// Human-readable collaborators currently typing in [noteId], one label per
  /// account even when the same person has the note open on two devices.
  List<String> typingNamesFor(String noteId) {
    final now = DateTime.now();
    final byUser = <String, _RemotePresence>{};
    for (final presence in _remotePresence.values) {
      if (presence.noteId != noteId || !presence.expiresAt.isAfter(now)) {
        continue;
      }
      byUser[presence.userId] = presence;
    }
    final names = [
      for (final presence in byUser.values) _presenceLabel(presence),
    ];
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return List.unmodifiable(names);
  }

  /// Records real editor activity. A sealed note id is sent once at the start
  /// and then refreshed, rather than doing encryption and a socket write for
  /// every key press.
  void reportTyping(String noteId) {
    if (_disposed || _vault == null) return;
    final note = _notes.byId(noteId);
    final spaceId = note?.spaceId;
    final space = _keyring.byId(spaceId);
    final key = spaceId == null ? null : _keyring.keyFor(spaceId);
    if (spaceId == null ||
        space == null ||
        !space.isTeam ||
        !space.canEdit ||
        key == null) {
      stopTyping();
      return;
    }

    _presenceIdleTimer?.cancel();
    _presenceIdleTimer = Timer(_typingIdle, () => stopTyping(noteId));
    if (_requestedTypingNoteId == noteId) return;

    _requestedTypingNoteId = noteId;
    final version = ++_outgoingPresenceVersion;
    unawaited(_beginPresence(noteId, spaceId, key, version));
  }

  /// Clears activity only when [noteId] is still the active editor. That guard
  /// prevents a disposed old editor from cancelling a newer note's presence.
  void stopTyping([String? noteId]) {
    if (noteId != null && _requestedTypingNoteId != noteId) return;
    _requestedTypingNoteId = null;
    _outgoingPresenceVersion++;
    _presenceIdleTimer?.cancel();
    _presenceIdleTimer = null;
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = null;
    final previous = _outgoingPresence;
    _outgoingPresence = null;
    if (previous != null) _writePresence(previous, active: false);
  }

  /// Changes the server has not acknowledged yet.
  int get pendingCount => _docs.pendingCount;
  bool get hasPendingChanges => pendingCount > 0 || _notes.hasPendingChanges;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Hands the service the master key. Called after an unlock, or at launch
  /// with the key read back from the platform keystore.
  void unlock(Vault vault) {
    _vault = vault;
    if (_status == SyncStatus.locked) _setStatus(SyncStatus.idle);
    _connect();
    _scheduleReconcile();
  }

  /// Opens the socket and keeps it open. Called when the app is in the
  /// foreground — which on desktop includes a window that has merely lost
  /// focus, because a stale open window is exactly what this exists for.
  void resume() {
    _foreground = true;
    _connect();
  }

  /// Closes it. Only for a real backgrounding: the OS is about to kill the
  /// socket anyway, and a radio held awake for it is battery nobody agreed
  /// to spend. Everything unsent stays in the outbox.
  void pause() {
    _foreground = false;
    stopTyping();
    _disconnect();
    _stopPolling();
    unawaited(_docs.flush());
  }

  /// Signing out. Sync stops; the notes stay exactly where they are.
  void lock() {
    stopTyping();
    _vault = null;
    _needsPro.clear();
    _askAboutPro = false;
    _sendTimer?.cancel();
    _sendTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _disconnect();
    _stopPolling();
    _setStatus(SyncStatus.locked);
  }

  /// Asks for a sync soon. Kept for callers that used to schedule a pass:
  /// now it reconciles what changed and drains the outbox.
  void requestSync() {
    if (_disposed || _vault == null) return;
    if (_status == SyncStatus.outdated) return;
    _scheduleReconcile();
    if (!_live) _scheduleRetry(soon: true);
  }

  /// Runs a full pass now: refreshes the spaces, does the duties, catches up
  /// every space — over the socket if it is up, over HTTP if not — and
  /// drains the outbox. Single-flight, with one follow-up for callers that
  /// asked mid-pass.
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
    _retryTimer?.cancel();
    _retryTimer = null;
    _setStatus(SyncStatus.syncing);

    try {
      await _docs.load();
      await _keyring.refresh(_api, vault);
      final personal = _keyring.personal;
      if (personal != null) _state.adoptPersonalSpace(personal.id);
      await _duties(vault);
      _forgetDepartedSpaces();
      if (_live) {
        _subscribeAll();
      } else if (_socket == null || _socketDown) {
        await _pullAllOverHttp();
      }
      _reconcileDirty();
      await _drain();
      _failures = 0;
      _lastError = null;
      _state.recordSync(_now());
      _setStatus(SyncStatus.idle);
    } on SyncAuthException catch (error) {
      _lastError = error.message;
      _setStatus(SyncStatus.signedOut);
    } on SyncOutdatedException catch (error) {
      _lastError = error.message;
      _stopPolling();
      _disconnect();
      _setStatus(SyncStatus.outdated);
    } on SyncTransientException catch (error) {
      _lastError = error.message;
      _setStatus(SyncStatus.offline);
      _scheduleRetry();
    } on SyncException catch (error) {
      // Every path that can meet one handles it per space, so this is only
      // a net: a space held back is not a failure of the pass.
      if (error is SyncRefusedException && error.code == proRequiredCode) {
        final spaceId = error.body['spaceId'];
        if (spaceId is String) _holdForPro(spaceId);
        _setStatus(SyncStatus.idle);
        return;
      }
      _lastError = error.message;
      _setStatus(SyncStatus.failed);
    }
  }

  // -------------------------------------------------------------------------
  // The socket
  // -------------------------------------------------------------------------

  void _connect() {
    if (_disposed || !_foreground || _vault == null) return;
    if (_status == SyncStatus.outdated) return;
    if (_socket != null) return;
    final socket = _api.openSocket();
    _socket = socket;
    _socketEvents = socket.events.listen(_onSocketEvent);
    socket.connect();
  }

  void _disconnect() {
    final socket = _socket;
    _socket = null;
    unawaited(_socketEvents?.cancel());
    _socketEvents = null;
    _subscribed.clear();
    _wentDown();
    unawaited(socket?.close());
  }

  void _wentDown() {
    if (_live) {
      _live = false;
      if (!_disposed) notifyListeners();
    }
    // Whatever was in flight may or may not have landed; the server will
    // recognise a repeat by its device counter, so it simply goes again.
    for (final waiting in _awaiting.values) {
      waiting.entry.inFlight = false;
    }
    _awaiting.clear();
    _clearRemotePresence();
  }

  void _onSocketEvent(SocketEvent event) {
    if (_disposed) return;
    switch (event.kind) {
      case SocketEventKind.connected:
        _live = true;
        _socketDown = false;
        _subscribed.clear();
        _stopPolling();
        // Whatever the server said about Pro while this was away — a
        // purchase on another device — is only learned by asking.
        _askAboutPro = _needsPro.isNotEmpty;
        notifyListeners();
        // A pass on every connect: the spaces may have changed while the
        // socket was down, and the subscription needs the current list.
        unawaited(syncNow());
      case SocketEventKind.disconnected:
        final first = !_socketDown;
        _socketDown = true;
        _wentDown();
        _startPolling();
        // The first time it goes down, catch up over HTTP at once rather
        // than at the next poll; the outbox goes the same way.
        if (first) unawaited(syncNow());
      case SocketEventKind.message:
        unawaited(_onMessage(event.message!));
    }
  }

  /// Subscribes to every space this device can read that it has not
  /// subscribed to on this connection.
  void _subscribeAll() {
    final socket = _socket;
    if (socket == null || !_live) return;
    final wanted = <String, int>{};
    for (final space in _keyring.spaces) {
      if (space.isTeam && !_keyring.holdsKey(space.id)) continue;
      if (_subscribed.contains(space.id)) continue;
      if (_needsPro.contains(space.id) && !_askAboutPro) continue;
      wanted[space.id] = _state.cursorFor(space.id);
    }
    if (wanted.isEmpty) {
      _askAboutPro = false;
      return;
    }
    if (socket.send({'t': 'sub', 'spaces': wanted})) {
      _subscribed.addAll(wanted.keys);
      _askAboutPro = false;
    }
  }

  Future<void> _onMessage(Map<String, Object?> message) async {
    final vault = _vault;
    if (vault == null) return;
    switch (message['t']) {
      case 'ops':
        final batch = OpsBatch.fromJson(message);
        if (batch != null) await _applyBatch(vault, batch);
      case 'synced':
        final spaceId = message['spaceId'];
        if (spaceId is String) {
          _servedAgain(spaceId);
          _caughtUp.add(spaceId);
          _resendPresence(spaceId);
          _reconcileDirty();
          _scheduleSend();
        }
      case 'ack':
        await _onAck(message);
      case 'spaces':
        // What this account may see has changed, and a purchase or a refund
        // is among the things that change it.
        _askAboutPro = _needsPro.isNotEmpty;
        unawaited(syncNow());
      case 'error':
        final spaceId = message['spaceId'];
        if (spaceId is String) _subscribed.remove(spaceId);
        if (spaceId is String && message['error'] == proRequiredCode) {
          // Not a pass: asking again would be refused again. It waits for
          // something that could change the answer; see [_askAboutPro].
          _holdForPro(spaceId);
        } else {
          debugPrint('KapyNotes: socket error: ${message['error']}');
          unawaited(syncNow());
        }
      case 'pong':
        break;
      case 'presence':
        await _onPresence(message);
    }
  }

  Future<void> _beginPresence(
    String noteId,
    String spaceId,
    Uint8List key,
    int version,
  ) async {
    final payload = await sealBytes(_encode({'noteId': noteId}), key);
    if (_disposed ||
        version != _outgoingPresenceVersion ||
        _requestedTypingNoteId != noteId) {
      return;
    }
    final previous = _outgoingPresence;
    if (previous != null) _writePresence(previous, active: false);
    final current = _OutgoingPresence(
      noteId: noteId,
      spaceId: spaceId,
      payload: payload,
    );
    _outgoingPresence = current;
    _writePresence(current, active: true);
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = Timer.periodic(
      _presenceRefresh,
      (_) => _writePresence(current, active: true),
    );
  }

  void _writePresence(_OutgoingPresence presence, {required bool active}) {
    final socket = _socket;
    if (socket == null || !_live || !_subscribed.contains(presence.spaceId)) {
      return;
    }
    socket.send({
      't': 'presence',
      'spaceId': presence.spaceId,
      'active': active,
      'payload': presence.payload.toJson(),
    });
  }

  void _resendPresence(String spaceId) {
    final presence = _outgoingPresence;
    if (presence?.spaceId == spaceId) {
      _writePresence(presence!, active: true);
    }
  }

  Future<void> _onPresence(Map<String, Object?> message) async {
    final userId = message['userId'];
    final deviceId = message['deviceId'];
    final spaceId = message['spaceId'];
    final active = message['active'];
    if (userId is! String ||
        deviceId is! String ||
        spaceId is! String ||
        active is! bool ||
        userId == _keyring.userId) {
      return;
    }
    final id = '$userId\u0000$deviceId';
    final version = ++_presenceMessageSerial;
    _presenceMessageVersions[id] = version;
    if (!active) {
      final changed = _remotePresence.remove(id) != null;
      _presenceMessageVersions.remove(id);
      _schedulePresenceExpiry();
      if (changed && !_disposed) notifyListeners();
      return;
    }

    try {
      final box = SealedBox.fromJson(message['payload']);
      final key = _keyring.keyFor(spaceId);
      if (box == null || key == null) return;
      final clear = await openBytes(box, key);
      if (clear == null || _presenceMessageVersions[id] != version) return;
      final decoded = jsonDecode(utf8.decode(clear));
      final noteId = decoded is Map ? decoded['noteId'] : null;
      if (noteId is! String || noteId.length > 64) return;

      final previous = _remotePresence[id];
      if (previous == null && _remotePresence.length >= _maxRemotePresence) {
        final oldest = _remotePresence.entries.reduce(
          (a, b) => a.value.expiresAt.isBefore(b.value.expiresAt) ? a : b,
        );
        _remotePresence.remove(oldest.key);
      }
      _remotePresence[id] = _RemotePresence(
        userId: userId,
        spaceId: spaceId,
        noteId: noteId,
        expiresAt: DateTime.now().add(_presenceTtl),
      );
      _schedulePresenceExpiry();
      final changed =
          previous == null ||
          previous.noteId != noteId ||
          previous.spaceId != spaceId;
      if (changed && !_disposed) notifyListeners();
    } on FormatException {
      // Opaque presence from a newer or corrupt client is safe to ignore.
    } finally {
      if (_presenceMessageVersions[id] == version) {
        _presenceMessageVersions.remove(id);
      }
    }
  }

  String _presenceLabel(_RemotePresence presence) {
    final space = _keyring.byId(presence.spaceId);
    final member = space?.member(presence.userId);
    final email = member?.email;
    if (email == null || email.isEmpty) return 'Someone';
    final local = email.split('@').first;
    if (local.isEmpty) return email;
    final collision = space!.members.any(
      (other) =>
          other.userId != presence.userId &&
          other.email.split('@').first.toLowerCase() == local.toLowerCase(),
    );
    return collision ? email : local;
  }

  void _schedulePresenceExpiry() {
    _presenceExpiryTimer?.cancel();
    _presenceExpiryTimer = null;
    if (_remotePresence.isEmpty) return;
    final now = DateTime.now();
    final expiry = _remotePresence.values
        .map((presence) => presence.expiresAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final delay = expiry.difference(now);
    _presenceExpiryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      _expirePresence,
    );
  }

  void _expirePresence() {
    final now = DateTime.now();
    final before = _remotePresence.length;
    _remotePresence.removeWhere((_, value) => !value.expiresAt.isAfter(now));
    _schedulePresenceExpiry();
    if (_remotePresence.length != before && !_disposed) notifyListeners();
  }

  void _clearRemotePresence() {
    _presenceExpiryTimer?.cancel();
    _presenceExpiryTimer = null;
    _presenceMessageSerial++;
    _presenceMessageVersions.clear();
    if (_remotePresence.isEmpty) return;
    _remotePresence.clear();
    if (!_disposed) notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Reconcile: local edits become ops
  // -------------------------------------------------------------------------

  void _onNotesChanged() => _scheduleReconcile();

  void _scheduleReconcile() {
    if (_disposed || _reconcileScheduled) return;
    _reconcileScheduled = true;
    // A microtask, not a timer: it runs after the change that scheduled it
    // and before any socket event, so a remote op is never applied on top of
    // a keystroke the document has not absorbed yet.
    scheduleMicrotask(() {
      _reconcileScheduled = false;
      if (_disposed) return;
      _reconcileDirty();
      _scheduleSend();
    });
  }

  /// Diffs every dirty note against its document and turns the difference
  /// into outbox entries. Synchronous once the store is loaded, which is
  /// what lets [_applyBatch] rely on it.
  void _reconcileDirty() {
    if (_vault == null || !_docs.isLoaded) return;
    final personal = _keyring.personal;
    if (personal == null) return;

    for (final note in _notes.dirtyNotes) {
      final spaceId = note.spaceId ?? personal.id;
      // Left dirty, not diffed: the diff is taken once, when it can go.
      if (_needsPro.contains(spaceId)) continue;
      final space = _keyring.byId(spaceId);
      if (space == null) continue;
      if (!space.canEdit) continue;
      if (space.isTeam && !_keyring.holdsKey(spaceId)) continue;

      var current = note;
      // A team note gets a content key on its first write, and a fresh one
      // after a removal: the write that rotates must seal under a key the
      // removed person never had.
      if (space.isTeam) {
        final stale =
            current.contentKey == null ||
            current.contentKeyGeneration < space.keyGeneration ||
            space.rotationPending;
        if (stale) {
          _notes.adoptKey(
            current.id,
            contentKey: randomKey(),
            contentKeyEpoch: current.contentKey == null
                ? 1
                : current.contentKeyEpoch + 1,
            contentKeyGeneration: space.keyGeneration,
          );
          current = _notes.byId(current.id) ?? current;
        }
      }

      // Pictures go up before the text that holds them: the ops carry the
      // server ids, and a note described before its images exist would
      // describe pictures nobody could ask for.
      if (_images != null &&
          current.attachments.any((ref) => !ref.isUploaded)) {
        if (_uploading.add(current.id)) {
          unawaited(_uploadThenReconcile(current));
        }
        continue;
      }

      final record = _docs.get(current.id);
      if (record == null) {
        if (!_caughtUp.contains(spaceId)) continue;
        _seed(current, spaceId);
      } else {
        _reconcileInto(record, current, spaceId);
      }
      _notes.markSynced(notes: [current]);
    }

    for (final stone in _notes.dirtyTombstones) {
      final spaceId = stone.spaceId ?? personal.id;
      if (_needsPro.contains(spaceId)) continue;
      final space = _keyring.byId(spaceId);
      if (space == null || !space.canEdit) continue;
      final record = _docs.get(stone.id);
      // A tombstone beside a live copy elsewhere is a move, and the move's
      // own entry tells the server where the note went.
      final live = _notes.byId(stone.id);
      if (live != null && (live.spaceId ?? personal.id) != spaceId) {
        if (record != null && record.spaceId == spaceId) continue;
        _notes.markSynced(tombstones: [stone]);
        continue;
      }
      if (record == null) {
        // Deleted before it was ever seeded: the server never had it.
        _notes.markSynced(tombstones: [stone]);
        continue;
      }
      if (record.outbox.any((entry) => entry.deleted == true)) continue;
      record.outbox.add(
        OutboxEntry(id: _nextRequestId(), spaceId: spaceId, deleted: true),
      );
      _docs.markDirty(stone.id);
    }
  }

  Future<void> _uploadThenReconcile(Note note) async {
    final images = _images;
    if (images == null) return;
    try {
      final uploaded = await images.upload(note);
      if (!identical(uploaded, note)) {
        // One ref at a time, against the note as it is *now*. The upload may
        // have taken a while, and the user may have been typing throughout.
        for (final ref in uploaded.attachments) {
          if (ref.attachmentId == null) continue;
          _notes.updateAttachment(note.id, ref.hash, (current) {
            // A picture minted two ids, and both have to land or the preview
            // is orphaned on the server and re-uploaded on every sync.
            if (current is NoteImageRef && ref is NoteImageRef) {
              return current.copyWith(
                attachmentId: ref.attachmentId,
                thumbId: ref.thumbId,
              );
            }
            return current.copyWith(attachmentId: ref.attachmentId);
          });
        }
      }
      if (uploaded.attachments.every((ref) => ref.isUploaded)) {
        _scheduleReconcile();
      } else {
        // A failed object-store request used to start another upload in the
        // next microtask forever. Backoff keeps RAM, radio and quota use flat
        // while the network or storage service is unavailable.
        _scheduleRetry();
      }
    } on SyncException catch (error) {
      debugPrint('KapyNotes: image upload deferred: ${error.message}');
    } finally {
      _uploading.remove(note.id);
    }
  }

  /// The note's first bytes on the server: a snapshot, marked as a seed so
  /// two devices holding the same old note cannot both write it.
  void _seed(Note note, String spaceId) {
    final record = _docs.create(note.id, spaceId);
    record.doc.reconcile(
      body: note.body,
      formats: note.formats,
      attachments: note.attachments,
      createdAt: note.createdAt,
      archivedAt: note.archivedAt,
      now: _now(),
    );
    record.outbox.add(
      OutboxEntry(
        id: _nextRequestId(),
        spaceId: spaceId,
        snapshot: record.doc.toSnapshot(),
        covers: _state.cursorFor(spaceId),
        seed: true,
      ),
    );
    _docs.markDirty(note.id);
  }

  void _reconcileInto(DocRecord record, Note note, String spaceId) {
    final ops = record.doc.reconcile(
      body: note.body,
      formats: note.formats,
      attachments: note.attachments,
      createdAt: note.createdAt,
      archivedAt: note.archivedAt,
      now: _now(),
    );
    var changed = false;
    if (record.spaceId != spaceId) {
      // Moved. The whole document seeds the new space, and the server
      // tombstones the old one in the same transaction.
      record.outbox.removeWhere((entry) => !entry.inFlight);
      record.outbox.add(
        OutboxEntry(
          id: _nextRequestId(),
          spaceId: spaceId,
          snapshot: record.doc.toSnapshot(),
          covers: _state.cursorFor(spaceId),
          seed: true,
          from: record.spaceId,
        ),
      );
      record.spaceId = spaceId;
      record.opsSinceSnapshot = 0;
      record.ownOpsSinceSnapshot = 0;
      changed = true;
    } else if (ops.isNotEmpty) {
      record.opsSinceSnapshot++;
      record.ownOpsSinceSnapshot++;
      // Coalesce with an unsent batch: a burst of typing is one op.
      final last = record.outbox.isEmpty ? null : record.outbox.last;
      if (last != null &&
          !last.inFlight &&
          last.ops != null &&
          last.spaceId == spaceId) {
        last.ops!.addAll(ops);
      } else {
        record.outbox.add(
          OutboxEntry(
            id: _nextRequestId(),
            spaceId: spaceId,
            ops: List<Object?>.of(ops),
            deviceSeq: ++record.deviceSeq,
          ),
        );
      }
      changed = true;
    }
    if (changed) _docs.markDirty(note.id);
  }

  // -------------------------------------------------------------------------
  // Send: the outbox drains
  // -------------------------------------------------------------------------

  void _scheduleSend() {
    if (_disposed || _vault == null || _docs.pendingCount == 0) return;
    _sendTimer ??= Timer(sendDelay, () {
      _sendTimer = null;
      unawaited(_drain());
    });
  }

  /// Sends the head of every note's outbox that is not already in flight.
  /// Over the socket when it is up; over HTTP when it is not, in which case
  /// the answer comes back inline.
  Future<void> _drain() async {
    final vault = _vault;
    if (vault == null || _disposed) return;
    for (final record in _docs.records.toList()) {
      if (record.outbox.isEmpty) continue;
      final entry = record.outbox.first;
      if (entry.inFlight) continue;
      // What was queued before the refusal waits in the outbox, in order.
      if (_needsPro.contains(entry.spaceId) ||
          (entry.from != null && _needsPro.contains(entry.from))) {
        continue;
      }
      final note = _notes.byId(record.noteId);
      final push = await _preparePush(vault, record, entry, note);
      if (push == null) continue;
      entry.inFlight = true;
      final socket = _socket;
      if (_live && socket != null) {
        _awaiting[entry.id] = (record: record, entry: entry);
        if (!socket.send({'t': 'push', 'id': entry.id, ...push.toJson()})) {
          _awaiting.remove(entry.id);
          entry.inFlight = false;
        }
      } else {
        try {
          final result = await _api.pushOps(push);
          _acknowledge(record, entry, result);
        } on SyncRefusedException catch (error) {
          entry.inFlight = false;
          if (error.code == proRequiredCode) {
            final spaceId = error.body['spaceId'];
            _holdForPro(spaceId is String ? spaceId : entry.spaceId);
            continue;
          }
          await _refused(record, entry, error.code, error.body);
        } on SyncException catch (error) {
          entry.inFlight = false;
          _lastError = error.message;
          if (error is SyncTransientException) {
            _setStatus(SyncStatus.offline);
            _scheduleRetry();
          } else if (error is SyncAuthException) {
            _setStatus(SyncStatus.signedOut);
          } else if (error is SyncOutdatedException) {
            _setStatus(SyncStatus.outdated);
          }
          return;
        }
      }
    }
  }

  /// Seals one entry under the note's current key. Null when the note has no
  /// key to seal under yet, in which case the entry waits.
  Future<OpsPush?> _preparePush(
    Vault vault,
    DocRecord record,
    OutboxEntry entry,
    Note? note,
  ) async {
    final space = _keyring.byId(entry.spaceId);
    if (space == null || !space.canEdit) return null;
    if (entry.from case final sourceId?) {
      final source = _keyring.byId(sourceId);
      if (source == null || !source.canEdit) return null;
    }
    Uint8List? contentKey;
    var epoch = 1;
    WireNoteKey? key;
    if (space.isTeam) {
      final spaceKey = _keyring.keyFor(space.id);
      if (spaceKey == null) return null;
      contentKey = note?.contentKey ?? record.keys.values.lastOrNull;
      if (contentKey == null) {
        if (entry.deleted == true &&
            entry.ops == null &&
            entry.snapshot == null) {
          // A bare tombstone needs no key.
        } else {
          return null;
        }
      } else {
        epoch = note?.contentKeyEpoch ?? record.keys.keys.reduce(max);
        key = WireNoteKey(
          wrapped: await wrapKey(contentKey, spaceKey),
          keyGeneration: space.keyGeneration,
          contentKeyEpoch: epoch,
        );
      }
    }

    final ops = <WireOp>[];
    if (entry.ops != null) {
      final plaintext = _encode({'ops': entry.ops});
      ops.add(
        WireOp(
          deviceSeq: entry.deviceSeq!,
          epoch: epoch,
          engine: fugueEngine,
          payload: await vault.sealRaw(plaintext, contentKey),
        ),
      );
    }
    WireSnapshot? snapshot;
    final snap = entry.snapshot;
    // A rotation — a local epoch ahead of the server's — must carry the
    // whole document under the new key; so must a seed; and every
    // `snapshotEvery` ops somebody writes one so nobody replays a year.
    final rotating = record.serverEpoch != 0 && epoch > record.serverEpoch;
    if (snap != null) {
      snapshot = WireSnapshot(
        covers: entry.covers,
        epoch: epoch,
        engine: fugueEngine,
        payload: await vault.sealRaw(_encode({'snap': snap}), contentKey),
      );
    } else if (rotating || (_dueForSnapshot(record) && entry.ops != null)) {
      snapshot = WireSnapshot(
        covers: _state.cursorFor(entry.spaceId),
        epoch: epoch,
        engine: fugueEngine,
        payload: await vault.sealRaw(
          _encode({'snap': record.doc.toSnapshot()}),
          contentKey,
        ),
      );
    }

    return OpsPush(
      spaceId: entry.spaceId,
      noteId: record.noteId,
      ops: ops,
      key: key,
      deleted: entry.deleted,
      from: entry.from,
      seed: entry.seed,
      snapshot: snapshot,
    );
  }

  bool _dueForSnapshot(DocRecord record) =>
      record.opsSinceSnapshot >= snapshotEvery &&
      record.ownOpsSinceSnapshot * 4 >= snapshotEvery;

  static Uint8List _encode(Map<String, Object?> json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  Future<void> _onAck(Map<String, Object?> message) async {
    final id = message['id'];
    if (id is! String) return;
    final waiting = _awaiting.remove(id);
    if (waiting == null) return;
    final error = message['error'];
    final result = message['result'];
    if (error is String) {
      waiting.entry.inFlight = false;
      final status = message['status'];
      if (status is int && status >= 500) {
        _scheduleRetry();
        return;
      }
      if (error == proRequiredCode) {
        // The socket's ack names no space; the entry does.
        final spaceId = message['spaceId'];
        _holdForPro(spaceId is String ? spaceId : waiting.entry.spaceId);
        return;
      }
      await _refused(waiting.record, waiting.entry, error, message);
      return;
    }
    if (result is Map<String, Object?>) {
      _acknowledge(
        waiting.record,
        waiting.entry,
        OpsPushResult.fromJson(result),
      );
    }
  }

  void _acknowledge(DocRecord record, OutboxEntry entry, OpsPushResult result) {
    _servedAgain(entry.spaceId);
    record.outbox.remove(entry);
    record.seeded = true;
    final note = _notes.byId(record.noteId);
    if (note != null && note.spaceId != null) {
      record.serverEpoch = note.contentKeyEpoch;
    }
    if (result.snapshotSeq != null) {
      record.opsSinceSnapshot = 0;
      record.ownOpsSinceSnapshot = 0;
    }
    if (entry.deleted != null) {
      final stone = _notes.tombstones.where(
        (s) =>
            s.id == record.noteId &&
            (s.spaceId ?? _keyring.personal?.id) == entry.spaceId,
      );
      if (stone.isNotEmpty) _notes.markSynced(tombstones: stone.toList());
    }
    if (entry.from != null) {
      // The server tombstoned the old space in the same transaction.
      final stones = _notes.tombstones.where(
        (s) =>
            s.id == record.noteId &&
            (s.spaceId ?? _keyring.personal?.id) == entry.from,
      );
      if (stones.isNotEmpty) _notes.markSynced(tombstones: stones.toList());
    }
    _docs.markDirty(record.noteId);
    _state.recordSync(_now());
    if (_status == SyncStatus.offline || _status == SyncStatus.failed) {
      _lastError = null;
      _setStatus(SyncStatus.idle);
    }
    _scheduleSend();
    notifyListeners();
  }

  /// The server refused a push for a reason it named. Most are answered by
  /// refreshing what this device knows and sending again.
  Future<void> _refused(
    DocRecord record,
    OutboxEntry entry,
    String code,
    Map<String, Object?> body,
  ) async {
    final vault = _vault;
    if (vault == null) return;
    switch (code) {
      case 'seeded':
        // Somebody else's copy of this note got there first. Ours goes —
        // unless theirs has already arrived and replaced it, in which case
        // only this entry does — and the local text is reconciled onto
        // theirs, which the subscription delivers if it has not yet.
        if (record.seeded) {
          record.outbox.remove(entry);
          _docs.markDirty(record.noteId);
        } else {
          _docs.remove(record.noteId);
        }
        if (_notes.byId(record.noteId) != null) _notes.touch(record.noteId);
        if (entry.from != null) {
          // A move that raced: the destination already holds it.
          unawaited(syncNow());
        }
      case 'content-key-epoch':
        await _adoptServerKey(vault, record.noteId, body);
        _scheduleSend();
      case 'stale-key-generation':
      case 'not a member of this space':
      case 'move-raced':
        unawaited(syncNow());
      case 'a content-key rotation carries a snapshot under the new epoch':
        // A rotation went up without its snapshot: make the next send one.
        record.opsSinceSnapshot = snapshotEvery;
        record.ownOpsSinceSnapshot = snapshotEvery;
        _scheduleSend();
      case proRequiredCode:
        // The entry stays exactly as it is, to go once the space is covered.
        _holdForPro(entry.spaceId);
      default:
        // Something this build cannot answer. The entry is replaced by a
        // snapshot of the whole document, which carries every op it held,
        // and the failure is shown rather than retried in a loop.
        debugPrint('KapyNotes: push refused: $code');
        record.outbox.remove(entry);
        if (entry.deleted == null) {
          record.outbox.insert(
            0,
            OutboxEntry(
              id: _nextRequestId(),
              spaceId: entry.spaceId,
              snapshot: record.doc.toSnapshot(),
              covers: _state.cursorFor(entry.spaceId),
              seed: !record.seeded,
              from: entry.from,
            ),
          );
        }
        _docs.markDirty(record.noteId);
        _lastError = code;
        _setStatus(SyncStatus.failed);
    }
  }

  /// The server holds a newer content key for a note this device is about
  /// to write. Take it, keep the local text, and let the write go up under it.
  Future<void> _adoptServerKey(
    Vault vault,
    String noteId,
    Map<String, Object?> body,
  ) async {
    final spaceId = body['spaceId'];
    if (spaceId is! String) return;
    await _keyring.refresh(_api, vault);
    final space = _keyring.byId(spaceId);
    final spaceKey = _keyring.keyFor(spaceId);
    if (space == null || spaceKey == null) return;
    for (final wire in await _api.fetchNoteKeys(spaceId)) {
      if (wire.noteId != noteId) continue;
      final content = await unwrapKey(wire.wrapped, spaceKey);
      if (content == null) return;
      _docs.get(noteId)?.keys[wire.contentKeyEpoch] = content;
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
    if (local == null) return;
    _notes.adoptKey(
      noteId,
      contentKey: local.contentKey ?? randomKey(),
      contentKeyEpoch: 1,
      contentKeyGeneration: space.keyGeneration,
    );
  }

  // -------------------------------------------------------------------------
  // Apply: the server's log lands
  // -------------------------------------------------------------------------

  Future<void> _pullAllOverHttp() async {
    final asking = _askAboutPro;
    _askAboutPro = false;
    for (final space in _keyring.spaces) {
      if (space.isTeam && !_keyring.holdsKey(space.id)) continue;
      if (_needsPro.contains(space.id) && !asking) continue;
      try {
        for (var page = 0; page < 100; page++) {
          final batch = await _api.pullOps(
            space: space.id,
            after: _state.cursorFor(space.id),
          );
          if (!batch.isEmpty) await _applyBatch(_vault!, batch);
          if (!batch.hasMore) break;
        }
      } on SyncRefusedException catch (error) {
        if (error.code != proRequiredCode) rethrow;
        // One space refused is not the pass refused: the rest still come.
        _holdForPro(space.id);
        continue;
      }
      _servedAgain(space.id);
      _caughtUp.add(space.id);
    }
  }

  /// The server refused [spaceId] for want of Pro. See [_needsPro].
  void _holdForPro(String spaceId) {
    _subscribed.remove(spaceId);
    // Its log is no longer being followed, so it has to be caught up again
    // before anything new is seeded into it.
    _caughtUp.remove(spaceId);
    if (_needsPro.add(spaceId) && !_disposed) notifyListeners();
  }

  /// The server served [spaceId] again, so whatever held it has changed.
  void _servedAgain(String spaceId) {
    if (_needsPro.remove(spaceId) && !_disposed) notifyListeners();
  }

  /// Applies one page of one space's log, in seq order, and moves the
  /// cursor past it.
  Future<void> _applyBatch(Vault vault, OpsBatch batch) async {
    await _docs.load();
    // Anything typed and not yet absorbed goes into the documents first, so
    // the render at the end of this cannot overwrite it.
    _reconcileDirty();

    final space = _keyring.byId(batch.spaceId);
    if (space == null) return;
    final storedSpaceId = space.isPersonal ? null : space.id;
    final personalId = _keyring.personal?.id;

    final items = <_LogItem>[
      for (final op in batch.ops) _LogItem.op(op),
      for (final snap in batch.snapshots) _LogItem.snapshot(snap),
    ]..sort((a, b) => a.seq.compareTo(b.seq));

    final touched = <String, _Touched>{};
    for (final item in items) {
      if (item.seq <= _state.cursorFor(batch.spaceId)) continue;
      final noteId = item.noteId;
      final touch = touched.putIfAbsent(noteId, () => _Touched());
      touch.deleted = item.deleted;
      touch.at = item.at;

      var record = _docs.get(noteId);
      var fresh = record == null;
      if (record == null) {
        record = _docs.create(noteId, batch.spaceId);
      } else if (!record.seeded && item.deviceId != _state.deviceId) {
        // This device seeded the note and so did another, and theirs won:
        // its history is what arrives here. Ours is discarded before
        // anything merges, or the same words would land twice under two
        // sets of ids. The local text is reconciled onto theirs afterwards.
        record.doc = NoteDoc(replica: _docs.replica);
        record.outbox.removeWhere((entry) => !entry.inFlight);
        record.deviceSeq = 0;
        fresh = true;
      }
      if (fresh) {
        touch.arrived = true;
        touch.localBefore ??= _notes.byId(noteId);
      }
      record.seeded = true;
      if (!item.isMarker && item.epoch > record.serverEpoch) {
        record.serverEpoch = item.epoch;
      }
      if (record.spaceId != batch.spaceId) {
        // The log says the note is here now, wherever the local copy sits.
        record.spaceId = batch.spaceId;
      }

      if (item.isMarker) {
        _docs.markDirty(noteId);
        continue;
      }
      if (item.deviceId == _state.deviceId && !fresh && !item.isSnapshot) {
        // Our own op, echoed back: already applied when it was made.
        record.opsSinceSnapshot++;
        continue;
      }
      if (item.engine != fugueEngine) {
        debugPrint('KapyNotes: op in unknown engine ${item.engine}');
        continue;
      }

      Uint8List? contentKey;
      if (space.isTeam) {
        contentKey = await _contentKeyFor(record, noteId, space, item.epoch);
        if (contentKey == null) {
          debugPrint(
            'KapyNotes: no key for note $noteId at epoch ${item.epoch}',
          );
          continue;
        }
      }
      final opened = await vault.openRaw(item.payload, contentKey);
      if (opened == null) {
        debugPrint('KapyNotes: could not open op ${item.seq} of $noteId');
        continue;
      }
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(opened));
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      final ops = decoded['ops'];
      final snap = decoded['snap'];
      var changed = false;
      if (ops is List) {
        changed = record.doc.apply(ops);
        record.opsSinceSnapshot++;
      } else if (snap is Map) {
        changed = record.doc.mergeSnapshot(
          Map<String, Object?>.of(snap.cast()),
        );
        if (item.isSnapshot) {
          record.opsSinceSnapshot = 0;
          record.ownOpsSinceSnapshot = 0;
        }
      }
      if (changed) touch.changed = true;
      _docs.markDirty(noteId);
    }

    for (final entry in touched.entries) {
      _render(
        entry.key,
        entry.value,
        space: space,
        storedSpaceId: storedSpaceId,
        personalId: personalId,
      );
    }
    _state.recordCursor(batch.spaceId, batch.cursor);
    if (touched.isNotEmpty) notifyListeners();
  }

  /// Writes a document back into the note list after a batch touched it.
  void _render(
    String noteId,
    _Touched touch, {
    required Space space,
    required String? storedSpaceId,
    required String? personalId,
  }) {
    final record = _docs.get(noteId);
    if (record == null) return;
    final at = touch.at ?? _now();
    final local = _notes.byId(noteId);

    if (touch.deleted) {
      if (local != null &&
          (local.spaceId ?? personalId) == (storedSpaceId ?? personalId)) {
        _notes.applyRemote(
          tombstones: [
            Tombstone(id: noteId, deletedAt: at, spaceId: storedSpaceId),
          ],
        );
      } else if (local == null) {
        _notes.applyRemote(
          tombstones: [
            Tombstone(id: noteId, deletedAt: at, spaceId: storedSpaceId),
          ],
        );
      }
      return;
    }

    // A local delete not yet acknowledged wins over anything the log says
    // while it is on its way up.
    final localStone = _notes.tombstones.where(
      (s) =>
          s.id == noteId &&
          (s.spaceId ?? personalId) == (storedSpaceId ?? personalId),
    );
    if (localStone.any((s) => s.isDirty)) return;

    if (!touch.changed && !touch.arrived && local != null) return;

    final view = record.doc.view;
    Uint8List? contentKey = local?.contentKey;
    var epoch = local?.contentKeyEpoch ?? 1;
    var generation = local?.contentKeyGeneration ?? 1;
    if (space.isTeam && record.keys.isNotEmpty) {
      final latest = record.keys.keys.reduce(max);
      if (contentKey == null || latest > epoch) {
        contentKey = record.keys[latest];
        epoch = latest;
        generation = record.keyGeneration ?? space.keyGeneration;
      }
    }

    var rendered = Note(
      id: noteId,
      body: view.body,
      formats: view.formats,
      attachments: view.attachments,
      createdAt: view.createdAt ?? local?.createdAt ?? at,
      updatedAt: at,
      archivedAt: view.archivedAt,
      syncedAt: at,
      spaceId: storedSpaceId,
      contentKey: contentKey,
      contentKeyEpoch: epoch,
      contentKeyGeneration: generation,
    );

    final before = touch.localBefore;
    if (touch.arrived && before != null && before.body != view.body) {
      // The first time this note's history reaches a device that already
      // holds a copy of its own. Newer local words go onto the document as
      // ops; older ones are kept beside it rather than lost — once, here,
      // and never again, because from now on every edit is an op.
      if (before.updatedAt.isAfter(at)) {
        _notes.touch(noteId);
        _scheduleReconcile();
        return;
      }
      _notes.keepCopy(before);
    }
    _notes.applyDoc(rendered);
  }

  /// The content key an op was sealed under: from the note, from the
  /// session's cache, or from the server, in that order.
  Future<Uint8List?> _contentKeyFor(
    DocRecord record,
    String noteId,
    Space space,
    int epoch,
  ) async {
    final cached = record.keys[epoch];
    if (cached != null) return cached;
    final local = _notes.byId(noteId);
    if (local?.contentKey != null && local!.contentKeyEpoch == epoch) {
      record.keys[epoch] = local.contentKey!;
      return local.contentKey;
    }
    final spaceKey = _keyring.keyFor(space.id);
    if (spaceKey == null) return null;
    try {
      for (final wire in await _api.fetchNoteKeys(space.id)) {
        final id = wire.noteId;
        if (id == null) continue;
        final content = await unwrapKey(wire.wrapped, spaceKey);
        if (content == null) continue;
        final target = _docs.get(id);
        if (target != null) {
          target.keys[wire.contentKeyEpoch] = content;
          target.keyGeneration =
              wire.contentKeyGeneration ?? wire.keyGeneration;
        }
      }
    } on SyncException catch (error) {
      debugPrint('KapyNotes: note keys unavailable: ${error.message}');
    }
    return record.keys[epoch];
  }

  // -------------------------------------------------------------------------
  // Duties: what the list of spaces asks this device to do
  // -------------------------------------------------------------------------

  /// Grants, rotations and trips home. Each is best-effort and independent:
  /// a refusal on one — another device got there first — must not stop the
  /// rest, so refusals are logged and the next pass sees the updated list.
  Future<void> _duties(Vault vault) async {
    var changed = false;
    for (final space in _keyring.teams) {
      final key = _keyring.keyFor(space.id);
      if (key == null || !space.canEdit) continue;
      try {
        // Handing a key to somebody new grows the space, which needs Pro;
        // rotating and bringing notes home are ways out, and never do.
        if (!_needsPro.contains(space.id) && await _grantWaiting(space, key)) {
          changed = true;
        }
        if (space.rotationPending && await _rotate(space, key)) changed = true;
        if (space.owedTripHome && space.isOwner && await bringHome(space.id)) {
          changed = true;
        }
      } on SyncRefusedException catch (error) {
        debugPrint('KapyNotes: duty on ${space.id} refused: ${error.code}');
        if (error.code == proRequiredCode) {
          // A way out can still meet it — a trip home writes into the personal
          // space — so it is held under whichever space said so.
          final spaceId = error.body['spaceId'];
          _holdForPro(spaceId is String ? spaceId : space.id);
        } else {
          changed = true;
        }
      }
    }
    if (changed) await _keyring.refresh(_api, vault);
  }

  /// Any Editor holding the key wraps it for a member who has none.
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
      if (content == null) return false;
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

  /// Ends a team space and brings its notes home: every note moves to the
  /// personal space as a seed under the master key, over HTTP, one at a
  /// time, and then the space goes. Nothing is deleted. Returns false if
  /// the notes are not all this device's to move yet.
  Future<bool> bringHome(String spaceId) async {
    final vault = _vault;
    final personal = _keyring.personal;
    final space = _keyring.byId(spaceId);
    if (vault == null || personal == null || space == null) return false;
    await _docs.load();
    _reconcileDirty();
    final mine = _notes.notesIn(spaceId);
    if (mine.any((note) => note.isDirty)) return false;
    for (final note in mine) {
      final record = _docs.get(note.id);
      if (record == null || record.hasPending) return false;
    }

    final at = _now();
    for (final note in mine) {
      final record = _docs.get(note.id)!;
      final snapshot = WireSnapshot(
        covers: _state.cursorFor(personal.id),
        epoch: 1,
        engine: fugueEngine,
        payload: await vault.sealRaw(
          _encode({'snap': record.doc.toSnapshot()}),
          null,
        ),
      );
      await _api.pushOps(
        OpsPush(
          spaceId: personal.id,
          noteId: note.id,
          from: spaceId,
          seed: true,
          snapshot: snapshot,
        ),
      );
      record.spaceId = personal.id;
      record.opsSinceSnapshot = 0;
      record.ownOpsSinceSnapshot = 0;
      record.keys.clear();
      _docs.markDirty(note.id);
    }
    await _api.stopSharing(spaceId, const []);
    _notes.bringHome(mine.map((note) => note.id), at: at);
    _state.forgetSpace(spaceId);
    _subscribed.remove(spaceId);
    _caughtUp.remove(spaceId);
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
      _subscribed.remove(spaceId);
      _caughtUp.remove(spaceId);
      for (final record in _docs.records.toList()) {
        if (record.spaceId == spaceId) _docs.remove(record.noteId);
      }
      if (kept.isNotEmpty) {
        debugPrint(
          'KapyNotes: kept ${kept.length} unsynced note(s) from a space '
          'this account left',
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Polling and retries
  // -------------------------------------------------------------------------

  /// The fallback, and only ever that: it runs while the socket is down and
  /// stops the moment it comes back.
  void _startPolling() {
    if (_disposed || _poll != null || !_foreground) return;
    _poll = Timer.periodic(pollInterval, (_) => unawaited(syncNow()));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void _scheduleRetry({bool soon = false}) {
    if (_disposed || _retryTimer != null) return;
    if (!soon) _failures++;
    final backoff = soon
        ? minRetry
        : minRetry * pow(2, min(max(_failures - 1, 0), 10)).toDouble();
    final capped = backoff > maxRetry ? maxRetry : backoff;
    final jitter = Random().nextDouble() * 0.3 + 0.85;
    _retryTimer = Timer(
      Duration(milliseconds: (capped.inMilliseconds * jitter).round()),
      () {
        _retryTimer = null;
        unawaited(syncNow());
      },
    );
  }

  String _nextRequestId() =>
      '${_state.deviceId.substring(0, 8)}-${++_requestCounter}-${_now().millisecondsSinceEpoch}';

  void _setStatus(SyncStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    stopTyping();
    _disposed = true;
    _notes.removeListener(_onNotesChanged);
    _sendTimer?.cancel();
    _retryTimer?.cancel();
    _presenceExpiryTimer?.cancel();
    _stopPolling();
    _disconnect();
    super.dispose();
  }
}

class _OutgoingPresence {
  const _OutgoingPresence({
    required this.noteId,
    required this.spaceId,
    required this.payload,
  });

  final String noteId;
  final String spaceId;
  final SealedBox payload;
}

class _RemotePresence {
  const _RemotePresence({
    required this.userId,
    required this.spaceId,
    required this.noteId,
    required this.expiresAt,
  });

  final String userId;
  final String spaceId;
  final String noteId;
  final DateTime expiresAt;
}

/// One entry of a space's log, op or snapshot, in the order it was written.
class _LogItem {
  _LogItem.op(WireStoredOp op)
    : seq = op.seq,
      noteId = op.noteId,
      deviceId = op.deviceId,
      epoch = op.epoch,
      engine = op.engine,
      payload = op.payload,
      deleted = op.deleted,
      at = op.at,
      isSnapshot = false,
      isMarker = op.isMarker;

  _LogItem.snapshot(WireStoredSnapshot snap)
    : seq = snap.seq,
      noteId = snap.noteId,
      deviceId = snap.deviceId,
      epoch = snap.epoch,
      engine = snap.engine,
      payload = snap.payload,
      deleted = snap.deleted,
      at = snap.at,
      isSnapshot = true,
      isMarker = false;

  final int seq;
  final String noteId;
  final String deviceId;
  final int epoch;
  final String engine;
  final SealedBox payload;
  final bool deleted;
  final DateTime at;
  final bool isSnapshot;
  final bool isMarker;
}

/// What a batch did to one note, for the render at the end.
class _Touched {
  bool changed = false;
  bool arrived = false;
  bool deleted = false;
  DateTime? at;

  /// The local copy as it stood before the note's history first arrived.
  Note? localBefore;
}
