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
      expect(repository.isStale, isFalse);
    },
  );

  test('automatically refreshes a stale cached snapshot', () async {
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
    var requests = 0;
    final repository = RatesRepository(
      store,
      client: MockClient((_) async {
        requests++;
        return http.Response(
          jsonEncode({
            'result': 'success',
            'base_code': 'USD',
            'rates': {'USD': 1, 'INR': 82, 'EUR': 0.9},
          }),
          200,
        );
      }),
    );
    addTearDown(repository.dispose);

    await repository.initialize();

    expect(requests, 1);
    expect(repository.rates['INR'], 82);
    expect(repository.rates['EUR'], 0.9);
    expect(repository.isStale, isFalse);
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
    response.complete(
      http.Response(
        jsonEncode({
          'result': 'success',
          'base_code': 'USD',
          'rates': {'USD': 1, 'INR': 82},
        }),
        200,
      ),
    );
    await refresh;

    // The widget-test binding also verifies that no refresh timer survived.
    expect(repository.isRefreshing, isFalse);
  });
}
