import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';

import 'sealed_box.dart';

/// The one symmetric primitive everything here is built on: XChaCha20-Poly1305
/// with a fresh random 24-byte nonce per seal. Notes, wrapped keys, identity
/// keys and space keys all go through these two functions, so there is exactly
/// one envelope to get right.
///
/// Top-level rather than methods, so the closures handed to `Isolate.run`
/// capture only the byte arrays they are given and never an object holding
/// more than it needs to.

/// Built once per isolate. Constructing it per call would re-resolve the
/// algorithm against `Cryptography.instance` on every note in a batch.
final Cipher _cipher = Xchacha20.poly1305Aead();

Future<SealedBox> sealBytes(Uint8List plaintext, Uint8List key) async {
  final box = await _cipher.encrypt(plaintext, secretKey: SecretKey(key));
  return SealedBox(
    // The contract carries the tag appended to the ciphertext; the Dart API
    // keeps them apart, so join here and split on the way back.
    cipherText: concatBytes(box.cipherText, box.mac.bytes),
    nonce: Uint8List.fromList(box.nonce),
    version: SealedBox.currentVersion,
  );
}

/// Null on a failed tag check, which is the expected outcome of the wrong key
/// rather than an exceptional one. The caller turns null into its own sentence.
Future<Uint8List?> openBytes(SealedBox box, Uint8List key) async {
  try {
    final split = box.cipherText.length - SealedBox.macLength;
    if (split < 0) return null;
    final clear = await _cipher.decrypt(
      SecretBox(
        Uint8List.sublistView(box.cipherText, 0, split),
        nonce: box.nonce,
        mac: Mac(Uint8List.sublistView(box.cipherText, split)),
      ),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  } catch (_) {
    return null;
  }
}

Uint8List concatBytes(List<int> a, List<int> b) {
  final joined = Uint8List(a.length + b.length);
  joined.setRange(0, a.length, a);
  joined.setRange(a.length, joined.length, b);
  return joined;
}

/// Key material only. [Random.secure] rather than a cheap PRNG: note ids are
/// not credentials, these are.
Uint8List randomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// Every key in the system — master, content, space, file — is 32 bytes.
const int keyLength = 32;

Uint8List randomKey() => randomBytes(keyLength);
