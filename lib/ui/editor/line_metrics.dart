import 'package:material_ui/material_ui.dart';

/// Where each logical line of the note sits vertically inside the text field.
class LineOffsets {
  /// Top edge of every logical line, in text-local coordinates.
  final List<double> tops;

  /// Height of one visual row. Uniform, because the editor forces its strut.
  final double lineHeight;

  final double totalHeight;

  const LineOffsets({
    required this.tops,
    required this.lineHeight,
    required this.totalHeight,
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
  LineOffsets? _cached;

  /// [span] must be the very span the field renders — styled runs can differ
  /// in width from the same characters in the base style.
  ///
  /// [placeholders] must describe every [WidgetSpan] in [span], in order.
  /// [TextPainter] refuses to lay out a span containing placeholders it has
  /// not been given dimensions for, and an image is a placeholder — so a note
  /// with pictures measures wrong, or not at all, without this.
  LineOffsets measure({
    required InlineSpan span,
    required String text,
    required double maxWidth,
    required StrutStyle strut,
    required TextScaler textScaler,
    required Object layoutKey,
    List<PlaceholderDimensions> placeholders = const [],
  }) {
    final placeholderKey = Object.hashAll([
      for (final placeholder in placeholders)
        Object.hash(placeholder.size.width, placeholder.size.height),
    ]);
    if (_text == text &&
        _width == maxWidth &&
        _scaler == textScaler &&
        _layoutKey == layoutKey &&
        _placeholderKey == placeholderKey &&
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
    var offset = 0;
    for (final line in text.split('\n')) {
      tops.add(
        painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy,
      );
      offset += line.length + 1;
    }

    final result = LineOffsets(
      tops: tops,
      lineHeight: painter.preferredLineHeight,
      totalHeight: painter.height,
    );
    painter.dispose();

    _text = text;
    _width = maxWidth;
    _scaler = textScaler;
    _layoutKey = layoutKey;
    _placeholderKey = placeholderKey;
    _cached = result;
    return result;
  }
}
