import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';

/// RFC 9106 §5.3 test vector for Argon2id.
///
/// This guards the one primitive whose failure would be silent and total: a
/// KDF that runs fast because it is not doing the work would still round-trip
/// every other test in this suite, while leaving every passphrase far cheaper
/// to brute-force than the parameters claim.
void main() {
  test('Argon2id matches the RFC 9106 test vector', () async {
    final argon2 = Argon2id(
      memory: 32, // KiB
      iterations: 3,
      parallelism: 4,
      hashLength: 32,
    );

    final derived = await argon2.deriveKey(
      secretKey: SecretKey(Uint8List(32)..fillRange(0, 32, 0x01)),
      nonce: Uint8List(16)..fillRange(0, 16, 0x02),
      optionalSecret: Uint8List(8)..fillRange(0, 8, 0x03),
      associatedData: Uint8List(12)..fillRange(0, 12, 0x04),
    );

    final actual = (await derived.extract()).bytes;
    expect(
      actual.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
    );
  });

  test('the memory parameter is load-bearing', () async {
    // Same inputs, more memory: a different tag proves `memory` reaches the
    // implementation rather than being quietly ignored.
    Future<String> tag(int memory) async {
      final derived = await Argon2id(
        memory: memory,
        iterations: 1,
        parallelism: 1,
        hashLength: 32,
      ).deriveKey(
        secretKey: SecretKey(Uint8List(16)),
        nonce: Uint8List(16),
      );
      return (await derived.extract())
          .bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    }

    expect(await tag(64), isNot(await tag(19456)));
  });
}
