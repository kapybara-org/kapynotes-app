import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography_plus/cryptography_plus.dart';

import 'aead.dart';
import 'sealed_box.dart';

/// A user's two identity keypairs, mirroring `IdentityKeys` in the contract.
///
/// Two, because one cannot do both jobs: X25519 is key agreement and cannot
/// sign; Ed25519 signs and cannot agree on a key. Others use the X25519
/// public half to seal a space key to this account. Ed25519 is for
/// attribution once an op log exists, and is generated now because the moment
/// to generate keys is the moment the master key is in memory.
///
/// Both private halves are sealed under the master key with the same envelope
/// notes use, so a passphrase change — which re-wraps the master key and
/// nothing else — leaves them untouched.
class IdentityKeys {
  final Uint8List x25519Public;
  final Uint8List x25519Private;
  final Uint8List ed25519Public;
  final Uint8List ed25519Private;

  const IdentityKeys({
    required this.x25519Public,
    required this.x25519Private,
    required this.ed25519Public,
    required this.ed25519Private,
  });

  static Future<IdentityKeys> generate() async {
    final x = await X25519().newKeyPair();
    final e = await Ed25519().newKeyPair();
    return IdentityKeys(
      x25519Public: Uint8List.fromList((await x.extractPublicKey()).bytes),
      x25519Private: Uint8List.fromList(await x.extractPrivateKeyBytes()),
      ed25519Public: Uint8List.fromList((await e.extractPublicKey()).bytes),
      ed25519Private: Uint8List.fromList(await e.extractPrivateKeyBytes()),
    );
  }

  /// Seals the private halves under [masterKey] for publishing.
  Future<WireIdentity> wrapUnder(Uint8List masterKey) async => WireIdentity(
    x25519Public: x25519Public,
    x25519Wrapped: await sealBytes(x25519Private, masterKey),
    ed25519Public: ed25519Public,
    ed25519Wrapped: await sealBytes(ed25519Private, masterKey),
  );

  /// Null when the wraps do not open under [masterKey], which means they
  /// belong to a different key than the one this device holds.
  static Future<IdentityKeys?> unwrap(
    WireIdentity wire,
    Uint8List masterKey,
  ) async {
    final x = await openBytes(wire.x25519Wrapped, masterKey);
    final e = await openBytes(wire.ed25519Wrapped, masterKey);
    if (x == null || e == null) return null;
    if (x.length != keyLength || e.length != keyLength) return null;
    return IdentityKeys(
      x25519Public: wire.x25519Public,
      x25519Private: x,
      ed25519Public: wire.ed25519Public,
      ed25519Private: e,
    );
  }

  String get fingerprint => fingerprintOf(x25519Public);
}

/// A short, readable digest of a public key, for a person to compare against
/// what another person reads out. Twelve hex pairs of SHA-256, grouped in
/// fours: enough that a forged key cannot realistically match, short enough
/// to say over a phone.
String fingerprintOf(Uint8List publicKey) {
  final digest = hashes.sha256.convert(publicKey).bytes;
  final hex = digest
      .take(12)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return [
    for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4),
  ].join(' ');
}

/// The identity as it crosses the wire: public halves in plain, private
/// halves sealed.
class WireIdentity {
  final Uint8List x25519Public;
  final SealedBox x25519Wrapped;
  final Uint8List ed25519Public;
  final SealedBox ed25519Wrapped;

  const WireIdentity({
    required this.x25519Public,
    required this.x25519Wrapped,
    required this.ed25519Public,
    required this.ed25519Wrapped,
  });

  Map<String, Object?> toJson() => {
    'x25519Public': base64.encode(x25519Public),
    'x25519Wrapped': x25519Wrapped.toJson(),
    'ed25519Public': base64.encode(ed25519Public),
    'ed25519Wrapped': ed25519Wrapped.toJson(),
  };

  static WireIdentity? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final xPublic = _key(raw['x25519Public']);
    final ePublic = _key(raw['ed25519Public']);
    final xWrapped = SealedBox.fromJson(raw['x25519Wrapped']);
    final eWrapped = SealedBox.fromJson(raw['ed25519Wrapped']);
    if (xPublic == null ||
        ePublic == null ||
        xWrapped == null ||
        eWrapped == null) {
      return null;
    }
    return WireIdentity(
      x25519Public: xPublic,
      x25519Wrapped: xWrapped,
      ed25519Public: ePublic,
      ed25519Wrapped: eWrapped,
    );
  }

  static Uint8List? _key(Object? raw) {
    if (raw is! String) return null;
    try {
      final bytes = base64.decode(raw);
      return bytes.length == keyLength ? bytes : null;
    } on FormatException {
      return null;
    }
  }
}
