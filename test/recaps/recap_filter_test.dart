import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/recaps/recap_filter.dart';

void main() {
  test('its bits never change: records keep them', () {
    // FNV-1a of "a" is 0xe40c292c.
    final filter = RecapFilter.of(['a', 'b']).sized(9);
    expect(filter.hashes, 16);
    expect(filter.toBase64(), 'Q6NUKBAoRIKF');
    expect(filter.mayHold('a'), isTrue);
    expect(filter.mayHold('b'), isTrue);
    expect(filter.mayHold('c'), isFalse);
    expect(filter.mayHold('trip'), isFalse);
  });

  test('holds the ids as they are until it is sized', () {
    final filter = RecapFilter.of(['a', 'b']);
    expect(filter.hashes, 0);
    expect(filter.mayHold('a'), isTrue);
    expect(filter.mayHold('c'), isFalse);
    expect(filter.bytes, RecapFilter.minBytes);
    expect(RecapFilter.of([for (var i = 0; i < 300; i++) '$i']).bytes, 450);
  });

  test('a whole recap\'s filter has bits of its own', () {
    final whole = RecapFilter.union([
      RecapFilter.of(['a']),
      RecapFilter.of(['b']),
    ])!.sized(9);
    expect(whole.hashes, 16);
    expect(whole.toBase64(), 'G5IkScK2TLBJ');
    expect(whole.mayHold('a'), isTrue);
    expect(whole.mayHold('b'), isTrue);
    expect(whole.mayHold('c'), isFalse);
    expect(whole.mayHold('trip'), isFalse);
    final back = RecapFilter.fromJson(
      whole.hashes,
      whole.toBase64(),
      whole: true,
    )!;
    expect(['a', 'b'].every(back.mayHold), isTrue);
    expect(back.mayHold('c'), isFalse);
    expect(
      RecapFilter.union([
        RecapFilter.of(['a']).sized(9),
      ]),
      isNull,
      reason: 'a sized filter no longer knows its ids',
    );
  });

  test('reads back what a record wrote, and nothing else', () {
    final filter = RecapFilter.of(['a', 'b']).sized(9);
    final back = RecapFilter.fromJson(filter.hashes, filter.toBase64())!;
    expect(back.mayHold('a'), isTrue);
    expect(back.sized(300), same(back), reason: 'its size is its own');
    expect(RecapFilter.fromJson(3, ''), isNull);
    expect(RecapFilter.fromJson(3, 'not base64!'), isNull);
    expect(RecapFilter.fromJson(0, filter.toBase64()), isNull);
    expect(RecapFilter.fromJson('3', filter.toBase64()), isNull);
  });

  test('never misses a note it holds, at any size', () {
    final ids = [for (var i = 0; i < 500; i++) 'note-$i'];
    for (final size in [9, 60, 300, 625]) {
      final filter = RecapFilter.of(ids).sized(size);
      expect(ids.every(filter.mayHold), isTrue, reason: '$size bytes');
    }
  });
}
