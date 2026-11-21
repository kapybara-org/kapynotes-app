import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/rates.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'rates-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

Map<String, double> _completeRates({double inr = 82}) => {
  'USD': 1,
  'AED': 3.67,
  'AUD': 1.5,
  'BRL': 5,
  'CAD': 1.35,
  'CHF': 0.88,
  'CNY': 7.2,
  'DKK': 6.8,
  'EUR': 0.9,
  'GBP': 0.8,
  'HKD': 7.8,
  'IDR': 15000,
  'INR': inr,
  'JPY': 150,
  'KRW': 1300,
  'MXN': 17,
  'NOK': 10.5,
  'NZD': 1.6,
  'SEK': 10,
  'SGD': 1.3,
  'THB': 35,
  'ZAR': 18,
};

List<Map<String, Object>> _frankfurterResponse({double inr = 82}) => [
  for (final entry in _completeRates(inr: inr).entries)
    if (entry.key != 'USD')
      {
        'date': entry.key == 'INR' ? '2026-09-02' : '2026-09-01',
        'base': 'USD',
        'quote': entry.key,
        'rate': entry.value,
      },
];

Map<String, Object> _exchangeRateApiResponse({double inr = 83}) => {
  'result': 'success',
  'base_code': 'USD',
  'time_last_update_utc': 'Wed, 02 Sep 2026 00:02:31 +0000',
  'rates': _completeRates(inr: inr),
};

void main() {
  test(
    'keeps a fresh cached snapshot and schedules it without fetching',
    () async {
      final store = _MemoryStore();
      store.put(
        'rates.v1',
        RateSnapshot(
          base: 'USD',
          date: 'cached',
          fetchedAt: DateTime.now(),
          rates: const {'USD': 1, 'INR': 80},
          provider: RateProvider.frankfurter,
        ).toJson(),
      );
      var requests = 0;
      final repository = RatesRepository(
        store,
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 500);
        }),
      );
      addTearDown(repository.dispose);

      await repository.initialize();

      expect(requests, 0);
      expect(repository.rates['INR'], 80);
      expect(repository.provider, RateProvider.frankfurter);
      expect(repository.isStale, isFalse);
    },
  );

  test(
    'refreshes a stale cache from Frankfurter without calling fallback',
    () async {
      final store = _MemoryStore();
      store.put(
        'rates.v1',
        RateSnapshot(
          base: 'USD',
          date: 'old',
          fetchedAt: DateTime.now().subtract(const Duration(hours: 7)),
          rates: const {'USD': 1, 'INR': 80},
        ).toJson(),
      );
      final requests = <Uri>[];
      final repository = RatesRepository(
        store,
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(jsonEncode(_frankfurterResponse(inr: 82)), 200);
        }),
      );
      addTearDown(repository.dispose);

      await repository.initialize();

      expect(requests, [RatesRepository.frankfurterEndpoint]);
      expect(repository.rates['INR'], 82);
      expect(repository.rates['EUR'], 0.9);
      expect(repository.rates['USD'], 1);
      expect(repository.snapshot?.date, '02 Sep 2026');
      expect(repository.provider, RateProvider.frankfurter);
      expect(repository.attributionLabel, 'Rates by Frankfurter');
      expect(repository.attributionUrl.toString(), 'https://frankfurter.dev');
      expect(repository.isStale, isFalse);
    },
  );

  test(
    'falls back to ExchangeRate-API when primary data is incomplete',
    () async {
      final store = _MemoryStore();
      final requests = <Uri>[];
      final repository = RatesRepository(
        store,
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url == RatesRepository.frankfurterEndpoint) {
            return http.Response(
              jsonEncode([
                {
                  'date': '2026-09-02',
                  'base': 'USD',
                  'quote': 'EUR',
                  'rate': 0.9,
                },
              ]),
              200,
            );
          }
          return http.Response(
            jsonEncode(_exchangeRateApiResponse(inr: 83)),
            200,
          );
        }),
      );
      addTearDown(repository.dispose);

      await repository.refresh();

      expect(requests, [
        RatesRepository.frankfurterEndpoint,
        RatesRepository.exchangeRateApiEndpoint,
      ]);
      expect(repository.rates['INR'], 83);
      expect(repository.snapshot?.date, '02 Sep 2026');
      expect(repository.provider, RateProvider.exchangeRateApi);
      expect(repository.attributionLabel, 'Rates By Exchange Rate API');
      expect(
        repository.attributionUrl.toString(),
        'https://www.exchangerate-api.com',
      );
    },
  );

  test('keeps the last good snapshot when both providers fail', () async {
    final store = _MemoryStore();
    final oldFetchedAt = DateTime.now().subtract(const Duration(days: 1));
    store.put(
      'rates.v1',
      RateSnapshot(
        base: 'USD',
        date: '01 Sep 2026',
        fetchedAt: oldFetchedAt,
        rates: _completeRates(inr: 80),
        provider: RateProvider.frankfurter,
      ).toJson(),
    );
    final requests = <Uri>[];
    final repository = RatesRepository(
      store,
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response('{}', 503);
      }),
    );
    addTearDown(repository.dispose);
    repository.loadCache();

    await repository.refresh();

    expect(requests, [
      RatesRepository.frankfurterEndpoint,
      RatesRepository.exchangeRateApiEndpoint,
    ]);
    expect(repository.rates['INR'], 80);
    expect(
      repository.snapshot?.fetchedAt.millisecondsSinceEpoch,
      oldFetchedAt.millisecondsSinceEpoch,
    );
    expect(repository.provider, RateProvider.frankfurter);
  });

  test('treats a legacy source-less cache as ExchangeRate-API data', () {
    final store = _MemoryStore();
    store.put('rates.v1', {
      'base': 'USD',
      'date': '01 Sep 2026',
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      'rates': _completeRates(),
    });
    final repository = RatesRepository(store);
    addTearDown(repository.dispose);

    repository.loadCache();

    expect(repository.provider, RateProvider.exchangeRateApi);
    expect(repository.attributionLabel, 'Rates By Exchange Rate API');
  });

  testWidgets('does not reschedule after disposal during a refresh', (
    tester,
  ) async {
    final requestStarted = Completer<void>();
    final response = Completer<http.Response>();
    final repository = RatesRepository(
      _MemoryStore(),
      client: MockClient((_) {
        requestStarted.complete();
        return response.future;
      }),
    );

    final refresh = repository.refresh();
    await requestStarted.future;
    repository.dispose();
    response.complete(http.Response(jsonEncode(_frankfurterResponse()), 200));
    await refresh;

    // The widget-test binding also verifies that no refresh timer survived.
    expect(repository.isRefreshing, isFalse);
  });
}
