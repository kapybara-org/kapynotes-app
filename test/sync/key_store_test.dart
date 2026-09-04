import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
}
