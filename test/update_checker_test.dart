import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/release_history.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:kapy_notes/data/update_installer.dart';

import 'fake_update_installer.dart';
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
  'notesUrl':
      'https://github.com/kapybara-org/kapynotes/releases/tag/v$version',
  'publishedAt': '2026-09-03T00:00:00Z',
});

UpdateChecker _checker(
  LocalStore store, {
  required http.Client client,
  PackageInfo? installed,
  UpdateInstaller? installer,
}) => UpdateChecker(
  store,
  client: client,
  packageInfo: installed ?? _installed(),
  installer: installer,
);

/// A manifest that also carries the Windows installer, as the release job
/// writes it now.
String _windowsManifest({String version = '1.0.1', int build = 2}) =>
    jsonEncode({
      ...jsonDecode(_manifest(version: version, build: build)) as Map,
      'windows': {
        'url': 'https://dl.example.test/KapyNotes-$version-setup.exe',
        'length': 1024,
        'dsaSignature': 'c2lnbmF0dXJl',
      },
    });

void _seedAvailable(LocalStore store, {String version = '1.0.1'}) =>
    store.put('updates.v1', {
      'available': {'version': version, 'build': 2, 'notesUrl': ''},
      'checkedAt': DateTime.now().toIso8601String(),
    });

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

  // Windows reports no build number at all: package_info_plus splits the
  // executable's ProductVersion on "+", and Runner.rc writes the bare release
  // triple there on purpose, because WinSparkle read the same string. Read
  // as a zero, the tie-break above fired on every Windows install of the
  // current release and the notice never went away.
  test('does not break a version tie against a build it cannot read', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    final store = _MemoryStore();
    final checker = _checker(
      store,
      installed: _installed(version: '1.9.0', build: ''),
      client: MockClient(
        (_) async => http.Response(_manifest(version: '1.9.0', build: 10), 200),
      ),
    );

    await checker.check();

    expect(checker.hasUpdate, isFalse);
    checker.dispose();
  });

  test('still offers a newer release where the build is unreadable', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    final store = _MemoryStore();
    final checker = _checker(
      store,
      installed: _installed(version: '1.9.0', build: ''),
      client: MockClient(
        (_) async =>
            http.Response(_manifest(version: '1.10.0', build: 11), 200),
      ),
    );

    await checker.check();

    expect(checker.hasUpdate, isTrue);
    expect(checker.available!.version, '1.10.0');
    checker.dispose();
  });

  test('says nothing when it cannot tell which build is running', () async {
    final store = _MemoryStore();
    final checker = _checker(
      store,
      installed: _installed(version: '', build: ''),
      client: MockClient((_) async => http.Response(_manifest(), 200)),
    );

    await checker.check();

    expect(checker.hasUpdate, isFalse);
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

  test(
    'a malformed manifest is treated as a failure, not as up to date',
    () async {
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
    },
  );

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

  test(
    'forgets a cached update the running build has caught up with',
    () async {
      final store = _MemoryStore();
      final checkedAt = DateTime.now().subtract(const Duration(minutes: 5));
      store.put('updates.v1', {
        'available': {'version': '1.0.1', 'build': 2, 'notesUrl': ''},
        'checkedAt': checkedAt.toIso8601String(),
      });
      // What the disk looks like the moment after that update is installed: the
      // notice that asked for it is still there, and the daily check that would
      // overwrite it is not due for another 23 hours.
      final checker = _checker(
        store,
        installed: _installed(version: '1.0.1', build: '2'),
        client: MockClient((_) async => fail('must not reach the network')),
      );

      checker.loadCache();

      expect(checker.hasUpdate, isFalse);
      expect(checker.available, isNull);
      expect(
        (store.read<Map<String, Object?>>('updates.v1'))!['available'],
        isNull,
        reason: 'and it must not come back at the next launch',
      );
      expect(
        checker.lastChecked,
        checkedAt,
        reason: 'the check still happened; only its subject is gone',
      );
      checker.dispose();
    },
  );

  test('hides a cached update older than the installed release', () async {
    final store = _MemoryStore();
    store.put('updates.v1', {
      'available': {'version': '1.2.0', 'build': 3, 'notesUrl': ''},
      'checkedAt': DateTime.now().toIso8601String(),
    });
    // An out-of-band install: the notice was written while 1.1.0 was running
    // and 1.4.0 was dropped on top by hand, so the cache now names a release
    // two versions behind the one in the version row.
    final checker = _checker(
      store,
      installed: _installed(version: '1.4.0', build: '5'),
      client: MockClient((_) async => fail('must not reach the network')),
    );

    checker.loadCache();

    expect(checker.hasUpdate, isFalse);
    checker.dispose();
  });

  test('keeps a cached update the running build has not reached', () async {
    final store = _MemoryStore();
    store.put('updates.v1', {
      'available': {'version': '1.4.0', 'build': 5, 'notesUrl': ''},
      'checkedAt': DateTime.now().toIso8601String(),
    });
    // The half-finished upgrade: 1.3.0 installed over 1.2.0 while 1.4.0 is
    // out. Still behind, so the notice stands.
    final checker = _checker(
      store,
      installed: _installed(version: '1.3.0', build: '4'),
      client: MockClient((_) async => fail('must not reach the network')),
    );

    checker.loadCache();

    expect(checker.available!.version, '1.4.0');
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

  group('downloads and installs', () {
    test('a release is downloaded as soon as a check finds it', () async {
      final store = _MemoryStore();
      final installer = FakeUpdateInstaller();
      final checker = _checker(
        store,
        client: MockClient((_) async => http.Response(_manifest(), 200)),
        installer: installer,
      );

      await checker.check();
      await pumpEventQueue();

      expect(checker.autoDownload, isTrue, reason: 'on unless turned off');
      expect(installer.downloads.single.version, '1.0.1');
      expect(checker.isDownloading, isTrue);
      expect(checker.downloadProgress, 0.5);
      expect(checker.isReadyToInstall, isFalse);

      installer.finish();
      await pumpEventQueue();

      expect(checker.isDownloading, isFalse);
      expect(checker.downloadProgress, isNull);
      expect(checker.isReadyToInstall, isTrue);
      expect(checker.staged!.version, '1.0.1');
      checker.dispose();
    });

    test('with automatic downloads off, only a click downloads', () async {
      final store = _MemoryStore();
      final installer = FakeUpdateInstaller();
      final checker = _checker(
        store,
        client: MockClient((_) async => http.Response(_manifest(), 200)),
        installer: installer,
      )..autoDownload = false;

      await checker.check();
      await pumpEventQueue();
      expect(checker.hasUpdate, isTrue);
      expect(installer.downloads, isEmpty);

      final downloaded = checker.download();
      await pumpEventQueue();
      expect(installer.downloads, hasLength(1));
      installer.finish();
      expect(await downloaded, isTrue);
      expect(checker.isReadyToInstall, isTrue);
      checker.dispose();
    });

    test(
      'the choice is kept, and turning it on fetches what was found',
      () async {
        final store = _MemoryStore();
        _seedAvailable(store);
        final installer = FakeUpdateInstaller();
        final checker = _checker(
          store,
          client: MockClient((_) async => fail('no check is due')),
          installer: installer,
        )..autoDownload = false;

        await checker.checkIfDue();
        await pumpEventQueue();
        expect(installer.downloads, isEmpty);
        expect(store.data['updates.autoDownload.v1'], isFalse);

        checker.autoDownload = true;
        await pumpEventQueue();
        expect(store.data['updates.autoDownload.v1'], isTrue);
        expect(installer.downloads.single.version, '1.0.1');
        checker.dispose();
      },
    );

    test('a download an earlier run finished is ready at once', () async {
      final store = _MemoryStore();
      _seedAvailable(store);
      final installer = FakeUpdateInstaller()
        ..onDisk = const StagedUpdate(version: '1.0.1', build: 2);
      final checker = _checker(
        store,
        client: MockClient((_) async => fail('no check is due')),
        installer: installer,
      );

      await checker.checkIfDue();
      await pumpEventQueue();

      expect(checker.isReadyToInstall, isTrue);
      expect(installer.downloads, isEmpty);
      // Everything but the release still wanted is tidied away.
      expect(installer.cleanUps.single?.version, '1.0.1');
      checker.dispose();
    });

    test('a failed download says why and waits before trying itself', () async {
      final store = _MemoryStore();
      _seedAvailable(store);
      final installer = FakeUpdateInstaller();
      final checker = _checker(
        store,
        client: MockClient((_) async => fail('no check is due')),
        installer: installer,
      );

      await checker.checkIfDue();
      await pumpEventQueue();
      installer.fail('The download stalled');
      await pumpEventQueue();

      expect(checker.isDownloading, isFalse);
      expect(checker.isReadyToInstall, isFalse);
      expect(checker.downloadError, 'The download stalled');

      // A resume soon after is not a reason to hammer a failing server...
      await checker.checkIfDue();
      await pumpEventQueue();
      expect(installer.downloads, hasLength(1));

      // ...but a click is.
      final retried = checker.download();
      await pumpEventQueue();
      expect(installer.downloads, hasLength(2));
      expect(checker.downloadError, isNull);
      installer.finish();
      expect(await retried, isTrue);
      checker.dispose();
    });

    test('a newer release replaces one already downloaded', () async {
      final store = _MemoryStore();
      final installer = FakeUpdateInstaller()
        ..onDisk = const StagedUpdate(version: '1.0.1', build: 2);
      _seedAvailable(store);
      var manifest = _manifest();
      final checker = _checker(
        store,
        client: MockClient((_) async => http.Response(manifest, 200)),
        installer: installer,
      );
      await checker.checkIfDue();
      await pumpEventQueue();
      expect(checker.staged!.version, '1.0.1');
      expect(installer.downloads, isEmpty);

      manifest = _manifest(version: '1.0.2', build: 3);
      await checker.check();
      await pumpEventQueue();

      expect(installer.downloads.single.version, '1.0.2');
      checker.dispose();
    });

    test(
      'a download that is not ahead of the running build is not offered',
      () async {
        final store = _MemoryStore();
        _seedAvailable(store);
        final installer = FakeUpdateInstaller();
        final checker = _checker(
          store,
          client: MockClient((_) async => fail('no check is due')),
          installer: installer,
        );
        await checker.checkIfDue();
        await pumpEventQueue();

        // The feed Sparkle read was behind the manifest, and handed back the
        // version already running.
        installer.finish(version: '1.0.0');
        await pumpEventQueue();

        expect(checker.isReadyToInstall, isFalse);
        expect(await checker.installAndRestart(), isFalse);
        expect(installer.installs, 0);
        checker.dispose();
      },
    );

    test('Windows installs, then quits so the installer can run', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      final store = _MemoryStore();
      _seedAvailable(store);
      final installer = FakeUpdateInstaller()
        ..onDisk = const StagedUpdate(version: '1.0.1', build: 2);
      final checker = _checker(
        store,
        client: MockClient((_) async => fail('no check is due')),
        installed: _installed(build: ''),
        installer: installer,
      );
      var quits = 0;
      checker.onBeforeQuitForUpdate = () async => quits++;
      await checker.checkIfDue();

      expect(await checker.installAndRestart(), isTrue);

      expect(installer.installs, 1);
      expect(quits, 1);
      expect(checker.isInstalling, isTrue);
      expect(
        await checker.installAndRestart(),
        isFalse,
        reason: 'a second click while the first is under way does nothing',
      );
      expect(installer.installs, 1);
      checker.dispose();
    });

    test('Sparkle quits the app itself', () async {
      final store = _MemoryStore();
      _seedAvailable(store);
      final installer = FakeUpdateInstaller(quitsTheApp: true)
        ..onDisk = const StagedUpdate(version: '1.0.1', build: 2);
      final checker = _checker(
        store,
        client: MockClient((_) async => fail('no check is due')),
        installer: installer,
      );
      var quits = 0;
      checker.onBeforeQuitForUpdate = () async => quits++;
      await checker.checkIfDue();

      expect(await checker.installAndRestart(), isTrue);

      expect(installer.installs, 1);
      expect(quits, 0);
      expect(checker.isInstalling, isTrue);
      checker.dispose();
    });

    test('an install that fails leaves a button that can work', () async {
      final store = _MemoryStore();
      _seedAvailable(store);
      final installer = FakeUpdateInstaller()
        ..onDisk = const StagedUpdate(version: '1.0.1', build: 2)
        ..installError = const UpdateInstallerException(
          'The downloaded update was damaged',
        );
      final checker = _checker(
        store,
        client: MockClient((_) async => fail('no check is due')),
        installer: installer,
      )..autoDownload = false;
      await checker.checkIfDue();
      // The installer threw the damaged file away.
      installer.onDisk = null;

      expect(await checker.installAndRestart(), isFalse);

      expect(checker.isInstalling, isFalse);
      expect(checker.downloadError, 'The downloaded update was damaged');
      expect(checker.isReadyToInstall, isFalse);
      expect(checker.hasUpdate, isTrue, reason: 'so Download is offered');
      checker.dispose();
    });

    test('Windows reads the manifest again for a notice cached without '
        'its installer', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      final store = _MemoryStore();
      _seedAvailable(store);
      var requests = 0;
      final installer = FakeUpdateInstaller();
      final checker = _checker(
        store,
        client: MockClient((_) async {
          requests++;
          return http.Response(_windowsManifest(), 200);
        }),
        installed: _installed(build: ''),
        installer: installer,
      );

      await checker.checkIfDue();
      await pumpEventQueue();

      expect(requests, 1);
      expect(installer.downloads.single.windows?.length, 1024);
      checker.dispose();
    });
  });

  group('the changelog', () {
    String changelog({int count = 2}) => jsonEncode({
      'releases': [
        for (var index = count; index >= 1; index -= 1)
          {
            'version': '1.$index.0',
            'date': '2026-09-0$index',
            'summary': 'Release 1.$index.0',
            'changes': ['Something changed in 1.$index.0'],
          },
      ],
    });

    test('lists every release the site serves, newest first', () async {
      final store = _MemoryStore();
      final history = ReleaseHistory(
        store,
        client: MockClient(
          (_) async => http.Response(changelog(count: 3), 200),
        ),
      );

      await history.load();

      expect(history.releases.map((release) => release.version), [
        '1.3.0',
        '1.2.0',
        '1.1.0',
      ]);
      expect(history.releases.first.summary, 'Release 1.3.0');
      expect(history.releases.first.changes.single, endsWith('1.3.0'));
      expect(history.hasFailed, isFalse);
      history.dispose();
    });

    test('keeps concise update highlights separate from full notes', () async {
      final store = _MemoryStore();
      final history = ReleaseHistory(
        store,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'releases': [
                {
                  'version': '1.4.0',
                  'date': '2026-09-04',
                  'summary': 'A focused release.',
                  'highlights': ['Faster startup.', 'Clearer settings.'],
                  'changes': [
                    'A long explanation that belongs in the full history.',
                  ],
                },
              ],
            }),
            200,
          ),
        ),
      );

      await history.load();

      expect(history.releases.single.highlights, [
        'Faster startup.',
        'Clearer settings.',
      ]);
      expect(history.releases.single.changes, [
        'A long explanation that belongs in the full history.',
      ]);
      expect(
        (store.read<Map<String, Object?>>('changelog.v1')!['releases'] as List)
            .single,
        containsPair('highlights', ['Faster startup.', 'Clearer settings.']),
      );
      history.dispose();
    });

    test('keeps what it read, and does not ask again the same day', () async {
      final store = _MemoryStore();
      var requests = 0;
      ReleaseHistory build() => ReleaseHistory(
        store,
        client: MockClient((_) async {
          requests++;
          return http.Response(changelog(), 200);
        }),
      );

      final first = build();
      await first.load();
      await first.load();
      first.dispose();
      expect(requests, 1, reason: 'a fresh list is not asked for twice');

      // A second run of the app, reading what the first one kept.
      final second = build();
      await second.load();
      expect(requests, 1);
      expect(second.releases, hasLength(2));
      second.dispose();
    });

    test('shows the list it kept when the site cannot be reached', () async {
      final store = _MemoryStore();
      final online = ReleaseHistory(
        store,
        client: MockClient((_) async => http.Response(changelog(), 200)),
      );
      await online.load();
      online.dispose();

      // A day later, offline: the answer on disk is still the answer.
      store.data['changelog.v1'] = {
        ...store.read<Map<String, Object?>>('changelog.v1')!,
        'fetchedAt': DateTime.now()
            .subtract(const Duration(days: 2))
            .toIso8601String(),
      };
      final offline = ReleaseHistory(
        store,
        client: MockClient((_) async => throw const SocketException('offline')),
      );

      await offline.load();

      expect(offline.releases, hasLength(2));
      expect(offline.hasFailed, isTrue);
      offline.dispose();
    });

    test('says nothing rather than an empty changelog', () async {
      final store = _MemoryStore();
      final history = ReleaseHistory(
        store,
        client: MockClient((_) async => http.Response('not json at all', 200)),
      );

      await history.load();

      expect(history.releases, isEmpty);
      expect(history.hasFailed, isTrue);
      expect(
        store.read<Map<String, Object?>>('changelog.v1'),
        isNull,
        reason: 'an answer it could not read must not be kept',
      );
      history.dispose();
    });

    test('drops an entry it cannot read and keeps the rest', () async {
      final store = _MemoryStore();
      final history = ReleaseHistory(
        store,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'releases': [
                {'version': '1.2.0', 'changes': <String>[]},
                {
                  'date': '2026-09-01',
                  'changes': ['No version on this one'],
                },
                {
                  'version': '1.1.0',
                  'date': '2026-09-01',
                  'changes': ['Something changed'],
                },
              ],
            }),
            200,
          ),
        ),
      );

      await history.load();

      expect(history.releases.single.version, '1.1.0');
      // No date, no summary: shown for what it has rather than dropped.
      expect(history.releases.single.summary, isEmpty);
      history.dispose();
    });

    test(
      'a release that answers with an error leaves the list alone',
      () async {
        final store = _MemoryStore();
        final history = ReleaseHistory(
          store,
          client: MockClient((_) async => http.Response('nope', 503)),
        );

        await history.load();

        expect(history.releases, isEmpty);
        expect(history.hasFailed, isTrue);
        history.dispose();
      },
    );

    test('the checker carries one, on the same client', () async {
      final store = _MemoryStore();
      final checker = _checker(
        store,
        client: MockClient((request) async {
          expect(request.url, ReleaseHistory.url);
          return http.Response(changelog(), 200);
        }),
      );

      await checker.history.load();

      expect(checker.history.releases, hasLength(2));
      checker.dispose();
    });
  });
}
