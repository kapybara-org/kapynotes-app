import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

/// Where each logical line of the note sits vertically inside the text field.
class LineOffsets {
  /// Top edge of every logical line, in text-local coordinates.
  final List<double> tops;

  /// Height of one visual row. Uniform, because the editor forces its strut.
  final double lineHeight;

  final double totalHeight;

  /// The last visual row of each line [LineMeasurer.measure] was asked
  /// about, in text-local coordinates: from the row's top to its bottom, and
  /// from where its writing starts to where it stops. A line that wraps ends
  /// on its last row, which is where its result goes.
  final Map<int, Rect> lastRows;

  const LineOffsets({
    required this.tops,
    required this.lineHeight,
    required this.totalHeight,
    this.lastRows = const {},
  });

  static const LineOffsets empty = LineOffsets(
    tops: [0],
    lineHeight: 0,
    totalHeight: 0,
  );
}

/// Measures line positions by laying the note out exactly the way the text
/// field does.
///
/// This is what keeps a result aligned to its line even when the line wraps:
/// wrapped rows push everything below them down, and the measurement sees it
/// because it uses the same width, style and strut as the real field.
class LineMeasurer {
  String? _text;
  double? _width;
  TextScaler? _scaler;
  Object? _layoutKey;
  int? _placeholderKey;
  List<int>? _lastRowLines;
  LineOffsets? _cached;

  /// [span] must be the very span the field renders — styled runs can differ
  /// in width from the same characters in the base style.
  ///
  /// [placeholders] must describe every [WidgetSpan] in [span], in order.
  /// [TextPainter] refuses to lay out a span containing placeholders it has
  /// not been given dimensions for, and an image is a placeholder — so a note
  /// with pictures measures wrong, or not at all, without this.
  ///
  /// [lastRowsOf] names the lines whose last visual row is wanted as well, in
  /// [LineOffsets.lastRows]. Only those lines pay for it.
  LineOffsets measure({
    required InlineSpan span,
    required String text,
    required double maxWidth,
    required StrutStyle strut,
    required TextScaler textScaler,
    required Object layoutKey,
    List<PlaceholderDimensions> placeholders = const [],
    Iterable<int> lastRowsOf = const [],
  }) {
    final placeholderKey = Object.hashAll([
      for (final placeholder in placeholders)
        Object.hash(placeholder.size.width, placeholder.size.height),
    ]);
    final lastRowLines = List<int>.unmodifiable(lastRowsOf);
    if (_text == text &&
        _width == maxWidth &&
        _scaler == textScaler &&
        _layoutKey == layoutKey &&
        _placeholderKey == placeholderKey &&
        listEquals(_lastRowLines, lastRowLines) &&
        _cached != null) {
      return _cached!;
    }
    if (maxWidth <= 0 || !maxWidth.isFinite) return LineOffsets.empty;

    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      strutStyle: strut,
      textScaler: textScaler,
    );
    if (placeholders.isNotEmpty) painter.setPlaceholderDimensions(placeholders);
    painter.layout(maxWidth: maxWidth);

    final tops = <double>[];
    final starts = <int>[];
    var offset = 0;
    for (final line in text.split('\n')) {
      starts.add(offset);
      tops.add(
        painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy,
      );
      offset += line.length + 1;
    }

    final lastRows = <int, Rect>{};
    for (final index in lastRowLines) {
      if (index < 0 || index >= starts.length) continue;
      final start = starts[index];
      final end = index + 1 < starts.length
          ? starts[index + 1] - 1
          : text.length;
      lastRows[index] = _lastRow(painter, start, end, tops[index]);
    }

    final result = LineOffsets(
      tops: tops,
      lineHeight: painter.preferredLineHeight,
      totalHeight: painter.height,
      lastRows: lastRows,
    );
    painter.dispose();

    _text = text;
    _width = maxWidth;
    _scaler = textScaler;
    _layoutKey = layoutKey;
    _placeholderKey = placeholderKey;
    _lastRowLines = lastRowLines;
    _cached = result;
    return result;
  }

  /// The last row the text from [start] to [end] is drawn on: that row's full
  /// height, and as wide as the writing on it.
  static Rect _lastRow(TextPainter painter, int start, int end, double top) {
    final empty = Rect.fromLTWH(0, top, 0, painter.preferredLineHeight);
    if (end <= start) return empty;
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      boxHeightStyle: BoxHeightStyle.max,
    );
    if (boxes.isEmpty) return empty;
    final rowTop = boxes.map((box) => box.top).reduce(math.max);
    final row = boxes.where((box) => (box.top - rowTop).abs() < 0.5);
    return Rect.fromLTRB(
      row.map((box) => box.left).reduce(math.min),
      rowTop,
      row.map((box) => box.right).reduce(math.max),
      row.map((box) => box.bottom).reduce(math.max),
    );
  }
}
