// The exchange rates every integration test that launches the app runs with.
// The app refreshes its rates two seconds after launch, and a real client
// reached the live rates service, so a test could fail at teardown when that
// request was cut off. This client answers every request with one fixed
// Frankfurter reply and never touches the network. Not a test file itself, so
// neither workflow runs it on its own.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/rates.dart';

/// Rates that refresh as they would on a good network, so amounts in other
/// currencies still convert, without a request leaving the test.
RatesRepository offlineRates(LocalStore store) => RatesRepository(
  store,
  client: MockClient(
    (_) async => http.Response(
      jsonEncode([
        for (final MapEntry(key: quote, value: rate) in _perUsd.entries)
          {'date': '2026-11-20', 'base': 'USD', 'quote': quote, 'rate': rate},
      ]),
      200,
    ),
  ),
);

const _perUsd = {
  'AUD': 1.53,
  'BRL': 5.33,
  'CAD': 1.4,
  'CHF': 0.8,
  'CNY': 7.11,
  'CZK': 20.9,
  'DKK': 6.43,
  'EUR': 0.86,
  'GBP': 0.76,
  'HKD': 7.78,
  'HUF': 332.0,
  'INR': 88.7,
  'JPY': 156.4,
  'KRW': 1465.0,
  'MXN': 18.4,
  'NOK': 10.1,
  'NZD': 1.77,
  'PLN': 3.65,
  'SEK': 9.5,
  'SGD': 1.3,
  'THB': 32.4,
  'TRY': 42.3,
  'ZAR': 17.3,
};
