import 'dart:math' as math;
import 'dart:typed_data';

import 'note_lines.dart';

/// Every line's height, kept so that a line's top and the line at a scroll
/// offset each take O(log n).
///
/// A line that hasn't been laid out yet holds an estimate. Laying it out
/// measures it, and it stays measured until an edit to it, or a new column
/// width, makes its height a guess again.
class LineHeights {
  LineHeights(List<double> estimates) {
    _index(Float64List.fromList(estimates), Uint8List(estimates.length));
  }

  late Float64List _heights;
  late Uint8List _measured;

  /// A Fenwick tree over [_heights], so a line's top is a prefix sum.
  late Float64List _tree;

  int get length => _heights.length;

  double heightOf(int line) => _heights[line];

  bool isMeasured(int line) => _measured[line] != 0;

  /// The sum of the heights of the lines before [line], which may be
  /// [length].
  double topOf(int line) {
    var sum = 0.0;
    for (var node = line; node > 0; node -= node & -node) {
      sum += _tree[node];
    }
    return sum;
  }

  double get total => topOf(length);

  /// The line [offset] falls in: the last line whose top is at or above it,
  /// held to the note's lines.
  int lineAt(double offset) {
    var line = 0;
    var rest = offset;
    for (var step = 1 << (length.bitLength - 1); step > 0; step >>= 1) {
      final next = line + step;
      if (next <= length && _tree[next] <= rest) {
        line = next;
        rest -= _tree[next];
      }
    }
    return math.min(line, length - 1);
  }

  /// Records [line]'s height as laid out.
  void measure(int line, double height) {
    _measured[line] = 1;
    final change = height - _heights[line];
    if (change == 0) return;
    _heights[line] = height;
    for (var node = line + 1; node <= length; node += node & -node) {
      _tree[node] += change;
    }
  }

  /// Makes every height a guess again, as a new column width does. Each line
  /// keeps the height it had as its estimate.
  void forget() => _measured.fillRange(0, length, 0);

  /// Follows [edit] to the note's lines. A line it changed in place keeps its
  /// height as an estimate, and a line it added is guessed by [estimate].
  void apply(LineEdit edit, double Function(int line) estimate) {
    if (edit.removed == edit.inserted) {
      _measured.fillRange(edit.line, edit.line + edit.inserted, 0);
      return;
    }
    final after = edit.line + edit.removed;
    final heights = Float64List(length - edit.removed + edit.inserted)
      ..setRange(0, edit.line, _heights);
    for (var line = edit.line; line < edit.line + edit.inserted; line++) {
      heights[line] = estimate(line);
    }
    heights.setRange(
      edit.line + edit.inserted,
      heights.length,
      _heights,
      after,
    );
    final measured = Uint8List(heights.length)
      ..setRange(0, edit.line, _measured)
      ..setRange(edit.line + edit.inserted, heights.length, _measured, after);
    _index(heights, measured);
  }

  void _index(Float64List heights, Uint8List measured) {
    final tree = Float64List(heights.length + 1);
    for (var node = 1; node < tree.length; node++) {
      tree[node] += heights[node - 1];
      final parent = node + (node & -node);
      if (parent < tree.length) tree[parent] += tree[node];
    }
    _heights = heights;
    _measured = measured;
    _tree = tree;
  }
}
