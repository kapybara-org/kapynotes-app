import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/line_heights.dart';

/// Heights a binary fraction can hold exactly, so every sum is exact too.
const _heights = [0.0, 29.0, 31.0, 36.75, 58.5, 400.0];

void main() {
  test('tops, the total and the line at an offset are the heights summed', () {
    final random = math.Random(14);
    final naive = [
      for (var i = 0; i < 300; i++) _heights[random.nextInt(_heights.length)],
    ];
    final heights = LineHeights(naive);

    void check() {
      var top = 0.0;
      for (var line = 0; line < naive.length; line++) {
        expect(heights.topOf(line), top, reason: 'line $line');
        expect(heights.heightOf(line), naive[line]);
        top += naive[line];
      }
      expect(heights.total, top);
      for (var i = 0; i < 500; i++) {
        final offset = random.nextDouble() * (top + 100) - 50;
        var expected = 0;
        var at = 0.0;
        for (var line = 0; line < naive.length; line++) {
          if (at > offset) break;
          expected = line;
          at += naive[line];
        }
        expect(heights.lineAt(offset), expected, reason: 'offset $offset');
      }
    }

    check();
    for (var i = 0; i < 200; i++) {
      final line = random.nextInt(naive.length);
      final height = _heights[random.nextInt(_heights.length)];
      naive[line] = height;
      heights.measure(line, height);
      expect(heights.isMeasured(line), isTrue);
    }
    check();
  });

  test('an edit keeps the heights and measurements of the lines around it, '
      'and guesses the lines it adds', () {
    final random = math.Random(5);
    final naive = [for (var i = 0; i < 40; i++) 31.0];
    final measured = [for (var i = 0; i < 40; i++) false];
    final heights = LineHeights(naive);
    for (var i = 0; i < 2000; i++) {
      if (random.nextBool()) {
        final line = random.nextInt(naive.length);
        final height = _heights[random.nextInt(_heights.length)];
        naive[line] = height;
        measured[line] = true;
        heights.measure(line, height);
        continue;
      }
      final line = random.nextInt(naive.length);
      final removed = 1 + random.nextInt(math.min(3, naive.length - line));
      final inserted = 1 + random.nextInt(3);
      final guess = _heights[random.nextInt(_heights.length)];
      heights.apply((
        line: line,
        removed: removed,
        inserted: inserted,
      ), (added) => guess);
      if (removed == inserted) {
        measured.fillRange(line, line + removed, false);
      } else {
        naive.replaceRange(line, line + removed, [
          for (var j = 0; j < inserted; j++) guess,
        ]);
        measured.replaceRange(line, line + removed, [
          for (var j = 0; j < inserted; j++) false,
        ]);
      }
      expect(heights.length, naive.length);
      var top = 0.0;
      for (var at = 0; at < naive.length; at++) {
        expect(heights.topOf(at), top, reason: 'edit $i, line $at');
        expect(heights.isMeasured(at), measured[at]);
        top += naive[at];
      }
      expect(heights.total, top);
    }
  });

  test('a new width makes every height a guess, kept as it was', () {
    final heights = LineHeights([31, 31, 31])
      ..measure(0, 62)
      ..measure(2, 31);
    heights.forget();
    expect(
      [for (var i = 0; i < 3; i++) heights.isMeasured(i)],
      [false, false, false],
    );
    expect(heights.total, 124);
  });
}
