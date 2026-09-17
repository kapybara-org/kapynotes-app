import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'line_metrics.dart';
import 'markdown_syntax.dart';
import 'table_geometry.dart';

/// The colours [MarkdownBackdrop] draws with, taken from the theme once per
/// build rather than looked up while painting.
@immutable
class MarkdownBackdropColors {
  const MarkdownBackdropColors({
    required this.quiet,
    required this.faint,
    required this.panel,
    required this.panelBorder,
    required this.accent,
    required this.onAccent,
  });

  /// Bullets, an unticked box, a quote's bar.
  final Color quiet;

  /// Rules and a table's lines.
  final Color faint;

  /// Behind a code block, and the pill behind inline code.
  final Color panel;
  final Color panelBorder;

  /// A ticked box, and the tick in it.
  final Color accent;
  final Color onAccent;

  @override
  bool operator ==(Object other) =>
      other is MarkdownBackdropColors &&
      other.quiet == quiet &&
      other.faint == faint &&
      other.panel == panel &&
      other.panelBorder == panelBorder &&
      other.accent == accent &&
      other.onAccent == onAccent;

  @override
  int get hashCode =>
      Object.hash(quiet, faint, panel, panelBorder, accent, onAccent);
}

/// What a markdown note draws behind its text: the parts of markdown that
/// are pictures rather than words.
///
/// Bullets, checkboxes and the pill behind inline code sit exactly where the
/// field laid out the characters they stand in for, read from the field as it
/// paints. The panel under a code block, a quote's bar and a rule cover the
/// rows their lines take up, from the same line measurement the results
/// gutter uses. A table the caret is not in is drawn as a grid over its own
/// text, which the field leaves invisible but in place.
///
/// Everything here is under the field, so its selection highlight still
/// shows over a checkbox or a code pill the way it does over words.
class MarkdownBackdrop extends LeafRenderObjectWidget {
  const MarkdownBackdrop({
    super.key,
    required this.analysis,
    required this.concealment,
    required this.grids,
    required this.offsets,
    required this.scroll,
    required this.editable,
    required this.colors,
    required this.markerRoom,
  });

  final MarkdownAnalysis analysis;
  final MarkdownConcealment concealment;

  /// The grid each table is drawn as, measured by the editor, which is the only
  /// place that knows how wide the writing column is. The same geometry decides
  /// the room each row reserves, so the two cannot drift apart.
  final Map<MarkdownTable, TableGeometry> grids;

  final LineOffsets offsets;
  final ScrollController scroll;

  /// The field whose text this draws behind.
  final RenderEditable? Function() editable;
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
        offsets: offsets,
        scroll: scroll,
        editable: editable,
        colors: colors,
        markerRoom: markerRoom,
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
      ..offsets = offsets
      ..scroll = scroll
      ..editable = editable
      ..colors = colors
      ..markerRoom = markerRoom
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
    required this.offsets,
    required ScrollController scroll,
    required this.editable,
    required this.colors,
    required this.markerRoom,
  }) : _analysis = analysis,
       _scroll = scroll;

  MarkdownAnalysis _analysis;
  set analysis(MarkdownAnalysis value) {
    if (identical(value, _analysis)) return;
    _analysis = value;
    _lineStarts = null;
  }

  MarkdownConcealment concealment;
  Map<MarkdownTable, TableGeometry> grids;
  LineOffsets offsets;
  RenderEditable? Function() editable;
  MarkdownBackdropColors colors;
  double markerRoom;

  ScrollController _scroll;
  set scroll(ScrollController value) {
    if (identical(value, _scroll)) return;
    if (attached) _scroll.removeListener(markNeedsPaint);
    _scroll = value;
    if (attached) _scroll.addListener(markNeedsPaint);
  }

  List<int>? _lineStarts;

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

  int _lineOf(int offset) {
    final starts = _lineStarts ??= [
      0,
      for (var i = 0; i < _analysis.text.length; i++)
        if (_analysis.text.codeUnitAt(i) == 0x0A) i + 1,
    ];
    var low = 0;
    var high = starts.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (starts[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  /// The top and bottom of the rows the lines from [start] to [end] take, in
  /// the text's own coordinates.
  (double, double)? _rows(int start, int end) {
    final tops = offsets.tops;
    if (tops.isEmpty) return null;
    final first = _lineOf(start);
    final last = _lineOf(math.max(start, end - 1));
    if (first >= tops.length) return null;
    final top = tops[first];
    final bottom = last + 1 < tops.length
        ? tops[last + 1]
        : offsets.totalHeight;
    return bottom > top ? (top, bottom) : null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final field = editable();
    if (field == null || !field.attached || !field.hasSize) return;
    // Everything below is in this layer's coordinates. The field's own boxes
    // already account for its scroll offset; the measured rows do not.
    final origin = globalToLocal(field.localToGlobal(Offset.zero));
    final visible = origin & field.size;
    final scrolled = _scroll.hasClients ? _scroll.offset : 0.0;
    double rowY(double y) => origin.dy + y - scrolled;

    // Only what is on screen. A long note can hold thousands of bullets, and
    // each one asked about below is a layout query.
    final fieldOrigin = field.localToGlobal(Offset.zero);
    final firstShown = field.getPositionForPoint(fieldOrigin).offset;
    final lastShown = field
        .getPositionForPoint(fieldOrigin + field.size.bottomRight(Offset.zero))
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
    final right = origin.dx + field.size.width;
    for (final block in _analysis.blocks) {
      if (!onScreen(block.start, block.end)) continue;
      if (block.kind == MarkdownBlockKind.quote && block.depth > 1) continue;
      final rows = _rows(block.start, block.end);
      if (rows == null) continue;
      final top = rowY(rows.$1);
      final bottom = rowY(rows.$2);
      switch (block.kind) {
        case MarkdownBlockKind.code:
          final panel = RRect.fromLTRBR(
            left - 8,
            top + 2,
            right + 6,
            bottom - 2,
            const Radius.circular(6),
          );
          canvas
            ..drawRRect(panel, Paint()..color = colors.panel)
            ..drawRRect(
              panel,
              Paint()
                ..color = colors.panelBorder
                ..style = PaintingStyle.stroke
                ..strokeWidth = 0.5,
            );
        case MarkdownBlockKind.quote:
          final x = math.max(2.0, left - 12);
          canvas.drawRRect(
            RRect.fromLTRBR(
              x,
              top + 4,
              x + 3,
              bottom - 4,
              const Radius.circular(1.5),
            ),
            Paint()..color = colors.quiet.withValues(alpha: 0.55),
          );
        case MarkdownBlockKind.rule:
          // Not through its own `---` while that is shown as written.
          if (!_hidden(block.start, block.end)) continue;
          final y = ((top + bottom) / 2).roundToDouble() + 0.5;
          canvas.drawLine(
            Offset(left, y),
            Offset(right, y),
            Paint()
              ..color = colors.faint
              ..strokeWidth = 1,
          );
      }
    }

    final room = markerRoom;
    for (final ornament in _analysis.ornaments) {
      if (!onScreen(ornament.start, ornament.end)) continue;
      final boxes = field.getBoxesForSelection(
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
          for (final box in boxes) {
            final rect = box.toRect().shift(origin);
            if (rect.width <= 0) continue;
            final height = math.min(rect.height - 6, 22.0);
            canvas.drawRRect(
              RRect.fromLTRBR(
                rect.left - 3,
                rect.center.dy - height / 2,
                rect.right + 3,
                rect.center.dy + height / 2,
                const Radius.circular(4),
              ),
              Paint()..color = colors.panel,
            );
          }
      }
    }

    for (final table in _analysis.tables) {
      if (!onScreen(table.start, table.end)) continue;
      _paintTable(canvas, table, left, rowY);
    }

    canvas.restore();
  }

  /// Whether all of [start, end) is hidden right now.
  bool _hidden(int start, int end) {
    final hidden = concealment.hidden;
    var low = 0;
    var high = hidden.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (hidden[middle].end <= start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low < hidden.length &&
        hidden[low].start <= start &&
        hidden[low].end >= end;
  }

  /// A task's box: how far in from where its item starts, and how big.
  static const double _boxInset = 1;
  static const double _boxSide = 15;

  void _paintBullet(Canvas canvas, Offset center, MarkdownOrnament bullet) {
    final paint = Paint()..color = colors.quiet;
    switch (bullet.depth % 3) {
      case 0:
        canvas.drawCircle(center, 2.6, paint);
      case 1:
        canvas.drawCircle(
          center,
          2.4,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      default:
        canvas.drawRect(
          Rect.fromCenter(center: center, width: 4.4, height: 4.4),
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
    final rounded = RRect.fromRectAndRadius(square, const Radius.circular(3.5));
    if (!checkbox.checked) {
      canvas.drawRRect(
        rounded.deflate(0.7),
        Paint()
          ..color = colors.quiet
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
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
          ? _rows(row.start, table.delimiterEnd)
          : _rows(row.start, row.end);
      if (rows == null) continue;
      bands.add((top: rowY(rows.$1), bottom: rowY(rows.$2), row: row));
    }
    if (bands.isEmpty) return;

    final top = bands.first.top + 2;
    final bottom = bands.last.bottom - 2;
    final width = geometry.width;
    final grid = Rect.fromLTRB(left, top, left + width, bottom);
    final outline = RRect.fromRectAndRadius(grid, const Radius.circular(6));
    final lines = Paint()
      ..color = colors.faint
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
        if (c < geometry.columns.length - 1) {
          canvas.drawLine(Offset(x, top), Offset(x, bottom), lines);
        }
      }
    }
    canvas.restore();
    canvas.drawRRect(
      outline.deflate(0.5),
      Paint()
        ..color = colors.faint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }
}
