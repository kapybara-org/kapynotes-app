import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'markdown_syntax.dart';

/// How a run of a cell's words is drawn, given the markdown over them.
typedef MarkdownRunStyle =
    TextStyle Function(TextStyle base, Set<MarkdownStyle> styles);

/// The grid one table is drawn as: how wide each column is, how tall each row
/// is, and the words of each cell laid out ready to paint.
///
/// Kept out of the render object that paints it for two reasons. Three things
/// have to agree on one answer — the grid painted behind the text, the room the
/// field reserves for it, and where a tap lands — and they can only agree by
/// reading the same geometry. And a layout reachable only from inside a render
/// object cannot be measured by a test without building one, which is how the
/// column arithmetic went unchecked until now.
///
/// Two ways of measuring, chosen by [fitToWidth]:
///
/// * Left null, every column is as wide as its own widest cell wants to be, one
///   line each, cut short with an ellipsis past [maxCellWidth]. A table that
///   fits the writing column reads best this way, and it is what the editor did
///   before any of this.
/// * Given a width, the columns are shrunk to fit inside it and cell words wrap
///   onto as many lines as they need. A phone's writing column is narrower than
///   most tables, and hiding half a cell behind an ellipsis is no way to edit
///   one.
class TableGeometry {
  TableGeometry({
    required this.table,
    required MarkdownAnalysis analysis,
    required TextStyle base,
    required TextScaler scaler,
    required MarkdownRunStyle runStyle,
    this.fitToWidth,
    this.minRowHeight = 0,
  }) {
    final fitting = fitToWidth != null;
    final count = table.rows.fold<int>(
      0,
      (most, row) => math.max(most, row.cells.length),
    );
    final natural = List<double>.filled(count, 0);
    // The longest word in each column: narrower than that, a word has to be
    // broken in the middle to fit.
    final longestWord = List<double>.filled(count, 0);

    for (final row in table.rows) {
      final painters = <TextPainter>[];
      for (var c = 0; c < row.cells.length; c++) {
        final cell = row.cells[c];
        final painter = TextPainter(
          text: TextSpan(
            style: base,
            children: [
              for (final run in analysis.runsIn(cell.start, cell.end))
                TextSpan(
                  text: run.text,
                  style: runStyle(base, {
                    ...run.styles,
                    if (row.header) MarkdownStyle.tableHeader,
                  }),
                ),
            ],
          ),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: fitting ? null : 1,
          ellipsis: fitting ? null : '…',
        )..layout(maxWidth: maxCellWidth);
        natural[c] = math.max(natural[c], painter.width);
        longestWord[c] = math.max(longestWord[c], painter.minIntrinsicWidth);
        painters.add(painter);
      }
      _cells[row] = painters;
    }

    columns = fitting
        ? _fitted(
            [for (final width in natural) width + padding * 2],
            [for (final width in longestWord) width + padding * 2],
            fitToWidth!,
            minColumnWidth,
          )
        : [for (final width in natural) width + padding * 2];

    // Measured again inside the column each cell ended up with, so that words
    // too long for it wrap rather than spill over the next one.
    if (fitting) {
      for (final painters in _cells.values) {
        for (var c = 0; c < painters.length; c++) {
          painters[c].layout(maxWidth: math.max(1, innerWidth(c)));
        }
      }
    }

    for (final row in table.rows) {
      var tallest = 0.0;
      for (final painter in _cells[row] ?? const <TextPainter>[]) {
        tallest = math.max(tallest, painter.height);
      }
      _rowHeights[row] = math.max(minRowHeight, tallest + padding * 2);
    }
  }

  /// The air between a cell's words and its column's edges.
  static const double padding = 10;

  /// How wide one cell's words may be before they are cut short. A column wider
  /// than this crowds out every other one.
  static const double maxCellWidth = 320;

  /// The narrowest a column is shrunk to when a table is fitted. Below this
  /// there is nothing left to read and nothing worth tapping.
  static const double minColumnWidth = padding * 2 + 24;

  final MarkdownTable table;

  /// The width the table is fitted into, or null to let it be its natural size.
  final double? fitToWidth;

  /// The shortest a row may be, whatever its words need. The editor passes the
  /// height of one row of text, since a table row occupies at least one line of
  /// the note whether its cells fill it or not.
  final double minRowHeight;

  /// The width of each column, the padding on both sides included.
  late final List<double> columns;

  final Map<MarkdownTableRow, List<TextPainter>> _cells = {};
  final Map<MarkdownTableRow, double> _rowHeights = {};

  /// How wide the whole grid is.
  double get width => columns.fold<double>(0, (sum, column) => sum + column);

  /// How tall the whole grid is, every row counted.
  double get height =>
      table.rows.fold<double>(0, (sum, row) => sum + rowHeight(row));

  /// How much room one row's words need, its padding included.
  double rowHeight(MarkdownTableRow row) => _rowHeights[row] ?? minRowHeight;

  /// The words of one cell, or null where the row has no such column.
  TextPainter? cell(MarkdownTableRow row, int column) {
    final painters = _cells[row];
    return painters == null || column >= painters.length
        ? null
        : painters[column];
  }

  /// Where a source offset inside one cell is painted, relative to that
  /// cell's top-left corner.
  ///
  /// Inline markdown markers are not present in the painted words, so their
  /// exact glyph boundary no longer exists. Mapping by progress through the
  /// source keeps a collaborator's caret close to the word they are editing
  /// while guaranteeing it remains inside the visible cell.
  Rect? caretRectInCell(MarkdownTableRow row, int column, int sourceOffset) {
    final painter = cell(row, column);
    if (painter == null || column < 0 || column >= row.cells.length) {
      return null;
    }
    final source = row.cells[column];
    final sourceLength = source.end - source.start;
    final plainLength = painter.plainText.length;
    final progress = sourceLength == 0
        ? 0.0
        : ((sourceOffset - source.start) / sourceLength).clamp(0.0, 1.0);
    final plainOffset = (plainLength * progress).round().clamp(0, plainLength);
    final position = TextPosition(offset: plainOffset);
    final caret = painter.getOffsetForCaret(position, Rect.zero);
    final inner = innerWidth(column);
    final aligned = switch (table.aligns.elementAtOrNull(column)) {
      MarkdownCellAlign.center => (inner - painter.width) / 2,
      MarkdownCellAlign.end => inner - painter.width,
      _ => 0.0,
    };
    final height = painter.getFullHeightForCaret(position, Rect.zero);
    return Rect.fromLTWH(
      padding + math.max(0, aligned) + caret.dx,
      (rowHeight(row) - painter.height) / 2 + caret.dy,
      0,
      height,
    );
  }

  /// The words a cell has room for, inside its padding.
  double innerWidth(int column) => column < 0 || column >= columns.length
      ? 0
      : columns[column] - padding * 2;

  /// Where a column's left edge sits, measured from the grid's own left edge.
  double columnLeft(int column) {
    var x = 0.0;
    for (var c = 0; c < column && c < columns.length; c++) {
      x += columns[c];
    }
    return x;
  }

  /// Which column [dx] falls in, measured from the grid's left edge, or null
  /// outside the grid.
  ///
  /// A caller hit-testing a tap clamps this itself: the edge of the last column
  /// is the edge of the table, and whether a press there counts is a question
  /// about taps rather than about geometry.
  int? columnAt(double dx) {
    if (dx < 0) return null;
    var x = 0.0;
    for (var c = 0; c < columns.length; c++) {
      x += columns[c];
      if (dx < x) return c;
    }
    return null;
  }

  /// [natural] shrunk to fit [available].
  ///
  /// Wide columns give way before narrow ones: the widest are capped at one
  /// shared ceiling, found by halving, and anything already narrower than that
  /// ceiling keeps the width it asked for. A column of long prose beside a
  /// column of numbers therefore loses the room, which is the sharing a reader
  /// would choose.
  ///
  /// No column is capped below its longest word while every column's longest
  /// word still fits: a phone-width table whose prose column broke `breakfast`
  /// into `breakfa` and `st` while a column of short labels kept its whole
  /// width was the wrong way round. Only when even that cannot fit are words
  /// broken, and then every column gives up room in proportion to its longest
  /// word — or all share it equally below [floor] each; a table that narrow is
  /// hard to read either way, and this at least keeps it inside the writing
  /// column.
  static List<double> _fitted(
    List<double> natural,
    List<double> longestWord,
    double available,
    double floor,
  ) {
    if (natural.isEmpty) return natural;
    double sum(Iterable<double> widths) =>
        widths.fold<double>(0, (sum, width) => sum + width);
    if (sum(natural) <= available) return natural;
    final minimum = [
      for (var i = 0; i < natural.length; i++)
        math.min(natural[i], math.max(floor, longestWord[i])),
    ];
    final needed = sum(minimum);
    if (needed > available) {
      if (available <= floor * natural.length) {
        final each = available / natural.length;
        return [for (var i = 0; i < natural.length; i++) each];
      }
      final share = available / needed;
      return [for (final width in minimum) width * share];
    }
    List<double> capped(double cap) => [
      for (var i = 0; i < natural.length; i++)
        math.max(minimum[i], math.min(natural[i], cap)),
    ];
    var low = 0.0;
    var high = natural.reduce(math.max);
    for (var i = 0; i < 40; i++) {
      final cap = (low + high) / 2;
      if (sum(capped(cap)) > available) {
        high = cap;
      } else {
        low = cap;
      }
    }
    return capped(low);
  }

  void dispose() {
    for (final painters in _cells.values) {
      for (final painter in painters) {
        painter.dispose();
      }
    }
    _cells.clear();
    _rowHeights.clear();
  }
}

final Map<(TextStyle, StrutStyle, TextScaler), double> _overheads = {};

/// How much taller than the height it is given a line holding a placeholder
/// comes out.
///
/// A `WidgetSpan` aligned to the top of its line is placed below the strut's
/// ascent, so a line asked for 60px comes out rather more than 60 tall. The
/// difference is the same whatever height is asked for, but it follows the
/// writing font and the text scale — so it is measured here rather than written
/// down as a number that would quietly stop being true.
///
/// Only meaningful with the strut relaxed. A forced strut pins every line to its
/// own height, and then a placeholder of any size changes nothing at all.
double placeholderLineOverhead({
  required TextStyle style,
  required StrutStyle strut,
  required TextScaler scaler,
}) {
  final key = (style, strut, scaler);
  final known = _overheads[key];
  if (known != null) return known;
  if (_overheads.length > 64) _overheads.clear();

  const asked = 200.0;
  final painter =
      TextPainter(
        text: TextSpan(
          style: style,
          children: const [
            TextSpan(text: 'a\n'),
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: SizedBox.shrink(),
            ),
            TextSpan(text: '\nb'),
          ],
        ),
        textDirection: TextDirection.ltr,
        strutStyle: strut,
        textScaler: scaler,
      )..setPlaceholderDimensions(const [
        PlaceholderDimensions(
          size: Size(0, asked),
          alignment: PlaceholderAlignment.top,
        ),
      ]);
  painter.layout();
  // The placeholder stands alone on the middle line: `a`, it, then `b`.
  final top = painter
      .getOffsetForCaret(const TextPosition(offset: 2), Rect.zero)
      .dy;
  final next = painter
      .getOffsetForCaret(const TextPosition(offset: 4), Rect.zero)
      .dy;
  painter.dispose();
  return _overheads[key] = math.max(0, next - top - asked);
}

typedef _Key = (int, TextStyle, TextScaler, double?, double);

/// The geometry of a note's tables, kept for as long as the note and the style
/// it is drawn in stay the same.
///
/// A table is named by where it starts, which is unique within one analysis, and
/// measured again whenever anything it depends on changes — the width it is
/// fitted into included, so that a narrower window never reuses the answer
/// worked out for a wider one.
class TableGeometryCache {
  final Map<_Key, TableGeometry> _geometry = {};
  MarkdownAnalysis? _analysis;

  TableGeometry of({
    required MarkdownTable table,
    required MarkdownAnalysis analysis,
    required TextStyle base,
    required TextScaler scaler,
    required MarkdownRunStyle runStyle,
    double? fitToWidth,
    double minRowHeight = 0,
  }) {
    // Any edit makes a new analysis, and every offset held here came from the
    // old one.
    if (!identical(analysis, _analysis)) {
      forget();
      _analysis = analysis;
    }
    return _geometry.putIfAbsent(
      (table.start, base, scaler, fitToWidth, minRowHeight),
      () => TableGeometry(
        table: table,
        analysis: analysis,
        base: base,
        scaler: scaler,
        runStyle: runStyle,
        fitToWidth: fitToWidth,
        minRowHeight: minRowHeight,
      ),
    );
  }

  void forget() {
    for (final geometry in _geometry.values) {
      geometry.dispose();
    }
    _geometry.clear();
  }

  void dispose() => forget();
}
