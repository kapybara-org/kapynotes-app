import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/system_region.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/release_history.dart';
import 'package:kapy_notes/data/store_updates.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'support/store_updates.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'store-updates-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// [body] as a server sends JSON, in UTF-8.
http.Response _json(Object? body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

/// The store's answer as it was given [age] ago.
void _answered(LocalStore store, Duration age, Map<String, Object?> offer) =>
    store.data['storeUpdate.v1'] = {
      'askedAt': DateTime.now().subtract(age).toIso8601String(),
      'offer': offer,
    };

/// This phone, running 1.35.4 as build 46, asking the real stores, with
/// [client] where the App Store or the changelog is asked.
StoreUpdates _asking(LocalStore store, http.Client client) {
  final updates = StoreUpdates(
    store,
    client: client,
    packageInfo: PackageInfo(
      appName: 'Kapy Notes',
      packageName: StoreUpdates.bundleId,
      version: '1.35.4',
      buildNumber: '46',
    ),
  );
  addTearDown(updates.dispose);
  return updates;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('compareVersions', () {
    test('orders versions part by part, as numbers', () {
      expect(compareVersions('1.35.10', '1.35.9'), greaterThan(0));
      expect(compareVersions('1.35.4', '1.36.0'), lessThan(0));
      expect(compareVersions('2.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('1.35.4', '1.35.4'), 0);
      expect(compareVersions('1.35', '1.35.0'), 0);
      expect(compareVersions(' 1.35.5 ', '1.35.4'), greaterThan(0));
    });

    test('reads nothing into a version written any other way', () {
      for (final odd in [
        '',
        'v1.35.5',
        '1.35.5-beta',
        '1..2',
        '1.2.3.4.5',
        'latest',
        '1.35.5 (47)',
        '1234567',
      ]) {
        expect(compareVersions(odd, '1.35.4'), isNull, reason: odd);
        expect(compareVersions('1.35.4', odd), isNull, reason: odd);
      }
    });
  });

  test('an answer that names no release it can read is no answer', () {
    for (final odd in <Object?>[
      null,
      'text',
      3,
      <Object?>[],
      <String, Object?>{},
      {'version': ''},
      {'version': 'soon'},
      {'version': 1.35},
      {'build': 0},
      {'build': -3},
      {'build': '47'},
    ]) {
      expect(StoreOffer.fromJson(odd), isNull, reason: '$odd');
    }
    expect(StoreOffer.fromJson({'version': '1.35.5'})?.name, '1.35.5');
    expect(StoreOffer.fromJson({'build': 47})?.name, '47');
    const offer = StoreOffer(
      version: '1.35.5',
      notes: 'Swipe a note to pin it.',
      released: '2026-11-25T12:00:00Z',
    );
    expect(StoreOffer.fromJson(offer.toJson())?.toJson(), offer.toJson());
  });

  group('StoreUpdates', () {
    test('a newer version in the store is an update, until this phone has '
        'it', () async {
      final store = _Store();
      var asked = 0;
      Future<StoreOffer?> answer() async {
        asked++;
        return const StoreOffer(version: '1.35.5');
      }

      final updates = fakeStoreUpdates(store, answer: answer);
      await updates.check();
      expect(updates.update?.version, '1.35.5');
      expect(updates.isLatest, isFalse);
      expect(updates.updateUnseen, isTrue);

      // Updated the same day: the day's answer stands, and now says this is
      // the latest.
      final updated = fakeStoreUpdates(
        store,
        installed: '1.35.5',
        build: 47,
        answer: answer,
      );
      await updated.check();
      expect(asked, 1);
      expect(updated.update, isNull);
      expect(updated.isLatest, isTrue);
      expect(updated.updateUnseen, isFalse);
    });

    test('an older version in the store is no update', () async {
      final updates = fakeStoreUpdates(
        _Store(),
        answer: () async => const StoreOffer(version: '1.35.3'),
      );
      await updates.check();
      expect(updates.update, isNull);
      expect(updates.updateUnseen, isFalse);
      expect(updates.isLatest, isTrue);
    });

    test('no answer claims neither an update nor the latest version', () async {
      for (final answer in <Future<StoreOffer?> Function()>[
        () async => null,
        () async => throw const SocketException('offline'),
        () async => throw const FormatException('not an answer'),
      ]) {
        final store = _Store();
        final updates = fakeStoreUpdates(store, answer: answer);
        await updates.check();
        expect(updates.latest, isNull);
        expect(updates.update, isNull);
        expect(updates.isLatest, isFalse);
        expect(store.data, isNot(contains('storeUpdate.v1')));
      }
    });

    test('a store that never answers is given up on', () {
      fakeAsync((async) {
        final updates = fakeStoreUpdates(
          _Store(),
          answer: () => Completer<StoreOffer?>().future,
        );
        var done = false;
        unawaited(updates.check().then((_) => done = true));
        async.elapse(const Duration(seconds: 7));
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(done, isTrue);
        expect(updates.update, isNull);
        expect(updates.isLatest, isFalse);
      });
    });

    test('the store hears from this phone at most once a day', () async {
      final store = _Store();
      var asked = 0;
      Future<StoreOffer?> answer() async {
        asked++;
        return const StoreOffer(version: '1.35.4');
      }

      final updates = fakeStoreUpdates(store, answer: answer);
      await Future.wait([updates.check(), updates.check()]);
      await updates.check();
      expect(asked, 1);

      // Settings opened again later the same day keeps the answer it has.
      await fakeStoreUpdates(store, answer: answer).check();
      expect(asked, 1);

      // A day on, the store is asked again.
      _answered(store, const Duration(hours: 25), {'version': '1.35.4'});
      await fakeStoreUpdates(store, answer: answer).check();
      expect(asked, 2);

      // And when the clock has gone back past the last answer.
      _answered(store, const Duration(hours: -5), {'version': '1.35.4'});
      await fakeStoreUpdates(store, answer: answer).check();
      expect(asked, 3);
    });

    test('a day-old answer no longer says this is the latest', () async {
      final store = _Store();
      _answered(store, const Duration(hours: 25), {'version': '1.35.4'});
      final updates = fakeStoreUpdates(
        store,
        answer: () async => throw const SocketException('offline'),
      );
      await updates.check();
      expect(updates.latest?.version, '1.35.4');
      expect(updates.isLatest, isFalse);
    });

    test('an update seen stays seen, until the store offers another', () async {
      final store = _Store();
      final updates = fakeStoreUpdates(
        store,
        answer: () async => const StoreOffer(version: '1.35.5'),
      );
      await updates.check();
      var told = 0;
      updates.addListener(() => told++);
      updates.markSeen();
      expect(updates.updateUnseen, isFalse);
      expect(told, 1);
      updates.markSeen();
      expect(told, 1, reason: 'nothing new to say');

      final again = fakeStoreUpdates(
        store,
        answer: () async => const StoreOffer(version: '1.35.5'),
      );
      await again.check();
      expect(again.updateUnseen, isFalse, reason: 'seen stays seen');

      _answered(store, const Duration(hours: 25), {'version': '1.35.5'});
      final next = fakeStoreUpdates(
        store,
        answer: () async => const StoreOffer(version: '1.35.6'),
      );
      await next.check();
      expect(next.updateUnseen, isTrue);
    });
  });

  group('the App Store', () {
    String? region = 'IN';
    setUp(() {
      region = 'IN';
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      messenger.setMockMethodCallHandler(
        SystemRegion.channel,
        (_) async => region,
      );
    });
    tearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(SystemRegion.channel, null);
    });

    Map<String, Object?> listing({
      String bundleId = StoreUpdates.bundleId,
      String version = '1.35.5',
      String? minimumOsVersion,
    }) => {
      'bundleId': bundleId,
      'version': version,
      'releaseNotes': 'Kapy Notes 1.35.5\n\n- Swipe a note to pin it.',
      'currentVersionReleaseDate': '2026-11-25T12:00:00Z',
      'minimumOsVersion': ?minimumOsVersion,
    };

    http.Response answer(List<Object?> results) =>
        _json({'resultCount': results.length, 'results': results});

    test('is asked for this app in the country the phone is set to, and '
        'nothing more', () async {
      final asked = <Uri>[];
      final updates = _asking(
        _Store(),
        MockClient((request) async {
          asked.add(request.url);
          return answer([listing()]);
        }),
      );
      await updates.check();
      expect(
        asked.single,
        Uri.parse(
          'https://itunes.apple.com/lookup'
          '?bundleId=com.kapybara.kapynotes&country=in',
        ),
      );
      final offer = updates.update!;
      expect(offer.version, '1.35.5');
      expect(offer.notes, contains('Swipe a note to pin it.'));
      expect(offer.released, '2026-11-25T12:00:00Z');

      region = null;
      asked.clear();
      await _asking(
        _Store(),
        MockClient((request) async {
          asked.add(request.url);
          return answer([listing()]);
        }),
      ).check();
      expect(asked.single.queryParameters, {'bundleId': StoreUpdates.bundleId});
    });

    test(
      'an answer it cannot read, or about another app, is no answer',
      () async {
        for (final response in [
          http.Response('', 500),
          http.Response('<html>busy</html>', 200),
          _json({'results': 'none'}),
          answer([]),
          answer(['1.35.5']),
          answer([listing(bundleId: 'com.example.other')]),
          answer([listing(version: 'next')]),
        ]) {
          final updates = _asking(_Store(), MockClient((_) async => response));
          await updates.check();
          expect(updates.latest, isNull, reason: response.body);
          expect(updates.isLatest, isFalse);
        }
      },
    );

    test('a version this iOS cannot run is not offered', () async {
      final updates = _asking(
        _Store(),
        MockClient((_) async => answer([listing(minimumOsVersion: '999.0')])),
      );
      await updates.check();
      expect(updates.latest, isNull);
      expect(updates.update, isNull);

      final runs = _asking(
        _Store(),
        MockClient((_) async => answer([listing(minimumOsVersion: '1.0')])),
      );
      await runs.check();
      expect(runs.update?.version, '1.35.5');
    });
  });

  group('Google Play', () {
    setUp(
      () => AppPlatform.debugTargetPlatformOverride = TargetPlatform.android,
    );
    tearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(StoreUpdates.playChannel, null);
    });

    void play(Object? Function() reply) => messenger.setMockMethodCallHandler(
      StoreUpdates.playChannel,
      (call) async {
        expect(call.method, 'check');
        return reply();
      },
    );

    test('names the update it has by its build', () async {
      play(() => {'available': true, 'versionCode': 47});
      final updates = _asking(
        _Store(),
        MockClient((_) async => http.Response('', 500)),
      );
      await updates.check();
      expect(updates.update?.build, 47);
      expect(updates.update?.name, '47');
      expect(updates.isLatest, isFalse);
    });

    test('with nothing newer, this is the latest', () async {
      play(() => {'available': false});
      final updates = _asking(
        _Store(),
        MockClient((_) async => http.Response('', 500)),
      );
      await updates.check();
      expect(updates.update, isNull);
      expect(updates.isLatest, isTrue);
    });

    test(
      'a copy Play did not install gets no answer, and claims nothing',
      () async {
        for (final reply in <Object? Function()>[
          () => null,
          () => throw PlatformException(code: 'ERROR_APP_NOT_OWNED'),
          () => {'available': true},
          () => {'available': true, 'versionCode': 0},
          () => {'available': 'yes'},
        ]) {
          play(reply);
          final updates = _asking(
            _Store(),
            MockClient((_) async => http.Response('', 500)),
          );
          await updates.check();
          expect(updates.latest, isNull);
          expect(updates.isLatest, isFalse);
        }
      },
    );

    test('what its update brings is found in the changelog by build', () async {
      play(() => {'available': true, 'versionCode': 47});
      final asked = <Uri>[];
      final updates = _asking(
        _Store(),
        MockClient((request) async {
          asked.add(request.url);
          return _json({'releases': aboutReleases()});
        }),
      );
      await updates.check();
      await updates.loadNotes();
      expect(asked.single, ReleaseHistory.url);
      expect(updates.noteFor(updates.update!)?.version, '1.35.5');
      expect(updates.installedNote?.version, '1.35.4');
    });

    test('a changelog without the build has nothing to say about it', () async {
      play(() => {'available': true, 'versionCode': 48});
      final updates = _asking(
        _Store(),
        MockClient((_) async => _json({'releases': aboutReleases()})),
      );
      await updates.check();
      await updates.loadNotes();
      expect(updates.update?.build, 48);
      expect(updates.noteFor(updates.update!), isNull);
    });
  });
}
