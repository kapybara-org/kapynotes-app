import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/recovery_key.dart';

void main() {
  Uint8List bytes(int fill) => Uint8List(32)..fillRange(0, 32, fill);

  test('a key survives being written down and typed back', () {
    final key = Uint8List.fromList(
      List.generate(32, (i) => (i * 37 + 11) & 0xff),
    );
    expect(parseRecoveryKey(formatRecoveryKey(key)), key);
  });

  test('it is grouped for copying by hand', () {
    final formatted = formatRecoveryKey(bytes(0));
    expect(formatted.split('-').every((group) => group.length <= 4), isTrue);
    // 32 bytes is 256 bits, which is 52 characters at five bits each.
    expect(formatted.replaceAll('-', '').length, 52);
  });

  test('the confusable characters are not in the alphabet', () {
    final formatted = formatRecoveryKey(
      Uint8List.fromList(List.generate(32, (i) => i * 7)),
    );
    for (final confusable in ['I', 'L', 'O', 'U']) {
      expect(formatted, isNot(contains(confusable)));
    }
  });

  test('a key read off a screen by eye still opens the account', () {
    final key = bytes(0xa7);
    final written = formatRecoveryKey(key);
    // Lower case, spaces instead of dashes, and the substitutions someone
    // makes when a 1 looks like an l and a 0 looks like an O.
    final transcribed = written
        .toLowerCase()
        .replaceAll('-', ' ')
        .replaceAll('1', 'l')
        .replaceAll('0', 'O');

    expect(parseRecoveryKey(transcribed), key);
  });

  test('nonsense is refused rather than half-read', () {
    expect(parseRecoveryKey(''), isNull);
    expect(parseRecoveryKey('not a key'), isNull);
    // Right alphabet, wrong length.
    expect(parseRecoveryKey('ABCD-EFGH'), isNull);
  });
}
