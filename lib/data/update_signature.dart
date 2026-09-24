import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The public half of the key every Windows installer is signed with.
///
/// A copy of `windows/runner/resources/dsa_pub.pem`, where WinSparkle used to
/// read it from the executable's resources. A test keeps the two identical;
/// the file stays because it is what the release secret was generated beside,
/// and what the README tells anyone rotating the key to replace.
///
/// Rotating it means the release after the rotation cannot be installed by
/// anyone still running an older build: their copy trusts only this one.
const String windowsUpdatePublicKey = '''
-----BEGIN PUBLIC KEY-----
MIIDQjCCAjUGByqGSM44BAEwggIoAoIBAQCzNuzxapObXTeUHHp8sGnE76UDTChW
Os6VxSV66Xr79PO1d6k9uEGD5CXlnYXN59NIhyApXM5/R5LpUB9NtEdkOB991AvT
mdPNvlD8a7oXXjkORL5gKyvfsp72AeQyCVznTLWMOi07nYCwYrIZKF/aNVwCBABW
wS4z/PJ1dYzNFeZ2Ku96UIy+iYraPWPWxvP3hBfvjiEIDy+4XFQ7WG4zBsvEi/7+
eI2d73jDFXXzYaat7wcYDbzgMATSWsrUazrNJLZ6KNk0Mfx/8sEwiS5eJJlcE6fS
u/I9aLHOrEyW0wUCmOaklRvhWfo7v7clzUHiv1G8gMYGb5Wzut/x1nrtAh0A2m7Q
gDCQT3PkR2S51875Ir3Hjaq5zUC1TGEkKQKCAQAHSOx+a+yCwcT9OK9gUhWCUJSr
pKcbSRs0Biwci0/JvEnV3wPDp1MD5yapgZ48EVNL8luDWqlKgfqXDfrWmdofN6JF
hw+yP9vtoIfiuo5ZXFJiFjzDLtIWXFO5xaPfbNcWpCZgGLHXqcSOOVRti1rVQmnl
WhCU87LIE5NfZ61obLwsVldf8svoJGEHtNB0E4yDGJR/kXGd0usz60+M291dEC4f
jGebydf8yMSpNNB+2Hua6yVvuxV2fXmwJGJlSn4UGkEUFalckqmCcJy8UlHoFgct
Ub8n4QtWSWKHSBxbIk2T8H/MkKFbCqUFbl6MUy8WMGSzgQPVAtb33qD50K8+A4IB
BQACggEAWJeEQRkAeboDFfvrkgjuw12nRx5WkY5eQ/8w2a7iGKRmkWPISDZh0xBK
PTsWEdW1vTz/v3XsiGj9jLKbP9q72cFRvQgMXzTH3y6W/siusge2e9V7kcO0tSOc
nrECM5yCRvqv20SYBiGYDZYfpKF1LHLnBZtRkI/ovZZ7WtJycz2JItTU2maOT6Gr
f96abfeGEBKYUpYZbDdp6l2EJq7yVBkuTKs+6n3/HRcA+TVGe5asze3O8ORBLvTL
oP5d19fom5wffdNqH2ZfTI5lvXf7FHFZeT8eKFPqkkBNdPYEkQHfdscYZHrubULA
/XwcEGGISAWS03llCEfiEhDDrzhQdA==
-----END PUBLIC KEY-----
''';

/// A DSA public key: the domain parameters and the public value.
class DsaPublicKey {
  const DsaPublicKey({
    required this.p,
    required this.q,
    required this.g,
    required this.y,
  });

  final BigInt p;
  final BigInt q;
  final BigInt g;
  final BigInt y;

  static const _dsaOid = [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x01];

  /// Reads a `-----BEGIN PUBLIC KEY-----` block, as `openssl dsa -pubout`
  /// writes it. Throws [FormatException] for anything else, an RSA or EC key
  /// included: accepting the wrong kind of key is how a check turns into one
  /// that passes.
  static DsaPublicKey parsePem(String pem) {
    final body = pem
        .replaceAll('-----BEGIN PUBLIC KEY-----', '')
        .replaceAll('-----END PUBLIC KEY-----', '')
        .replaceAll(RegExp(r'\s'), '');
    final Uint8List der;
    try {
      der = base64.decode(body);
    } on FormatException {
      throw const FormatException('The public key is not base64');
    }

    // SubjectPublicKeyInfo ::= SEQUENCE {
    //   algorithm SEQUENCE { OID dsa, SEQUENCE { INTEGER p, q, g } },
    //   subjectPublicKey BIT STRING { INTEGER y } }
    final info = _Der(der).sequence();
    final algorithm = info.sequence();
    final oid = algorithm.element(0x06);
    if (!_sameBytes(oid, _dsaOid)) {
      throw const FormatException('The public key is not a DSA key');
    }
    final parameters = algorithm.sequence();
    final p = parameters.integer();
    final q = parameters.integer();
    final g = parameters.integer();
    final bits = info.element(0x03);
    // The first byte of a BIT STRING counts the unused bits; a key has none.
    if (bits.isEmpty || bits[0] != 0) {
      throw const FormatException('The public key is malformed');
    }
    final y = _Der(Uint8List.sublistView(bits, 1)).integer();
    if (p <= BigInt.one || q <= BigInt.one || g <= BigInt.one) {
      throw const FormatException('The public key is malformed');
    }
    return DsaPublicKey(p: p, q: q, g: g, y: y);
  }

  /// Whether [signature] — base64 DER, as `openssl dgst -sign` writes it —
  /// is this key's signature over [message], hashed with SHA-1.
  ///
  /// Never throws: a signature that cannot even be read is a signature that
  /// does not verify.
  bool verifySha1(List<int> message, String signature) {
    final BigInt r;
    final BigInt s;
    try {
      final values = _Der(base64.decode(signature.trim())).sequence();
      r = values.integer();
      s = values.integer();
    } on FormatException {
      return false;
    }
    if (r <= BigInt.zero || r >= q || s <= BigInt.zero || s >= q) return false;

    // FIPS 186-4 §4.7. The digest is used whole: SHA-1's 160 bits are
    // fewer than q's, so there is nothing to truncate.
    final z = _unsigned(sha1.convert(message).bytes);
    final w = s.modInverse(q);
    final u1 = (z * w) % q;
    final u2 = (r * w) % q;
    final v = ((g.modPow(u1, p) * y.modPow(u2, p)) % p) % q;
    return v == r;
  }
}

/// Checks a downloaded Windows installer the way WinSparkle did, so the
/// signature the release job has always written still means the same thing.
///
/// That scheme signs a digest of a digest: the job runs
/// `openssl dgst -sha1 -binary < setup.exe | openssl dgst -sha1 -sign key`,
/// so what is signed is the file's twenty-byte SHA-1, hashed once more by the
/// signature itself.
///
/// Reads the whole file, fifty-odd megabytes of it, so callers run this off
/// the UI isolate.
Future<bool> verifyInstallerSignature(
  File file, {
  required String signature,
  required String publicKeyPem,
}) async {
  final DsaPublicKey key;
  try {
    key = DsaPublicKey.parsePem(publicKeyPem);
  } on FormatException {
    return false;
  }
  final digest = await sha1.bind(file.openRead()).first;
  return key.verifySha1(digest.bytes, signature);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

BigInt _unsigned(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

/// Just enough DER to read a DSA key and signature: definite lengths, and the
/// four tags those use. Anything else is a [FormatException].
class _Der {
  _Der(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  Uint8List element(int tag) {
    if (_offset + 2 > _bytes.length || _bytes[_offset] != tag) {
      throw const FormatException('Unexpected DER');
    }
    _offset++;
    var length = _bytes[_offset++];
    if (length & 0x80 != 0) {
      final count = length & 0x7F;
      if (count == 0 || count > 4 || _offset + count > _bytes.length) {
        throw const FormatException('Unsupported DER length');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | _bytes[_offset++];
      }
    }
    if (_offset + length > _bytes.length) {
      throw const FormatException('Truncated DER');
    }
    final value = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }

  _Der sequence() => _Der(element(0x30));

  BigInt integer() {
    final bytes = element(0x02);
    // Only non-negative integers appear in a key or a signature; DER marks
    // one whose top bit is set with a leading zero byte.
    if (bytes.isEmpty || bytes[0] & 0x80 != 0) {
      throw const FormatException('Unexpected negative integer');
    }
    return _unsigned(bytes);
  }
}
