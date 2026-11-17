import 'dart:io';

import 'package:flutter/foundation.dart';
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

    test('writes go to the new store only', () async {
      final current = InMemorySecureStore();

      await MigratingSecureStore(current, legacy).write(token, 'new-session');

      expect(await current.read(token), 'new-session');
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

    test('macOS migrates; other platforms use their store as is', () {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      expect(platformSecureStore(), isA<MigratingSecureStore>());

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      expect(platformSecureStore(), isA<PlatformSecureStore>());
    });

    test('release builds claim only the team-prefixed group', () {
      final entitlements = File(
        'macos/Runner/Release.entitlements',
      ).readAsStringSync();
      final groups = RegExp(
        r'<key>com\.apple\.security\.application-groups</key>\s*<array>(.*?)</array>',
        dotAll: true,
      ).firstMatch(entitlements)!.group(1)!;

      expect(
        RegExp(
          r'<string>(.*?)</string>',
        ).allMatches(groups).map((m) => m.group(1)).toList(),
        ['96V66447C6.com.kapybara.kapynotes'],
      );
      expect(entitlements, isNot(contains('keychain-access-groups')));
    });
  });
}
