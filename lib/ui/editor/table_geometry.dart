import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'markdown_editing.dart';
import 'markdown_syntax.dart';

/// How a run of a cell's words is drawn, given the markdown over them.
typedef MarkdownRunStyle =
    TextStyle Function(TextStyle base, Set<MarkdownStyle> styles, String words);

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
///
/// Either way a `<br>` in a cell starts a new line of it, so a cell has as
/// many lines as it was written with at the least: one each, cut short one by
/// one, when the table is its natural size.
class TableGeometry {
  TableGeometry({
    required this.table,
    required MarkdownAnalysis analysis,
    required TextStyle base,
    required TextScaler scaler,
    required MarkdownRunStyle runStyle,
    this.fitToWidth,
    this.fill = false,
    this.minRowHeight = 0,
    TableGeometry? reuse,
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
      final source = analysis.text.substring(row.start, row.end);
      _rowWords[row] = source;
      final kept = reuse?._take(source, header: row.header);
      if (kept != null) {
        _cells[row] = kept.painters;
        _sources[row] = kept.sources;
        _widths[row] = kept.widths;
        for (var c = 0; c < kept.widths.length; c++) {
          natural[c] = math.max(natural[c], kept.widths[c].natural);
          longestWord[c] = math.max(longestWord[c], kept.widths[c].longestWord);
        }
        continue;
      }
      final painters = <TextPainter>[];
      final sources = <List<int>>[];
      final widths = <({double natural, double longestWord})>[];
      for (var c = 0; c < row.cells.length; c++) {
        final cell = row.cells[c];
        final words = [
          for (final run in analysis.runsIn(cell.start, cell.end))
            TextSpan(
              text: run.text,
              style: runStyle(base, {
                ...run.styles,
                if (row.header) MarkdownStyle.tableHeader,
              }, run.text),
            ),
        ];
        final broken = words.any((span) => span.text!.contains('\n'));
        final painter = TextPainter(
          text: TextSpan(
            style: base,
            children: fitting || !broken
                ? words
                : _cutShort(words, base, scaler, maxCellWidth),
          ),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: fitting || broken ? null : 1,
          ellipsis: fitting || broken ? null : '…',
        )..layout(maxWidth: maxCellWidth);
        natural[c] = math.max(natural[c], painter.width);
        longestWord[c] = math.max(longestWord[c], painter.minIntrinsicWidth);
        painters.add(painter);
        sources.add(_sourcesOf(analysis, cell, painter.plainText));
        widths.add((
          natural: painter.width,
          longestWord: painter.minIntrinsicWidth,
        ));
      }
      _cells[row] = painters;
      _sources[row] = sources;
      _widths[row] = widths;
    }

    charWidth = _averageCharWidth(base, scaler);
    final dashes = markdownTableDashes(analysis.text, table);
    final set = [
      for (var c = 0; c < count; c++)
        c < dashes.length ? markdownTableColumnWidth(dashes[c]) : null,
    ];
    columns = fitting && set.any((width) => width != null)
        ? _preferred([
            for (var c = 0; c < count; c++)
              (set[c] == null ? natural[c] : set[c]! * charWidth) + padding * 2,
          ], fitToWidth!)
        : fitting
        ? _fitted(
            [for (final width in natural) width + padding * 2],
            [for (final width in longestWord) width + padding * 2],
            fitToWidth!,
            minColumnWidth,
          )
        : [for (final width in natural) width + padding * 2];
    // A table someone has sized keeps those sizes rather than stretching.
    if (fill && fitting && set.every((width) => width == null)) {
      final spare = fitToWidth! - width;
      if (spare > 0) columns[0] += spare;
    }

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
      _rowHeights[row] = math.max(minRowHeight, tallest + verticalPadding * 2);
    }
  }

  /// [measured]'s grid for [table], the same words where they stand now. The
  /// cells' painters stay [measured]'s, and go when it is disposed.
  TableGeometry._movedTo(this.table, TableGeometry measured)
    : fitToWidth = measured.fitToWidth,
      fill = measured.fill,
      minRowHeight = measured.minRowHeight {
    columns = measured.columns;
    charWidth = measured.charWidth;
    for (var i = 0; i < table.rows.length; i++) {
      final row = measured.table.rows[i];
      final cells = measured._cells[row];
      final sources = measured._sources[row];
      final widths = measured._widths[row];
      final words = measured._rowWords[row];
      final height = measured._rowHeights[row];
      if (cells != null) _cells[table.rows[i]] = cells;
      if (sources != null) _sources[table.rows[i]] = sources;
      if (widths != null) _widths[table.rows[i]] = widths;
      if (words != null) _rowWords[table.rows[i]] = words;
      if (height != null) _rowHeights[table.rows[i]] = height;
    }
  }

  /// The air between a cell's words and its column's edges, and above and
  /// below them: Paper's 14 across and 36px rows.
  static const double padding = 14;
  static const double verticalPadding = 8;

  /// How wide one cell's words may be before they are cut short. A column wider
  /// than this crowds out every other one.
  static const double maxCellWidth = 320;

  /// The narrowest a column is shrunk to when a table is fitted. Below this
  /// there is nothing left to read and nothing worth tapping.
  static const double minColumnWidth = padding * 2 + 24;

  final MarkdownTable table;

  /// One character of the cells' face, on average: what one dash past the
  /// third in the delimiter row is worth when a column's width is set.
  late final double charWidth;

  static double _averageCharWidth(TextStyle base, TextScaler scaler) {
    const sample = 'abcdefghijklmnopqrstuvwxyz';
    final painter = TextPainter(
      text: TextSpan(text: sample, style: base),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width / sample.length;
    painter.dispose();
    return width;
  }

  /// Widths someone set, kept while they fit in [available], and all scaled
  /// down together when they do not: a set width is a preference, and a table
  /// never runs out of the column it is written in.
  static List<double> _preferred(List<double> wanted, double available) {
    final total = wanted.fold<double>(0, (sum, width) => sum + width);
    if (total <= available) return wanted;
    return [
      for (final width in wanted)
        math.max(minColumnWidth, width * available / total),
    ];
  }

  /// The width the table is fitted into, or null to let it be its natural size.
  final double? fitToWidth;

  /// Whether a table narrower than [fitToWidth] is widened to it, its first
  /// column taking what is spare, as Paper's page sets a table.
  final bool fill;

  /// The shortest a row may be, whatever its words need. The editor passes the
  /// height of one row of text, since a table row occupies at least one line of
  /// the note whether its cells fill it or not.
  final double minRowHeight;

  /// The width of each column, the padding on both sides included.
  late final List<double> columns;

  final Map<MarkdownTableRow, List<TextPainter>> _cells = {};
  final Map<MarkdownTableRow, List<List<int>>> _sources = {};
  final Map<MarkdownTableRow, List<({double natural, double longestWord})>>
  _widths = {};
  final Map<MarkdownTableRow, String> _rowWords = {};

  /// The measured cells of a row whose source is [words], taken out of this
  /// grid for a new one to keep, so a row nobody edited is not measured again.
  /// This grid draws nothing afterwards, and is only disposed.
  ({
    List<TextPainter> painters,
    List<List<int>> sources,
    List<({double natural, double longestWord})> widths,
  })?
  _take(String words, {required bool header}) {
    for (final row in table.rows) {
      if (row.header != header || _rowWords[row] != words) continue;
      final painters = _cells.remove(row);
      final sources = _sources.remove(row);
      final widths = _widths.remove(row);
      _rowWords.remove(row);
      if (painters == null || sources == null || widths == null) return null;
      return (painters: painters, sources: sources, widths: widths);
    }
    return null;
  }

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
    final position = TextPosition(
      offset: _plainOffset(row, column, painter, sourceOffset),
    );
    final caret = painter.getOffsetForCaret(position, Rect.zero);
    final height = painter.getFullHeightForCaret(position, Rect.zero);
    return Rect.fromLTWH(
      0,
      0,
      0,
      height,
    ).shift(_wordsAt(row, column, painter) + caret);
  }

  /// Where the source from [start] to [end] inside one cell is painted, row
  /// by row, relative to that cell's top-left corner, mapped as
  /// [caretRectInCell] maps a caret.
  List<Rect> selectionInCell(
    MarkdownTableRow row,
    int column,
    int start,
    int end,
  ) {
    final painter = cell(row, column);
    if (painter == null || column < 0 || column >= row.cells.length) {
      return const [];
    }
    final at = _wordsAt(row, column, painter);
    return [
      for (final box in painter.getBoxesForSelection(
        TextSelection(
          baseOffset: _plainOffset(row, column, painter, start),
          extentOffset: _plainOffset(row, column, painter, end),
        ),
      ))
        box.toRect().shift(at),
    ];
  }

  /// Where a source offset inside a cell falls in its painted words: past
  /// every painted character whose source comes before it, so the markers the
  /// words leave out take up no room.
  int _plainOffset(
    MarkdownTableRow row,
    int column,
    TextPainter painter,
    int sourceOffset,
  ) {
    final sources = _sources[row]?.elementAtOrNull(column) ?? const <int>[];
    final at = sourceOffset - row.cells[column].start;
    var low = 0;
    var high = sources.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (sources[middle] < at) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// Where each character of a cell's painted words, [plain], comes from in
  /// its source, counted from the cell's start. The words are the source with
  /// its markers hidden, each `<br>` read as a line break, and the spaces at
  /// either end and around a break left out, so each painted character is
  /// matched to the next source character it can be. An ellipsis, which the
  /// source never holds, and what follows it map past the cell's end.
  static List<int> _sourcesOf(
    MarkdownAnalysis analysis,
    MarkdownTableCell cell,
    String plain,
  ) {
    final text = analysis.text;
    final hidden = [
      for (final conceal in analysis.conceals)
        if (conceal.start < cell.end && conceal.end > cell.start) conceal,
    ];
    final breaks = [
      for (final tag in analysis.lineBreaks)
        if (tag.start >= cell.start && tag.end <= cell.end) tag,
    ];
    final sources = <int>[];
    var at = cell.start;
    for (var i = 0; i < plain.length; i++) {
      final wanted = plain[i];
      int? found;
      while (at < cell.end) {
        final tag = breaks.where((tag) => tag.start == at).firstOrNull;
        if (tag != null) {
          at = tag.end;
          if (wanted == '\n') {
            found = tag.start;
            break;
          }
          continue;
        }
        final conceal = hidden
            .where((conceal) => conceal.start <= at && at < conceal.end)
            .firstOrNull;
        if (conceal != null) {
          at = conceal.end;
          continue;
        }
        at++;
        if (text[at - 1] == wanted) {
          found = at - 1;
          break;
        }
      }
      if (found == null) {
        at = cell.end;
        sources.add(cell.end - cell.start);
      } else {
        sources.add(found - cell.start);
      }
    }
    return sources;
  }

  /// Where a cell's words start, relative to the cell's top-left corner.
  Offset _wordsAt(MarkdownTableRow row, int column, TextPainter painter) {
    final inner = innerWidth(column);
    final aligned = switch (table.aligns.elementAtOrNull(column)) {
      MarkdownCellAlign.center => (inner - painter.width) / 2,
      MarkdownCellAlign.end => inner - painter.width,
      _ => 0.0,
    };
    return Offset(
      padding + math.max(0, aligned),
      (rowHeight(row) - painter.height) / 2,
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

  /// [words] with each of its lines that is wider than [width] cut short, an
  /// ellipsis in place of the rest: what a single-line cell gets from its
  /// painter, done line by line, since a painter only shortens the last line
  /// it is allowed and wraps every one before it.
  static List<TextSpan> _cutShort(
    List<TextSpan> words,
    TextStyle base,
    TextScaler scaler,
    double width,
  ) {
    final lines = <List<TextSpan>>[[]];
    for (final span in words) {
      final pieces = span.text!.split('\n');
      for (var i = 0; i < pieces.length; i++) {
        if (i > 0) lines.add([]);
        if (pieces[i].isNotEmpty) {
          lines.last.add(TextSpan(text: pieces[i], style: span.style));
        }
      }
    }
    double widthOf(List<TextSpan> line) {
      final painter = TextPainter(
        text: TextSpan(style: base, children: line),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    List<TextSpan> ellipsized(List<TextSpan> line, int length) {
      final kept = <TextSpan>[];
      var left = length;
      for (final span in line) {
        final text = span.text!;
        if (left < text.length) {
          var end = left;
          if (end > 0 && _isLeadSurrogate(text.codeUnitAt(end - 1))) end--;
          kept.add(
            TextSpan(text: '${text.substring(0, end)}…', style: span.style),
          );
          return kept;
        }
        kept.add(span);
        left -= text.length;
      }
      return kept;
    }

    final result = <TextSpan>[];
    for (var l = 0; l < lines.length; l++) {
      var line = lines[l];
      if (widthOf(line) > width) {
        var low = 0;
        var high = line.fold<int>(0, (sum, span) => sum + span.text!.length);
        while (low < high) {
          final middle = (low + high + 1) ~/ 2;
          if (widthOf(ellipsized(line, middle)) <= width) {
            low = middle;
          } else {
            high = middle - 1;
          }
        }
        line = ellipsized(line, low);
      }
      if (l > 0) result.add(const TextSpan(text: '\n'));
      result.addAll(line);
    }
    return result;
  }

  static bool _isLeadSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

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
    _sources.clear();
    _widths.clear();
    _rowWords.clear();
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

typedef _Key = (String, TextStyle, TextScaler, double?, bool, double, Object?);

/// The geometry of a note's tables, kept for as long as each table's words
/// and the style it is drawn in stay the same.
///
/// A table is named by its source text, so an edit anywhere else in the note,
/// which only moves it, measures nothing again: the grid measured before is
/// handed back for the table where it now stands. It is measured again
/// whenever anything it depends on changes — the width it is fitted into
/// included, so that a narrower window never reuses the answer worked out for
/// a wider one. A grid no table asked for while the note was read the last
/// two times is let go.
class TableGeometryCache {
  Map<_Key, TableGeometry> _geometry = {};
  Map<_Key, TableGeometry> _previous = {};
  MarkdownAnalysis? _analysis;

  /// [style] names whatever else [runStyle] draws with, such as the theme's
  /// colours: a grid is measured again when it changes.
  TableGeometry of({
    required MarkdownTable table,
    required MarkdownAnalysis analysis,
    required TextStyle base,
    required TextScaler scaler,
    required MarkdownRunStyle runStyle,
    double? fitToWidth,
    bool fill = false,
    double minRowHeight = 0,
    Object? style,
  }) {
    if (!identical(analysis, _analysis)) {
      _release(_previous);
      _previous = _geometry;
      _geometry = {};
      _analysis = analysis;
    }
    final key = (
      analysis.text.substring(table.start, table.end),
      base,
      scaler,
      fitToWidth,
      fill,
      minRowHeight,
      style,
    );
    final measured = _geometry[key] ??=
        _previous.remove(key) ??
        _measure(
          key,
          table: table,
          analysis: analysis,
          base: base,
          scaler: scaler,
          runStyle: runStyle,
          fitToWidth: fitToWidth,
          fill: fill,
          minRowHeight: minRowHeight,
        );
    return identical(measured.table, table)
        ? measured
        : TableGeometry._movedTo(table, measured);
  }

  /// A new grid for [table], keeping the measured rows of the grid the same
  /// table had in the note before, drawn the same way, wherever a row's
  /// source is unchanged: typing in one cell of a long table measures that
  /// row again and not the rest.
  TableGeometry _measure(
    _Key key, {
    required MarkdownTable table,
    required MarkdownAnalysis analysis,
    required TextStyle base,
    required TextScaler scaler,
    required MarkdownRunStyle runStyle,
    required double? fitToWidth,
    required bool fill,
    required double minRowHeight,
  }) {
    final before = _previous.entries
        .where(
          (entry) =>
              entry.value.table.start == table.start &&
              entry.key.$2 == key.$2 &&
              entry.key.$3 == key.$3 &&
              entry.key.$4 == key.$4 &&
              entry.key.$5 == key.$5 &&
              entry.key.$6 == key.$6 &&
              entry.key.$7 == key.$7,
        )
        .firstOrNull;
    if (before != null) _previous.remove(before.key);
    final measured = TableGeometry(
      table: table,
      analysis: analysis,
      base: base,
      scaler: scaler,
      runStyle: runStyle,
      fitToWidth: fitToWidth,
      fill: fill,
      minRowHeight: minRowHeight,
      reuse: before?.value,
    );
    before?.value.dispose();
    return measured;
  }

  static void _release(Map<_Key, TableGeometry> geometry) {
    for (final measured in geometry.values) {
      measured.dispose();
    }
    geometry.clear();
  }

  void forget() {
    _release(_geometry);
    _release(_previous);
    _analysis = null;
  }

  void dispose() => forget();
}
