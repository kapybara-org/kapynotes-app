import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';

import 'aead.dart';
import 'sealed_box.dart';

/// The two ways a key travels wrapped, mirroring `WrappedKey` and
/// `SealedToPublicKey` in the contract.
///
/// **To a symmetric key** — a note's content key under its space key — is the
/// plain envelope from [sealBytes], with the fields renamed so a wrapped key
/// cannot be mistaken for a sealed note on the wire.
///
/// **To a public key** — a space key to a member — is a sealed box: an
/// ephemeral X25519 keypair, agreement with the recipient's public key,
/// HKDF-SHA256 to a 32-byte key, XChaCha20-Poly1305 over the payload, and the
/// ephemeral public key stored beside the ciphertext. Only the holder of the
/// matching private key can open it, and nothing is recoverable from the
/// ephemeral public half alone.

class WrappedKey {
  /// Ciphertext with the tag appended.
  final Uint8List wrapped;
  final Uint8List nonce;
  final int version;

  const WrappedKey({
    required this.wrapped,
    required this.nonce,
    required this.version,
  });

  static const int currentVersion = 1;

  Map<String, Object?> toJson() => {
    'wrapped': base64.encode(wrapped),
    'n': base64.encode(nonce),
    'v': version,
  };

  static WrappedKey? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final box = SealedBox.fromJson({
      'ct': raw['wrapped'],
      'n': raw['n'],
      'v': raw['v'],
    });
    if (box == null) return null;
    return WrappedKey(
      wrapped: box.cipherText,
      nonce: box.nonce,
      version: box.version,
    );
  }

  SealedBox get _asBox =>
      SealedBox(cipherText: wrapped, nonce: nonce, version: version);
}

Future<WrappedKey> wrapKey(Uint8List key, Uint8List under) async {
  final box = await sealBytes(key, under);
  return WrappedKey(
    wrapped: box.cipherText,
    nonce: box.nonce,
    version: WrappedKey.currentVersion,
  );
}

/// Null when [under] is not the key this was wrapped with.
Future<Uint8List?> unwrapKey(WrappedKey wrapped, Uint8List under) async {
  final key = await openBytes(wrapped._asBox, under);
  return key != null && key.length == keyLength ? key : null;
}

class SealedToPublicKey {
  final Uint8List wrapped;
  final Uint8List ephemeralPublic;
  final Uint8List nonce;
  final int version;

  const SealedToPublicKey({
    required this.wrapped,
    required this.ephemeralPublic,
    required this.nonce,
    required this.version,
  });

  static const int currentVersion = 1;

  Map<String, Object?> toJson() => {
    'wrapped': base64.encode(wrapped),
    'ephemeralPublic': base64.encode(ephemeralPublic),
    'n': base64.encode(nonce),
    'v': version,
  };

  static SealedToPublicKey? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final box = SealedBox.fromJson({
      'ct': raw['wrapped'],
      'n': raw['n'],
      'v': raw['v'],
    });
    final ephemeral = raw['ephemeralPublic'];
    if (box == null || ephemeral is! String) return null;
    final Uint8List ephemeralBytes;
    try {
      ephemeralBytes = base64.decode(ephemeral);
    } on FormatException {
      return null;
    }
    if (ephemeralBytes.length != keyLength) return null;
    return SealedToPublicKey(
      wrapped: box.cipherText,
      ephemeralPublic: ephemeralBytes,
      nonce: box.nonce,
      version: box.version,
    );
  }
}

final X25519 _x25519 = X25519();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: keyLength);

/// Domain separation, so a key derived here can never collide with one
/// derived anywhere else from the same agreement.
final List<int> _sealedBoxInfo = utf8.encode('kapynotes.sealed-box.v1');

/// Derives the symmetric key that seals a box to [recipientPublic], from one
/// side's private half and the other's public half. Both ends reach the same
/// result, which is the whole of what Diffie-Hellman offers.
Future<Uint8List> _agree({
  required KeyPair own,
  required Uint8List theirPublic,
  required Uint8List ephemeralPublic,
  required Uint8List recipientPublic,
}) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: own,
    remotePublicKey: SimplePublicKey(theirPublic, type: KeyPairType.x25519),
  );
  final derived = await _hkdf.deriveKey(
    secretKey: shared,
    // Binding both public halves into the salt ties the derived key to this
    // exact pair of parties, not merely to the shared secret.
    nonce: concatBytes(ephemeralPublic, recipientPublic),
    info: _sealedBoxInfo,
  );
  return Uint8List.fromList(derived.bytes);
}

Future<SealedToPublicKey> sealToPublicKey(
  Uint8List key,
  Uint8List recipientPublic,
) async {
  final ephemeral = await _x25519.newKeyPair();
  final ephemeralPublic = Uint8List.fromList(
    (await ephemeral.extractPublicKey()).bytes,
  );
  final under = await _agree(
    own: ephemeral,
    theirPublic: recipientPublic,
    ephemeralPublic: ephemeralPublic,
    recipientPublic: recipientPublic,
  );
  final box = await sealBytes(key, under);
  return SealedToPublicKey(
    wrapped: box.cipherText,
    ephemeralPublic: ephemeralPublic,
    nonce: box.nonce,
    version: SealedToPublicKey.currentVersion,
  );
}

/// Null when this box was not sealed to the keypair given.
Future<Uint8List?> openSealedToPublicKey(
  SealedToPublicKey sealed,
  Uint8List recipientPrivate,
  Uint8List recipientPublic,
) async {
  final own = await _x25519.newKeyPairFromSeed(recipientPrivate);
  final under = await _agree(
    own: own,
    theirPublic: sealed.ephemeralPublic,
    ephemeralPublic: sealed.ephemeralPublic,
    recipientPublic: recipientPublic,
  );
  final key = await openBytes(
    SealedBox(
      cipherText: sealed.wrapped,
      nonce: sealed.nonce,
      version: sealed.version,
    ),
    under,
  );
  return key != null && key.length == keyLength ? key : null;
}
