import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sync/sync_api.dart';
import 'entitlements.dart';

/// Reads the server-authoritative plan and usage totals for one account.
abstract class BillingApi {
  Future<Entitlements> entitlements();
}

class HttpBillingApi implements BillingApi {
  HttpBillingApi({
    required Uri baseUrl,
    required String token,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _baseUrl = baseUrl,
       _token = token,
       _client = client ?? http.Client();

  final Uri _baseUrl;
  final String _token;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<Entitlements> entitlements() async {
    final request =
        http.Request('GET', _baseUrl.resolve('billing/entitlements'))
          ..headers['authorization'] = 'Bearer $_token'
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

    if (response.statusCode == 401) {
      throw const SyncAuthException('session rejected');
    }
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw SyncTransientException(
        'server returned ${response.statusCode}',
        answered: true,
      );
    }
    final body = _decode(response.body);
    if (response.statusCode >= 400) {
      final code = body['error'];
      throw SyncRefusedException(
        response.statusCode,
        code is String ? code : 'error',
        body,
      );
    }
    return Entitlements.fromJson(body);
  }

  static Map<String, Object?> _decode(String body) {
    if (body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }
}
