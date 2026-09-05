import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';

import 'note_payload.dart';
import 'sealed_box.dart';

/// The key hierarchy that makes sync end-to-end encrypted.
///
///   passphrase --Argon2id(salt)--> key-encryption key
///   key-encryption key ------------> unwraps the master key
///   master key --------------------> seals every note payload
///
/// Wrapping rather than deriving the master key from the passphrase directly
/// is what makes a passphrase change cheap: it re-seals one 32-byte key
/// instead of re-encrypting every note the user has ever written, and other
/// devices keep working untouched.
///
/// There is no separate "is this the right passphrase" check, because the AEAD
/// already is one. Unwrapping with the wrong key fails the Poly1305 tag, which
/// is exactly the signal we want and one that cannot be forged.
///
/// ## Cost
///
/// Nothing in here runs when the app opens. Notes are stored as plaintext JSON
/// on local disk exactly as before, so launch does no crypto at all; the vault
/// is touched only when syncing. Argon2id — the one genuinely expensive step,
/// deliberately so — runs once per device and always in a background isolate,
/// never on the thread drawing frames.
class Vault {
  final Uint8List _masterKey;

  Vault._(this._masterKey);

  /// Master and file keys are both 32 bytes.
  static const int keyLength = 32;

  /// Beneath this many plaintext bytes, spawning an isolate costs more than
  /// the encryption it would offload. Mirrors the threshold in [LocalStore].
  static const int _isolateThreshold = 32 * 1024;

  /// Creates a brand-new account's keys.
  ///
  /// Returns the recovery key in the clear — the *only* time it exists outside
  /// a sealed box. The caller must make saving it a required step: this is the
  /// single thing standing between a forgotten passphrase and notes that are
  /// gone for good.
  static Future<VaultSetup> create({required String passphrase}) async {
    final masterKey = _randomBytes(keyLength);
    final recoveryKey = _randomBytes(keyLength);
    final kdf = KdfParams(
      salt: _randomBytes(KdfParams.saltLength),
      memory: KdfParams.defaultMemory,
      iterations: KdfParams.defaultIterations,
      parallelism: KdfParams.defaultParallelism,
    );

    final kek = await _deriveKeyEncryptionKey(passphrase, kdf);
    // Both wraps seal the same master key, so either route recovers the same
    // notes and neither has to be re-done when the other changes.
    final wrapped = await _sealBytes(masterKey, kek);
    final recoveryWrapped = await _sealBytes(masterKey, recoveryKey);

    return VaultSetup(
      vault: Vault._(masterKey),
      kdf: kdf,
      wrappedMasterKey: wrapped,
      recoveryWrappedMasterKey: recoveryWrapped,
      recoveryKey: recoveryKey,
    );
  }

  /// Unlocks on a new device. Returns null when the passphrase is wrong —
  /// there is nothing to distinguish "wrong passphrase" from "tampered blob",
  /// and the user-facing answer is the same either way.
  static Future<Vault?> unlockWithPassphrase({
    required String passphrase,
    required KdfParams kdf,
    required SealedBox wrappedMasterKey,
  }) async {
    final kek = await _deriveKeyEncryptionKey(passphrase, kdf);
    final masterKey = await _openBytes(wrappedMasterKey, kek);
    return masterKey == null ? null : Vault._(masterKey);
  }

  /// Unlocks from the recovery key. No KDF: that key is already 256 bits of
  /// uniform entropy, so stretching it would buy nothing and would cost the
  /// user a slow unlock on the worst possible day.
  static Future<Vault?> unlockWithRecoveryKey({
    required Uint8List recoveryKey,
    required SealedBox recoveryWrappedMasterKey,
  }) async {
    if (recoveryKey.length != keyLength) return null;
    final masterKey = await _openBytes(recoveryWrappedMasterKey, recoveryKey);
    return masterKey == null ? null : Vault._(masterKey);
  }

  /// Restores a vault from the master key cached in the platform keystore.
  /// This is the ordinary path on a device that has unlocked once before, and
  /// it costs a keystore read rather than an Argon2id run.
  static Vault fromMasterKey(Uint8List masterKey) {
    if (masterKey.length != keyLength) {
      throw ArgumentError.value(
        masterKey.length,
        'masterKey',
        'expected $keyLength bytes',
      );
    }
    return Vault._(masterKey);
  }

  /// The master key, for handing to the platform keystore. Never send this
  /// anywhere else — it is the whole secret.
  Uint8List get masterKeyForKeystore => _masterKey;

  /// Re-seals the master key under a new passphrase. The master key itself is
  /// unchanged, so no note has to be rewritten and other devices are unaffected.
  Future<({SealedBox wrappedMasterKey, KdfParams kdf})> rewrapForPassphrase(
    String passphrase,
  ) async {
    final kdf = KdfParams(
      salt: _randomBytes(KdfParams.saltLength),
      memory: KdfParams.defaultMemory,
      iterations: KdfParams.defaultIterations,
      parallelism: KdfParams.defaultParallelism,
    );
    final kek = await _deriveKeyEncryptionKey(passphrase, kdf);
    return (wrappedMasterKey: await _sealBytes(_masterKey, kek), kdf: kdf);
  }

  Future<SealedBox> seal(NotePayload payload) async =>
      (await sealAll([payload])).single;

  /// Seals a batch in a single isolate hop.
  ///
  /// Batching is the point: a push carries up to 200 notes, and paying the
  /// isolate spawn once instead of 200 times is the difference between a few
  /// milliseconds and a visible stall. Small batches stay inline, where the
  /// spawn would cost more than the work.
  Future<List<SealedBox>> sealAll(List<NotePayload> payloads) async {
    if (payloads.isEmpty) return const [];

    final encoded = List<Uint8List>.generate(
      payloads.length,
      (i) => _utf8Json(payloads[i].toJson()),
      growable: false,
    );
    final key = _masterKey;
    return _totalLength(encoded) < _isolateThreshold
        ? _sealBatch(encoded, key)
        : Isolate.run(() => _sealBatch(encoded, key));
  }

  Future<NotePayload?> open(SealedBox box) async =>
      (await openAll([box])).single;

  /// Opens a batch, returning null in place of any box that fails to
  /// authenticate. One unreadable note — sealed under a key this account no
  /// longer has, say — must not cost the user the other 199.
  Future<List<NotePayload?>> openAll(List<SealedBox> boxes) async {
    if (boxes.isEmpty) return const [];

    final key = _masterKey;
    final total = boxes.fold<int>(0, (sum, b) => sum + b.cipherText.length);
    final plaintexts = total < _isolateThreshold
        ? await _openBatch(boxes, key)
        : await Isolate.run(() => _openBatch(boxes, key));

    return List<NotePayload?>.generate(plaintexts.length, (i) {
      final bytes = plaintexts[i];
      if (bytes == null) return null;
      try {
        return NotePayload.fromJson(jsonDecode(utf8.decode(bytes)));
      } on FormatException {
        return null;
      }
    }, growable: false);
  }
}

/// Everything produced by first-run key setup. [recoveryKey] is in the clear
/// and must be shown once, then dropped.
class VaultSetup {
  final Vault vault;
  final KdfParams kdf;
  final SealedBox wrappedMasterKey;
  final SealedBox recoveryWrappedMasterKey;
  final Uint8List recoveryKey;

  const VaultSetup({
    required this.vault,
    required this.kdf,
    required this.wrappedMasterKey,
    required this.recoveryWrappedMasterKey,
    required this.recoveryKey,
  });
}

// ---------------------------------------------------------------------------
// Primitives. Top-level so the closures handed to Isolate.run capture only
// the byte arrays they are given, and never a Vault instance.
// ---------------------------------------------------------------------------

/// Argon2id, always off the UI isolate: it is designed to be slow and to hold
/// [KdfParams.memory] KiB while it runs, which is precisely what must not
/// happen on the thread drawing frames.
Future<Uint8List> _deriveKeyEncryptionKey(
  String passphrase,
  KdfParams kdf,
) async {
  final salt = kdf.salt;
  final memory = kdf.memory;
  final iterations = kdf.iterations;
  final parallelism = kdf.parallelism;

  return Isolate.run(() async {
    final argon2 = Argon2id(
      memory: memory,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: Vault.keyLength,
    );
    final derived = await argon2.deriveKey(
      // Known limitation: the passphrase is hashed as the platform's keyboard
      // emitted it. A composed and a decomposed "é" are the same passphrase to
      // the user but derive different keys, so a passphrase typed with combining
      // marks may not unlock across platforms. Normalising to NFC would need a
      // Unicode dependency Dart does not ship; revisit if it ever bites.
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    return Uint8List.fromList((await derived.extract()).bytes);
  });
}

/// Built once per isolate. Constructing it per call would re-resolve the
/// algorithm against `Cryptography.instance` on every note in a batch.
final Cipher _cipher = Xchacha20.poly1305Aead();

/// Seals arbitrary JSON under an arbitrary 32-byte key.
///
/// For share links, whose key is not the account's master key and whose
/// plaintext is not a [NotePayload]. It goes through the same cipher as
/// everything else on purpose: a second sealing path is a second chance to get
/// a nonce or a tag layout wrong, and this one is already the audited one.
Future<SealedBox> sealJsonUnderKey(
  Map<String, Object?> json,
  Uint8List key,
) async {
  if (key.length != Vault.keyLength) {
    throw ArgumentError.value(
      key.length,
      'key',
      'expected ${Vault.keyLength} bytes',
    );
  }
  return _sealBytes(_utf8Json(json), key);
}

Future<SealedBox> _sealBytes(Uint8List plaintext, Uint8List key) async {
  final box = await _cipher.encrypt(plaintext, secretKey: SecretKey(key));
  return SealedBox(
    // The contract carries the tag appended to the ciphertext; the Dart API
    // keeps them apart, so join here and split on the way back.
    cipherText: _concat(box.cipherText, box.mac.bytes),
    nonce: Uint8List.fromList(box.nonce),
    version: SealedBox.currentVersion,
  );
}

Future<Uint8List?> _openBytes(SealedBox box, Uint8List key) async {
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
    // A failed tag check is the expected outcome of a wrong passphrase, not an
    // exceptional one. The caller turns null into "that didn't unlock".
    return null;
  }
}

Future<List<SealedBox>> _sealBatch(
  List<Uint8List> plaintexts,
  Uint8List key,
) async {
  final sealed = <SealedBox>[];
  for (final plaintext in plaintexts) {
    sealed.add(await _sealBytes(plaintext, key));
  }
  return sealed;
}

Future<List<Uint8List?>> _openBatch(
  List<SealedBox> boxes,
  Uint8List key,
) async {
  final opened = <Uint8List?>[];
  for (final box in boxes) {
    opened.add(await _openBytes(box, key));
  }
  return opened;
}

Uint8List _utf8Json(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

int _totalLength(List<Uint8List> items) =>
    items.fold<int>(0, (sum, item) => sum + item.length);

Uint8List _concat(List<int> a, List<int> b) {
  final joined = Uint8List(a.length + b.length);
  joined.setRange(0, a.length, a);
  joined.setRange(a.length, joined.length, b);
  return joined;
}

/// Key material only. [Random.secure] rather than the store's cheap PRNG:
/// note ids are not credentials, these are.
Uint8List _randomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}
