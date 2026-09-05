import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sealed_box.dart';
import 'share_link.dart';
import 'sync_api.dart' show SyncAuthException, SyncProtocolException, SyncTransientException;

/// The share endpoints, kept apart from [SyncApi] because they are not sync.
///
/// Nothing here runs on a timer or a cursor: every call is something the user
/// just did in a dialog and is watching the result of. That difference is why
/// the failures surface as exceptions for the dialog to show, rather than
/// being folded into a retry queue.
abstract class ShareApi {
  /// Every link this account has minted.
  Future<List<ShareState>> list();

  /// Publishes [noteId], or republishes it if a link already exists.
  ///
  /// The server upserts on the note, so this returns the token the user has
  /// already handed out rather than minting a rival one.
  Future<ShareState> publish({
    required String noteId,
    required SealedBox sealed,
    required ShareVisibility visibility,
    required ShareExpiry expiry,
  });

  /// Changes one thing about an existing link. [sealed] republishes the copy
  /// visitors read; the other two are settings and cost no re-sealing.
  Future<ShareState> update(
    String token, {
    ShareVisibility? visibility,
    ShareExpiry? expiry,
    SealedBox? sealed,
  });

  /// Unpublishes for good, freeing the token. Distinct from pausing.
  Future<void> revoke(String token);
}

class HttpShareApi implements ShareApi {
  HttpShareApi({
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
  Future<List<ShareState>> list() async {
    final body = await _send('GET', _baseUrl.resolve('shares'));
    final shares = body['shares'];
    return shares is List
        ? shares.map(ShareState.fromJson).whereType<ShareState>().toList()
        : const [];
  }

  @override
  Future<ShareState> publish({
    required String noteId,
    required SealedBox sealed,
    required ShareVisibility visibility,
    required ShareExpiry expiry,
  }) async {
    final body = await _send(
      'POST',
      _baseUrl.resolve('shares'),
      payload: {
        'noteId': noteId,
        'sealed': sealed.toJson(),
        'visibility': visibility.wire,
        'expiry': expiry.wire,
      },
    );
    return _parse(body);
  }

  @override
  Future<ShareState> update(
    String token, {
    ShareVisibility? visibility,
    ShareExpiry? expiry,
    SealedBox? sealed,
  }) async {
    final body = await _send(
      'PATCH',
      _baseUrl.resolve('shares/$token'),
      payload: {
        if (visibility != null) 'visibility': visibility.wire,
        if (expiry != null) 'expiry': expiry.wire,
        if (sealed != null) 'sealed': sealed.toJson(),
      },
    );
    return _parse(body);
  }

  @override
  Future<void> revoke(String token) async {
    // A share already gone is a share revoked: two devices racing to turn the
    // same link off both did what was asked.
    await _send('DELETE', _baseUrl.resolve('shares/$token'), absentIsNull: true);
  }

  static ShareState _parse(Map<String, Object?> body) {
    final state = ShareState.fromJson(body);
    if (state == null) throw const SyncProtocolException('malformed share');
    return state;
  }

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
      throw SyncTransientException('$error');
    }

    final status = response.statusCode;
    if (status == 401 || status == 403) {
      throw const SyncAuthException('session rejected');
    }
    if (status == 404 && absentIsNull) return const {};
    if (status == 413) {
      throw const SyncProtocolException('this note is too long to share');
    }
    if (status == 429 || status >= 500) {
      throw SyncTransientException('server returned $status');
    }
    if (status >= 400) throw SyncProtocolException('server returned $status');
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
