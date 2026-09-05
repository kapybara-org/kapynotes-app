import 'dart:math';
import 'dart:typed_data';

/// Crockford's base32, for the one secret a person has to copy by hand.
///
/// The alphabet leaves out I, L, O and U: the first three because they are
/// indistinguishable from 1 and 0 in most fonts at the moment somebody is
/// squinting at a recovery key, and U so that no group of letters accidentally
/// spells something unfortunate. Decoding is forgiving in the same spirit —
/// case is ignored, and I and L are read as 1, O as 0, so a key transcribed by
/// eye still opens the account.
const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Four characters at a time. Long enough not to be tedious, short enough to
/// hold in your head while your eyes move between screen and paper.
const int _groupSize = 4;

String formatRecoveryKey(Uint8List bytes) {
  final buffer = StringBuffer();
  var accumulator = 0;
  var bits = 0;
  var written = 0;

  for (final byte in bytes) {
    accumulator = (accumulator << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      if (written > 0 && written % _groupSize == 0) buffer.write('-');
      buffer.write(_alphabet[(accumulator >> bits) & 0x1f]);
      written++;
    }
  }
  if (bits > 0) {
    if (written > 0 && written % _groupSize == 0) buffer.write('-');
    buffer.write(_alphabet[(accumulator << (5 - bits)) & 0x1f]);
  }
  return buffer.toString();
}

/// A passphrase nobody had to invent, in the same shape as a recovery key.
///
/// The alphabet and the grouping are shared deliberately: this is the other
/// secret somebody may end up reading off one screen and typing into another,
/// so the letters that are easy to confuse should be missing from both.
///
/// Sixteen bytes is 128 bits, which is past the point where guessing the
/// passphrase is easier than attacking the key it derives — unlike a
/// passphrase a person chooses, where the KDF is doing the heavy lifting.
/// [Random.secure] for the same reason [Vault] uses it: anything cheaper is a
/// PRNG whose output an attacker can reproduce.
String generatePassphrase({int byteLength = 16}) {
  final random = Random.secure();
  return formatRecoveryKey(
    Uint8List.fromList(
      List<int>.generate(byteLength, (_) => random.nextInt(256)),
    ),
  );
}

/// Null for anything that is not a recovery key. Separators, spaces and case
/// are all ignored before the check, so what the user pastes rarely has to
/// match what they were shown character for character.
Uint8List? parseRecoveryKey(String typed, {int expectedLength = 32}) {
  final bytes = <int>[];
  var accumulator = 0;
  var bits = 0;

  for (final rune in typed.toUpperCase().runes) {
    final char = String.fromCharCode(rune);
    if (char == '-' || char == ' ' || char == '\n' || char == '\t') continue;

    final value = switch (char) {
      'I' || 'L' => 1,
      'O' => 0,
      _ => _alphabet.indexOf(char),
    };
    if (value < 0) return null;

    accumulator = (accumulator << 5) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((accumulator >> bits) & 0xff);
    }
  }

  if (bytes.length != expectedLength) return null;
  return Uint8List.fromList(bytes);
}
