import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/recaps/recap_filter.dart';

void main() {
  test('its bits never change: records keep them', () {
    // FNV-1a of "a" is 0xe40c292c, so "a" sets bits 44, 57 and 70.
    final filter = RecapFilter.of(['a', 'b']);
    expect(filter.toBase64(), 'AAAAAAAQAAJAAAAAAAAAAAAAAAAAAAAAAAAAACAABIA=');
    expect(filter.mayHold('a'), isTrue);
    expect(filter.mayHold('b'), isTrue);
    expect(filter.mayHold('c'), isFalse);
    expect(filter.mayHold('trip'), isFalse);
  });

  test('reads back what it wrote, and nothing else', () {
    final filter = RecapFilter.of(['a', 'b']);
    expect(RecapFilter.fromBase64(filter.toBase64())!.mayHold('a'), isTrue);
    expect(RecapFilter.fromBase64('AAAA'), isNull);
    expect(RecapFilter.fromBase64('not base64!'), isNull);
    expect(RecapFilter.fromBase64(7), isNull);
  });

  test('either one holds what both hold', () {
    final both = RecapFilter.of(['a']) | RecapFilter.of(['b']);
    expect(both.toBase64(), RecapFilter.of(['a', 'b']).toBase64());
  });
}
