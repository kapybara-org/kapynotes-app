import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/spike_b_note_sliver.dart';

void main() {
  test('tops and the line at an offset agree with a plain running sum', () {
    final random = math.Random(14);
    final heights = [
      for (var i = 0; i < 5000; i++) 29.0 * (1 + random.nextInt(3)),
    ];
    final index = HeightIndex(heights);
    final tops = <double>[0];
    for (final height in heights) {
      tops.add(tops.last + height);
    }
    void check() {
      for (var line = 0; line <= heights.length; line += 7) {
        expect(index.topOf(line), moreOrLessEquals(tops[line]));
      }
      expect(index.total, moreOrLessEquals(tops.last));
      for (var i = 0; i < 2000; i++) {
        final offset = random.nextDouble() * tops.last;
        var expected = 0;
        while (expected + 1 < heights.length && tops[expected + 1] <= offset) {
          expected++;
        }
        expect(index.lineAt(offset), expected, reason: 'offset $offset');
      }
      expect(index.lineAt(-5), 0);
      expect(index.lineAt(tops.last + 100), heights.length - 1);
    }

    check();
    for (var i = 0; i < 3000; i++) {
      final line = random.nextInt(heights.length);
      final height = 29.0 * (1 + random.nextInt(4));
      index.setHeight(line, height);
      final delta = height - heights[line];
      heights[line] = height;
      for (var j = line + 1; j < tops.length; j++) {
        tops[j] += delta;
      }
    }
    check();
  });

  test('a line starting exactly at an offset is the line at that offset', () {
    final index = HeightIndex([10, 20, 30, 40]);
    expect(index.lineAt(0), 0);
    expect(index.lineAt(10), 1);
    expect(index.lineAt(29.9), 1);
    expect(index.lineAt(30), 2);
    expect(index.lineAt(60), 3);
  });
}
