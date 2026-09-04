import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'key_bundle.dart';
import 'sealed_box.dart';

/// A note as it crosses the wire: everything the server is allowed to read,
/// which is only enough to order, page and resolve conflicts.
class WireNote {
  final String id;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final SealedBox? payload;

  const WireNote({
    required this.id,
    required this.updatedAt,
    this.deletedAt,
    this.payload,
  });

  bool get isTombstone => deletedAt != null;

  Map<String, Object?> toJson() => {
    'id': id,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'payload': payload?.toJson(),
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

    return WireNote(
      id: id,
      updatedAt: parsedUpdated.toLocal(),
      deletedAt: parsedDeleted?.toLocal(),
      payload: SealedBox.fromJson(raw['payload']),
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
/// differs: retry, sign in again, or stop and report a bug.
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

/// The sync endpoints. Abstract so the service can be tested end to end
/// without a server, which is most of what there is to get wrong.
abstract class SyncApi {
  Future<PullPage> pull({String? cursor, int limit});
  Future<PushResult> push(List<WireNote> notes);

  /// Null when this account has no bundle yet — a fresh sign-up that still has
  /// to choose a passphrase.
  Future<KeyBundle?> fetchKeyBundle();

  /// First-run setup. Fails with [SyncProtocolException] if a bundle already
  /// exists; replacing one is a rotation, which has to prove knowledge of the
  /// current key.
  Future<void> createKeyBundle(KeyBundle bundle);
  Future<void> rotateKeyBundle(KeyBundle bundle);
}

/// One request may not carry more than this. Matches `PUSH_MAX_NOTES`.
const int pushMaxNotes = 200;
const int pullDefaultLimit = 200;

class HttpSyncApi implements SyncApi {
  HttpSyncApi({
    required Uri baseUrl,
    required Future<String?> Function() token,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _baseUrl = baseUrl,
       _token = token,
       _client = client ?? http.Client();

  final Uri _baseUrl;
  final Future<String?> Function() _token;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<PullPage> pull({String? cursor, int limit = pullDefaultLimit}) async {
    final body = await _send(
      'GET',
      _baseUrl.resolve('sync/pull').replace(
        queryParameters: {
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
      ..headers['accept'] = 'application/json';
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
    if (status == 401 || status == 403) {
      throw const SyncAuthException('session rejected');
    }
    if (status == 404 && absentIsNull) return const {};
    // 429 and 5xx are the server asking for patience, not a bad request.
    if (status == 429 || status >= 500) {
      throw SyncTransientException('server returned $status');
    }
    if (status >= 400) {
      throw SyncProtocolException('server returned $status');
    }
    if (response.body.isEmpty) return const {};

    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      throw const SyncProtocolException('response was not JSON');
    }
  }

  void close() => _client.close();
}
