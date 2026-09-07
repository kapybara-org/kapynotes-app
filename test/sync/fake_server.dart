import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/auth_api.dart';
import 'package:kapy_notes/sync/identity.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/key_wrap.dart';
import 'package:kapy_notes/sync/safety.dart';
import 'package:kapy_notes/sync/sealed_box.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_socket.dart';
import 'package:kapy_notes/sync/vault.dart';

/// An in-memory stand-in for the server, implementing the rules that matter
/// under protocol 3: one op log per space with a monotonic `seq`, a note
/// registry whose tombstone state is plaintext, membership on every read and
/// write, the key-generation and content-key-epoch rules of `ops.ts`, seeds
/// refused where history exists, moves as a seed here and a marker there,
/// snapshots that prune what they cover, and the grant, removal, rotation,
/// reap and stop-sharing rules of `server/src`.
///
/// Sockets are the same as `ws.ts`'s `Session`: subscribe, catch up in pages,
/// `synced`, then live ops — with anything that lands mid-catch-up held and
/// released after the pages. A push over the socket is acked and fanned out
/// to every subscribed socket in the space, the sender included.
///
/// Having one lets several devices of several accounts talk to the same store,
/// which is the only way to test the cases sharing actually gets wrong — a
/// member removed while another edits, a rotation racing a write, a space
/// that empties.
class FakeServer {
  final Map<String, FakeUser> users = {};
  final Map<String, FakeSpace> spaces = {};

  /// Requests recorded in order, so a test can assert on what was sent.
  /// HTTP calls by name (`pushOps`, `pullOps:<after>`, `spaces`, ...), socket
  /// frames as `ws:<t>`.
  final List<String> calls = [];

  /// The same, with who made each: every HTTP call and socket frame, by
  /// account and device, so a test can say which device asked.
  final List<({String user, String device, String call})> log = [];

  /// [calls], for one account.
  List<String> callsBy(String userId) => [
    for (final entry in log)
      if (entry.user == userId) entry.call,
  ];

  /// Every refusal the op log handed back, by code, in order.
  final List<String> refusals = [];

  /// Set to fail the next HTTP call, to exercise the offline and signed-out
  /// paths.
  SyncException? failNext;

  /// The server's clock. Ops are stamped with it; tests that compare a local
  /// `updatedAt` against an op's `at` set it.
  DateTime Function() now = DateTime.now;

  /// Stored attachment bytes, by id. Stands in for the bucket.
  final Map<String, Uint8List> blobs = {};

  /// Attachment rows: what note and space each belongs to, and whether its
  /// bytes have been confirmed.
  final Map<String, FakeAttachment> attachments = {};

  /// Attachments that were created but never confirmed, so a test can check
  /// that an abandoned upload is not billed.
  Map<String, ({String owner, int claimed})> get pendingBlobs => {
    for (final entry in attachments.entries)
      if (!entry.value.ready && !entry.value.deleted)
        entry.key: (owner: entry.value.owner, claimed: entry.value.bytes),
  };

  /// Bytes billed per owning user.
  final Map<String, int> storageUsed = {};

  /// Refuses an upload once the owner is over this. Generous by default so
  /// only a test that means to exercise quota ever hits it.
  int storageQuota = 1 << 30;

  /// Invitation emails "sent". A blocked sender's invitation never appears
  /// here, which is how a test sees the silence.
  final List<({String to, String token})> outbox = [];

  /// Reports filed, in order. `content` is null unless consent was given.
  final List<FakeReport> reports = [];

  /// The minimum protocol the server serves. Raise it to see a build refuse.
  int minProtocol = 1;

  /// Rows returned per page of the log, over HTTP and on the socket's
  /// catch-up alike, mirroring the real limit being smaller than the corpus.
  int pageSize = 200;

  // --- sockets ------------------------------------------------------------

  /// Connected sockets, by device id.
  final Map<String, FakeSocket> sockets = {};

  /// Sockets that asked to connect while [socketsAllowed] was false, or whose
  /// connection was dropped, and are waiting to try again.
  final Set<FakeSocket> _parked = {};

  /// Sessions by space, as `ws.ts` keeps them.
  final Map<String, Set<FakeSocket>> _bySpace = {};

  bool _socketsAllowed = true;

  /// False for a network that will not carry a socket: `connect()` never
  /// answers, and the client is left with HTTP. Setting it back to true lets
  /// every waiting socket in.
  bool get socketsAllowed => _socketsAllowed;
  set socketsAllowed(bool value) {
    _socketsAllowed = value;
    if (!value) return;
    for (final socket in _parked.toList()) {
      socket._scheduleOpen();
    }
  }

  /// True to fan pushes out to the sockets in the space and to tell sockets
  /// their spaces changed; false to drop everything the server would say
  /// unasked, standing in for a relay that lost its channel. Direct answers
  /// — acks, catch-up pages, `synced`, `pong` — still go. The devices should
  /// still converge — slower, on the poll.
  bool deliverLive = true;

  /// How long a dropped socket waits before coming back. The real one backs
  /// off from a second; this just needs to be later than "now".
  Duration reconnectDelay = const Duration(milliseconds: 5);

  /// Frames scheduled and not yet delivered, plus pushes still in their
  /// chain. Zero means the server has nothing more to say until asked.
  int _busy = 0;
  bool get isQuiet => _busy == 0;

  /// The address [deleteAccount] will accept for the default account,
  /// mirroring the real server's check that the caller named the account it
  /// meant.
  String get email => user('user-1').email;
  set email(String value) => user('user-1').email = value;

  /// True once the default account has been deleted, so a test can tell "the
  /// request was refused" apart from "the request never arrived".
  bool get deleted => users['user-1']?.deleted ?? false;

  /// The default account's key bundle.
  KeyBundle? get bundle => users['user-1']?.bundle;
  set bundle(KeyBundle? value) => user('user-1').bundle = value;

  /// Every note row across every space, keyed by note id, with a live copy
  /// taking precedence over a tombstone left behind by a move. What a
  /// single-account test means by "what the server holds".
  Map<String, FakeNoteRow> get rows {
    final all = <String, FakeNoteRow>{};
    for (final space in spaces.values) {
      for (final row in space.notes.values) {
        final existing = all[row.id];
        if (existing == null || (existing.isTombstone && !row.isTombstone)) {
          all[row.id] = row;
        }
      }
    }
    return all;
  }

  Map<String, FakeNoteRow> rowsIn(String spaceId) =>
      spaces[spaceId]?.notes ?? const {};

  /// One space's ops, in seq order.
  List<WireStoredOp> opsIn(String spaceId) =>
      List.unmodifiable(spaces[spaceId]?.ops ?? const []);

  /// One space's snapshots, by note id.
  Map<String, WireStoredSnapshot> snapshotsIn(String spaceId) =>
      Map.unmodifiable(spaces[spaceId]?.snapshots ?? const {});

  WireStoredSnapshot? snapshotOf(String spaceId, String noteId) =>
      spaces[spaceId]?.snapshots[noteId];

  int opSeqOf(String spaceId) => spaces[spaceId]?.opSeq ?? 0;

  /// Every byte of ciphertext the server holds for a space, as text, so a
  /// test can assert that a word never reached it.
  String ciphertextIn(String spaceId) {
    final space = spaces[spaceId];
    if (space == null) return '';
    final buffer = StringBuffer();
    for (final op in space.ops) {
      buffer.write(String.fromCharCodes(op.payload.cipherText));
    }
    for (final snap in space.snapshots.values) {
      buffer.write(String.fromCharCodes(snap.payload.cipherText));
    }
    return buffer.toString();
  }

  /// Gives an account a key bundle with no identity keys yet, the shape an
  /// account that unlocked before sharing existed has: the first sync then
  /// generates and publishes the identity keys, as it would in the app.
  KeyBundle seedBundle(String userId) {
    final account = user(userId);
    return account.bundle ??= KeyBundle(
      wrappedMasterKey: SealedBox(
        cipherText: Uint8List(48),
        nonce: Uint8List(24),
        version: 1,
      ),
      kdf: KdfParams(
        salt: Uint8List(16),
        memory: 8,
        iterations: 1,
        parallelism: 1,
      ),
    );
  }

  FakeUser user(String id) => users.putIfAbsent(
    id,
    () => FakeUser(
      id: id,
      email: id == 'user-1' ? 'someone@example.com' : '$id@example.com',
    ),
  );

  /// The personal space for [userId], created on first contact.
  FakeSpace personal(String userId) {
    for (final space in spaces.values) {
      if (space.kind == SpaceKind.personal && space.ownerId == userId) {
        return space;
      }
    }
    final space = FakeSpace(
      id: 'personal-$userId',
      kind: SpaceKind.personal,
      name: null,
      ownerId: userId,
    )..members[userId] = SpaceRole.owner;
    spaces[space.id] = space;
    return space;
  }

  // -------------------------------------------------------------------------
  // Socket plumbing
  // -------------------------------------------------------------------------

  /// Drops every connection, as a proxy reaping idle sockets would. Each
  /// socket comes back on its own after [reconnectDelay], unless
  /// [socketsAllowed] is off.
  void dropSockets() {
    for (final socket in sockets.values.toList()) {
      socket._dropped();
    }
  }

  bool isConnected(String device) => sockets.containsKey(device);

  void _addTo(String spaceId, FakeSocket socket) =>
      _bySpace.putIfAbsent(spaceId, () => {}).add(socket);

  void _removeFrom(String spaceId, FakeSocket socket) {
    final room = _bySpace[spaceId];
    if (room == null) return;
    room.remove(socket);
    if (room.isEmpty) _bySpace.remove(spaceId);
  }

  /// Writes a range of a space's log to every session subscribed to it —
  /// the sender included; the client recognises its own device id.
  void _deliverRange(String spaceId, int from, int to) {
    if (!deliverLive) return;
    final room = _bySpace[spaceId];
    if (room == null || room.isEmpty) return;
    final batch = _rangeOps(spaceId, from, to);
    for (final socket in room.toList()) {
      socket._deliver(spaceId, batch);
    }
  }

  /// Tells these users' sockets that their list of spaces changed, and drops
  /// any subscription that no longer holds.
  void announceUsers(Iterable<String> userIds) {
    if (!deliverLive) return;
    final wanted = userIds.toSet();
    for (final socket in sockets.values.toList()) {
      if (!wanted.contains(socket.userId)) continue;
      socket._send({'t': 'spaces'});
      socket._revalidate();
    }
  }

  /// A change to a space — a member, an invitation, a key — reaches every
  /// member's socket as a spaces change.
  void announceSpace(String spaceId) {
    final space = spaces[spaceId];
    if (space == null) return;
    announceUsers(space.members.keys);
  }

  // -------------------------------------------------------------------------
  // The op log
  // -------------------------------------------------------------------------

  Never _refuse(int status, String code, [Map<String, Object?> extra = const {}]) {
    refusals.add(code);
    throw SyncRefusedException(status, code, {'error': code, ...extra});
  }

  FakeSpace _member(String userId, String spaceId) {
    final space = spaces[spaceId];
    if (space == null || !space.members.containsKey(userId)) {
      _refuse(404, 'no such space');
    }
    return space;
  }

  bool _hasHistory(FakeSpace space, String noteId) =>
      space.snapshots.containsKey(noteId) ||
      space.ops.any((op) => op.noteId == noteId);

  void _forgetHistory(FakeSpace space, String noteId) {
    space.ops.removeWhere((op) => op.noteId == noteId);
    space.snapshots.remove(noteId);
  }

  /// Takes [n] seqs from a space's clock.
  ({int first, int last}) _allocate(FakeSpace space, int n) {
    space.opSeq += n;
    return (first: space.opSeq - n + 1, last: space.opSeq);
  }

  WireStoredOp _marker(FakeSpace space, String noteId, String device, String userId, int seq, bool deleted, DateTime at) =>
      WireStoredOp(
        seq: seq,
        spaceId: space.id,
        noteId: noteId,
        deviceId: device,
        authorId: userId,
        // Unique per space, and never a number a device would send.
        deviceSeq: -seq,
        epoch: 0,
        engine: markerEngine,
        payload: SealedBox.empty,
        deleted: deleted,
        at: at,
      );

  /// One push, applied whole or not at all. Mirrors `applyOps`.
  OpsPushResult pushOps(String userId, String device, OpsPush push) {
    if (push.from == push.spaceId) _refuse(400, 'a move names two different spaces');

    final spaceIds = [push.spaceId, if (push.from != null) push.from!];
    for (final id in spaceIds) {
      final space = spaces[id];
      if (space == null || !space.members.containsKey(userId)) {
        _refuse(403, 'not a member of this space', {'spaceId': id});
      }
    }
    final space = spaces[push.spaceId]!;
    final source = push.from == null ? null : spaces[push.from!]!;
    final at = now();

    final prior = space.notes[push.noteId];
    final wasDeleted = prior != null && prior.deletedAt != null;

    // --- keys and epochs ----------------------------------------------------
    var epoch = 1;
    int? rotatedFrom;
    FakeNoteKey? pendingKey;
    if (space.kind == SpaceKind.personal) {
      if (push.key != null) {
        _refuse(400, 'a personal note carries no key', {'noteId': push.noteId});
      }
    } else {
      final current = space.noteKeys[push.noteId];
      final key = push.key;
      Never refuseEpoch() => _refuse(409, 'content-key-epoch', {
        'spaceId': push.spaceId,
        'noteId': push.noteId,
        'contentKeyEpoch': current?.contentKeyEpoch ?? 0,
      });
      if (key != null && key.keyGeneration != space.keyGeneration) {
        _refuse(409, 'stale-key-generation', {
          'spaceId': push.spaceId,
          'keyGeneration': space.keyGeneration,
        });
      }
      if (current == null) {
        if (key == null) {
          if (push.ops.isNotEmpty || push.snapshot != null) {
            _refuse(400, 'a team note needs a key', {'noteId': push.noteId});
          }
          epoch = 0;
        } else {
          if (key.contentKeyEpoch != 1) refuseEpoch();
          pendingKey = FakeNoteKey(
            wrapped: key.wrapped,
            keyGeneration: space.keyGeneration,
            contentKeyEpoch: 1,
            contentKeyGeneration: space.keyGeneration,
          );
          epoch = 1;
        }
      } else if (key == null || key.contentKeyEpoch == current.contentKeyEpoch) {
        epoch = current.contentKeyEpoch;
      } else if (key.contentKeyEpoch == current.contentKeyEpoch + 1) {
        if (push.snapshot == null || push.snapshot!.epoch != key.contentKeyEpoch) {
          _refuse(400, 'a content-key rotation carries a snapshot under the new epoch');
        }
        pendingKey = FakeNoteKey(
          wrapped: key.wrapped,
          keyGeneration: space.keyGeneration,
          contentKeyEpoch: key.contentKeyEpoch,
          contentKeyGeneration: space.keyGeneration,
        );
        rotatedFrom = current.contentKeyEpoch;
        epoch = key.contentKeyEpoch;
      } else {
        refuseEpoch();
      }
    }
    Never epochRefusal() => _refuse(409, 'content-key-epoch', {
      'spaceId': push.spaceId,
      'noteId': push.noteId,
      'contentKeyEpoch': epoch,
    });
    for (final op in push.ops) {
      if (op.epoch != epoch) epochRefusal();
    }
    if (push.snapshot != null && push.snapshot!.epoch != epoch) epochRefusal();

    // --- seeding and moves --------------------------------------------------
    var dropHistory = false;
    if (push.seed || push.from != null) {
      if (_hasHistory(space, push.noteId)) {
        if (!wasDeleted) {
          _refuse(409, 'seeded', {'spaceId': push.spaceId, 'noteId': push.noteId});
        }
        dropHistory = true;
      }
    }
    if (source != null) {
      final srcRow = source.notes[push.noteId];
      if (srcRow == null || srcRow.deletedAt != null) {
        _refuse(409, 'move-raced', {'noteId': push.noteId});
      }
      if (source.ownerId != space.ownerId) {
        final bytes = _readyBytes(source.id, push.noteId);
        if (bytes > 0) {
          final used = storageUsed[space.ownerId] ?? 0;
          if (used + bytes > storageQuota) {
            _refuse(413, 'quota exceeded', {
              'spaceId': push.spaceId,
              'usedBytes': used,
              'quotaBytes': storageQuota,
            });
          }
        }
      }
    }

    // --- idempotency --------------------------------------------------------
    final sent = {for (final op in push.ops) op.deviceSeq};
    if (sent.length != push.ops.length) _refuse(400, 'an op appears twice');
    final known = <int, int>{};
    for (final op in space.ops) {
      if (op.noteId == push.noteId && op.deviceId == device && sent.contains(op.deviceSeq)) {
        known[op.deviceSeq] = op.seq;
      }
    }
    final fresh = push.ops.where((op) => !known.containsKey(op.deviceSeq)).toList();

    if (push.snapshot != null && push.snapshot!.covers > space.opSeq) {
      _refuse(400, 'snapshot covers seqs that do not exist');
    }

    // Nothing below can refuse: apply.
    if (pendingKey != null) space.noteKeys[push.noteId] = pendingKey;
    if (dropHistory) _forgetHistory(space, push.noteId);

    // --- the note row -------------------------------------------------------
    final deletedAfter = push.deleted ?? wasDeleted;
    final deletedAt = deletedAfter ? (prior?.deletedAt ?? at) : null;
    space.notes[push.noteId] = FakeNoteRow(
      id: push.noteId,
      spaceId: push.spaceId,
      userId: userId,
      updatedAt: at,
      deletedAt: deletedAt,
    );

    final marker = push.deleted != null &&
        push.deleted != wasDeleted &&
        fresh.isEmpty &&
        push.snapshot == null;
    final count = fresh.length + (push.snapshot != null ? 1 : 0) + (marker ? 1 : 0);
    final ranges = <({String spaceId, int from, int to})>[];
    final seqs = Map<int, int>.of(known);
    int? snapshotSeq;

    if (count > 0) {
      final range = _allocate(space, count);
      ranges.add((spaceId: space.id, from: range.first, to: range.last));
      var next = range.first;
      for (final op in fresh) {
        final seq = next++;
        seqs[op.deviceSeq] = seq;
        space.ops.add(
          WireStoredOp(
            seq: seq,
            spaceId: space.id,
            noteId: push.noteId,
            deviceId: device,
            authorId: userId,
            deviceSeq: op.deviceSeq,
            epoch: op.epoch,
            engine: op.engine,
            payload: op.payload,
            deleted: deletedAfter,
            at: at,
          ),
        );
      }
      final snap = push.snapshot;
      if (snap != null) {
        final seq = next++;
        snapshotSeq = seq;
        space.snapshots[push.noteId] = WireStoredSnapshot(
          seq: seq,
          spaceId: space.id,
          noteId: push.noteId,
          covers: snap.covers,
          deviceId: device,
          authorId: userId,
          epoch: snap.epoch,
          engine: snap.engine,
          payload: snap.payload,
          deleted: deletedAfter,
          at: at,
        );
        // Only what the writer had applied. An op that landed between its
        // cursor and this seq was not in the snapshot and stays.
        space.ops.removeWhere((op) => op.noteId == push.noteId && op.seq <= snap.covers);
        if (rotatedFrom != null) {
          space.ops.removeWhere((op) => op.noteId == push.noteId && op.epoch < epoch);
        }
      }
      if (marker) {
        final seq = next++;
        space.ops.add(_marker(space, push.noteId, device, userId, seq, deletedAfter, at));
      }
    }

    // --- side effects of the tombstone --------------------------------------
    final reaped = <String>[];
    if (deletedAfter && !wasDeleted) {
      if (space.kind == SpaceKind.team) space.noteKeys.remove(push.noteId);
      _releaseAttachments(space.id, push.noteId);
      if (space.kind == SpaceKind.team) reaped.addAll(_reapIfEmpty(space.id));
    }

    // --- the move's source side ---------------------------------------------
    if (source != null) {
      source.notes[push.noteId] = FakeNoteRow(
        id: push.noteId,
        spaceId: source.id,
        userId: userId,
        updatedAt: at,
        deletedAt: at,
      );
      source.noteKeys.remove(push.noteId);
      _forgetHistory(source, push.noteId);
      _moveAttachments(push.noteId, source, space);
      final range = _allocate(source, 1);
      source.ops.add(_marker(source, push.noteId, device, userId, range.first, true, at));
      ranges.add((spaceId: source.id, from: range.first, to: range.first));
      if (source.kind == SpaceKind.team) reaped.addAll(_reapIfEmpty(source.id));
    }

    for (final range in ranges) {
      _deliverRange(range.spaceId, range.from, range.to);
    }
    if (reaped.isNotEmpty) announceUsers(reaped);

    return OpsPushResult(
      seqs: [for (final op in push.ops) seqs[op.deviceSeq]!],
      snapshotSeq: snapshotSeq,
      serverTime: at,
    );
  }

  /// Everything in a space past a cursor, in seq order, snapshots and ops
  /// interleaved. Mirrors `pullOps`.
  OpsBatch pullOps(String userId, String spaceId, int after, int limit) {
    final space = _member(userId, spaceId);
    final ops = space.ops.where((op) => op.seq > after).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    final snaps = space.snapshots.values.where((s) => s.seq > after).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return _pageOf(spaceId, after, min(limit, pageSize), ops, snaps);
  }

  OpsBatch _rangeOps(String spaceId, int from, int to) {
    final space = spaces[spaceId];
    if (space == null) {
      return OpsBatch(spaceId: spaceId, ops: const [], snapshots: const [], cursor: from - 1, hasMore: false);
    }
    final ops = space.ops.where((op) => op.seq >= from && op.seq <= to).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    final snaps = space.snapshots.values.where((s) => s.seq >= from && s.seq <= to).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return _pageOf(spaceId, from - 1, 1 << 30, ops, snaps);
  }

  static OpsBatch _pageOf(
    String spaceId,
    int after,
    int limit,
    List<WireStoredOp> ops,
    List<WireStoredSnapshot> snaps,
  ) {
    final pageOps = <WireStoredOp>[];
    final pageSnaps = <WireStoredSnapshot>[];
    var i = 0;
    var j = 0;
    var last = after;
    while (pageOps.length + pageSnaps.length < limit && (i < ops.length || j < snaps.length)) {
      final op = i < ops.length ? ops[i] : null;
      final snap = j < snaps.length ? snaps[j] : null;
      if (op != null && (snap == null || op.seq < snap.seq)) {
        pageOps.add(op);
        last = op.seq;
        i++;
      } else if (snap != null) {
        pageSnaps.add(snap);
        last = snap.seq;
        j++;
      }
    }
    return OpsBatch(
      spaceId: spaceId,
      ops: pageOps,
      snapshots: pageSnaps,
      cursor: last,
      hasMore: i < ops.length || j < snaps.length,
    );
  }

  // -------------------------------------------------------------------------
  // Attachments
  // -------------------------------------------------------------------------

  int _readyBytes(String spaceId, String noteId) => attachments.values
      .where((a) => a.spaceId == spaceId && a.noteId == noteId && a.ready && !a.deleted)
      .fold(0, (sum, a) => sum + a.bytes);

  void _releaseAttachments(String spaceId, String noteId) {
    for (final row in attachments.values) {
      if (row.spaceId != spaceId || row.noteId != noteId || row.deleted) continue;
      row.deleted = true;
      if (row.ready) storageUsed[row.owner] = (storageUsed[row.owner] ?? 0) - row.bytes;
    }
  }

  void _moveAttachments(String noteId, FakeSpace from, FakeSpace to) {
    for (final row in attachments.values) {
      if (row.spaceId != from.id || row.noteId != noteId || row.deleted) continue;
      row.spaceId = to.id;
      if (row.owner != to.ownerId) {
        if (row.ready) {
          storageUsed[row.owner] = (storageUsed[row.owner] ?? 0) - row.bytes;
          storageUsed[to.ownerId] = (storageUsed[to.ownerId] ?? 0) + row.bytes;
        }
        row.owner = to.ownerId;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Spaces
  // -------------------------------------------------------------------------

  List<Space> spacesFor(String userId) {
    personal(userId);
    return [
      for (final space in spaces.values)
        if (space.members.containsKey(userId)) _wire(space, userId),
    ];
  }

  Space _wire(FakeSpace space, String userId) => Space(
    id: space.id,
    kind: space.kind,
    name: space.name,
    ownerId: space.ownerId,
    role: space.members[userId]!,
    keyGeneration: space.keyGeneration,
    rotationPending: space.rotationPending,
    spaceKey: space.keys[userId],
    members: [
      for (final entry in space.members.entries)
        SpaceMember(
          userId: entry.key,
          email: user(entry.key).email,
          role: entry.value,
          joinedAt: DateTime.utc(2026, 9, 1),
          hasKey: space.keys.containsKey(entry.key),
          x25519Public: user(entry.key).bundle?.identity?.x25519Public,
          ed25519Public: user(entry.key).bundle?.identity?.ed25519Public,
        ),
    ],
    invites: [
      for (final entry in space.invites.entries)
        SpaceInvite(
          token: entry.key,
          email: entry.value,
          expiresAt: DateTime.utc(2027),
          createdAt: DateTime.utc(2026, 9, 1),
        ),
    ],
    liveNotes: _liveNotes(space.id).length,
    createdAt: DateTime.utc(2026, 9, 1),
  );

  Iterable<FakeNoteRow> _liveNotes(String spaceId) =>
      (spaces[spaceId]?.notes ?? const {}).values.where((n) => !n.isTombstone);

  List<String> _reapIfEmpty(String spaceId) {
    final space = spaces[spaceId];
    if (space == null || space.kind != SpaceKind.team) return const [];
    if (space.members.length > 1) return const [];
    if (space.invites.isNotEmpty) return const [];
    if (_liveNotes(spaceId).isNotEmpty) return const [];
    final members = space.members.keys.toList();
    spaces.remove(spaceId);
    for (final socket in (_bySpace[spaceId] ?? const <FakeSocket>{}).toList()) {
      socket._unsubscribe(spaceId);
    }
    return members;
  }

  void _requireTerms(String userId) {
    if (user(userId).termsVersion < sharingTermsVersion) {
      _refuse(403, termsRequiredCode);
    }
  }

  Space createSpace(String userId, String name, SealedToPublicKey key) {
    calls.add('createSpace');
    _requireTerms(userId);
    final space = FakeSpace(
      id: 'space-${spaces.length + 1}-$name',
      kind: SpaceKind.team,
      name: name,
      ownerId: userId,
    )
      ..members[userId] = SpaceRole.owner
      ..keys[userId] = key;
    spaces[space.id] = space;
    return _wire(space, userId);
  }

  InviteResult invite(String userId, String spaceId, String email) {
    calls.add('invite:$email');
    _requireTerms(userId);
    final space = _member(userId, spaceId);
    if (space.members[userId] != SpaceRole.owner) {
      _refuse(403, 'only the owner can do this');
    }
    for (final member in space.members.keys) {
      if (user(member).email.toLowerCase() == email) _refuse(409, 'already a member');
    }
    space.invites.removeWhere((_, existing) => existing == email);
    final token = 'invite-${email.split('@').first}-${space.invites.length}';
    space.invites[token] = email;
    // Blocked: written, never delivered, and the sender is told nothing.
    final blockedBy = users.values.where(
      (u) => u.email.toLowerCase() == email && u.blocks.contains(user(userId).email.toLowerCase()),
    );
    if (blockedBy.isEmpty) outbox.add((to: email, token: token));
    announceSpace(spaceId);
    return InviteResult(
      token: token,
      email: email,
      expiresAt: DateTime.utc(2027),
      emailed: true,
    );
  }

  List<PendingInvite> invitesFor(String userId) {
    final email = user(userId).email.toLowerCase();
    final blocked = user(userId).blocks;
    return [
      for (final space in spaces.values)
        for (final entry in space.invites.entries)
          if (entry.value == email &&
              !blocked.contains(user(space.ownerId).email.toLowerCase()))
            PendingInvite(
              token: entry.key,
              spaceId: space.id,
              spaceName: space.name ?? 'Shared notes',
              invitedBy: user(space.ownerId).email,
              expiresAt: DateTime.utc(2027),
            ),
    ];
  }

  Space acceptInvite(String userId, String token) {
    calls.add('accept');
    final email = user(userId).email.toLowerCase();
    for (final space in spaces.values) {
      if (space.invites[token] != email) continue;
      // A blocked sender's invitation does not exist, however its link
      // travelled, and the rules are agreed to before joining.
      if (user(userId).blocks.contains(user(space.ownerId).email.toLowerCase())) {
        _refuse(404, 'no such invitation');
      }
      _requireTerms(userId);
      space.invites.remove(token);
      space.members[userId] = SpaceRole.member;
      announceSpace(space.id);
      return _wire(space, userId);
    }
    _refuse(404, 'no such invitation');
  }

  void declineInvite(String userId, String token) {
    final email = user(userId).email.toLowerCase();
    for (final space in spaces.values) {
      if (space.invites[token] == email) {
        space.invites.remove(token);
        return;
      }
    }
    _refuse(404, 'no such invitation');
  }

  void grantKey(String userId, String spaceId, String target, int generation, SealedToPublicKey key) {
    calls.add('grant:$target');
    final space = _member(userId, spaceId);
    if (!space.keys.containsKey(userId)) _refuse(403, 'you do not hold this space key');
    if (!space.members.containsKey(target)) _refuse(404, 'not a member');
    if (space.keyGeneration != generation) {
      _refuse(409, 'stale-key-generation', {'keyGeneration': space.keyGeneration});
    }
    if (space.keys.containsKey(target)) _refuse(409, 'already granted');
    space.keys[target] = key;
    announceSpace(spaceId);
  }

  void removeMember(String userId, String spaceId, String target) {
    calls.add('remove:$target');
    final space = _member(userId, spaceId);
    final role = space.members[userId]!;
    if (target == userId) {
      if (role == SpaceRole.owner) _refuse(400, 'the owner cannot leave');
    } else if (role != SpaceRole.owner) {
      _refuse(403, 'only the owner can remove someone');
    }
    if (!space.members.containsKey(target)) _refuse(404, 'not a member');
    space.members.remove(target);
    space.keys.remove(target);
    space.rotationPending = true;
    announceUsers([target]);
    final reaped = _reapIfEmpty(spaceId);
    if (reaped.isNotEmpty) {
      announceUsers(reaped);
    } else {
      announceSpace(spaceId);
    }
  }

  List<WireNoteKey> noteKeys(String userId, String spaceId) {
    final space = _member(userId, spaceId);
    return [
      for (final note in _liveNotes(spaceId))
        if (space.noteKeys[note.id] case final key?)
          WireNoteKey(
            wrapped: key.wrapped,
            keyGeneration: key.keyGeneration,
            contentKeyEpoch: key.contentKeyEpoch,
            contentKeyGeneration: key.contentKeyGeneration,
            noteId: note.id,
          ),
    ];
  }

  void rotate(
    String userId,
    String spaceId,
    int expected,
    Map<String, SealedToPublicKey> spaceKeys,
    Map<String, ({WrappedKey key, int fromEpoch})> wraps,
  ) {
    calls.add('rotate');
    final space = _member(userId, spaceId);
    if (space.keyGeneration != expected) {
      _refuse(409, 'stale-key-generation', {'keyGeneration': space.keyGeneration});
    }
    for (final holder in space.keys.keys) {
      if (!spaceKeys.containsKey(holder)) _refuse(409, 'incomplete', {'missingMember': holder});
    }
    for (final target in spaceKeys.keys) {
      if (!space.members.containsKey(target)) _refuse(409, 'not a member');
    }
    for (final note in _liveNotes(spaceId)) {
      final wrap = wraps[note.id];
      final stored = space.noteKeys[note.id];
      if (wrap == null || stored == null) _refuse(409, 'incomplete', {'missingNote': note.id});
      if (wrap.fromEpoch != stored.contentKeyEpoch) {
        _refuse(409, 'content-key-epoch', {'noteId': note.id});
      }
    }
    final generation = expected + 1;
    space.keys
      ..clear()
      ..addAll(spaceKeys);
    for (final note in _liveNotes(spaceId)) {
      final stored = space.noteKeys[note.id]!;
      space.noteKeys[note.id] = FakeNoteKey(
        wrapped: wraps[note.id]!.key,
        keyGeneration: generation,
        contentKeyEpoch: stored.contentKeyEpoch,
        contentKeyGeneration: stored.contentKeyGeneration,
      );
    }
    space.noteKeys.removeWhere((_, key) => key.keyGeneration != generation);
    space.keyGeneration = generation;
    space.rotationPending = false;
    announceSpace(spaceId);
  }

  Space transfer(String userId, String spaceId, String target) {
    final space = _member(userId, spaceId);
    if (space.members[userId] != SpaceRole.owner) _refuse(403, 'only the owner can do this');
    if (space.members[target] != SpaceRole.member) _refuse(404, 'not a member');
    if (!space.keys.containsKey(target)) _refuse(409, 'the new owner does not hold the key yet');
    space.ownerId = target;
    space.members[userId] = SpaceRole.member;
    space.members[target] = SpaceRole.owner;
    announceSpace(spaceId);
    return _wire(space, userId);
  }

  /// Ends a space. Under protocol 3 the notes have already gone home as
  /// moves, one push each, so the space must be empty of live notes.
  void stopSharing(String userId, String spaceId, List<WireNote> notes) {
    calls.add('stop');
    final space = _member(userId, spaceId);
    if (space.members[userId] != SpaceRole.owner) _refuse(403, 'only the owner can do this');
    if (notes.isNotEmpty) {
      _refuse(400, 'notes come home as moves under protocol 3');
    }
    final remaining = _liveNotes(spaceId).toList();
    if (remaining.isNotEmpty) {
      _refuse(409, 'incomplete', {'missingNote': remaining.first.id});
    }
    final members = space.members.keys.toList();
    spaces.remove(spaceId);
    for (final socket in (_bySpace[spaceId] ?? const <FakeSocket>{}).toList()) {
      socket._unsubscribe(spaceId);
    }
    announceUsers(members);
  }

  void deleteAccount(String userId, String confirmation) {
    calls.add('deleteAccount');
    final account = user(userId);
    if (confirmation.trim().toLowerCase() != account.email.trim().toLowerCase()) {
      throw const SyncRefusedException(400, 'confirmation does not match this account', {});
    }
    final owned = [
      for (final space in spaces.values)
        if (space.kind == SpaceKind.team && space.ownerId == userId)
          {'id': space.id, 'name': space.name},
    ];
    if (owned.isNotEmpty) {
      throw SyncRefusedException(409, 'owned-spaces', {'error': 'owned-spaces', 'spaces': owned});
    }
    for (final space in spaces.values.toList()) {
      if (space.kind == SpaceKind.team && space.members.containsKey(userId)) {
        space.members.remove(userId);
        space.keys.remove(userId);
        space.rotationPending = true;
        _reapIfEmpty(space.id);
      }
    }
    final own = personal(userId).id;
    spaces.remove(own);
    account.deleted = true;
    account.bundle = null;
    for (final socket in sockets.values.toList()) {
      if (socket.userId == userId) socket._dropped(forGood: true);
    }
  }
}

/// One note as the server's registry knows it: where it is, and whether it
/// is a tombstone. Nothing else about it is the server's to read.
class FakeNoteRow {
  const FakeNoteRow({
    required this.id,
    required this.spaceId,
    required this.userId,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String spaceId;
  final String userId;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isTombstone => deletedAt != null;
}

class FakeAttachment {
  FakeAttachment({
    required this.id,
    required this.noteId,
    required this.spaceId,
    required this.owner,
    required this.bytes,
  });

  final String id;
  final String noteId;
  String spaceId;
  String owner;

  /// Claimed until confirmed, then measured.
  int bytes;
  bool ready = false;
  bool deleted = false;
}

class FakeUser {
  FakeUser({required this.id, required this.email});
  final String id;
  String email;
  KeyBundle? bundle;
  bool deleted = false;

  /// Accepted by default, because almost every test is about something else.
  /// Set to 0 for an account that has agreed to nothing.
  int termsVersion = sharingTermsVersion;

  /// Lower-cased addresses this account will not accept invitations from.
  final Set<String> blocks = {};
}

class FakeReport {
  const FakeReport({
    required this.kind,
    required this.reason,
    required this.reporter,
    this.reportedEmail,
    this.spaceId,
    this.noteId,
    this.content,
    this.details,
  });

  final ReportKind kind;
  final ReportReason reason;
  final String reporter;
  final String? reportedEmail;
  final String? spaceId;
  final String? noteId;

  /// Null unless the person reporting explicitly chose to attach the note.
  final String? content;
  final String? details;
}

class FakeSpace {
  FakeSpace({
    required this.id,
    required this.kind,
    required this.name,
    required this.ownerId,
  });

  final String id;
  final SpaceKind kind;
  String? name;
  String ownerId;
  int keyGeneration = 1;
  bool rotationPending = false;
  final Map<String, SpaceRole> members = {};
  final Map<String, SealedToPublicKey> keys = {};
  final Map<String, String> invites = {};
  final Map<String, FakeNoteKey> noteKeys = {};

  /// The space's clock: the last seq handed out.
  int opSeq = 0;

  /// The log, in seq order. Pruned by snapshots and by moves.
  final List<WireStoredOp> ops = [];

  /// One snapshot per note.
  final Map<String, WireStoredSnapshot> snapshots = {};

  /// The note registry: every note that has ever been written here, live or
  /// as a tombstone.
  final Map<String, FakeNoteRow> notes = {};
}

class FakeNoteKey {
  const FakeNoteKey({
    required this.wrapped,
    required this.keyGeneration,
    required this.contentKeyEpoch,
    required this.contentKeyGeneration,
  });
  final WrappedKey wrapped;
  final int keyGeneration;
  final int contentKeyEpoch;
  final int contentKeyGeneration;
}

/// One subscription on one socket, as `ws.ts` keeps it.
class _Subscription {
  _Subscription(this.cursor);

  /// Live batches held back while the catch-up runs; null once released.
  List<OpsBatch>? pending = [];
  int cursor;
}

/// One device's socket to [FakeServer]: the client's half is [SyncSocket],
/// the server's half is a `Session`.
///
/// Frames in both directions are delivered on a later turn of the event
/// loop, never inline, so a test sees the same ordering a real socket gives:
/// a push is acked after the fan-out was queued, a catch-up page arrives
/// before `synced`, and nothing the client does inside a handler can see the
/// server's answer to it.
class FakeSocket implements SyncSocket {
  FakeSocket(this.server, {required this.device, required this.userId, required this.protocol});

  final FakeServer server;
  final String device;
  final String userId;
  final int protocol;

  final StreamController<SocketEvent> _events = StreamController.broadcast();
  final Map<String, _Subscription> _subs = {};
  Future<void> _chain = Future.value();
  bool _wanted = false;
  bool _connected = false;
  bool _closed = false;

  @override
  Stream<SocketEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  /// Spaces this socket is subscribed to.
  List<String> get subscribed => _subs.keys.toList();

  @override
  void connect() {
    if (_closed || _wanted) return;
    _wanted = true;
    _scheduleOpen();
  }

  void _scheduleOpen() {
    server._parked.remove(this);
    _later(_open);
  }

  void _open() {
    if (!_wanted || _closed || _connected) return;
    if (!server.socketsAllowed ||
        protocol < server.minProtocol ||
        server.user(userId).deleted) {
      server._parked.add(this);
      return;
    }
    // One socket per device: a reconnect replaces what was there.
    server.sockets[device]?._dropped(forGood: true);
    server.sockets[device] = this;
    _connected = true;
    _emit(const SocketEvent.connected());
  }

  /// Drops this one connection from the server's side, as [FakeServer.dropSockets]
  /// does for all of them. It comes back on its own unless
  /// [FakeServer.socketsAllowed] is off.
  void drop() => _dropped();

  /// The server's end went away. The client's end notices and, unless it
  /// was told to stop, comes back.
  void _dropped({bool forGood = false}) {
    if (!_connected) return;
    _connected = false;
    _teardown();
    _emit(const SocketEvent.disconnected());
    if (forGood) {
      _closed = true;
      _wanted = false;
      return;
    }
    if (_wanted) {
      Timer(server.reconnectDelay, () {
        if (_wanted && !_closed && !_connected) _open();
      });
    }
  }

  void _teardown() {
    if (identical(server.sockets[device], this)) server.sockets.remove(device);
    for (final spaceId in _subs.keys.toList()) {
      server._removeFrom(spaceId, this);
    }
    _subs.clear();
  }

  @override
  bool send(Map<String, Object?> message) {
    if (!_connected) return false;
    final frame = Map<String, Object?>.of(message);
    server.calls.add('ws:${frame['t']}');
    server.log.add((user: userId, device: device, call: 'ws:${frame['t']}'));
    _later(() => _handle(frame));
    return true;
  }

  /// Closing is the client's own act, so it is answered inline: nothing is
  /// scheduled, and a widget test that disposes its account on the way out
  /// is not left with a timer it never pumped. Anything already scheduled
  /// finds the controller closed and says nothing.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _wanted = false;
    server._parked.remove(this);
    if (_connected) {
      _connected = false;
      _teardown();
      _events.add(const SocketEvent.disconnected());
    }
    await _events.close();
  }

  // --- the server's half -------------------------------------------------

  void _later(void Function() body) {
    server._busy++;
    Timer.run(() {
      server._busy--;
      body();
    });
  }

  void _emit(SocketEvent event) {
    _later(() {
      if (!_events.isClosed) _events.add(event);
    });
  }

  void _send(Map<String, Object?> frame) {
    if (!_connected) return;
    _emit(SocketEvent.message(frame));
  }

  void _handle(Map<String, Object?> frame) {
    if (!_connected) return;
    switch (frame['t']) {
      case 'ping':
        _send({'t': 'pong'});
      case 'sub':
        final spaces = frame['spaces'];
        if (spaces is Map) _subscribe(spaces);
      case 'unsub':
        final spaceId = frame['spaceId'];
        if (spaceId is String) _unsubscribe(spaceId);
      case 'push':
        final id = frame['id'];
        if (id is! String) {
          _send({'t': 'error', 'error': 'bad-message'});
          return;
        }
        server._busy++;
        _chain = _chain.then((_) => _push(id, frame)).whenComplete(() => server._busy--);
      default:
        _send({'t': 'error', 'error': 'bad-message'});
    }
  }

  void _subscribe(Map<Object?, Object?> requested) {
    for (final entry in requested.entries) {
      final spaceId = entry.key;
      final cursor = entry.value;
      if (spaceId is! String) continue;
      final space = server.spaces[spaceId];
      if (space == null || !space.members.containsKey(userId)) {
        _send({'t': 'error', 'spaceId': spaceId, 'error': 'not a member'});
        continue;
      }
      // Registered before the first page, so nothing that lands during the
      // catch-up is missed: it is held until the pages are out.
      final sub = _Subscription(cursor is int ? cursor : 0);
      _subs[spaceId] = sub;
      server._addTo(spaceId, this);
      unawaited(_catchUp(spaceId, sub));
    }
  }

  Future<void> _catchUp(String spaceId, _Subscription sub) async {
    server._busy++;
    try {
      var after = sub.cursor;
      for (;;) {
        // Each page on its own turn, as a query would be, so a push can land
        // between two of them and be held.
        await Future<void>.delayed(Duration.zero);
        if (!_connected || !identical(_subs[spaceId], sub)) return;
        final OpsBatch batch;
        try {
          batch = server.pullOps(userId, spaceId, after, server.pageSize);
        } on SyncException {
          _send({'t': 'error', 'spaceId': spaceId, 'error': 'internal'});
          _unsubscribe(spaceId);
          return;
        }
        if (!batch.isEmpty) {
          _send({..._batchJson(batch), 't': 'ops'});
          sub.cursor = batch.cursor;
        }
        after = batch.cursor;
        if (!batch.hasMore) break;
      }
      final held = sub.pending ?? const <OpsBatch>[];
      sub.pending = null;
      for (final batch in held) {
        _deliver(spaceId, batch);
      }
      _send({'t': 'synced', 'spaceId': spaceId, 'cursor': sub.cursor});
    } finally {
      server._busy--;
    }
  }

  void _unsubscribe(String spaceId) {
    if (_subs.remove(spaceId) == null) return;
    server._removeFrom(spaceId, this);
  }

  /// A live batch for one space: held during catch-up, trimmed to what the
  /// client has not seen, and written otherwise.
  void _deliver(String spaceId, OpsBatch batch) {
    final sub = _subs[spaceId];
    if (sub == null) return;
    if (sub.pending != null) {
      sub.pending!.add(batch);
      return;
    }
    final ops = batch.ops.where((o) => o.seq > sub.cursor).toList();
    final snapshots = batch.snapshots.where((s) => s.seq > sub.cursor).toList();
    if (ops.isEmpty && snapshots.isEmpty) return;
    final cursor = max(
      ops.isEmpty ? 0 : ops.last.seq,
      snapshots.isEmpty ? 0 : snapshots.last.seq,
    );
    sub.cursor = cursor;
    _send({
      't': 'ops',
      'spaceId': spaceId,
      'ops': [for (final op in ops) op.toJson()],
      'snapshots': [for (final snap in snapshots) snap.toJson()],
      'cursor': cursor,
      'hasMore': false,
    });
  }

  Future<void> _push(String id, Map<String, Object?> frame) async {
    if (!_connected) return;
    final push = _parsePush(frame);
    if (push == null) {
      _send({'t': 'ack', 'id': id, 'result': null, 'error': 'bad-message', 'status': 400});
      return;
    }
    try {
      final result = server.pushOps(userId, device, push);
      _send({
        't': 'ack',
        'id': id,
        'result': <String, Object?>{
          'seqs': result.seqs,
          'snapshotSeq': result.snapshotSeq,
          'serverTime': result.serverTime.toUtc().toIso8601String(),
        },
      });
    } on SyncRefusedException catch (error) {
      _send({
        't': 'ack',
        'id': id,
        'result': null,
        'error': error.code,
        'status': error.status,
        for (final entry in error.body.entries)
          if (entry.key != 'error') entry.key: entry.value,
      });
    } on SyncException {
      _send({'t': 'ack', 'id': id, 'result': null, 'error': 'internal', 'status': 500});
    }
  }

  /// Drops any subscription the user is no longer entitled to.
  void _revalidate() {
    for (final spaceId in _subs.keys.toList()) {
      final space = server.spaces[spaceId];
      if (space != null && space.members.containsKey(userId)) continue;
      _unsubscribe(spaceId);
      _send({'t': 'error', 'spaceId': spaceId, 'error': 'not a member'});
    }
  }

  static Map<String, Object?> _batchJson(OpsBatch batch) => {
    'spaceId': batch.spaceId,
    'ops': [for (final op in batch.ops) op.toJson()],
    'snapshots': [for (final snap in batch.snapshots) snap.toJson()],
    'cursor': batch.cursor,
    'hasMore': batch.hasMore,
  };

  /// The wire form back into the client's own types: what the server would
  /// have parsed with the contract schema.
  static OpsPush? _parsePush(Map<String, Object?> frame) {
    final spaceId = frame['spaceId'];
    final noteId = frame['noteId'];
    if (spaceId is! String || noteId is! String) return null;
    final rawOps = frame['ops'];
    final ops = <WireOp>[];
    if (rawOps is List) {
      for (final raw in rawOps) {
        if (raw is! Map) return null;
        final payload = SealedBox.fromJson(raw['payload']);
        final deviceSeq = raw['deviceSeq'];
        final epoch = raw['epoch'];
        final engine = raw['engine'];
        if (payload == null || deviceSeq is! int || epoch is! int || engine is! String) {
          return null;
        }
        ops.add(WireOp(deviceSeq: deviceSeq, epoch: epoch, engine: engine, payload: payload));
      }
    }
    WireSnapshot? snapshot;
    final rawSnap = frame['snapshot'];
    if (rawSnap is Map) {
      final payload = SealedBox.fromJson(rawSnap['payload']);
      final covers = rawSnap['covers'];
      final epoch = rawSnap['epoch'];
      final engine = rawSnap['engine'];
      if (payload == null || covers is! int || epoch is! int || engine is! String) {
        return null;
      }
      snapshot = WireSnapshot(covers: covers, epoch: epoch, engine: engine, payload: payload);
    }
    final deleted = frame['deleted'];
    final from = frame['from'];
    return OpsPush(
      spaceId: spaceId,
      noteId: noteId,
      ops: ops,
      key: WireNoteKey.fromJson(frame['key']),
      deleted: deleted is bool ? deleted : null,
      from: from is String ? from : null,
      seed: frame['seed'] == true,
      snapshot: snapshot,
    );
  }
}

/// One device's connection to [FakeServer], as one account.
class FakeApi implements SyncApi {
  FakeApi(this.server, {String? device, this.userId = 'user-1'})
    : device = device ?? 'device-${++_minted}';

  static int _minted = 0;

  final FakeServer server;

  /// Which device this connection belongs to: the id on every op it writes
  /// and on its socket. A service whose [SyncState.deviceId] is the same
  /// string recognises its own ops when they come back; see [deviceIdFor].
  final String device;
  final String userId;

  /// What this build claims to speak. Lower it to see the server refuse.
  int protocol = protocolVersion;

  void _gate() {
    final failure = server.failNext;
    if (failure != null) {
      server.failNext = null;
      throw failure;
    }
    if (protocol < server.minProtocol) {
      throw SyncOutdatedException(server.minProtocol);
    }
    if (server.user(userId).deleted) {
      throw const SyncAuthException('session rejected');
    }
  }

  void _record(String call) {
    server.calls.add(call);
    server.log.add((user: userId, device: device, call: call));
  }

  @override
  Future<OpsPushResult> pushOps(OpsPush push) async {
    _gate();
    _record('pushOps');
    return server.pushOps(userId, device, push);
  }

  @override
  Future<OpsBatch> pullOps({
    required String space,
    int after = 0,
    int limit = opsPullDefaultLimit,
  }) async {
    _gate();
    _record('pullOps:$after');
    return server.pullOps(userId, space, after, limit);
  }

  @override
  SyncSocket openSocket() =>
      FakeSocket(server, device: device, userId: userId, protocol: protocol);

  @override
  Future<KeyBundle?> fetchKeyBundle() async {
    _gate();
    return server.user(userId).bundle;
  }

  @override
  Future<void> createKeyBundle(KeyBundle bundle) async {
    _gate();
    server.user(userId).bundle = bundle;
  }

  @override
  Future<void> rotateKeyBundle(KeyBundle bundle) async {
    _gate();
    final existing = server.user(userId).bundle;
    server.user(userId).bundle = KeyBundle(
      wrappedMasterKey: bundle.wrappedMasterKey,
      kdf: bundle.kdf,
      recoveryWrappedMasterKey: bundle.recoveryWrappedMasterKey,
      identity: existing?.identity,
    );
  }

  @override
  Future<void> publishIdentity(WireIdentity identity) async {
    _gate();
    final account = server.user(userId);
    final existing = account.bundle;
    if (existing == null) throw const SyncRefusedException(404, 'no key bundle', {});
    if (existing.identity != null) {
      throw const SyncRefusedException(409, 'identity keys already exist', {});
    }
    account.bundle = KeyBundle(
      wrappedMasterKey: existing.wrappedMasterKey,
      kdf: existing.kdf,
      recoveryWrappedMasterKey: existing.recoveryWrappedMasterKey,
      identity: identity,
    );
  }

  @override
  Future<void> deleteAccount(String confirmation) async {
    _gate();
    server.deleteAccount(userId, confirmation);
  }

  @override
  Future<List<Space>> fetchSpaces() async {
    _gate();
    _record('spaces');
    return server.spacesFor(userId);
  }

  @override
  Future<Space> createSpace({required String name, required SealedToPublicKey spaceKey}) async {
    _gate();
    return server.createSpace(userId, name, spaceKey);
  }

  @override
  Future<Space> renameSpace(String spaceId, String name) async {
    _gate();
    final space = server._member(userId, spaceId);
    space.name = name;
    return server._wire(space, userId);
  }

  @override
  Future<InviteResult> invite(String spaceId, String email) async {
    _gate();
    return server.invite(userId, spaceId, email);
  }

  @override
  Future<void> revokeInvite(String spaceId, String token) async {
    _gate();
    server._member(userId, spaceId).invites.remove(token);
  }

  @override
  Future<List<PendingInvite>> fetchInvites() async {
    _gate();
    return server.invitesFor(userId);
  }

  @override
  Future<Space> acceptInvite(String token) async {
    _gate();
    return server.acceptInvite(userId, token);
  }

  @override
  Future<void> declineInvite(String token) async {
    _gate();
    server.declineInvite(userId, token);
  }

  @override
  Future<void> grantKey({
    required String spaceId,
    required String userId,
    required int keyGeneration,
    required SealedToPublicKey spaceKey,
  }) async {
    _gate();
    server.grantKey(this.userId, spaceId, userId, keyGeneration, spaceKey);
  }

  @override
  Future<void> removeMember(String spaceId, String userId) async {
    _gate();
    server.removeMember(this.userId, spaceId, userId);
  }

  @override
  Future<List<WireNoteKey>> fetchNoteKeys(String spaceId) async {
    _gate();
    return server.noteKeys(userId, spaceId);
  }

  @override
  Future<void> rotate({
    required String spaceId,
    required int expectedGeneration,
    required Map<String, SealedToPublicKey> spaceKeys,
    required Map<String, ({WrappedKey key, int fromEpoch})> noteKeys,
  }) async {
    _gate();
    server.rotate(userId, spaceId, expectedGeneration, spaceKeys, noteKeys);
  }

  @override
  Future<Space> transfer(String spaceId, String userId) async {
    _gate();
    return server.transfer(this.userId, spaceId, userId);
  }

  @override
  Future<void> stopSharing(String spaceId, List<WireNote> notes) async {
    _gate();
    server.stopSharing(userId, spaceId, notes);
  }

  @override
  Future<List<Block>> fetchBlocks() async {
    _gate();
    return [
      for (final email in server.user(userId).blocks)
        Block(email: email, createdAt: DateTime.utc(2026, 9, 1)),
    ];
  }

  @override
  Future<void> block(String email) async {
    _gate();
    final address = email.trim().toLowerCase();
    if (address == server.user(userId).email.toLowerCase()) {
      throw const SyncRefusedException(400, 'you cannot block yourself', {});
    }
    server.user(userId).blocks.add(address);
    // Anything already sent stops being visible in the same moment.
    for (final space in server.spaces.values) {
      space.invites.removeWhere(
        (_, invited) =>
            invited == server.user(userId).email.toLowerCase() &&
            server.user(space.ownerId).email.toLowerCase() == address,
      );
    }
  }

  @override
  Future<void> unblock(String email) async {
    _gate();
    server.user(userId).blocks.remove(email.trim().toLowerCase());
  }

  @override
  Future<TermsStatus> fetchTerms() async {
    _gate();
    return TermsStatus(
      acceptedVersion: server.user(userId).termsVersion,
      currentVersion: sharingTermsVersion,
    );
  }

  @override
  Future<TermsStatus> acceptTerms() async {
    _gate();
    server.user(userId).termsVersion = sharingTermsVersion;
    return const TermsStatus(
      acceptedVersion: sharingTermsVersion,
      currentVersion: sharingTermsVersion,
    );
  }

  @override
  Future<AttachmentSlot> createAttachment({
    required String noteId,
    String? spaceId,
    required int bytes,
  }) async {
    _gate();
    final space = spaceId == null ? server.personal(userId) : server.spaces[spaceId];
    final owner = space?.ownerId ?? userId;
    final used = server.storageUsed[owner] ?? 0;
    if (used + bytes > server.storageQuota) {
      throw const SyncProtocolException('over quota');
    }
    final id = 'att-${server.attachments.length + 1}';
    server.attachments[id] = FakeAttachment(
      id: id,
      noteId: noteId,
      spaceId: space?.id ?? spaceId!,
      owner: owner,
      bytes: bytes,
    );
    return AttachmentSlot(
      id: id,
      uploadUrl: Uri.parse('https://blobs.test/put/$id'),
    );
  }

  @override
  Future<void> completeAttachment(String id) async {
    _gate();
    final row = server.attachments[id];
    if (row == null || row.ready) return;
    // Billed on what actually landed, never on what was claimed.
    row.bytes = server.blobs[id]?.length ?? 0;
    row.ready = true;
    server.storageUsed[row.owner] = (server.storageUsed[row.owner] ?? 0) + row.bytes;
  }

  @override
  Future<Map<String, Uri>> attachmentUrls(List<String> ids) async {
    _gate();
    return {
      for (final id in ids)
        if (server.blobs.containsKey(id))
          id: Uri.parse('https://blobs.test/get/$id'),
    };
  }

  @override
  Future<void> putBlob(Uri url, Uint8List bytes) async {
    final id = url.pathSegments.last;
    server.blobs[id] = bytes;
  }

  @override
  Future<Uint8List?> getBlob(Uri url) async =>
      server.blobs[url.pathSegments.last];

  @override
  Future<void> report({
    required ReportTarget target,
    required ReportReason reason,
    String? details,
    bool includeContent = false,
  }) async {
    _gate();
    final attach = includeContent && target.canAttachContent;
    server.reports.add(
      FakeReport(
        kind: target.kind,
        reason: reason,
        reporter: server.user(userId).email,
        reportedEmail: target.email,
        spaceId: target.spaceId,
        noteId: target.noteId,
        details: details,
        content: attach ? target.noteBody : null,
      ),
    );
  }
}

/// Both devices in these tests hold the same master key, which is what having
/// unlocked the same account means.
Vault sharedVault() =>
    Vault.fromMasterKey(Uint8List(Vault.keyLength)..fillRange(0, 32, 42));

/// A distinct master key per account, so two people's devices are plainly
/// not the same person.
Vault vaultFor(String userId) => Vault.fromMasterKey(
  Uint8List(Vault.keyLength)..fillRange(0, 32, 40 + userId.hashCode % 200),
);

/// A device id a test can read: the name, padded to the width the service
/// slices request ids from. Seed it into the store under `sync.v1` so
/// [SyncState.deviceId] and the [FakeApi] agree on it.
String deviceIdFor(String name) => name.padRight(16, '_');

/// A signed-in account, without a server to sign in to.
class FakeAuth implements AuthApi {
  FakeAuth({this.id = 'user-1', this.email = 'someone@example.com'});
  String id;
  String email;
  AuthResult? nextResult;
  bool sessionValid = true;
  int signOutCalls = 0;

  AccountUser get _user =>
      AccountUser(id: id, email: email, emailVerified: true);

  @override
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async => nextResult ?? AuthSignedIn('token-$id', _user);

  /// The code a test types back. Real enough: it is compared, not guessed.
  String code = '123456';
  String? sentCodeTo;

  @override
  Future<AuthResult> sendCode(String email) async {
    sentCodeTo = email;
    return nextResult ?? AuthCodeSent(email);
  }

  @override
  Future<AuthResult> signInWithCode({
    required String email,
    required String code,
  }) async => code == this.code
      ? (nextResult ?? AuthSignedIn('token-$id', _user))
      : const AuthRejected('That code is not right.');

  /// The password the fake currently believes in, so a reset can be seen to
  /// have changed something.
  String password = 'original';

  @override
  Future<AuthResult> requestPasswordReset(String email) async {
    sentCodeTo = email;
    return nextResult ?? AuthCodeSent(email);
  }

  @override
  Future<AuthResult> resetPassword({
    required String email,
    required String code,
    required String password,
  }) async {
    if (code != this.code) return const AuthRejected('That code is not right.');
    this.password = password;
    return const AuthPasswordChanged();
  }

  @override
  Future<void> signOut(String token) async => signOutCalls++;

  @override
  Future<AccountUser?> currentUser(String token) async =>
      sessionValid ? _user : null;
}

/// Waits for something that nothing in the test asked for — a frame, a
/// reconnect — since there is no future to await for it. Fails rather than
/// hanging: a signal that never arrives is the bug these tests exist to
/// catch, and a timeout says so where a hang does not.
Future<void> until(bool Function() done, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'the condition never became true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Lets everything in flight land: the server's queued frames, the clients'
/// send timers, and whatever those set off in turn. Returns once the server
/// has been quiet for [rounds] rounds in a row.
Future<void> settle(
  FakeServer server, {
  int rounds = 3,
  Duration pause = const Duration(milliseconds: 8),
}) async {
  var calm = 0;
  for (var i = 0; i < 400 && calm < rounds; i++) {
    await _pumpEventQueue();
    await Future<void>.delayed(pause);
    await _pumpEventQueue();
    calm = server.isQuiet ? calm + 1 : 0;
  }
}

Future<void> _pumpEventQueue([int times = 20]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>(() {});
  }
}
