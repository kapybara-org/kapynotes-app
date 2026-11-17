import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/iconography.dart';
import '../../core/theme.dart' show EditorMetrics;
import 'markdown_syntax.dart';
import 'note_field.dart';
import 'table_geometry.dart';

/// The colours [MarkdownBackdrop] draws with, taken from the theme once per
/// build rather than looked up while painting.
@immutable
class MarkdownBackdropColors {
  const MarkdownBackdropColors({
    required this.quiet,
    required this.rule,
    required this.quoteBar,
    required this.panel,
    required this.panelBorder,
    required this.codePanel,
    required this.codeChip,
    required this.accent,
    required this.onAccent,
    required this.box,
    required this.chip,
    required this.chipInk,
  });

  /// Bullets, and an unticked box off the page.
  final Color quiet;

  /// A rule across the column.
  final Color rule;
  final Color quoteBar;

  /// A table's header row, and the edges of a table and a code block.
  final Color panel;
  final Color panelBorder;

  /// Behind a code block, and the pill behind inline code.
  final Color codePanel;
  final Color codeChip;

  /// A ticked box, and the tick in it.
  final Color accent;
  final Color onAccent;

  /// An unticked box's edge on the page, and the chip under a web address.
  final Color box;
  final Color chip;
  final Color chipInk;

  @override
  bool operator ==(Object other) =>
      other is MarkdownBackdropColors &&
      other.quiet == quiet &&
      other.rule == rule &&
      other.quoteBar == quoteBar &&
      other.panel == panel &&
      other.panelBorder == panelBorder &&
      other.codePanel == codePanel &&
      other.codeChip == codeChip &&
      other.accent == accent &&
      other.onAccent == onAccent &&
      other.box == box &&
      other.chip == chip &&
      other.chipInk == chipInk;

  @override
  int get hashCode => Object.hash(
    quiet,
    rule,
    quoteBar,
    panel,
    panelBorder,
    codePanel,
    codeChip,
    accent,
    onAccent,
    box,
    chip,
    chipInk,
  );
}

/// What a markdown note draws behind its text: the parts of markdown that
/// are pictures rather than words.
///
/// Bullets, checkboxes and the pill behind inline code sit exactly where the
/// field laid out the characters they stand in for, read from the field as it
/// paints. The panel under a code block, a quote's bar and a rule cover the
/// rows their lines take up, from the same line measurement the results
/// gutter uses. A table is drawn as a grid over its own text, which the
/// field leaves invisible but in place. Paper's p-5-0 draws all of them.
///
/// Everything here is under the field, so its selection highlight still
/// shows over a checkbox or a code pill the way it does over words.
class MarkdownBackdrop extends LeafRenderObjectWidget {
  const MarkdownBackdrop({
    super.key,
    required this.analysis,
    required this.concealment,
    required this.grids,
    required this.scroll,
    required this.field,
    required this.colors,
    required this.markerRoom,
    this.checkboxes = const [],
    this.chips = const [],
  });

  final MarkdownAnalysis analysis;

  /// The app's own checkboxes, drawn the way a task's box is, on the page.
  final List<MarkdownOrnament> checkboxes;

  /// The web addresses the page sets as chips.
  final List<TextRange> chips;
  final MarkdownConcealment concealment;

  /// The grid each table is drawn as, measured by the editor, which is the only
  /// place that knows how wide the writing column is. The same geometry decides
  /// the room each row reserves, so the two cannot drift apart.
  final Map<MarkdownTable, TableGeometry> grids;

  final ScrollController scroll;

  /// The field whose text this draws behind.
  final NoteFieldState? Function() field;
  final MarkdownBackdropColors colors;

  /// The room the field gives a list marker, which a bullet is drawn in. See
  /// `HighlightingController.markdownMarkerRoom`.
  final double markerRoom;

  @override
  RenderMarkdownBackdrop createRenderObject(BuildContext context) =>
      RenderMarkdownBackdrop(
        analysis: analysis,
        concealment: concealment,
        grids: grids,
        scroll: scroll,
        field: field,
        colors: colors,
        markerRoom: markerRoom,
        checkboxes: checkboxes,
        chips: chips,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMarkdownBackdrop renderObject,
  ) {
    renderObject
      ..analysis = analysis
      ..concealment = concealment
      ..grids = grids
      ..scroll = scroll
      ..field = field
      ..colors = colors
      ..markerRoom = markerRoom
      ..checkboxes = checkboxes
      ..chips = chips
      // The field was rebuilt alongside this, and its layout can change with
      // nothing here changing — a wider window, a new writing font.
      ..markNeedsPaint();
  }
}

class RenderMarkdownBackdrop extends RenderBox {
  RenderMarkdownBackdrop({
    required MarkdownAnalysis analysis,
    required this.concealment,
    required this.grids,
    required ScrollController scroll,
    required this.field,
    required this.colors,
    required this.markerRoom,
    required this.checkboxes,
    required this.chips,
  }) : _analysis = analysis,
       _scroll = scroll;

  MarkdownAnalysis _analysis;
  set analysis(MarkdownAnalysis value) => _analysis = value;

  MarkdownConcealment concealment;
  Map<MarkdownTable, TableGeometry> grids;
  NoteFieldState? Function() field;
  MarkdownBackdropColors colors;
  double markerRoom;
  List<MarkdownOrnament> checkboxes;
  List<TextRange> chips;

  ScrollController _scroll;
  set scroll(ScrollController value) {
    if (identical(value, _scroll)) return;
    if (attached) _scroll.removeListener(markNeedsPaint);
    _scroll = value;
    if (attached) _scroll.addListener(markNeedsPaint);
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  /// Repaints with every scroll; this keeps those to this layer.
  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scroll.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _scroll.removeListener(markNeedsPaint);
    super.detach();
  }

  /// The top and bottom of the rows the lines from [start] to [end] take, in
  /// [field]'s coordinates.
  (double, double)? _rows(NoteFieldState field, int start, int end) {
    final lines = field.lines;
    final top = field.lineTop(lines.lineAt(start));
    final bottom = field.lineTop(lines.lineAt(math.max(start, end - 1)) + 1);
    if (top == null || bottom == null) return null;
    return bottom > top ? (top, bottom) : null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final field = this.field();
    final box = field?.box;
    if (field == null || box == null) return;
    // Everything below is in this layer's coordinates. The field's rows and
    // boxes already account for its scroll offset.
    final fieldOrigin = box.localToGlobal(Offset.zero);
    final origin = globalToLocal(fieldOrigin);
    final visible = origin & box.size;
    double rowY(double y) => origin.dy + y;

    // Only what is on screen. A long note can hold thousands of bullets, and
    // each one asked about below is a layout query.
    final firstShown = field.positionAt(fieldOrigin).offset;
    final lastShown = field
        .positionAt(fieldOrigin + box.size.bottomRight(Offset.zero))
        .offset;
    bool onScreen(int start, int end) =>
        end >= firstShown && start <= lastShown + 1;

    // Clipped top and bottom where the field clips its text, and no further:
    // a code panel and a quote's bar reach into the margin to the left.
    final canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..clipRect(Rect.fromLTRB(0, visible.top, size.width, visible.bottom));

    final left = origin.dx;
    // Across the writing and the room its rows keep for the caret. On the
    // page, the column: the field runs on past it for attachments.
    final width = field.layout.width;
    final right =
        origin.dx +
        (width == null
            ? box.size.width
            : EditorMetrics.page
            ? math.min(width, EditorMetrics.columnWidth)
            : width + field.layout.caretRoom);
    for (final block in _analysis.blocks) {
      if (!onScreen(block.start, block.end)) continue;
      if (block.kind == MarkdownBlockKind.quote && block.depth > 1) continue;
      final rows = _rows(field, block.start, block.end);
      if (rows == null) continue;
      final top = rowY(rows.$1);
      final bottom = rowY(rows.$2);
      switch (block.kind) {
        case MarkdownBlockKind.code:
          _paintCode(canvas, field, block, left, right, top, bottom, rowY);
        case MarkdownBlockKind.quote:
          // The page's bar is Paper's: in the column, with the words past
          // it and 2px of room above and below. A phone's is out in the
          // margin, so the words line up with the rest.
          final x = EditorMetrics.page
              ? left
              : left - EditorMetrics.quoteIndent;
          final room = EditorMetrics.page ? 2.0 : 0.0;
          canvas.drawRRect(
            RRect.fromLTRBR(
              x,
              top - room,
              x + 3,
              bottom + room,
              const Radius.circular(2),
            ),
            Paint()..color = colors.quoteBar,
          );
        case MarkdownBlockKind.rule:
          // Not through its own \`---\` while that is shown as written.
          if (!concealment.hides(block.start, block.end)) continue;
          final y = ((top + bottom) / 2).roundToDouble() + 0.5;
          canvas.drawLine(
            Offset(left, y),
            Offset(right, y),
            Paint()
              ..color = colors.rule
              ..strokeWidth = 1,
          );
      }
    }

    for (final chip in chips) {
      if (!onScreen(chip.start, chip.end)) continue;
      for (final box in field.boxesFor(
        TextSelection(baseOffset: chip.start, extentOffset: chip.end),
      )) {
        final rect = box.toRect().shift(origin);
        final left = rect.left - EditorMetrics.linkChipLead;
        canvas.drawRRect(
          RRect.fromLTRBR(
            left,
            rect.center.dy - _chipHeight / 2,
            rect.right + EditorMetrics.linkChipTrail,
            rect.center.dy + _chipHeight / 2,
            const Radius.circular(_chipHeight / 2),
          ),
          Paint()..color = colors.chip,
        );
        _paintLink(
          canvas,
          Offset(left + 8, rect.center.dy - EditorMetrics.linkChipIcon / 2),
        );
      }
    }

    final room = markerRoom;
    // The app's own boxes stand in a room before the words the way a task's
    // does: their glyph and the space after it are spaced out to fill it.
    for (final checkbox in checkboxes) {
      if (!onScreen(checkbox.start, checkbox.end)) continue;
      final boxes = field.boxesFor(
        TextSelection(
          baseOffset: checkbox.start,
          extentOffset: checkbox.end + 1,
        ),
      );
      if (boxes.isEmpty) continue;
      final row = boxes.first.toRect().shift(origin);
      final words = boxes.last.toRect().shift(origin).right;
      _paintCheckbox(
        canvas,
        Rect.fromLTRB(words - room, row.top, words, row.bottom),
        checkbox,
      );
    }
    for (final ornament in _analysis.ornaments) {
      if (!onScreen(ornament.start, ornament.end)) continue;
      final boxes = field.boxesFor(
        TextSelection(baseOffset: ornament.start, extentOffset: ornament.end),
      );
      if (boxes.isEmpty) continue;
      switch (ornament.kind) {
        case MarkdownOrnamentKind.bullet:
          // In the column a task's box is drawn in: a room before the words,
          // which is where the bullet's own characters end.
          final words = boxes.last.toRect().shift(origin).right;
          final row = boxes.first.toRect().shift(origin);
          _paintBullet(
            canvas,
            Offset(
              words - room + _boxInset + _boxSide / 2,
              row.center.dy + 0.5,
            ),
            ornament,
          );
        case MarkdownOrnamentKind.checkbox:
          _paintCheckbox(canvas, boxes.first.toRect().shift(origin), ornament);
        case MarkdownOrnamentKind.codeSpan:
          // On the page the field already spaced the last character out by
          // the pill's reach; see `HighlightingController`.
          final page = EditorMetrics.page;
          final reach = page ? EditorMetrics.codeChipReach : 3.0;
          for (final box in boxes) {
            final rect = box.toRect().shift(origin);
            if (rect.width <= 0) continue;
            final height = math.min(rect.height - 6, 22.0);
            canvas.drawRRect(
              RRect.fromLTRBR(
                rect.left - reach,
                rect.center.dy - height / 2,
                rect.right + (page ? 0 : reach),
                rect.center.dy + height / 2,
                const Radius.circular(6),
              ),
              Paint()..color = colors.codeChip,
            );
          }
      }
    }

    for (final table in _analysis.tables) {
      if (!onScreen(table.start, table.end)) continue;
      _paintTable(canvas, field, table, left, rowY);
    }

    canvas.restore();
  }

  /// How far a phone's code block panel reaches out from the writing: the
  /// 14px Paper's panel has around its code.
  static const double _codeInset = 14;

  /// Paper's code block: a panel a step below the page reaching [_codeInset]
  /// past the code, and over a fenced block whose fence is hidden, the row
  /// that fence keeps ruled off as a header, where the editor puts the
  /// language and Copy. Closed and hidden, the closing fence's row gives the
  /// panel no more than Paper's 10 under the code.
  void _paintCode(
    Canvas canvas,
    NoteFieldState field,
    MarkdownBlock block,
    double left,
    double right,
    double top,
    double bottom,
    double Function(double) rowY,
  ) {
    final fences = _analysis.fencesOf(block);
    final close = fences?.close;
    final closeRows = close != null && concealment.hides(close.start, close.end)
        ? _rows(field, close.start, close.end)
        : null;
    final open = fences?.open;
    final openRows = open == null
        ? null
        : concealment.hides(open.start, open.end)
        ? _rows(field, open.start, open.end)
        : null;
    // The rows a hidden fence keeps are Paper's gap, header and margin or
    // its panel's foot and gap, at the size the note's text is.
    final openScale = openRows == null
        ? 1.0
        : (openRows.$2 - openRows.$1) / EditorMetrics.codeOpenRow;
    final closeScale = closeRows == null
        ? 1.0
        : (closeRows.$2 - closeRows.$1) / EditorMetrics.codeCloseRow;
    // The page's panel is the column wide, with the code inset in it; a
    // phone's reaches out into the margin, with the code on the column.
    final reach = EditorMetrics.page ? 0.0 : _codeInset;
    final panel = RRect.fromLTRBR(
      left - reach,
      openRows == null
          ? top
          : rowY(openRows.$1) + EditorMetrics.codeGapBefore * openScale,
      right + reach,
      closeRows == null
          ? bottom
          : rowY(closeRows.$1) + EditorMetrics.codePanelBottom * closeScale,
      const Radius.circular(10),
    );
    canvas
      ..drawRRect(panel, Paint()..color = colors.codePanel)
      ..drawRRect(
        panel.deflate(0.5),
        Paint()
          ..color = colors.panelBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    if (openRows == null) return;
    final y = (panel.top + EditorMetrics.codeHeader * openScale)
        .roundToDouble();
    canvas.drawLine(
      Offset(panel.left, y),
      Offset(panel.right, y),
      Paint()
        ..color = colors.panelBorder
        ..strokeWidth = 1,
    );
  }

  /// A task's box: how far in from where its item starts, and how big.
  /// The page's is Paper's 20px box with a 6px corner.
  static double get _boxInset => EditorMetrics.page ? 0 : 1;
  static double get _boxSide => EditorMetrics.page ? 20 : 15;
  static double get _boxRadius => EditorMetrics.page ? 6 : 3.5;

  /// Paper's link chip is 28 tall.
  static const double _chipHeight = 28;

  /// The link icon of a chip, with its top left at [at]: the app's own link
  /// icon, whose paths are all absolute moves, lines and curves in a 24px
  /// box.
  static final _pathToken = RegExp(r'[MLC]|-?\d+\.?\d*');

  void _paintLink(Canvas canvas, Offset at) {
    const side = EditorMetrics.linkChipIcon;
    const scale = side / 24;
    final paint = Paint()
      ..color = colors.chipInk
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5 * scale;
    for (final element in KapyIcons.linkRounded.paths) {
      final path = Path();
      final tokens = [
        for (final m in _pathToken.allMatches(
          (element[1] as Map<String, dynamic>)['d'] as String,
        ))
          m[0]!,
      ];
      var i = 0;
      Offset point() {
        final p = Offset(
          double.parse(tokens[i]) * scale + at.dx,
          double.parse(tokens[i + 1]) * scale + at.dy,
        );
        i += 2;
        return p;
      }

      while (i < tokens.length) {
        switch (tokens[i++]) {
          case 'M':
            final p = point();
            path.moveTo(p.dx, p.dy);
          case 'L':
            final p = point();
            path.lineTo(p.dx, p.dy);
          default:
            final a = point();
            final b = point();
            final c = point();
            path.cubicTo(a.dx, a.dy, b.dx, b.dy, c.dx, c.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  /// Paper's bullets: a 6px dot, a 6px ring, then a 5px square.
  void _paintBullet(Canvas canvas, Offset center, MarkdownOrnament bullet) {
    final paint = Paint()..color = colors.quiet;
    switch (bullet.depth % 3) {
      case 0:
        canvas.drawCircle(center, 3, paint);
      case 1:
        canvas.drawCircle(
          center,
          2.5,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      default:
        canvas.drawRect(
          Rect.fromCenter(center: center, width: 5, height: 5),
          paint,
        );
    }
  }

  void _paintCheckbox(Canvas canvas, Rect box, MarkdownOrnament checkbox) {
    final side = math.min(_boxSide, box.height - 8);
    final square = Rect.fromLTWH(
      box.left + _boxInset,
      box.center.dy - side / 2 + 0.5,
      side,
      side,
    );
    final rounded = RRect.fromRectAndRadius(
      square,
      Radius.circular(_boxRadius),
    );
    if (!checkbox.checked) {
      final page = EditorMetrics.page;
      canvas.drawRRect(
        rounded.deflate(page ? 0.75 : 0.7),
        Paint()
          ..color = page ? colors.box : colors.quiet
          ..style = PaintingStyle.stroke
          ..strokeWidth = page ? 1.5 : 1.4,
      );
      return;
    }
    canvas.drawRRect(rounded, Paint()..color = colors.accent);
    final tick = Path()
      ..moveTo(square.left + side * 0.24, square.top + side * 0.52)
      ..lineTo(square.left + side * 0.43, square.top + side * 0.70)
      ..lineTo(square.left + side * 0.77, square.top + side * 0.31);
    canvas.drawPath(
      tick,
      Paint()
        ..color = colors.onAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _paintTable(
    Canvas canvas,
    NoteFieldState field,
    MarkdownTable table,
    double left,
    double Function(double) rowY,
  ) {
    final geometry = grids[table];
    if (geometry == null || geometry.columns.isEmpty) return;

    // The header takes its own line and the `|---|` line under it, so the
    // grid covers every row the table's text does.
    final bands = <({double top, double bottom, MarkdownTableRow row})>[];
    for (final row in table.rows) {
      final rows = row.header
          ? _rows(field, row.start, table.delimiterEnd)
          : _rows(field, row.start, row.end);
      if (rows == null) continue;
      bands.add((top: rowY(rows.$1), bottom: rowY(rows.$2), row: row));
    }
    if (bands.isEmpty) return;

    // Paper's table: rows ruled across with no lines between columns, the
    // header on a panel, all in a rounded edge.
    final top = bands.first.top;
    final bottom = bands.last.bottom;
    final width = geometry.width;
    final grid = Rect.fromLTRB(left, top, left + width, bottom);
    final outline = RRect.fromRectAndRadius(grid, const Radius.circular(10));
    final lines = Paint()
      ..color = colors.panelBorder
      ..strokeWidth = 1;

    canvas
      ..save()
      ..clipRRect(outline);
    for (final band in bands) {
      if (band.row.header) {
        canvas.drawRect(
          Rect.fromLTRB(grid.left, band.top, grid.right, band.bottom),
          Paint()..color = colors.panel,
        );
      } else if (band.top > top) {
        canvas.drawLine(
          Offset(grid.left, band.top),
          Offset(grid.right, band.top),
          lines,
        );
      }
      var x = grid.left;
      for (var c = 0; c < geometry.columns.length; c++) {
        final cellWidth = geometry.columns[c];
        final painter = geometry.cell(band.row, c);
        if (painter != null) {
          final inner = geometry.innerWidth(c);
          final dx = switch (table.aligns.elementAtOrNull(c)) {
            MarkdownCellAlign.center => (inner - painter.width) / 2,
            MarkdownCellAlign.end => inner - painter.width,
            _ => 0.0,
          };
          painter.paint(
            canvas,
            Offset(
              x + TableGeometry.padding + math.max(0, dx),
              band.top + (band.bottom - band.top - painter.height) / 2,
            ),
          );
        }
        x += cellWidth;
      }
    }
    canvas.restore();
    canvas.drawRRect(
      outline.deflate(0.5),
      Paint()
        ..color = colors.panelBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }
}
