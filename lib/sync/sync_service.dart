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
import 'presence.dart';
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
class SyncService extends ChangeNotifier implements RemoteCaretSource {
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
    this.presenceThrottle = const Duration(milliseconds: 90),
    this.typingIdle = const Duration(milliseconds: 1500),
    this.presenceLinger = const Duration(milliseconds: 1500),
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

  /// Pushes awaiting an acknowledgement, by request id.
  final Map<String, ({DocRecord record, OutboxEntry entry})> _awaiting = {};

  /// Between frames while a caret moves: a dozen a second reads as live, and
  /// a held arrow key does not become a stream of relayed frames.
  final Duration presenceThrottle;

  /// How long after the last keystroke somebody stops counting as typing.
  final Duration typingIdle;

  /// How long a caret stays after its device says it has gone. It covers the
  /// stop-then-start a typist sends on pausing (see [_flushPresence]), so
  /// that does not flicker, and reads as leaving rather than vanishing.
  final Duration presenceLinger;

  /// Presence is deliberately bounded and ephemeral. One local frame is kept
  /// and refreshed while this device is in a shared note, and at most one
  /// remote frame per device is kept until its short expiry.
  static const _presenceTtl = Duration(seconds: 30);
  static const _presenceRefresh = Duration(seconds: 10);

  /// How long a note counts as open here with nothing happening in it. Long
  /// enough to read a page; short enough that a window left open over lunch
  /// does not keep a caret in somebody else's note all afternoon.
  static const _presenceIdle = Duration(minutes: 3);
  static const _maxRemotePresence = 128;
  final Map<String, _RemotePresence> _remotePresence = {};
  final Map<String, int> _presenceMessageVersions = {};
  int _presenceMessageSerial = 0;
  final _Pulse _caretPulse = _Pulse();

  /// What this device is doing in a shared note, as last reported.
  _LocalPresence? _local;

  /// The frame last written for it, which a stop has to repeat exactly.
  _SentPresence? _sent;
  int _presenceGeneration = 0;
  Future<void> _presenceChain = Future<void>.value();
  Timer? _typingTimer;
  Timer? _presenceSendTimer;
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

  /// Everyone else with [noteId] open, one entry per person however many of
  /// their devices have it, in the order they arrived.
  List<Collaborator> collaboratorsIn(String noteId) =>
      _collaborators((presence) => presence.noteId == noteId);

  /// Everyone else with any note of [spaceId] open.
  List<Collaborator> collaboratorsInSpace(String spaceId) =>
      _collaborators((presence) => presence.spaceId == spaceId);

  /// Every note somebody else has open right now, for the note list.
  Map<String, List<Collaborator>> get collaboratorsByNote {
    final noteIds = {
      for (final presence in _remotePresence.values) presence.noteId,
    };
    return {
      for (final noteId in noteIds)
        if (collaboratorsIn(noteId) case final people when people.isNotEmpty)
          noteId: people,
    };
  }

  /// Whoever is typing in [noteId] right now, alphabetically, so the footer
  /// does not reshuffle its sentence as they take turns.
  List<Collaborator> typistsIn(String noteId) => List.unmodifiable(
    collaboratorsIn(noteId).where((person) => person.typing).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
  );

  /// What to call each collaborator typing in [noteId], alphabetically.
  List<String> typingNamesFor(String noteId) =>
      List.unmodifiable([for (final person in typistsIn(noteId)) person.name]);

  List<Collaborator> _collaborators(bool Function(_RemotePresence) where) {
    final now = DateTime.now();
    final byUser = <String, _RemotePresence>{};
    for (final presence in _remotePresence.values) {
      if (!where(presence) || !presence.expiresAt.isAfter(now)) continue;
      final seen = byUser[presence.userId];
      if (seen == null || (presence.typing && !seen.typing)) {
        byUser[presence.userId] = presence;
      }
    }
    return [for (final presence in byUser.values) _collaborator(presence)];
  }

  Collaborator _collaborator(_RemotePresence presence) {
    final space = _keyring.byId(presence.spaceId);
    final member = space?.member(presence.userId);
    return Collaborator(
      userId: presence.userId,
      name: space?.shortNameOf(presence.userId) ?? 'Someone',
      fullName: member?.displayName ?? 'Someone',
      image: member?.image,
      typing: presence.typing,
    );
  }

  @override
  Listenable get caretChanges => _caretPulse;

  /// Other people's carets in [noteId], resolved against the note's document.
  ///
  /// A caret whose characters have not arrived yet — the frame outran the ops
  /// it points into — is drawn where that device's previous caret was, which
  /// is exactly right for text that has not changed here yet either.
  @override
  RemoteCarets caretsFor(String noteId) {
    if (_remotePresence.isEmpty || !_docs.isLoaded) return RemoteCarets.empty;
    final record = _docs.get(noteId);
    if (record == null) return RemoteCarets.empty;
    final now = DateTime.now();
    NoteDoc? doc;
    final carets = <RemoteCaret>[];
    for (final entry in _remotePresence.entries) {
      final presence = entry.value;
      if (presence.noteId != noteId || !presence.expiresAt.isAfter(now)) {
        continue;
      }
      final wanted = presence.selection;
      if (wanted == null) continue;
      doc ??= record.doc;
      final shown = _knows(doc, wanted)
          ? wanted
          : presence.fallback != null && _knows(doc, presence.fallback!)
          ? presence.fallback!
          : null;
      if (shown == null) continue;
      carets.add(
        RemoteCaret(
          id: entry.key,
          userId: presence.userId,
          name:
              _keyring.byId(presence.spaceId)?.shortNameOf(presence.userId) ??
              'Someone',
          base: doc.offsetOf(shown.base),
          extent: doc.offsetOf(shown.extent),
          typing: presence.typing,
          movedAt: presence.movedAt,
          leaving: presence.leaving,
        ),
      );
    }
    if (doc == null || carets.isEmpty) return RemoteCarets.empty;
    return RemoteCarets(text: doc.text, carets: List.unmodifiable(carets));
  }

  static bool _knows(NoteDoc doc, AnchoredSelection selection) =>
      doc.knows(selection.base) && doc.knows(selection.extent);

  /// Records what this device is doing in [noteId]: where its caret is, as
  /// offsets into [text], and whether that came with an edit.
  ///
  /// Cheap enough for every keystroke and every caret move. Nothing is sealed
  /// or sent here: frames go out at most every [presenceThrottle], and only
  /// when what they would say has changed. A note that is not shared, or not
  /// this account's to edit, ends any presence instead.
  void reportPresence(
    String noteId, {
    int? base,
    int? extent,
    String? text,
    bool edited = false,
  }) {
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
      leaveNote();
      return;
    }

    var local = _local;
    if (local == null || local.noteId != noteId || local.spaceId != spaceId) {
      leaveNote();
      local = _local = _LocalPresence(
        noteId: noteId,
        spaceId: spaceId,
        key: key,
      );
    } else {
      // A rotation replaces the space key; later frames seal under the new one.
      local.key = key;
    }
    if (base != null && extent != null && text != null) {
      local
        ..base = base
        ..extent = extent
        ..text = text;
    }
    if (edited) {
      local.typing = true;
      _typingTimer?.cancel();
      final typist = local;
      _typingTimer = Timer(typingIdle, () {
        if (!identical(_local, typist)) return;
        typist.typing = false;
        _schedulePresenceSend();
      });
    }
    _presenceIdleTimer?.cancel();
    _presenceIdleTimer = Timer(_presenceIdle, () => leaveNote(noteId));
    _schedulePresenceSend();
  }

  /// Records a keystroke in [noteId] without moving the reported caret.
  void reportTyping(String noteId) => reportPresence(noteId, edited: true);

  /// Ends this device's presence, or only if it is still in [noteId]: a
  /// disposed editor must not end the presence of the note that replaced it.
  void leaveNote([String? noteId]) {
    final local = _local;
    if (noteId != null && local?.noteId != noteId) return;
    _presenceGeneration++;
    _local = null;
    _typingTimer?.cancel();
    _typingTimer = null;
    _presenceSendTimer?.cancel();
    _presenceSendTimer = null;
    _presenceIdleTimer?.cancel();
    _presenceIdleTimer = null;
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = null;
    final sent = _sent;
    _sent = null;
    if (sent != null) _writePresence(sent.spaceId, sent.box, active: false);
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
    leaveNote();
    _disconnect();
    _stopPolling();
    unawaited(_docs.flush());
  }

  /// Signing out. Sync stops; the notes stay exactly where they are.
  void lock() {
    leaveNote();
    _vault = null;
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
      wanted[space.id] = _state.cursorFor(space.id);
    }
    if (wanted.isEmpty) return;
    if (socket.send({'t': 'sub', 'spaces': wanted})) {
      _subscribed.addAll(wanted.keys);
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
          _caughtUp.add(spaceId);
          _resendPresence(spaceId);
          _reconcileDirty();
          _scheduleSend();
        }
      case 'ack':
        await _onAck(message);
      case 'spaces':
        unawaited(syncNow());
      case 'error':
        final spaceId = message['spaceId'];
        if (spaceId is String) _subscribed.remove(spaceId);
        debugPrint('KapyNotes: socket error: ${message['error']}');
        unawaited(syncNow());
      case 'pong':
        break;
      case 'presence':
        await _onPresence(message);
    }
  }

  void _schedulePresenceSend() {
    _presenceSendTimer ??= Timer(presenceThrottle, () {
      _presenceSendTimer = null;
      _flushPresence();
    });
  }

  /// Seals and writes what this device is doing, if that has changed.
  ///
  /// The payload names the note under one of two keys, and the choice is the
  /// whole of the compatibility story. Builds before carets read any frame
  /// with a `noteId` as somebody typing, and hold it until a stop repeating
  /// that exact frame arrives. So a typing frame says `noteId`, a quiet one
  /// says `note` — which those builds pass over — and a typist who pauses
  /// withdraws the typing frame before announcing the quiet one, or they
  /// would be shown typing for as long as they sat in the note.
  void _flushPresence() {
    final local = _local;
    if (local == null || _disposed) return;
    final selection = _anchoredSelection(local);
    final plain = <String, Object?>{
      local.typing ? 'noteId' : 'note': local.noteId,
      'v': 2,
      if (selection != null) 'sel': selection.toJson(),
    };
    final json = jsonEncode(plain);
    final sent = _sent;
    if (sent != null && sent.json == json && sent.spaceId == local.spaceId) {
      return;
    }
    final generation = _presenceGeneration;
    final key = local.key;
    final typing = local.typing;
    // Padded to a fixed step, so the ciphertext's length says nothing about
    // how far into a note a caret is. JSON ignores the trailing spaces.
    final padded = json.padRight((json.length ~/ 64 + 1) * 64);
    _presenceChain = _presenceChain
        .then((_) async {
          final box = await sealBytes(
            Uint8List.fromList(utf8.encode(padded)),
            key,
          );
          if (_disposed ||
              generation != _presenceGeneration ||
              !identical(_local, local)) {
            return;
          }
          final previous = _sent;
          if (previous != null && previous.typing && !typing) {
            _writePresence(previous.spaceId, previous.box, active: false);
          }
          final next = _SentPresence(
            spaceId: local.spaceId,
            box: box,
            json: json,
            typing: typing,
          );
          _sent = next;
          _writePresence(next.spaceId, next.box, active: true);
          _presenceRefreshTimer ??= Timer.periodic(_presenceRefresh, (_) {
            final current = _sent;
            if (current != null) {
              _writePresence(current.spaceId, current.box, active: true);
            }
          });
        })
        .catchError((Object error) {
          debugPrint('KapyNotes: presence not sent: $error');
        });
  }

  /// The reported caret as the characters it sits after, or null while the
  /// note has no document to anchor into yet.
  AnchoredSelection? _anchoredSelection(_LocalPresence local) {
    final text = local.text;
    if (text == null || !_docs.isLoaded) return null;
    final record = _docs.get(local.noteId);
    if (record == null) return null;
    final doc = record.doc;
    var base = local.base;
    var extent = local.extent;
    final current = doc.text;
    if (text != current) {
      // The editor can hold blank lines an append session has not committed,
      // or be a keystroke past what the document has absorbed. Offsets are
      // mapped across the difference rather than pinned to whatever
      // character they happen to land beside.
      final edit = diffTexts(text, current);
      base = mapOffsetAcross(edit, base);
      extent = mapOffsetAcross(edit, extent);
    }
    return AnchoredSelection(doc.anchorAt(base), doc.anchorAt(extent));
  }

  void _writePresence(String spaceId, SealedBox box, {required bool active}) {
    final socket = _socket;
    if (socket == null || !_live || !_subscribed.contains(spaceId)) return;
    socket.send({
      't': 'presence',
      'spaceId': spaceId,
      'active': active,
      'payload': box.toJson(),
    });
  }

  void _resendPresence(String spaceId) {
    final sent = _sent;
    if (sent != null && sent.spaceId == spaceId) {
      _writePresence(spaceId, sent.box, active: true);
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
    final id = '$userId|$deviceId';
    final version = ++_presenceMessageSerial;
    _presenceMessageVersions[id] = version;
    if (!active) {
      _presenceMessageVersions.remove(id);
      _beginLeaving(id);
      return;
    }

    try {
      final box = SealedBox.fromJson(message['payload']);
      final key = _keyring.keyFor(spaceId);
      if (box == null || key == null) return;
      final clear = await openBytes(box, key);
      if (clear == null || _presenceMessageVersions[id] != version) return;
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map) return;
      // `noteId` is a typist, from this build or an older one; `note` is
      // somebody who is only there. See [_flushPresence].
      final typingIn = decoded['noteId'];
      final quietIn = decoded['note'];
      final noteId = typingIn is String
          ? typingIn
          : quietIn is String
          ? quietIn
          : null;
      if (noteId == null || noteId.isEmpty || noteId.length > 64) return;
      final typing = typingIn is String;
      final selection = AnchoredSelection.fromJson(decoded['sel']);

      final previous = _remotePresence[id];
      if (previous == null && _remotePresence.length >= _maxRemotePresence) {
        final oldest = _remotePresence.entries.reduce(
          (a, b) => a.value.expiresAt.isBefore(b.value.expiresAt) ? a : b,
        );
        _remotePresence.remove(oldest.key);
      }
      final now = DateTime.now();
      final samePlace =
          previous != null &&
          previous.noteId == noteId &&
          previous.spaceId == spaceId;
      final moved = !samePlace || previous.selection != selection;
      _remotePresence[id] = _RemotePresence(
        userId: userId,
        spaceId: spaceId,
        noteId: noteId,
        typing: typing,
        selection: selection,
        // Kept in case the new caret points at characters still on their way.
        fallback: samePlace
            ? (moved ? previous.selection : previous.fallback)
            : null,
        movedAt: moved || typing ? now : previous.movedAt,
        expiresAt: now.add(_presenceTtl),
      );
      _schedulePresenceExpiry();
      _caretPulse.pulse();
      final rosterChanged =
          !samePlace || previous.leaving || previous.typing != typing;
      if (rosterChanged && !_disposed) notifyListeners();
    } on FormatException {
      // Opaque presence from a newer or corrupt client is safe to ignore.
    } finally {
      if (_presenceMessageVersions[id] == version) {
        _presenceMessageVersions.remove(id);
      }
    }
  }

  /// A device said it has gone. Its typing ends at once; the rest lingers for
  /// [presenceLinger], in case what follows is the same person carrying on.
  void _beginLeaving(String id) {
    final presence = _remotePresence[id];
    if (presence == null || presence.leaving) return;
    _remotePresence[id] = presence.leavingBy(
      DateTime.now().add(presenceLinger),
    );
    _schedulePresenceExpiry();
    _caretPulse.pulse();
    if (presence.typing && !_disposed) notifyListeners();
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
    if (_remotePresence.length != before && !_disposed) {
      _caretPulse.pulse();
      notifyListeners();
    }
  }

  void _clearRemotePresence() {
    _presenceExpiryTimer?.cancel();
    _presenceExpiryTimer = null;
    _presenceMessageSerial++;
    _presenceMessageVersions.clear();
    if (_remotePresence.isEmpty) return;
    _remotePresence.clear();
    if (!_disposed) {
      _caretPulse.pulse();
      notifyListeners();
    }
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
          }, key: ref.key);
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
      hiddenAt: note.hiddenAt,
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
      hiddenAt: note.hiddenAt,
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
    for (final space in _keyring.spaces) {
      if (space.isTeam && !_keyring.holdsKey(space.id)) continue;
      for (var page = 0; page < 100; page++) {
        final batch = await _api.pullOps(
          space: space.id,
          after: _state.cursorFor(space.id),
        );
        if (!batch.isEmpty) await _applyBatch(_vault!, batch);
        if (!batch.hasMore) break;
      }
      _caughtUp.add(space.id);
    }
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
      hiddenAt: view.hiddenAt,
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
        if (await _grantWaiting(space, key)) changed = true;
        if (space.rotationPending && await _rotate(space, key)) changed = true;
        if (space.owedTripHome && space.isOwner && await bringHome(space.id)) {
          changed = true;
        }
      } on SyncRefusedException catch (error) {
        debugPrint('KapyNotes: duty on ${space.id} refused: ${error.code}');
        changed = true;
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
    leaveNote();
    _disposed = true;
    _notes.removeListener(_onNotesChanged);
    _sendTimer?.cancel();
    _retryTimer?.cancel();
    _presenceExpiryTimer?.cancel();
    _stopPolling();
    _disconnect();
    _caretPulse.dispose();
    super.dispose();
  }
}

/// A [ChangeNotifier] anyone holding it may fire.
class _Pulse extends ChangeNotifier {
  void pulse() => notifyListeners();
}

/// What this device last reported doing in a shared note.
class _LocalPresence {
  _LocalPresence({
    required this.noteId,
    required this.spaceId,
    required this.key,
  });

  final String noteId;
  final String spaceId;
  Uint8List key;

  /// The caret, as offsets into [text] — the editor's text when it reported,
  /// which the document may not have caught up with yet.
  int base = 0;
  int extent = 0;
  String? text;
  bool typing = false;
}

/// The frame last written, kept whole: the server only honours a stop that
/// repeats the frame it is stopping.
class _SentPresence {
  const _SentPresence({
    required this.spaceId,
    required this.box,
    required this.json,
    required this.typing,
  });

  final String spaceId;
  final SealedBox box;

  /// The plaintext it sealed, so an unchanged caret is not sent again.
  final String json;
  final bool typing;
}

class _RemotePresence {
  const _RemotePresence({
    required this.userId,
    required this.spaceId,
    required this.noteId,
    required this.typing,
    required this.selection,
    required this.fallback,
    required this.movedAt,
    required this.expiresAt,
    this.leaving = false,
  });

  final String userId;
  final String spaceId;
  final String noteId;
  final bool typing;

  /// Where their caret is. Null from a build that sends no caret.
  final AnchoredSelection? selection;

  /// Where it was before, for as long as [selection] names characters that
  /// have not arrived here yet.
  final AnchoredSelection? fallback;
  final DateTime movedAt;
  final DateTime expiresAt;

  /// Their device has said it is going; this is the lingering remainder.
  final bool leaving;

  _RemotePresence leavingBy(DateTime until) => _RemotePresence(
    userId: userId,
    spaceId: spaceId,
    noteId: noteId,
    typing: false,
    selection: selection,
    fallback: fallback,
    movedAt: movedAt,
    expiresAt: until,
    leaving: true,
  );
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
