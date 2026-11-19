import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/sync/key_store.dart';

/// A store whose every call fails, like the data-protection keychain in a
/// build signed without the team's entitlement.
class BrokenStore implements SecureStore {
  @override
  Future<String?> read(String key) async => throw Exception('-34018');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('-34018');

  @override
  Future<void> delete(String key) async => throw Exception('-34018');
}

/// Reads fine, but every write fails.
class ReadOnlyStore extends InMemorySecureStore {
  @override
  Future<void> write(String key, String value) async =>
      throw Exception('write refused');
}

/// Accepts writes and keeps nothing, so a copy never reads back.
class LosingStore extends InMemorySecureStore {
  @override
  Future<void> write(String key, String value) async {}
}

const token = 'kapynotes.sessionToken';

void main() {
  late InMemorySecureStore legacy;

  setUp(() async {
    MigratingSecureStore.debugForgetSwept();
    legacy = InMemorySecureStore();
    await legacy.write(token, 'old-session');
  });

  group('moving out of the file keychain', () {
    test(
      'an old entry moves, and goes only once the copy reads back',
      () async {
        final current = InMemorySecureStore();

        final read = await MigratingSecureStore(current, legacy).read(token);

        expect(read, 'old-session');
        expect(await current.read(token), 'old-session');
        expect(await legacy.read(token), isNull);
      },
    );

    test('a session survives the move through KeyStore', () async {
      final current = InMemorySecureStore();
      final keys = KeyStore(MigratingSecureStore(current, legacy));

      expect(await keys.readToken(), 'old-session');
      expect(await KeyStore(current).readToken(), 'old-session');
    });

    test('a new entry wins and the old one is left alone', () async {
      final current = InMemorySecureStore();
      await current.write(token, 'new-session');

      final read = await MigratingSecureStore(current, legacy).read(token);

      expect(read, 'new-session');
      expect(await legacy.read(token), 'old-session');
    });

    test('a failed copy keeps the user signed in on the old entry', () async {
      final read = await MigratingSecureStore(
        ReadOnlyStore(),
        legacy,
      ).read(token);

      expect(read, 'old-session');
      expect(await legacy.read(token), 'old-session');
    });

    test('a copy that does not read back leaves the old entry', () async {
      final read = await MigratingSecureStore(
        LosingStore(),
        legacy,
      ).read(token);

      expect(read, 'old-session');
      expect(await legacy.read(token), 'old-session');
    });

    test('an unreadable new store falls back to the old entry', () async {
      final read = await MigratingSecureStore(
        BrokenStore(),
        legacy,
      ).read(token);

      expect(read, 'old-session');
      expect(await legacy.read(token), 'old-session');
    });

    test('nothing anywhere reads as null', () async {
      final store = MigratingSecureStore(
        InMemorySecureStore(),
        InMemorySecureStore(),
      );

      expect(await store.read(token), isNull);
    });

    test('a write clears the old copy, so it cannot come back', () async {
      final current = InMemorySecureStore();
      final store = MigratingSecureStore(current, legacy);

      await store.write(token, 'new-session');
      await current.delete(token);

      expect(await legacy.read(token), isNull);
      expect(await store.read(token), isNull);
    });

    test('a failed write leaves the old copy in place', () async {
      final store = MigratingSecureStore(ReadOnlyStore(), legacy);

      await expectLater(store.write(token, 'new-session'), throwsException);

      expect(await legacy.read(token), 'old-session');
    });

    test(
      'signing out clears both, so the old session cannot come back',
      () async {
        final current = InMemorySecureStore();
        final store = MigratingSecureStore(current, legacy);
        await store.write(token, 'new-session');

        await store.delete(token);

        expect(await current.read(token), isNull);
        expect(await legacy.read(token), isNull);
        expect(await store.read(token), isNull);
      },
    );
  });

  group('isolation on macOS', () {
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    test('entries live in the data-protection keychain', () {
      expect(macOsKeychain.usesDataProtectionKeychain, isTrue);
    });

    test('macOS and iOS migrate; other platforms use their store as is', () {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      expect(platformSecureStore(), isA<MigratingSecureStore>());

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      expect(platformSecureStore(), isA<MigratingSecureStore>());

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      expect(platformSecureStore(), isA<PlatformSecureStore>());
    });

    test('the Hidden Notes PIN stays where 1.33 kept it on iOS', () {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      expect(hiddenNotesSecureStore(), isA<PlatformSecureStore>());

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      expect(hiddenNotesSecureStore(), isA<MigratingSecureStore>());
    });

    test('a crash between the copy and the delete leaves no old entry after the next launch', () async {
      final current = InMemorySecureStore();
      await current.write(token, 'old-session');

      final read = await MigratingSecureStore(current, legacy, sweep: true).read(token);

      expect(read, 'old-session');
      expect(await legacy.read(token), isNull);
    });

    test('at launch every entry that moves is moved, read before or not', () async {
      const aiKey = 'kapynotes.openRouterKey';
      await legacy.write(aiKey, 'sk-or-test');
      final current = InMemorySecureStore();

      await moveEntries(MigratingSecureStore(current, legacy, sweep: true), [token, aiKey]);

      expect(await current.read(token), 'old-session');
      expect(await current.read(aiKey), 'sk-or-test');
      expect(await legacy.read(token), isNull);
      expect(await legacy.read(aiKey), isNull);
    });

    test('iOS entries stay on the device and open after the first unlock', () {
      expect(
        iosKeychain.toMap()['accessibility'],
        KeychainAccessibility.first_unlock_this_device.name,
      );
      expect(
        iosKeychain.toMap()['accountName'],
        isNot(AppleOptions.defaultAccountName),
        reason: 'the keychain keeps one entry per service and account',
      );
    });

    test('the Android secure store stays out of backups and transfers', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
      final legacy = File(
        'android/app/src/main/res/xml/backup_rules.xml',
      ).readAsStringSync();
      final modern = File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ).readAsStringSync();
      for (final prefs in [
        'FlutterSecureStorage',
        'FlutterSecureKeyStorage',
        'FlutterSecureStorageConfiguration',
        'FlutterSecureStorageConfiguration:FlutterSecureStorage',
      ]) {
        final rule = '<exclude domain="sharedpref" path="$prefs.xml"/>';
        expect(legacy, contains(rule));
        expect(RegExp(RegExp.escape(rule)).allMatches(modern), hasLength(2));
      }
    });

    test('only the Developer ID build claims a keychain group', () {
      String read(String name) =>
          File('macos/Runner/$name.entitlements').readAsStringSync();
      final developerId = read('DeveloperID');
      final group = RegExp(
        r'\t<!--(?:(?!-->).)*-->\n\t<key>keychain-access-groups</key>\s*<array>\s*<string>(.*?)</string>\s*</array>\n',
        dotAll: true,
      ).firstMatch(developerId)!;

      expect(
        group.group(1),
        r'$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)',
      );
      expect(developerId.replaceFirst(group.group(0)!, ''), read('Release'));
    });
  });

  group('the file keychain', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('kapynotes/file_keychain');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'read' ? 'old-session' : null;
          });
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test(
      'is read and emptied through the app channel, never written',
      () async {
        const store = FileKeychainStore();

        expect(await store.read(token), 'old-session');
        await store.delete(token);

        expect(calls.map((c) => [c.method, c.arguments]), [
          [
            'read',
            {'service': 'flutter_secure_storage_service', 'account': token},
          ],
          [
            'delete',
            {'service': 'flutter_secure_storage_service', 'account': token},
          ],
        ]);
        expect(() => store.write(token, 'x'), throwsUnsupportedError);
      },
    );
  });
}
