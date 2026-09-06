import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'identity.dart';
import 'key_bundle.dart';
import 'key_wrap.dart';
import 'live_channel.dart';
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

class PullPage {
  final List<WireNote> notes;
  final String cursor;
  final bool hasMore;

  const PullPage({
    required this.notes,
    required this.cursor,
    required this.hasMore,
  });
}

class PushResult {
  /// Ids the server accepted.
  final Set<String> applied;

  /// The server's winning copies of everything it rejected, so a conflicted
  /// copy can be written without a second round trip.
  final List<WireNote> conflicts;
  final DateTime serverTime;

  const PushResult({
    required this.applied,
    required this.conflicts,
    required this.serverTime,
  });
}

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
  /// One page of one space. [space] null means the personal space, which is
  /// what a build from before spaces asked for without knowing it.
  Future<PullPage> pull({String? space, String? cursor, int limit});
  Future<PushResult> push(List<WireNote> notes);

  /// The wake-up channel: one [LiveSignal] per "something changed somewhere
  /// else", naming the space where the server knows it.
  ///
  /// Connects on the first listener and disconnects when it is cancelled.
  /// Failures are the channel's own business — it reconnects, and stops
  /// emitting while it cannot — so this never produces an error.
  Stream<LiveSignal> live();

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
}

/// One request may not carry more than this. Matches `PUSH_MAX_NOTES`.
const int pushMaxNotes = 200;
const int pullDefaultLimit = 200;

/// Names the device a request came from. Matches `DEVICE_HEADER`.
const String deviceHeader = 'x-kapynotes-device';

/// Which sync protocol this build speaks. Matches `PROTOCOL_HEADER` and
/// `PROTOCOL_VERSION`: version 2 is space-scoped sync.
const String protocolHeader = 'x-kapynotes-protocol';
const int protocolVersion = 2;

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

  /// One channel, however many times [live] is called. It shares [_client],
  /// and so its connection pool: a second one would mean a second TLS
  /// handshake to the same host for no reason.
  LiveChannel? _live;

  @override
  Stream<LiveSignal> live() => (_live ??= LiveChannel(
    url: _baseUrl.resolve('sync/live'),
    token: _token,
    headers: {deviceHeader: _deviceId, protocolHeader: '$protocolVersion'},
    client: _client,
  )).signals;

  @override
  Future<PullPage> pull({
    String? space,
    String? cursor,
    int limit = pullDefaultLimit,
  }) async {
    final body = await _send(
      'GET',
      _baseUrl.resolve('sync/pull').replace(
        queryParameters: {
          'space': ?space,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          'limit': '$limit',
        },
      ),
    );

    final notes = body['notes'];
    return PullPage(
      notes: notes is List
          ? notes.map(WireNote.fromJson).whereType<WireNote>().toList()
          : const [],
      cursor: body['cursor'] is String ? body['cursor'] as String : '',
      hasMore: body['hasMore'] == true,
    );
  }

  @override
  Future<PushResult> push(List<WireNote> notes) async {
    if (notes.length > pushMaxNotes) {
      throw SyncProtocolException(
        'push of ${notes.length} exceeds the $pushMaxNotes limit',
      );
    }

    final body = await _send(
      'POST',
      _baseUrl.resolve('sync/push'),
      payload: {'notes': notes.map((note) => note.toJson()).toList()},
    );

    final applied = body['applied'];
    final conflicts = body['conflicts'];
    final serverTime = body['serverTime'];

    return PushResult(
      applied: applied is List ? applied.whereType<String>().toSet() : const {},
      conflicts: conflicts is List
          ? conflicts.map(WireNote.fromJson).whereType<WireNote>().toList()
          : const [],
      serverTime: serverTime is String
          ? (DateTime.tryParse(serverTime)?.toLocal() ?? DateTime.now())
          : DateTime.now(),
    );
  }

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

  void close() {
    unawaited(_live?.dispose());
    _live = null;
    _client.close();
  }
}
