import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'identity.dart';
import 'key_bundle.dart';
import 'key_wrap.dart';
import 'sync_socket.dart';
import 'safety.dart';
import 'sealed_box.dart';
import 'spaces.dart';

/// A note's content key as it rides beside the note on the wire, wrapped
/// under the space key. Mirrors `NoteKey` in the contract.
class WireNoteKey {
  final WrappedKey wrapped;

  /// The space generation the wrap was made under; refused if not current.
  final int keyGeneration;

  /// Bumped when the content key itself is replaced.
  final int contentKeyEpoch;

  /// The generation the content key was minted under. Set by the server;
  /// null on the way up.
  final int? contentKeyGeneration;

  /// Only set by `GET /spaces/:id/keys`, where the key is not beside its note.
  final String? noteId;

  const WireNoteKey({
    required this.wrapped,
    required this.keyGeneration,
    required this.contentKeyEpoch,
    this.contentKeyGeneration,
    this.noteId,
  });

  Map<String, Object?> toJson() => {
    ...wrapped.toJson(),
    'keyGeneration': keyGeneration,
    'contentKeyEpoch': contentKeyEpoch,
  };

  static WireNoteKey? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final wrapped = WrappedKey.fromJson(raw);
    final generation = raw['keyGeneration'];
    final epoch = raw['contentKeyEpoch'];
    final minted = raw['contentKeyGeneration'];
    final noteId = raw['noteId'];
    if (wrapped == null || generation is! int || epoch is! int) return null;
    return WireNoteKey(
      wrapped: wrapped,
      keyGeneration: generation,
      contentKeyEpoch: epoch,
      contentKeyGeneration: minted is int ? minted : null,
      noteId: noteId is String ? noteId : null,
    );
  }
}

/// A note as it crosses the wire: everything the server is allowed to read,
/// which is only enough to order, page, resolve conflicts, and route.
class WireNote {
  final String id;

  /// Null on the way up means the personal space; always set on the way down.
  final String? spaceId;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final SealedBox? payload;

  /// Present on a live note in a team space, absent otherwise.
  final WireNoteKey? key;

  const WireNote({
    required this.id,
    this.spaceId,
    required this.updatedAt,
    this.deletedAt,
    this.payload,
    this.key,
  });

  bool get isTombstone => deletedAt != null;

  Map<String, Object?> toJson() => {
    'id': id,
    if (spaceId != null) 'spaceId': spaceId,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'payload': payload?.toJson(),
    if (key != null) 'key': key!.toJson(),
  };

  static WireNote? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final updatedAt = raw['updatedAt'];
    if (id is! String || updatedAt is! String) return null;
    final parsedUpdated = DateTime.tryParse(updatedAt);
    if (parsedUpdated == null) return null;

    final deletedAt = raw['deletedAt'];
    final parsedDeleted = deletedAt is String
        ? DateTime.tryParse(deletedAt)
        : null;
    final spaceId = raw['spaceId'];

    return WireNote(
      id: id,
      spaceId: spaceId is String ? spaceId : null,
      updatedAt: parsedUpdated.toLocal(),
      deletedAt: parsedDeleted?.toLocal(),
      payload: SealedBox.fromJson(raw['payload']),
      key: WireNoteKey.fromJson(raw['key']),
    );
  }
}

/// One op as this device sends it: a sealed delta, counted per (device,
/// note) so a retried push is a no-op rather than a duplicate. Mirrors
/// `NoteOp` in the contract.
class WireOp {
  final int deviceSeq;

  /// The content-key epoch the payload is sealed under.
  final int epoch;
  final String engine;
  final SealedBox payload;

  const WireOp({
    required this.deviceSeq,
    required this.epoch,
    required this.engine,
    required this.payload,
  });

  Map<String, Object?> toJson() => {
    'deviceSeq': deviceSeq,
    'epoch': epoch,
    'engine': engine,
    'payload': payload.toJson(),
  };
}

/// An op as the server stored and relayed it. Mirrors `StoredOp`.
class WireStoredOp {
  final int seq;
  final String spaceId;
  final String noteId;
  final String deviceId;
  final String authorId;
  final int deviceSeq;
  final int epoch;
  final String engine;

  /// Empty for a marker — the server's own record that the tombstone
  /// changed — which carries nothing to open.
  final SealedBox payload;

  /// The note's tombstone state after this op.
  final bool deleted;
  final DateTime at;

  const WireStoredOp({
    required this.seq,
    required this.spaceId,
    required this.noteId,
    required this.deviceId,
    required this.authorId,
    required this.deviceSeq,
    required this.epoch,
    required this.engine,
    required this.payload,
    required this.deleted,
    required this.at,
  });

  bool get isMarker => engine == markerEngine;

  Map<String, Object?> toJson() => {
    'seq': seq,
    'spaceId': spaceId,
    'noteId': noteId,
    'deviceId': deviceId,
    'authorId': authorId,
    'deviceSeq': deviceSeq,
    'epoch': epoch,
    'engine': engine,
    'payload': payload.toJson(),
    'deleted': deleted,
    'at': at.toUtc().toIso8601String(),
  };

  static WireStoredOp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = raw['seq'];
    final spaceId = raw['spaceId'];
    final noteId = raw['noteId'];
    final at = raw['at'];
    final payload = SealedBox.fromJson(raw['payload'], allowEmpty: true);
    if (seq is! int ||
        spaceId is! String ||
        noteId is! String ||
        at is! String ||
        payload == null) {
      return null;
    }
    final parsedAt = DateTime.tryParse(at);
    if (parsedAt == null) return null;
    return WireStoredOp(
      seq: seq,
      spaceId: spaceId,
      noteId: noteId,
      deviceId: raw['deviceId'] is String ? raw['deviceId'] as String : '',
      authorId: raw['authorId'] is String ? raw['authorId'] as String : '',
      deviceSeq: raw['deviceSeq'] is int ? raw['deviceSeq'] as int : 0,
      epoch: raw['epoch'] is int ? raw['epoch'] as int : 0,
      engine: raw['engine'] is String ? raw['engine'] as String : '',
      payload: payload,
      deleted: raw['deleted'] == true,
      at: parsedAt.toLocal(),
    );
  }
}

/// A snapshot as this device writes it: the whole note, sealed, and the
/// space cursor it had applied when it took it. Mirrors `SnapshotPut`
/// without the ids, which travel on the push.
class WireSnapshot {
  final int covers;
  final int epoch;
  final String engine;
  final SealedBox payload;

  const WireSnapshot({
    required this.covers,
    required this.epoch,
    required this.engine,
    required this.payload,
  });

  Map<String, Object?> toJson() => {
    'covers': covers,
    'epoch': epoch,
    'engine': engine,
    'payload': payload.toJson(),
  };
}

/// A snapshot as the server stored and relayed it. Mirrors `StoredSnapshot`.
class WireStoredSnapshot {
  final int seq;
  final String spaceId;
  final String noteId;
  final int covers;
  final String deviceId;
  final String authorId;
  final int epoch;
  final String engine;
  final SealedBox payload;
  final bool deleted;
  final DateTime at;

  const WireStoredSnapshot({
    required this.seq,
    required this.spaceId,
    required this.noteId,
    required this.covers,
    required this.deviceId,
    required this.authorId,
    required this.epoch,
    required this.engine,
    required this.payload,
    required this.deleted,
    required this.at,
  });

  Map<String, Object?> toJson() => {
    'seq': seq,
    'spaceId': spaceId,
    'noteId': noteId,
    'covers': covers,
    'deviceId': deviceId,
    'authorId': authorId,
    'epoch': epoch,
    'engine': engine,
    'payload': payload.toJson(),
    'deleted': deleted,
    'at': at.toUtc().toIso8601String(),
  };

  static WireStoredSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = raw['seq'];
    final spaceId = raw['spaceId'];
    final noteId = raw['noteId'];
    final covers = raw['covers'];
    final epoch = raw['epoch'];
    final engine = raw['engine'];
    final at = raw['at'];
    final payload = SealedBox.fromJson(raw['payload']);
    if (seq is! int ||
        spaceId is! String ||
        noteId is! String ||
        covers is! int ||
        epoch is! int ||
        engine is! String ||
        at is! String ||
        payload == null) {
      return null;
    }
    final parsedAt = DateTime.tryParse(at);
    if (parsedAt == null) return null;
    return WireStoredSnapshot(
      seq: seq,
      spaceId: spaceId,
      noteId: noteId,
      covers: covers,
      deviceId: raw['deviceId'] is String ? raw['deviceId'] as String : '',
      authorId: raw['authorId'] is String ? raw['authorId'] as String : '',
      epoch: epoch,
      engine: engine,
      payload: payload,
      deleted: raw['deleted'] == true,
      at: parsedAt.toLocal(),
    );
  }
}

/// One push: a note's new ops, and whatever has to travel beside them.
/// Mirrors `OpsPushRequest`.
class OpsPush {
  final String spaceId;
  final String noteId;
  final List<WireOp> ops;

  /// A team note's content key, under the same generation and epoch rules
  /// the blob push had. Null for a personal note.
  final WireNoteKey? key;

  /// Sets the tombstone. Not an op — the server has to see it — and may
  /// travel with no ops at all.
  final bool? deleted;

  /// The space the note is leaving, for a move.
  final String? from;

  /// These are the note's first bytes here; refused with `seeded` if not.
  final bool seed;
  final WireSnapshot? snapshot;

  const OpsPush({
    required this.spaceId,
    required this.noteId,
    this.ops = const [],
    this.key,
    this.deleted,
    this.from,
    this.seed = false,
    this.snapshot,
  });

  Map<String, Object?> toJson() => {
    'spaceId': spaceId,
    'noteId': noteId,
    'ops': ops.map((op) => op.toJson()).toList(),
    if (key != null) 'key': key!.toJson(),
    if (deleted != null) 'deleted': deleted,
    if (from != null) 'from': from,
    if (seed) 'seed': true,
    if (snapshot != null) 'snapshot': snapshot!.toJson(),
  };
}

class OpsPushResult {
  /// One per op sent, in order.
  final List<int> seqs;
  final int? snapshotSeq;
  final DateTime serverTime;

  const OpsPushResult({
    required this.seqs,
    required this.snapshotSeq,
    required this.serverTime,
  });

  static OpsPushResult fromJson(Map<String, Object?> body) {
    final seqs = body['seqs'];
    final snapshotSeq = body['snapshotSeq'];
    final serverTime = body['serverTime'];
    return OpsPushResult(
      seqs: seqs is List ? seqs.whereType<int>().toList() : const [],
      snapshotSeq: snapshotSeq is int ? snapshotSeq : null,
      serverTime: serverTime is String
          ? (DateTime.tryParse(serverTime)?.toLocal() ?? DateTime.now())
          : DateTime.now(),
    );
  }
}

/// A page of a space's log past a cursor: ops and snapshots, each in seq
/// order, to be applied interleaved by seq. Mirrors `OpsBatch`.
class OpsBatch {
  final String spaceId;
  final List<WireStoredOp> ops;
  final List<WireStoredSnapshot> snapshots;

  /// The highest seq here, or the cursor asked for when there is nothing.
  final int cursor;
  final bool hasMore;

  const OpsBatch({
    required this.spaceId,
    required this.ops,
    required this.snapshots,
    required this.cursor,
    required this.hasMore,
  });

  bool get isEmpty => ops.isEmpty && snapshots.isEmpty;

  static OpsBatch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final spaceId = raw['spaceId'];
    final cursor = raw['cursor'];
    if (spaceId is! String || cursor is! int) return null;
    final ops = raw['ops'];
    final snapshots = raw['snapshots'];
    return OpsBatch(
      spaceId: spaceId,
      ops: ops is List
          ? ops.map(WireStoredOp.fromJson).whereType<WireStoredOp>().toList()
          : const [],
      snapshots: snapshots is List
          ? snapshots
                .map(WireStoredSnapshot.fromJson)
                .whereType<WireStoredSnapshot>()
                .toList()
          : const [],
      cursor: cursor,
      hasMore: raw['hasMore'] == true,
    );
  }
}

/// The engine tag on a server-written marker. Matches `ENGINE_MARKER`.
const String markerEngine = 'tomb';

/// Sync failed for a reason worth distinguishing, because the right response
/// differs: retry, sign in again, refresh and try once more, update the app,
/// or stop and report a bug.
sealed class SyncException implements Exception {
  const SyncException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The token is missing, expired or rejected. Retrying will not help; the user
/// has to sign in again.
class SyncAuthException extends SyncException {
  const SyncAuthException(super.message);
}

/// A network failure, a 5xx, or a rate limit. Worth retrying with backoff.
class SyncTransientException extends SyncException {
  const SyncTransientException(super.message);
}

/// The server rejected the request itself. Retrying sends the same bad request
/// again, so this surfaces rather than looping.
class SyncProtocolException extends SyncException {
  const SyncProtocolException(super.message);
}

/// The server refused this particular request for a reason it named — a key
/// generation that has moved on, an epoch behind the stored one, a space the
/// caller is no longer in. The right answer is usually to refresh what the
/// client knows and try once more, and [code] says which.
class SyncRefusedException extends SyncProtocolException {
  const SyncRefusedException(this.status, this.code, this.body)
    : super('$status $code');

  final int status;
  final String code;
  final Map<String, Object?> body;
}

/// This build speaks a protocol the server no longer serves. Not a transient
/// failure and not an auth one: the only fix is a newer build, so sync stops
/// rather than retrying, and says so.
class SyncOutdatedException extends SyncException {
  const SyncOutdatedException(this.minimum)
    : super('update to keep syncing (needs protocol $minimum)');

  final int minimum;
}

/// The sync endpoints. Abstract so the service can be tested end to end
/// without a server, which is most of what there is to get wrong.
abstract class SyncApi {
  /// Appends a note's ops. The same rules the socket applies: the answer
  /// names the seq each op took, and a retried push gets the same ones.
  Future<OpsPushResult> pushOps(OpsPush push);

  /// One page of one space's log past [after]. The fallback for a socket
  /// that cannot connect; the socket's catch-up is the same query.
  Future<OpsBatch> pullOps({required String space, int after, int limit});

  /// A fresh socket to the server, not yet connected. The caller owns it:
  /// connects it, subscribes, pushes through it, and closes it.
  SyncSocket openSocket();

  /// Null when this account has no bundle yet — a fresh sign-up that still has
  /// to choose a passphrase.
  Future<KeyBundle?> fetchKeyBundle();

  /// First-run setup. Fails with [SyncProtocolException] if a bundle already
  /// exists; replacing one is a rotation, which has to prove knowledge of the
  /// current key.
  Future<void> createKeyBundle(KeyBundle bundle);
  Future<void> rotateKeyBundle(KeyBundle bundle);

  /// Publishes the identity keypairs for an account created before they
  /// existed. Refused once they exist.
  Future<void> publishIdentity(WireIdentity identity);

  /// Closes the account and erases everything the server holds for it.
  ///
  /// [confirmation] must be the account's own email address; the server
  /// refuses anything else with a 400. Nothing about this is recoverable —
  /// the key bundle goes with the account, and the ciphertext is noise
  /// without it — so the confirmation is the design, not ceremony. Refused
  /// with [SyncRefusedException] `owned-spaces` while the caller still owns a
  /// shared space.
  Future<void> deleteAccount(String confirmation);

  // Spaces.

  Future<List<Space>> fetchSpaces();
  Future<Space> createSpace({
    required String name,
    required SealedToPublicKey spaceKey,
  });
  Future<Space> renameSpace(String spaceId, String name);
  Future<InviteResult> invite(String spaceId, String email);
  Future<void> revokeInvite(String spaceId, String token);
  Future<List<PendingInvite>> fetchInvites();
  Future<Space> acceptInvite(String token);
  Future<void> declineInvite(String token);
  Future<void> grantKey({
    required String spaceId,
    required String userId,
    required int keyGeneration,
    required SealedToPublicKey spaceKey,
  });
  Future<void> removeMember(String spaceId, String userId);
  Future<List<WireNoteKey>> fetchNoteKeys(String spaceId);
  Future<void> rotate({
    required String spaceId,
    required int expectedGeneration,
    required Map<String, SealedToPublicKey> spaceKeys,
    required Map<String, ({WrappedKey key, int fromEpoch})> noteKeys,
  });
  Future<Space> transfer(String spaceId, String userId);
  Future<void> stopSharing(String spaceId, List<WireNote> notes);

  // Blocking, reporting and the sharing terms.

  Future<List<Block>> fetchBlocks();
  Future<void> block(String email);
  Future<void> unblock(String email);

  Future<TermsStatus> fetchTerms();
  Future<TermsStatus> acceptTerms();

  /// Files a report. [includeContent] is the only thing here that can send
  /// anything the server could not already see, and it is false unless the
  /// person reporting has been told what it means and said yes.
  Future<void> report({
    required ReportTarget target,
    required ReportReason reason,
    String? details,
    bool includeContent = false,
  });

  /// Asks permission to store [bytes] and gets somewhere to put them.
  ///
  /// Quota is checked here, before anything moves, so an upload that will not
  /// fit fails on a small JSON round trip rather than after a 20 MB transfer.
  Future<AttachmentSlot> createAttachment({
    required String noteId,
    String? spaceId,
    required int bytes,
  });

  /// Confirms the bytes landed. The server measures the object itself and
  /// bills that, so a client cannot understate what it stored.
  Future<void> completeAttachment(String id);

  /// Presigned reads, in one round trip for a whole note's worth of images.
  Future<Map<String, Uri>> attachmentUrls(List<String> ids);

  /// Straight to object storage, carrying no session and no auth header.
  ///
  /// Bytes never pass through the API container: a phone on a slow connection
  /// would otherwise hold one of its connections open for the whole transfer.
  Future<void> putBlob(Uri url, Uint8List bytes);
  Future<Uint8List?> getBlob(Uri url);
}

/// Somewhere to put one attachment's bytes.
class AttachmentSlot {
  const AttachmentSlot({required this.id, required this.uploadUrl});

  final String id;
  final Uri uploadUrl;
}

/// What every attachment is stored as, whatever the picture actually is.
///
/// The object is ciphertext, so its real type is not the server's business —
/// and saying `image/png` on the bucket would leak one more fact about what
/// the user keeps in their notes.
const String attachmentMime = 'application/octet-stream';

/// One push may not carry more ops than this. Matches `OPS_PUSH_MAX`.
const int opsPushMax = 100;
const int opsPullDefaultLimit = 500;

/// Names the device a request came from. Matches `DEVICE_HEADER`.
const String deviceHeader = 'x-kapynotes-device';

/// Which sync protocol this build speaks. Matches `PROTOCOL_HEADER` and
/// `PROTOCOL_VERSION`: version 3 is the encrypted op log over the socket.
const String protocolHeader = 'x-kapynotes-protocol';
const int protocolVersion = 3;

class HttpSyncApi implements SyncApi {
  HttpSyncApi({
    required Uri baseUrl,
    required Future<String?> Function() token,
    required String deviceId,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _baseUrl = baseUrl,
       _token = token,
       _deviceId = deviceId,
       _client = client ?? http.Client();

  final Uri _baseUrl;
  final Future<String?> Function() _token;
  final String _deviceId;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<OpsPushResult> pushOps(OpsPush push) async {
    if (push.ops.length > opsPushMax) {
      throw SyncProtocolException(
        'push of ${push.ops.length} ops exceeds the $opsPushMax limit',
      );
    }
    return OpsPushResult.fromJson(
      await _send('POST', _baseUrl.resolve('sync/ops'), payload: push.toJson()),
    );
  }

  @override
  Future<OpsBatch> pullOps({
    required String space,
    int after = 0,
    int limit = opsPullDefaultLimit,
  }) async {
    final body = await _send(
      'GET',
      _baseUrl.resolve('sync/ops').replace(
        queryParameters: {'space': space, 'after': '$after', 'limit': '$limit'},
      ),
    );
    final batch = OpsBatch.fromJson(body);
    if (batch == null) {
      throw const SyncProtocolException('ops response was malformed');
    }
    return batch;
  }

  @override
  SyncSocket openSocket() => WebSocketSyncSocket(
    url: _baseUrl.resolve('sync/ws'),
    token: _token,
    headers: {deviceHeader: _deviceId, protocolHeader: '$protocolVersion'},
  );

  @override
  Future<KeyBundle?> fetchKeyBundle() async {
    final body = await _send(
      'GET',
      _baseUrl.resolve('keys'),
      absentIsNull: true,
    );
    return body.isEmpty ? null : KeyBundle.fromJson(body);
  }

  @override
  Future<void> createKeyBundle(KeyBundle bundle) =>
      _send('POST', _baseUrl.resolve('keys'), payload: bundle.toJson());

  @override
  Future<void> rotateKeyBundle(KeyBundle bundle) =>
      _send('PUT', _baseUrl.resolve('keys'), payload: bundle.toJson());

  @override
  Future<void> publishIdentity(WireIdentity identity) => _send(
    'PUT',
    _baseUrl.resolve('keys/identity'),
    payload: identity.toJson(),
  );

  @override
  Future<void> deleteAccount(String confirmation) => _send(
    'DELETE',
    _baseUrl.resolve('account'),
    payload: {'confirm': confirmation},
  );

  @override
  Future<List<Space>> fetchSpaces() async {
    final body = await _send('GET', _baseUrl.resolve('spaces'));
    return _spaces(body['spaces']);
  }

  @override
  Future<Space> createSpace({
    required String name,
    required SealedToPublicKey spaceKey,
  }) async => _space(
    await _send(
      'POST',
      _baseUrl.resolve('spaces'),
      payload: {'name': name, 'spaceKey': spaceKey.toJson()},
    ),
  );

  @override
  Future<Space> renameSpace(String spaceId, String name) async => _space(
    await _send(
      'PUT',
      _baseUrl.resolve('spaces/$spaceId'),
      payload: {'name': name},
    ),
  );

  @override
  Future<InviteResult> invite(String spaceId, String email) async {
    final body = await _send(
      'POST',
      _baseUrl.resolve('spaces/$spaceId/invites'),
      payload: {'email': email},
    );
    final token = body['token'];
    final expires = DateTime.tryParse(body['expiresAt'] as String? ?? '');
    if (token is! String || expires == null) {
      throw const SyncProtocolException('invitation response was malformed');
    }
    return InviteResult(
      token: token,
      email: body['email'] is String ? body['email'] as String : email,
      expiresAt: expires.toLocal(),
      emailed: body['emailed'] == true,
    );
  }

  @override
  Future<void> revokeInvite(String spaceId, String token) =>
      _send('DELETE', _baseUrl.resolve('spaces/$spaceId/invites/$token'));

  @override
  Future<List<PendingInvite>> fetchInvites() async {
    final body = await _send('GET', _baseUrl.resolve('invites'));
    final invites = body['invites'];
    return invites is List
        ? invites.map(PendingInvite.fromJson).whereType<PendingInvite>().toList()
        : const [];
  }

  @override
  Future<Space> acceptInvite(String token) async =>
      _space(await _send('POST', _baseUrl.resolve('invites/$token/accept')));

  @override
  Future<void> declineInvite(String token) =>
      _send('DELETE', _baseUrl.resolve('invites/$token'));

  @override
  Future<void> grantKey({
    required String spaceId,
    required String userId,
    required int keyGeneration,
    required SealedToPublicKey spaceKey,
  }) => _send(
    'PUT',
    _baseUrl.resolve('spaces/$spaceId/keys/$userId'),
    payload: {'keyGeneration': keyGeneration, 'spaceKey': spaceKey.toJson()},
  );

  @override
  Future<void> removeMember(String spaceId, String userId) =>
      _send('DELETE', _baseUrl.resolve('spaces/$spaceId/members/$userId'));

  @override
  Future<List<WireNoteKey>> fetchNoteKeys(String spaceId) async {
    final body = await _send('GET', _baseUrl.resolve('spaces/$spaceId/keys'));
    final keys = body['keys'];
    return keys is List
        ? keys.map(WireNoteKey.fromJson).whereType<WireNoteKey>().toList()
        : const [];
  }

  @override
  Future<void> rotate({
    required String spaceId,
    required int expectedGeneration,
    required Map<String, SealedToPublicKey> spaceKeys,
    required Map<String, ({WrappedKey key, int fromEpoch})> noteKeys,
  }) => _send(
    'POST',
    _baseUrl.resolve('spaces/$spaceId/rotate'),
    payload: {
      'expectedGeneration': expectedGeneration,
      'spaceKeys': {
        for (final entry in spaceKeys.entries) entry.key: entry.value.toJson(),
      },
      'noteKeys': {
        for (final entry in noteKeys.entries)
          entry.key: {
            'key': entry.value.key.toJson(),
            'fromEpoch': entry.value.fromEpoch,
          },
      },
    },
  );

  @override
  Future<Space> transfer(String spaceId, String userId) async => _space(
    await _send(
      'POST',
      _baseUrl.resolve('spaces/$spaceId/transfer'),
      payload: {'userId': userId},
    ),
  );

  @override
  Future<void> stopSharing(String spaceId, List<WireNote> notes) => _send(
    'DELETE',
    _baseUrl.resolve('spaces/$spaceId'),
    payload: {'notes': notes.map((note) => note.toJson()).toList()},
  );

  @override
  Future<List<Block>> fetchBlocks() async {
    final body = await _send('GET', _baseUrl.resolve('blocks'));
    final blocks = body['blocks'];
    return blocks is List
        ? blocks.map(Block.fromJson).whereType<Block>().toList()
        : const [];
  }

  @override
  Future<void> block(String email) => _send(
    'POST',
    _baseUrl.resolve('blocks'),
    payload: {'email': email.trim().toLowerCase()},
  );

  @override
  Future<void> unblock(String email) => _send(
    'DELETE',
    _baseUrl.resolve('blocks/${Uri.encodeComponent(email.trim().toLowerCase())}'),
  );

  @override
  Future<TermsStatus> fetchTerms() async =>
      TermsStatus.fromJson(await _send('GET', _baseUrl.resolve('terms'))) ??
      TermsStatus.unknown;

  @override
  Future<TermsStatus> acceptTerms() async =>
      TermsStatus.fromJson(
        await _send(
          'POST',
          _baseUrl.resolve('terms'),
          payload: {'version': sharingTermsVersion},
        ),
      ) ??
      TermsStatus.unknown;

  @override
  Future<void> report({
    required ReportTarget target,
    required ReportReason reason,
    String? details,
    bool includeContent = false,
  }) {
    final attach = includeContent && target.canAttachContent;
    return _send(
      'POST',
      _baseUrl.resolve('reports'),
      payload: {
        'kind': target.kind.name,
        'reason': reason.wire,
        if (details != null && details.trim().isNotEmpty)
          'details': details.trim(),
        if (target.token != null) 'token': target.token,
        if (target.spaceId != null) 'spaceId': target.spaceId,
        if (target.noteId != null) 'noteId': target.noteId,
        if (target.email != null) 'email': target.email,
        // Both fields together or neither: the server refuses content that
        // arrives without the consent beside it, and so should we.
        if (attach) 'content': target.noteBody,
        'contentConsent': attach,
      },
    );
  }

  @override
  Future<AttachmentSlot> createAttachment({
    required String noteId,
    String? spaceId,
    required int bytes,
  }) async {
    final body = await _send(
      'POST',
      _baseUrl.resolve('attachments'),
      payload: {'noteId': noteId, 'spaceId': ?spaceId, 'bytes': bytes},
    );
    final id = body['id'];
    final url = body['uploadUrl'];
    if (id is! String || url is! String) {
      throw const SyncProtocolException('attachment response was malformed');
    }
    return AttachmentSlot(id: id, uploadUrl: Uri.parse(url));
  }

  @override
  Future<void> completeAttachment(String id) =>
      _send('POST', _baseUrl.resolve('attachments/$id/complete'));

  @override
  Future<Map<String, Uri>> attachmentUrls(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final body = await _send(
      'POST',
      _baseUrl.resolve('attachments/urls'),
      payload: {'ids': ids},
    );
    final urls = body['urls'];
    if (urls is! Map) return const {};
    return {
      for (final entry in urls.entries)
        if (entry.key is String && entry.value is Map)
          if ((entry.value as Map)['url'] is String)
            entry.key as String: Uri.parse((entry.value as Map)['url'] as String),
    };
  }

  @override
  Future<void> putBlob(Uri url, Uint8List bytes) async {
    // No authorization header: the signature is in the URL, and sending a
    // session token to object storage would leak it there for no gain.
    final response = await _client
        .put(url, body: bytes, headers: {'content-type': attachmentMime})
        .timeout(timeout);
    if (response.statusCode >= 400) {
      throw SyncProtocolException(
        'storing an image failed with ${response.statusCode}',
      );
    }
  }

  @override
  Future<Uint8List?> getBlob(Uri url) async {
    final response = await _client.get(url).timeout(timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) {
      throw SyncProtocolException(
        'reading an image failed with ${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  List<Space> _spaces(Object? raw) => raw is List
      ? raw.map(Space.fromJson).whereType<Space>().toList()
      : const [];

  Space _space(Map<String, Object?> body) {
    final space = Space.fromJson(body);
    if (space == null) {
      throw const SyncProtocolException('space response was malformed');
    }
    return space;
  }

  /// Returns the decoded body, or an empty map when [absentIsNull] turned a
  /// 404 into "there isn't one".
  Future<Map<String, Object?>> _send(
    String method,
    Uri url, {
    Map<String, Object?>? payload,
    bool absentIsNull = false,
  }) async {
    final token = await _token();
    if (token == null) throw const SyncAuthException('not signed in');

    final request = http.Request(method, url)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json'
      // Only /sync/push reads it, but sending it everywhere costs a header
      // and means the one endpoint that matters cannot be the one that
      // forgets. The server already knows which device this is.
      ..headers[deviceHeader] = _deviceId
      // Every request says which protocol it speaks, so a server that has
      // moved on can refuse it with 426 before doing any work.
      ..headers[protocolHeader] = '$protocolVersion';
    if (payload != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(payload);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      );
    } on TimeoutException {
      throw const SyncTransientException('timed out');
    } catch (error) {
      // Offline, DNS failure, TLS problem: all worth retrying later.
      throw SyncTransientException('$error');
    }

    final status = response.statusCode;
    if (status == 401) throw const SyncAuthException('session rejected');
    if (status == 426) {
      final body = _decode(response.body);
      final minimum = body['minimum'];
      throw SyncOutdatedException(minimum is int ? minimum : protocolVersion);
    }
    if (status == 404 && absentIsNull) return const {};
    // 429 and 5xx are the server asking for patience, not a bad request.
    if (status == 429 || status >= 500) {
      throw SyncTransientException('server returned $status');
    }
    if (status >= 400) {
      final body = _decode(response.body);
      final code = body['error'];
      throw SyncRefusedException(
        status,
        code is String ? code : 'server returned $status',
        body,
      );
    }
    if (response.body.isEmpty) return const {};
    return _decode(response.body, strict: true);
  }

  Map<String, Object?> _decode(String body, {bool strict = false}) {
    if (body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      if (strict) throw const SyncProtocolException('response was not JSON');
      return const {};
    }
  }

  void close() => _client.close();
}
