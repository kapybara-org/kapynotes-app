import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sync/sync_api.dart';
import 'entitlements.dart';

/// The server's half of billing: what this account may do.
///
/// Purchases themselves never pass through here. They go from the store to
/// RevenueCat to the server's webhook, and this is how the app finds out they
/// arrived.
abstract class BillingApi {
  Future<Entitlements> entitlements();
}

class HttpBillingApi implements BillingApi {
  HttpBillingApi({
    required Uri baseUrl,
    required Future<String?> Function() token,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _baseUrl = baseUrl,
       _token = token,
       _client = client ?? http.Client();

  final Uri _baseUrl;
  final Future<String?> Function() _token;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<Entitlements> entitlements() async =>
      Entitlements.fromJson(await _json('GET', 'billing/entitlements'));

  /// The same request shape and error ladder as the speech client, so a
  /// billing failure reads like every other server failure in the app.
  Future<Map<String, Object?>> _json(String method, String path) async {
    final token = await _token();
    if (token == null) throw const SyncAuthException('not signed in');

    final request = http.Request(method, _baseUrl.resolve(path))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json'
      ..headers[protocolHeader] = '$protocolVersion';

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
    if (status == 401) throw const SyncAuthException('session rejected');
    if (status == 429 || status >= 500) {
      throw SyncTransientException('server returned $status', answered: true);
    }

    final decoded = _decode(response.body);
    if (status >= 400) {
      final code = decoded['error'];
      throw SyncRefusedException(
        status,
        code is String ? code : 'error',
        decoded,
      );
    }
    return decoded;
  }

  Map<String, Object?> _decode(String body) {
    if (body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }
}
