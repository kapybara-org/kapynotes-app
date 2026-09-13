import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sync/sync_api.dart';
import 'entitlements.dart';

/// What the server says an account owns, once it has claimed it.
class AdoptedPurchases {
  const AdoptedPurchases({
    required this.claimed,
    required this.heldByAnother,
    required this.entitlements,
  });

  /// The skus this account has just taken ownership of. Empty is the ordinary
  /// answer: almost every purchase arrives by webhook, already owned.
  final List<String> claimed;

  /// Something bought on this store account belongs to a different Kapy Notes
  /// account, and stays there.
  final bool heldByAnother;

  final Entitlements entitlements;

  static AdoptedPurchases fromJson(Map<String, Object?> raw) =>
      AdoptedPurchases(
        claimed: [
          for (final sku
              in raw['claimed'] is List ? raw['claimed'] as List : const [])
            if (sku is String) sku,
        ],
        heldByAnother: raw['heldByAnother'] == true,
        entitlements: Entitlements.fromJson(
          raw['entitlements'] is Map
              ? (raw['entitlements'] as Map).cast<String, Object?>()
              : const {},
        ),
      );
}

/// The server's half of billing: what this account may do.
///
/// A purchase normally reaches it without passing through here at all — store
/// to RevenueCat to the webhook — and [entitlements] is how the app finds out
/// it arrived. [adopt] is for the one purchase that cannot: the one made
/// before there was an account to grant it to.
abstract class BillingApi {
  Future<Entitlements> entitlements();

  /// Asks the server to claim whatever the store already holds for this
  /// account. Called once, on signing in.
  Future<AdoptedPurchases> adopt();

  /// Creates an identified RevenueCat checkout for this signed-in account.
  Future<Uri> webCheckout();
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

  @override
  Future<AdoptedPurchases> adopt() async =>
      AdoptedPurchases.fromJson(await _json('POST', 'billing/adopt'));

  @override
  Future<Uri> webCheckout() async {
    final raw = (await _json('POST', 'billing/web-checkout'))['url'];
    final url = raw is String ? Uri.tryParse(raw) : null;
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      throw const SyncTransientException(
        'server returned an invalid checkout URL',
        answered: true,
      );
    }
    return url;
  }

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
