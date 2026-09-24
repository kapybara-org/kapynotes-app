import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/update_signature.dart';

import 'update_test_fixtures.dart';

/// The 1.28.0 Windows installer as it shipped: the SHA-1 of the file
/// (`KapyNotes-1.28.0-setup.exe`, 58,133,591 bytes) and the signature its
/// appcast carried. Proves the verifier agrees with the key and scheme every
/// release has actually used, without shipping the installer in the repo.
const _release128Sha1 = 'b7e230af748c51b55fb828f74acd5473fd2a836b';
const _release128Signature =
    'MD0CHBKzCmXfW1PNss05qcOITHBPudFFwiHj9SFs9VUCHQC8WkVEdEaKx3NIDT+snyw85Dx'
    'rvrzier7Eks/X';

List<int> _hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

void main() {
  test('the compiled-in key is the one the runner resources carry', () {
    final file = File('windows/runner/resources/dsa_pub.pem');
    expect(
      windowsUpdatePublicKey.trim(),
      file.readAsStringSync().trim(),
      reason: 'rotate both, or the release job signs for a key nobody checks',
    );
  });

  test('the real key verifies the signature 1.28.0 shipped with', () {
    final key = DsaPublicKey.parsePem(windowsUpdatePublicKey);
    expect(key.q.bitLength, 224);
    expect(key.p.bitLength, 2048);
    expect(key.verifySha1(_hex(_release128Sha1), _release128Signature), isTrue);
  });

  test('the real key refuses that signature over any other file', () {
    final key = DsaPublicKey.parsePem(windowsUpdatePublicKey);
    final other = _hex(_release128Sha1)..[0] ^= 1;
    expect(key.verifySha1(other, _release128Signature), isFalse);
  });

  test('verifies a whole file the way the release job signs it', () async {
    final dir = await Directory.systemTemp.createTemp('kn-signature');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/setup.exe')..writeAsStringSync(testPayload);

    expect(
      await verifyInstallerSignature(
        file,
        signature: testPayloadSignature,
        publicKeyPem: testUpdateKey,
      ),
      isTrue,
    );
  });

  test('a single changed byte fails', () async {
    final dir = await Directory.systemTemp.createTemp('kn-signature');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/setup.exe')
      ..writeAsStringSync(testPayload.replaceFirst('K', 'k'));

    expect(
      await verifyInstallerSignature(
        file,
        signature: testPayloadSignature,
        publicKeyPem: testUpdateKey,
      ),
      isFalse,
    );
  });

  test('a signature made by another key fails', () async {
    final dir = await Directory.systemTemp.createTemp('kn-signature');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/setup.exe')..writeAsStringSync(testPayload);

    // Right file, right scheme, wrong signer: the release key never signed
    // this payload.
    expect(
      await verifyInstallerSignature(
        file,
        signature: testPayloadSignature,
        publicKeyPem: windowsUpdatePublicKey,
      ),
      isFalse,
    );
  });

  test('a signature it cannot read is a signature that fails', () {
    final key = DsaPublicKey.parsePem(testUpdateKey);
    final message = utf8.encode(testPayload);
    final digest = _hex('00' * 20);

    expect(key.verifySha1(message, ''), isFalse);
    expect(key.verifySha1(message, 'not base64 at all!'), isFalse);
    expect(key.verifySha1(message, base64.encode([0x30, 0x00])), isFalse);
    // r and s of zero, which the range check must refuse before any maths.
    expect(
      key.verifySha1(digest, base64.encode([0x30, 6, 2, 1, 0, 2, 1, 0])),
      isFalse,
    );
    // r of q, just out of range.
    final q = key.q.toRadixString(16).padLeft(58, '0');
    final r = [0x02, 29, ..._hex(q)];
    expect(
      key.verifySha1(
        digest,
        base64.encode([0x30, r.length + 3, ...r, 2, 1, 1]),
      ),
      isFalse,
    );
  });

  test('only a DSA key is accepted as one', () {
    // An EC key, P-256: a well-formed public key of the wrong kind.
    const ec = '''
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEftBoposK9Rx2s69QHocgTqzGox8e
BWTbZfhWhXKQELwVmAOXi5wAORJJ4nOPQJvKcCYS8MoThZFsA68uFC7M7w==
-----END PUBLIC KEY-----
''';
    expect(() => DsaPublicKey.parsePem(ec), throwsFormatException);
    expect(() => DsaPublicKey.parsePem('nonsense'), throwsFormatException);
  });
}
