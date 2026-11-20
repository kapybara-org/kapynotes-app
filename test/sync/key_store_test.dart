import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/keyring.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/sync/key_store.dart';

/// Counts reads, so the caching claim can be checked rather than assumed.
class CountingStore extends InMemorySecureStore {
  int reads = 0;

  @override
  Future<String?> read(String key) {
    reads++;
    return super.read(key);
  }
}

/// A keystore that refuses everything — a sandboxed build without the
/// entitlement, or a Linux box with no libsecret.
class BrokenStore implements SecureStore {
  const BrokenStore();

  @override
  Future<String?> read(String key) async => throw Exception('no keystore');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('no keystore');

  @override
  Future<void> delete(String key) async => throw Exception('no keystore');
}

Uint8List key(int fill) => Uint8List(32)..fillRange(0, 32, fill);

void main() {
  test('a master key survives a write and read', () async {
    final store = KeyStore(InMemorySecureStore());
    await store.writeMasterKey(key(7));

    expect(await store.readMasterKey(), key(7));
  });

  test('the key is read from the platform once, then cached', () async {
    final backing = CountingStore();
    await KeyStore(backing).writeMasterKey(key(3));

    final store = KeyStore(backing);
    await store.readMasterKey();
    await store.readMasterKey();
    await store.readMasterKey();

    // Every sync needs the key; a platform channel round trip each time would
    // be pure waste.
    expect(backing.reads, 1);
  });

  test('an absent key reads as null without re-asking each time', () async {
    final backing = CountingStore();
    final store = KeyStore(backing);

    expect(await store.readMasterKey(), isNull);
    expect(await store.readMasterKey(), isNull);
    expect(backing.reads, 1);
  });

  test('an entry of the wrong length is treated as absent', () async {
    final backing = InMemorySecureStore();
    // Something else wrote here, or an older format did. Handing 16 bytes to a
    // cipher expecting 32 is worse than starting over.
    await backing.write('kapynotes.masterKey', base64.encode(Uint8List(16)));

    expect(await KeyStore(backing).readMasterKey(), isNull);
  });

  test('unparseable bytes read as absent rather than throwing', () async {
    final backing = InMemorySecureStore();
    await backing.write('kapynotes.masterKey', 'not base64 at all!!');

    expect(await KeyStore(backing).readMasterKey(), isNull);
  });

  test('signing out drops the key and the token', () async {
    final store = KeyStore(InMemorySecureStore());
    await store.writeMasterKey(key(1));
    await store.writeToken('t0ken');

    await store.clear();

    expect(await store.readMasterKey(), isNull);
    expect(await store.readToken(), isNull);
  });

  test('a keystore that throws costs a prompt, not the launch', () async {
    final store = KeyStore(const ForgivingSecureStore(BrokenStore()));

    // Reads come back empty and writes are dropped, but nothing escapes.
    expect(await store.readMasterKey(), isNull);
    await store.writeMasterKey(key(5));
    await store.clear();
  });

  test(
    'a missing keyring is asked once, and the key stays for this launch only',
    () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      final status = KeyringStatus();
      var calls = 0;
      final backing = _CountingBroken(() => calls++);
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add('$message');
      addTearDown(() => debugPrint = previous);

      final session = KeyStore(ForgivingSecureStore(backing, status: status));
      await session.readMasterKey();
      await session.writeMasterKey(key(5));
      await session.readToken();
      await session.writeToken('session');

      // The first refusal is remembered. Later calls do not ask again.
      expect(calls, 1);
      expect(status.available, isFalse);
      expect(lines, hasLength(1));
      expect(lines.single, contains('keyring is not running'));
      // This launch still has the key it just made.
      expect(await session.readMasterKey(), key(5));
      expect(await session.readToken(), 'session');

      // The next launch does not.
      final next = KeyStore(ForgivingSecureStore(backing, status: status));
      expect(await next.readMasterKey(), isNull);
      expect(await next.readToken(), isNull);
      expect(calls, 1);
    },
  );

  test('elsewhere a refusal is transient, so it is not remembered', () async {
    // A locked keychain or a denied prompt on macOS or Windows opens again
    // later in the same launch. Marking the store unavailable would keep
    // Hidden Notes from unlocking until the app was relaunched.
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final status = KeyringStatus();
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() => debugPrint = previous);

    final store = KeyStore(ForgivingSecureStore(BrokenStore(), status: status));
    expect(await store.readMasterKey(), isNull);

    expect(status.available, isTrue);
    // And the Hidden Notes store is the one 1.33 used, unwrapped.
    expect(hiddenNotesSecureStore(), isA<MigratingSecureStore>());
  });
}

class _CountingBroken implements SecureStore {
  _CountingBroken(this.onCall);

  final void Function() onCall;

  @override
  Future<String?> read(String key) async {
    onCall();
    throw Exception('no keystore');
  }

  @override
  Future<void> write(String key, String value) async {
    onCall();
    throw Exception('no keystore');
  }

  @override
  Future<void> delete(String key) async {
    onCall();
    throw Exception('no keystore');
  }
}
