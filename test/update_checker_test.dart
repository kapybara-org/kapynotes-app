import 'dart:convert';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'update-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

PackageInfo _installed({String version = '1.0.0', String build = '1'}) =>
    PackageInfo(
      appName: 'Kapy Notes',
      packageName: 'com.kapybara.kapynotes',
      version: version,
      buildNumber: build,
    );

String _manifest({String version = '1.0.1', int build = 2}) => jsonEncode({
  'version': version,
  'build': build,
  'notesUrl': 'https://github.com/kapybara-org/kapynotes/releases/tag/v$version',
  'publishedAt': '2026-09-03T00:00:00Z',
});

UpdateChecker _checker(
  LocalStore store, {
  required http.Client client,
  PackageInfo? installed,
}) => UpdateChecker(
  store,
  client: client,
  packageInfo: installed ?? _installed(),
);

void main() {
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  test('offers a release that is ahead of the running build', () async {
    final store = _MemoryStore();
    final checker = _checker(
      store,
      client: MockClient((_) async => http.Response(_manifest(), 200)),
    );

    await checker.check();

    expect(checker.hasUpdate, isTrue);
    expect(checker.available!.version, '1.0.1');
    expect(checker.available!.notesUrl, endsWith('/v1.0.1'));
    checker.dispose();
  });

  test('offers nothing when the manifest matches what is installed', () async {
    final store = _MemoryStore();
    final checker = _checker(
      store,
      client: MockClient(
        (_) async => http.Response(_manifest(version: '1.0.0', build: 1), 200),
      ),
    );

    await checker.check();

    expect(checker.hasUpdate, isFalse);
    expect(checker.lastChecked, isNotNull);
    checker.dispose();
  });

  test('breaks a version tie on the build number', () async {
    final store = _MemoryStore();
    final checker = _checker(
      store,
      client: MockClient(
        (_) async => http.Response(_manifest(version: '1.0.0', build: 7), 200),
      ),
    );

    await checker.check();

    expect(checker.hasUpdate, isTrue);
    expect(checker.available!.build, 7);
    checker.dispose();
  });

  test('does not mistake an older manifest for an update', () async {
    final store = _MemoryStore();
    final checker = _checker(
      store,
      installed: _installed(version: '1.2.0', build: '9'),
      client: MockClient(
        (_) async => http.Response(_manifest(version: '1.10.0', build: 3), 200),
      ),
    );

    // 1.10.0 is ahead of 1.2.0 — the comparison is numeric per segment, not
    // the string ordering that would put "1.10.0" before "1.2.0".
    await checker.check();

    expect(checker.hasUpdate, isTrue);
    checker.dispose();
  });

  test('a failed fetch leaves a known update and the clock alone', () async {
    final store = _MemoryStore();
    var calls = 0;
    final checker = _checker(
      store,
      client: MockClient((_) async {
        calls++;
        return calls == 1
            ? http.Response(_manifest(), 200)
            : http.Response('gateway blew up', 502);
      }),
    );

    await checker.check();
    final checkedAt = checker.lastChecked;
    expect(checker.hasUpdate, isTrue);

    await checker.check();

    expect(calls, 2);
    expect(checker.hasUpdate, isTrue, reason: 'the cached result survives');
    expect(checker.lastChecked, checkedAt, reason: 'a failure is not a check');
    checker.dispose();
  });

  test('a malformed manifest is treated as a failure, not as up to date', () async {
    final store = _MemoryStore();
    final checker = _checker(
      store,
      client: MockClient((_) async => http.Response('{"version":42}', 200)),
    );
    store.put('updates.v1', {
      'available': {'version': '1.0.1', 'build': 2, 'notesUrl': ''},
      'checkedAt': DateTime(2026, 9, 1).toIso8601String(),
    });
    checker.loadCache();

    await checker.check();

    expect(checker.hasUpdate, isTrue);
    checker.dispose();
  });

  test('publishes the last known result before any network call', () async {
    final store = _MemoryStore();
    store.put('updates.v1', {
      'available': {
        'version': '2.0.0',
        'build': 5,
        'notesUrl': 'https://example.test/notes',
      },
      'checkedAt': DateTime.now().toIso8601String(),
    });
    final checker = _checker(
      store,
      client: MockClient((_) async => fail('must not reach the network')),
    );

    checker.loadCache();

    expect(checker.available!.version, '2.0.0');
    checker.dispose();
  });

  test('skips the network when the last check was recent', () async {
    final store = _MemoryStore();
    store.put('updates.v1', {
      'available': null,
      'checkedAt': DateTime.now()
          .subtract(const Duration(hours: 1))
          .toIso8601String(),
    });
    final checker = _checker(
      store,
      client: MockClient((_) async => fail('must not reach the network')),
    );

    await checker.checkIfDue();

    expect(checker.hasUpdate, isFalse);
    checker.dispose();
  });

  test('checks again once a day has passed', () async {
    final store = _MemoryStore();
    store.put('updates.v1', {
      'available': null,
      'checkedAt': DateTime.now()
          .subtract(const Duration(hours: 25))
          .toIso8601String(),
    });
    var calls = 0;
    final checker = _checker(
      store,
      client: MockClient((_) async {
        calls++;
        return http.Response(_manifest(), 200);
      }),
    );

    await checker.checkIfDue();

    expect(calls, 1);
    expect(checker.hasUpdate, isTrue);
    checker.dispose();
  });

  test('stays quiet where the app cannot update itself', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
    final store = _MemoryStore();
    final checker = _checker(
      store,
      client: MockClient((_) async => fail('must not reach the network')),
    );

    await checker.check();

    expect(checker.hasUpdate, isFalse);
    expect(checker.lastChecked, isNull);
    checker.dispose();
  });
}
