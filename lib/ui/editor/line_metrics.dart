import 'package:flutter/foundation.dart';
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

/// Words in one style, or a placeholder of a known size: a piece of a line as
/// it is laid out.
@immutable
class _Run {
  const _Run(this.text, this.style)
    : placeholder = null,
      alignment = PlaceholderAlignment.bottom,
      baseline = null;

  const _Run.placeholder(
    this.style,
    PlaceholderDimensions this.placeholder, {
    required this.alignment,
    required this.baseline,
  }) : text = null;

  final String? text;
  final TextStyle? style;
  final PlaceholderDimensions? placeholder;

  /// Where the placeholder sits on its row: the span's own say, which is
  /// what the paragraph goes by.
  final PlaceholderAlignment alignment;
  final TextBaseline? baseline;

  int get length => text?.length ?? 1;

  InlineSpan get span => placeholder == null
      ? TextSpan(text: text, style: style)
      : WidgetSpan(
          child: const SizedBox.shrink(),
          alignment: alignment,
          baseline: baseline,
          style: style,
        );

  @override
  bool operator ==(Object other) =>
      other is _Run &&
      other.text == text &&
      other.style == style &&
      other.alignment == alignment &&
      other.baseline == baseline &&
      other.placeholder?.size == placeholder?.size &&
      other.placeholder?.baselineOffset == placeholder?.baselineOffset;

  @override
  int get hashCode => Object.hash(text, style, placeholder?.size);
}

/// One logical line: its runs, and the style of the line break that ends it.
@immutable
class _Line {
  const _Line(this.runs, {required this.broken, this.breakStyle});

  final List<_Run> runs;

  /// False on the last line, which has no line break after it.
  final bool broken;
  final TextStyle? breakStyle;

  @override
  bool operator ==(Object other) =>
      other is _Line &&
      other.broken == broken &&
      other.breakStyle == breakStyle &&
      listEquals(other.runs, runs);

  @override
  int get hashCode => Object.hash(broken, breakStyle, Object.hashAll(runs));
}

/// Measures line positions by laying the note out the way the text field
/// does, a line at a time.
///
/// This is what keeps a result aligned to its line even when the line wraps:
/// wrapped rows push everything below them down, and the measurement sees it
/// because it uses the same width, styles and strut as the real field.
///
/// A line at a time because a line break is hard: how one line wraps never
/// depends on another, so an edit only needs the lines it changed laid out
/// again. The whole note laid out as one paragraph instead costs as much as
/// the field's own layout, on every keystroke, and in a long note that is
/// most of a second.
class LineMeasurer {
  double? _width;
  TextScaler? _scaler;
  StrutStyle? _strut;
  TextStyle? _style;
  double _lineHeight = 0;
  List<_Line> _lines = const [];
  List<({double height, double caret})> _heights = const [];
  final Map<TextStyle?, double> _letterCarets = {};

  /// [span] must be the very span the field renders — styled runs can differ
  /// in width from the same characters in the base style.
  ///
  /// [placeholders] must describe every [WidgetSpan] in [span], in order. An
  /// image is a placeholder, and a line holding one is as tall as the image,
  /// so a note with pictures measures wrong without this.
  LineOffsets measure({
    required InlineSpan span,
    required double maxWidth,
    required StrutStyle strut,
    required TextScaler textScaler,
    List<PlaceholderDimensions> placeholders = const [],
  }) {
    if (maxWidth <= 0 || !maxWidth.isFinite) return LineOffsets.empty;
    if (_width != maxWidth ||
        _scaler != textScaler ||
        _strut != strut ||
        _style != span.style) {
      _width = maxWidth;
      _scaler = textScaler;
      _strut = strut;
      _style = span.style;
      _lines = const [];
      _heights = const [];
      _letterCarets.clear();
      final row = TextPainter(
        text: TextSpan(style: span.style),
        textDirection: TextDirection.ltr,
        strutStyle: strut,
        textScaler: textScaler,
      );
      _lineHeight = row.preferredLineHeight;
      row.dispose();
    }

    final lines = _linesOf(span, placeholders);
    // The lines an edit left alone keep their heights: those before the first
    // one that differs, and those after the last.
    var before = 0;
    while (before < lines.length &&
        before < _lines.length &&
        lines[before] == _lines[before]) {
      before++;
    }
    var after = 0;
    while (after < lines.length - before &&
        after < _lines.length - before &&
        lines[lines.length - 1 - after] == _lines[_lines.length - 1 - after]) {
      after++;
    }
    final heights = [
      ..._heights.take(before),
      for (var i = before; i < lines.length - after; i++)
        _heightOf(lines[i], span.style),
      ..._heights.skip(_heights.length - after),
    ];
    _lines = lines;
    _heights = heights;

    // A line's top is where the caret stands at its start, as the field
    // reports it: below the rows above, and as far down its own first row as
    // its first characters sit.
    final tops = <double>[];
    var top = 0.0;
    for (final line in heights) {
      tops.add(top + line.caret);
      top += line.height;
    }
    return LineOffsets(tops: tops, lineHeight: _lineHeight, totalHeight: top);
  }

  /// How tall [line]'s rows are, its line break included, and how far down
  /// the first of them the caret stands at its start.
  ({double height, double caret}) _heightOf(_Line line, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(
        style: style,
        children: [
          for (final run in line.runs) run.span,
          if (line.broken) TextSpan(text: '\nx', style: line.breakStyle),
        ],
      ),
      textDirection: TextDirection.ltr,
      strutStyle: _strut,
      textScaler: _scaler!,
    );
    final placeholders = [for (final run in line.runs) ?run.placeholder];
    if (placeholders.isNotEmpty) painter.setPlaceholderDimensions(placeholders);
    painter.layout(maxWidth: _width!);
    var height = painter.height;
    if (line.broken) {
      // Laid out with its break and a letter after it, which stands in for
      // the next line: the caret before that letter is as far down its row
      // as it is on a row of the letter alone.
      final length = line.runs.fold(0, (sum, run) => sum + run.length);
      height =
          _caretTop(painter, length + 1) -
          _letterCarets.putIfAbsent(
            line.breakStyle,
            () => _letterCaret(style, line.breakStyle),
          );
    }
    final caret = _caretTop(painter, 0);
    painter.dispose();
    return (height: height, caret: caret);
  }

  /// How far down a row of one letter in [breakStyle] the caret stands.
  double _letterCaret(TextStyle? style, TextStyle? breakStyle) {
    final painter = TextPainter(
      text: TextSpan(
        style: style,
        children: [TextSpan(text: 'x', style: breakStyle)],
      ),
      textDirection: TextDirection.ltr,
      strutStyle: _strut,
      textScaler: _scaler!,
    )..layout(maxWidth: _width!);
    final caret = _caretTop(painter, 0);
    painter.dispose();
    return caret;
  }

  static double _caretTop(TextPainter painter, int offset) =>
      painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy;

  /// [span] cut at its line breaks, every run with the style it inherits.
  static List<_Line> _linesOf(
    InlineSpan span,
    List<PlaceholderDimensions> placeholders,
  ) {
    final lines = <_Line>[];
    var runs = <_Run>[];
    var placeholder = 0;
    void visit(InlineSpan node, TextStyle? inherited) {
      final own = node.style;
      final style = own == null
          ? inherited
          : inherited == null
          ? own
          : inherited.merge(own);
      if (node is TextSpan) {
        final text = node.text;
        if (text != null && text.isNotEmpty) {
          var start = 0;
          while (true) {
            final newline = text.indexOf('\n', start);
            final end = newline < 0 ? text.length : newline;
            if (end > start) runs.add(_Run(text.substring(start, end), style));
            if (newline < 0) break;
            lines.add(_Line(runs, broken: true, breakStyle: style));
            runs = <_Run>[];
            start = newline + 1;
          }
        }
        for (final child in node.children ?? const <InlineSpan>[]) {
          visit(child, style);
        }
      } else if (node is PlaceholderSpan) {
        runs.add(
          _Run.placeholder(
            style,
            placeholder < placeholders.length
                ? placeholders[placeholder]
                : PlaceholderDimensions.empty,
            alignment: node.alignment,
            baseline: node.baseline,
          ),
        );
        placeholder++;
      }
    }

    visit(span, null);
    lines.add(_Line(runs, broken: false));
    return lines;
  }
}
