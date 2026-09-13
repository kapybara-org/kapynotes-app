import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/local_store.dart';
import 'billing_api.dart';
import 'entitlements.dart';

/// Follows the active account and keeps its plan and usage answer current.
class PlanUsage extends ChangeNotifier {
  PlanUsage({
    required Listenable session,
    required String? Function() userId,
    required String? Function() token,
    required BillingApi Function(String token) api,
    LocalStore? cache,
  }) : _session = session,
       _userIdOf = userId,
       _tokenOf = token,
       _apiFor = api,
       _cache = cache {
    _session.addListener(_onSession);
    _onSession();
  }

  static const _cacheKey = 'plan-usage.v1';

  final Listenable _session;
  final String? Function() _userIdOf;
  final String? Function() _tokenOf;
  final BillingApi Function(String token) _apiFor;
  final LocalStore? _cache;

  String? _userId;
  Entitlements? _entitlements;
  bool _refreshing = false;
  bool _refreshFailed = false;

  String? get userId => _userId;
  bool get isSignedIn => _userId != null;
  Entitlements? get entitlements => _entitlements;
  bool get refreshing => _refreshing;
  bool get refreshFailed => _refreshFailed;

  void _onSession() {
    final id = _userIdOf();
    if (id == _userId) return;
    _userId = id;
    // A request for the previous account may still finish, but it must not
    // leave the new account looking permanently busy.
    _refreshing = false;
    _refreshFailed = false;
    _entitlements = id == null ? null : _readCache(id);
    notifyListeners();
    if (id != null) unawaited(refresh());
  }

  /// Fetches fresh totals. A cached answer remains visible if the network is
  /// unavailable, with a small retry affordance instead of an empty pane.
  Future<Entitlements?> refresh() async {
    final id = _userId;
    final token = _tokenOf();
    if (id == null || token == null || _refreshing) return _entitlements;
    _refreshing = true;
    _refreshFailed = false;
    notifyListeners();
    try {
      final fresh = await _apiFor(token).entitlements();
      if (_userId != id) return null;
      _entitlements = fresh;
      _cache?.put(_cacheKey, {'userId': id, 'entitlements': fresh.toJson()});
      return fresh;
    } catch (error) {
      debugPrint('KapyNotes: could not read plan usage: $error');
      if (_userId == id) _refreshFailed = true;
      return null;
    } finally {
      if (_userId == id) {
        _refreshing = false;
        notifyListeners();
      }
    }
  }

  Entitlements? _readCache(String id) {
    final raw = _cache?.read<Map<String, Object?>>(_cacheKey);
    if (raw == null || raw['userId'] != id) return null;
    final stored = raw['entitlements'];
    return stored is Map
        ? Entitlements.fromJson(stored.cast<String, Object?>())
        : null;
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    super.dispose();
  }
}
