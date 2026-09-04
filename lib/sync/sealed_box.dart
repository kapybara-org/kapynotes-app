import 'dart:convert';
import 'dart:typed_data';

/// An AEAD-sealed blob, mirroring `SealedBox` in `packages/contract`.
///
/// The server stores these verbatim and can never open one: the key exists
/// only on the user's devices.
///
/// XChaCha20-Poly1305 with a fresh 24-byte nonce per write. The nonce is
/// public by design — it only has to be unique, never secret — and 24 bytes is
/// wide enough that generating it randomly will not realistically collide.
/// That is the reason to prefer XChaCha over ChaCha20's 12-byte nonce, which
/// would force a counter tracked across devices that sync out of order.
class SealedBox {
  /// Ciphertext with the Poly1305 tag appended.
  final Uint8List cipherText;

  /// 24 bytes.
  final Uint8List nonce;

  /// Schema version of the *plaintext* inside, so a future build can change
  /// the payload shape without stranding notes sealed by an older one.
  final int version;

  const SealedBox({
    required this.cipherText,
    required this.nonce,
    required this.version,
  });

  /// The payload version this build writes. Matches `PAYLOAD_VERSION`.
  static const int currentVersion = 1;

  /// XChaCha20 nonce width, in bytes.
  static const int nonceLength = 24;

  /// Poly1305 tag width, in bytes.
  static const int macLength = 16;

  Map<String, Object?> toJson() => {
    'ct': base64.encode(cipherText),
    'n': base64.encode(nonce),
    'v': version,
  };

  /// Returns null rather than throwing: a malformed box from the wire is a
  /// note we skip, not a sync run we abandon.
  static SealedBox? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ct = raw['ct'];
    final n = raw['n'];
    final v = raw['v'];
    if (ct is! String || n is! String || v is! int || v <= 0) return null;

    final Uint8List cipherText;
    final Uint8List nonce;
    try {
      cipherText = base64.decode(ct);
      nonce = base64.decode(n);
    } on FormatException {
      return null;
    }
    if (nonce.length != nonceLength) return null;
    if (cipherText.length < macLength) return null;

    return SealedBox(cipherText: cipherText, nonce: nonce, version: v);
  }
}

/// Argon2id parameters, mirroring `KdfParams` in the contract.
///
/// Public by necessity: a salt is not a secret, and the cost parameters have
/// to be known before the derivation can run. Stored per-user rather than
/// hardcoded so the cost can be raised for new accounts as phones get faster,
/// without invalidating anyone already signed up.
class KdfParams {
  /// 16 bytes.
  final Uint8List salt;

  /// Memory cost, KiB.
  final int memory;

  /// Time cost (iterations).
  final int iterations;

  /// Parallelism (lanes).
  final int parallelism;

  const KdfParams({
    required this.salt,
    required this.memory,
    required this.iterations,
    required this.parallelism,
  });

  static const int saltLength = 16;

  /// Defaults for a new account, at the low end of the OWASP guidance for
  /// Argon2id (19 MiB / t=2 / p=1).
  ///
  /// Deliberately not higher. This runs on the oldest phone the user owns,
  /// while they watch an unlock screen, and it allocates [memory] KiB for the
  /// duration. The derived key is cached in the platform keystore afterwards,
  /// so the cost is paid once per device rather than once per launch — but the
  /// once it is paid still has to feel quick.
  static const int defaultMemory = 19456;
  static const int defaultIterations = 2;
  static const int defaultParallelism = 1;

  Map<String, Object?> toJson() => {
    'alg': 'argon2id',
    'salt': base64.encode(salt),
    'm': memory,
    't': iterations,
    'p': parallelism,
  };

  static KdfParams? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['alg'] != 'argon2id') return null;
    final salt = raw['salt'];
    final m = raw['m'];
    final t = raw['t'];
    final p = raw['p'];
    if (salt is! String || m is! int || t is! int || p is! int) return null;
    if (m <= 0 || t <= 0 || p <= 0) return null;

    final Uint8List decoded;
    try {
      decoded = base64.decode(salt);
    } on FormatException {
      return null;
    }
    if (decoded.isEmpty) return null;

    return KdfParams(
      salt: decoded,
      memory: m,
      iterations: t,
      parallelism: p,
    );
  }
}
