import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'local_store.dart';

/// A snapshot of exchange rates, expressed as units per 1 USD.
@immutable
class RateSnapshot {
  final String base;
  final String date;
  final DateTime fetchedAt;
  final Map<String, double> rates;

  const RateSnapshot({
    required this.base,
    required this.date,
    required this.fetchedAt,
    required this.rates,
  });

  Map<String, Object?> toJson() => {
    'base': base,
    'date': date,
    'fetchedAt': fetchedAt.millisecondsSinceEpoch,
    'rates': rates,
  };

  static RateSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rates = raw['rates'];
    if (rates is! Map) return null;
    final parsed = <String, double>{};
    rates.forEach((key, value) {
      if (key is String && value is num) parsed[key] = value.toDouble();
    });
    if (parsed.isEmpty) return null;
    return RateSnapshot(
      base: raw['base'] is String ? raw['base'] as String : 'USD',
      date: raw['date'] is String ? raw['date'] as String : '',
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(
        raw['fetchedAt'] is int ? raw['fetchedAt'] as int : 0,
      ),
      rates: parsed,
    );
  }
}

/// Fetches and caches exchange rates.
///
/// Offline-first: the cached snapshot is published before any network call is
/// made, so currency maths is available on the first frame and stays
/// available with the network unplugged. A refresh only ever replaces good
/// data with newer good data — a failed fetch changes nothing.
class RatesRepository extends ChangeNotifier {
  static const String _key = 'rates.v1';
  static const Duration staleAfter = Duration(hours: 6);
  static const Duration retryAfter = Duration(minutes: 15);
  static const Duration timeout = Duration(seconds: 8);
  static final Uri endpoint = Uri.parse(
    'https://open.er-api.com/v6/latest/USD',
  );

  final LocalStore _store;
  http.Client? _client;

  RateSnapshot? _snapshot;
  bool _refreshing = false;
  bool _disposed = false;
  bool _cacheLoaded = false;
  Timer? _refreshTimer;

  RatesRepository(this._store, {http.Client? client}) : _client = client;

  RateSnapshot? get snapshot => _snapshot;
  bool get isRefreshing => _refreshing;
  bool get hasRates => _snapshot != null;

  Map<String, double> get rates => _snapshot?.rates ?? const {};

  bool get isStale {
    final fetched = _snapshot?.fetchedAt;
    if (fetched == null) return true;
    return !DateTime.now().isBefore(fetched.add(staleAfter));
  }

  /// Publishes persisted rates without creating an HTTP client or refreshing.
  void loadCache() {
    if (_disposed || _cacheLoaded) return;
    _cacheLoaded = true;
    _snapshot = RateSnapshot.fromJson(_store.read<Map<String, Object?>>(_key));
    notifyListeners();
  }

  /// Loads the cache, refreshes if stale, then keeps refreshing automatically.
  Future<void> initialize() async {
    if (_disposed) return;
    loadCache();
    await refreshIfStale();
  }

  /// Refreshes on launch, resume, or the scheduled stale time when needed.
  Future<void> refreshIfStale() async {
    if (_disposed) return;
    if (isStale) {
      await refresh();
    } else {
      _scheduleNextRefresh();
    }
  }

  Future<void> refresh() async {
    if (_disposed || _refreshing) return;
    _refreshTimer?.cancel();
    _refreshing = true;
    notifyListeners();

    try {
      final client = _client ??= http.Client();
      final response = await client.get(endpoint).timeout(timeout);
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return;
      if (decoded['result'] == 'error') return;

      final rawRates = decoded['rates'];
      if (rawRates is! Map) return;
      final parsed = <String, double>{};
      rawRates.forEach((key, value) {
        if (key is String && value is num && value > 0) {
          parsed[key] = value.toDouble();
        }
      });
      if (parsed.isEmpty) return;

      final snapshot = RateSnapshot(
        base: decoded['base_code'] as String? ?? 'USD',
        date: _readDate(decoded),
        fetchedAt: DateTime.now(),
        rates: parsed,
      );
      if (_disposed) return;
      _snapshot = snapshot;
      _store.put(_key, snapshot.toJson());
    } catch (error) {
      // Offline, timed out, or rate-limited: keep serving the cache.
      debugPrint('KapyNotes: rate refresh failed: $error');
    } finally {
      _refreshing = false;
      if (!_disposed) {
        notifyListeners();
        _scheduleNextRefresh();
      }
    }
  }

  void _scheduleNextRefresh() {
    if (_disposed) return;
    _refreshTimer?.cancel();
    final fetched = _snapshot?.fetchedAt;
    final untilStale = fetched?.add(staleAfter).difference(DateTime.now());
    final delay = untilStale != null && untilStale > Duration.zero
        ? untilStale
        : retryAfter;
    _refreshTimer = Timer(delay, () => unawaited(refreshIfStale()));
  }

  static String _readDate(Map<Object?, Object?> decoded) {
    final raw = decoded['time_last_update_utc'];
    if (raw is String && raw.length >= 16) {
      // "Tue, 01 Sep 2026 00:02:31 +0000" → "01 Sep 2026"
      final parts = raw.split(' ');
      if (parts.length >= 4) return '${parts[1]} ${parts[2]} ${parts[3]}';
    }
    final unix = decoded['time_last_update_unix'];
    if (unix is int) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        unix * 1000,
        isUtc: true,
      );
      return '${date.day.toString().padLeft(2, '0')} '
          '${_months[date.month - 1]} ${date.year}';
    }
    return '';
  }

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _client?.close();
    super.dispose();
  }
}
