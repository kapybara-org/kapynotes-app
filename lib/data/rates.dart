import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'local_store.dart';

const List<String> _monthAbbreviations = [
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

String _formatDisplayDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')} '
    '${_monthAbbreviations[date.month - 1]} ${date.year}';

/// The service that supplied a complete rate snapshot.
enum RateProvider {
  frankfurter(
    cacheValue: 'frankfurter',
    attributionLabel: 'Rates by Frankfurter',
    attributionUrlValue: 'https://frankfurter.dev',
  ),
  exchangeRateApi(
    cacheValue: 'exchange-rate-api',
    attributionLabel: 'Rates By Exchange Rate API',
    attributionUrlValue: 'https://www.exchangerate-api.com',
  );

  const RateProvider({
    required this.cacheValue,
    required this.attributionLabel,
    required this.attributionUrlValue,
  });

  final String cacheValue;
  final String attributionLabel;
  final String attributionUrlValue;

  Uri get attributionUrl => Uri.parse(attributionUrlValue);

  /// Source-less snapshots predate Frankfurter and came from ExchangeRate-API.
  static RateProvider fromCache(Object? raw) {
    for (final provider in values) {
      if (provider.cacheValue == raw) return provider;
    }
    return exchangeRateApi;
  }
}

/// A snapshot of exchange rates, expressed as units per 1 USD.
@immutable
class RateSnapshot {
  final String base;
  final String date;
  final DateTime fetchedAt;
  final Map<String, double> rates;
  final RateProvider provider;

  const RateSnapshot({
    required this.base,
    required this.date,
    required this.fetchedAt,
    required this.rates,
    // Every persisted snapshot before this field was introduced was fetched
    // from ExchangeRate-API, so that is the safe compatibility default.
    this.provider = RateProvider.exchangeRateApi,
  });

  String get refreshedDate => fetchedAt.millisecondsSinceEpoch > 0
      ? _formatDisplayDate(fetchedAt.toLocal())
      : date;

  Map<String, Object?> toJson() => {
    'base': base,
    'date': date,
    'fetchedAt': fetchedAt.millisecondsSinceEpoch,
    'rates': rates,
    'provider': provider.cacheValue,
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
      provider: RateProvider.fromCache(raw['provider']),
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
  static const int _minimumRateCount = 20;
  static const Set<String> _requiredRateCodes = {
    'USD',
    'EUR',
    'GBP',
    'JPY',
    'INR',
  };
  static final Uri frankfurterEndpoint = Uri.parse(
    'https://api.frankfurter.dev/v2/rates?base=USD',
  );
  static final Uri exchangeRateApiEndpoint = Uri.parse(
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
  RateProvider get provider => _snapshot?.provider ?? RateProvider.frankfurter;
  String get attributionLabel => provider.attributionLabel;
  Uri get attributionUrl => provider.attributionUrl;
  String get refreshedDate => _snapshot?.refreshedDate ?? '';

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
      final primary = await _fetchSnapshot(
        client,
        provider: RateProvider.frankfurter,
        endpoint: frankfurterEndpoint,
        parse: _parseFrankfurter,
      );
      if (_disposed) return;
      final snapshot =
          primary ??
          await _fetchSnapshot(
            client,
            provider: RateProvider.exchangeRateApi,
            endpoint: exchangeRateApiEndpoint,
            parse: _parseExchangeRateApi,
          );
      if (_disposed || snapshot == null) return;
      _snapshot = snapshot;
      _store.put(_key, snapshot.toJson());
    } catch (error) {
      // An unexpected repository failure must never displace the good cache.
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

  Future<RateSnapshot?> _fetchSnapshot(
    http.Client client, {
    required RateProvider provider,
    required Uri endpoint,
    required RateSnapshot? Function(Object?, DateTime) parse,
  }) async {
    try {
      final response = await client.get(endpoint).timeout(timeout);
      if (response.statusCode != 200) {
        debugPrint(
          'KapyNotes: ${provider.cacheValue} returned '
          'HTTP ${response.statusCode}',
        );
        return null;
      }
      final snapshot = parse(jsonDecode(response.body), DateTime.now());
      if (snapshot == null) {
        debugPrint('KapyNotes: ${provider.cacheValue} returned invalid rates');
      }
      return snapshot;
    } catch (error) {
      // Offline, timed out, malformed, or rate-limited: let the next provider
      // try, then keep serving the last good cached snapshot if both fail.
      debugPrint('KapyNotes: ${provider.cacheValue} refresh failed: $error');
      return null;
    }
  }

  static RateSnapshot? _parseFrankfurter(Object? decoded, DateTime fetchedAt) {
    if (decoded is! List) return null;
    final parsed = <String, double>{'USD': 1};
    DateTime? latestRateDate;

    for (final row in decoded) {
      if (row is! Map || row['base'] != 'USD') continue;
      final quote = row['quote'];
      final rate = row['rate'];
      if (quote is! String || rate is! num || !rate.isFinite || rate <= 0) {
        continue;
      }
      parsed[quote.toUpperCase()] = rate.toDouble();

      final rawDate = row['date'];
      final date = rawDate is String ? DateTime.tryParse(rawDate) : null;
      if (date != null &&
          (latestRateDate == null || date.isAfter(latestRateDate))) {
        latestRateDate = date;
      }
    }

    if (!_ratesAreUsable(parsed)) return null;
    return RateSnapshot(
      base: 'USD',
      date: latestRateDate == null ? '' : _formatDisplayDate(latestRateDate),
      fetchedAt: fetchedAt,
      rates: parsed,
      provider: RateProvider.frankfurter,
    );
  }

  static RateSnapshot? _parseExchangeRateApi(
    Object? decoded,
    DateTime fetchedAt,
  ) {
    if (decoded is! Map ||
        decoded['result'] != 'success' ||
        decoded['base_code'] != 'USD') {
      return null;
    }
    final rawRates = decoded['rates'];
    if (rawRates is! Map) return null;
    final parsed = <String, double>{};
    rawRates.forEach((key, value) {
      if (key is String && value is num && value.isFinite && value > 0) {
        parsed[key.toUpperCase()] = value.toDouble();
      }
    });
    parsed['USD'] = 1;
    if (!_ratesAreUsable(parsed)) return null;

    return RateSnapshot(
      base: 'USD',
      date: _readExchangeRateDate(decoded),
      fetchedAt: fetchedAt,
      rates: parsed,
      provider: RateProvider.exchangeRateApi,
    );
  }

  static bool _ratesAreUsable(Map<String, double> rates) {
    if (rates.length < _minimumRateCount) return false;
    for (final code in _requiredRateCodes) {
      final rate = rates[code];
      if (rate == null || !rate.isFinite || rate <= 0) return false;
    }
    return true;
  }

  static String _readExchangeRateDate(Map<Object?, Object?> decoded) {
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
      return _formatDisplayDate(date);
    }
    return '';
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _client?.close();
    super.dispose();
  }
}
