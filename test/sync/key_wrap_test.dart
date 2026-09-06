import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/aead.dart';
import 'package:kapy_notes/sync/identity.dart';
import 'package:kapy_notes/sync/key_wrap.dart';

void main() {
  group('symmetric wrap', () {
    test('round-trips a key and refuses the wrong one', () async {
      final key = randomKey();
      final under = randomKey();
      final wrapped = await wrapKey(key, under);

      expect(await unwrapKey(wrapped, under), key);
      expect(await unwrapKey(wrapped, randomKey()), isNull);
      // The wire shape is the contract's, not a sealed note's.
      expect(wrapped.toJson().keys, containsAll(['wrapped', 'n', 'v']));
      expect(WrappedKey.fromJson(wrapped.toJson())!.wrapped, wrapped.wrapped);
    });
  });

  group('sealed box to a public key', () {
    test('only the holder of the private key opens it', () async {
      final alice = await IdentityKeys.generate();
      final mallory = await IdentityKeys.generate();
      final key = randomKey();

      final sealed = await sealToPublicKey(key, alice.x25519Public);
      expect(
        await openSealedToPublicKey(
          sealed,
          alice.x25519Private,
          alice.x25519Public,
        ),
        key,
      );
      expect(
        await openSealedToPublicKey(
          sealed,
          mallory.x25519Private,
          mallory.x25519Public,
        ),
        isNull,
      );
      // Two seals of the same key never look alike: a fresh ephemeral pair
      // each time.
      final again = await sealToPublicKey(key, alice.x25519Public);
      expect(again.ephemeralPublic, isNot(sealed.ephemeralPublic));
      expect(again.wrapped, isNot(sealed.wrapped));
    });

    test('survives the wire', () async {
      final alice = await IdentityKeys.generate();
      final key = randomKey();
      final sealed = SealedToPublicKey.fromJson(
        (await sealToPublicKey(key, alice.x25519Public)).toJson(),
      );
      expect(sealed, isNotNull);
      expect(
        await openSealedToPublicKey(
          sealed!,
          alice.x25519Private,
          alice.x25519Public,
        ),
        key,
      );
    });
  });

  group('identity keys', () {
    test('private halves are sealed under the master key and nothing else', () async {
      final identity = await IdentityKeys.generate();
      final master = randomKey();
      final wire = await identity.wrapUnder(master);

      // Public halves in the clear; private halves not.
      expect(wire.x25519Public, identity.x25519Public);
      expect(wire.toJson()['x25519Public'], isA<String>());
      expect(wire.x25519Wrapped.cipherText, isNot(identity.x25519Private));

      final back = await IdentityKeys.unwrap(
        WireIdentity.fromJson(wire.toJson())!,
        master,
      );
      expect(back, isNotNull);
      expect(back!.x25519Private, identity.x25519Private);
      expect(back.ed25519Private, identity.ed25519Private);
      expect(await IdentityKeys.unwrap(wire, randomKey()), isNull);
    });

    test('a fingerprint is short, stable, and different per key', () async {
      final a = await IdentityKeys.generate();
      final b = await IdentityKeys.generate();
      expect(a.fingerprint, fingerprintOf(a.x25519Public));
      expect(a.fingerprint, isNot(b.fingerprint));
      expect(a.fingerprint.split(' '), hasLength(6));
      expect(a.fingerprint, matches(RegExp(r'^([0-9A-F]{4} ){5}[0-9A-F]{4}$')));
    });
  });

  test('every key in the system is 32 bytes', () {
    expect(randomKey(), hasLength(keyLength));
    expect(Uint8List(keyLength), hasLength(32));
  });
}
