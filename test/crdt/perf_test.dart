import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/crdt.dart';

import 'helpers.dart';

void main() {
  test('20k single-char appends are not quadratic', () {
    final doc = NoteDoc(replica: 'a');
    final buffer = StringBuffer();
    final watch = Stopwatch()..start();
    for (var i = 0; i < 20000; i++) {
      buffer.writeCharCode(0x61 + (i % 26));
      type(doc, buffer.toString());
    }
    watch.stop();
    expect(doc.length, 20000);
    expect(doc.text, buffer.toString());
    // Generous: this guards against a blow-up, not a regression of 10%.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('a large paste and a large snapshot stay linear', () {
    // Measured as a ratio rather than against the clock: the suite runs in
    // parallel on whatever machine it runs on, and a fixed bound on a
    // megabyte of text was the first thing to fail there. What matters is
    // that four times the text costs about four times the work, not sixteen.
    Duration cost(int lines) {
      final doc = NoteDoc(replica: 'a');
      final big = List.generate(lines, (i) => 'line $i = $i * 2').join('\n');
      final watch = Stopwatch()..start();
      type(doc, big);
      final snapshot = doc.toSnapshot();
      final restored = NoteDoc.fromSnapshot(snapshot, replica: 'b');
      watch.stop();
      expect(restored.text, big);
      return watch.elapsed;
    }

    // Warm the JIT so the first measurement is not paying for compilation.
    cost(2000);
    final small = cost(5000);
    final large = cost(20000);
    final ratio = large.inMicroseconds / small.inMicroseconds.clamp(1, 1 << 62);
    expect(ratio, lessThan(8), reason: 'small=$small large=$large');
  });
}
