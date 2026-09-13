import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

/// Shows the selection on blank lines, which the text field leaves bare.
///
/// The field draws its highlight tight to each line's text — see
/// `selectionWidthStyle` in note_editor.dart for why — and a blank line has no
/// text: its one character is the line break, whose box is zero wide. So a
/// selection running over blank lines showed nothing on them, and one made of
/// nothing but blank lines looked like no selection at all, though Delete
/// would take every one of them.
///
/// Each blank line inside the selection gets the highlight a selected space
/// would have, which is how word processors show a selected paragraph mark.
/// It is painted in the field's own selection colour, read from the field, so
/// it comes and goes with focus exactly as the rest of the highlight does.
class BlankLineHighlight extends LeafRenderObjectWidget {
  const BlankLineHighlight({
    super.key,
    required this.editable,
    required this.repaint,
  });

  /// The field whose highlight this completes.
  final RenderEditable? Function() editable;

  /// Whatever moves the selection or the lines under it: the controller, the
  /// scroll position, and the focus that decides whether a highlight shows.
  final Listenable repaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderBlankLineHighlight(editable: editable, repaint: repaint);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBlankLineHighlight renderObject,
  ) {
    renderObject
      ..editable = editable
      ..repaint = repaint
      // The field was rebuilt alongside this, and its colour or its layout
      // can change with nothing in [repaint] firing — a new theme, a new
      // writing font, a wider window.
      ..markNeedsPaint();
  }
}

/// Paints [BlankLineHighlight]; reads everything from the field as it paints.
class RenderBlankLineHighlight extends RenderBox {
  RenderBlankLineHighlight({
    required this.editable,
    required Listenable repaint,
  }) : _repaint = repaint;

  RenderEditable? Function() editable;

  Listenable _repaint;
  set repaint(Listenable value) {
    if (identical(value, _repaint)) return;
    if (attached) _repaint.removeListener(markNeedsPaint);
    _repaint = value;
    if (attached) _repaint.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  /// A space in the field's text style, measured once per style.
  double _spaceWidth = 0;
  TextStyle? _measuredStyle;
  TextScaler? _measuredScaler;

  double _spaceWidthIn(RenderEditable field) {
    final style = field.text?.style;
    final scaler = field.textScaler;
    if (style != _measuredStyle || scaler != _measuredScaler) {
      _measuredStyle = style;
      _measuredScaler = scaler;
      _spaceWidth = TextPainter.computeWidth(
        text: TextSpan(text: ' ', style: style),
        textDirection: field.textDirection,
        textScaler: scaler,
      );
    }
    return _spaceWidth;
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  /// Repaints with every scroll and selection change; this keeps those to
  /// this layer rather than whatever sits around it.
  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final field = editable();
    if (field == null || !field.attached || !field.hasSize) return;
    // Null while the field is unfocused, which is when it shows no
    // highlight of its own either.
    final color = field.selectionColor;
    final selection = field.selection;
    if (color == null ||
        selection == null ||
        !selection.isValid ||
        selection.isCollapsed) {
      return;
    }
    final text = field.plainText;

    // Only the lines on screen. A long note can hold thousands of selected
    // blank lines, and each one asked about below is a layout query.
    final fieldOrigin = field.localToGlobal(Offset.zero);
    final firstShown = field.getPositionForPoint(fieldOrigin).offset;
    final lastShown = field
        .getPositionForPoint(fieldOrigin + field.size.bottomRight(Offset.zero))
        .offset;
    final from = math.max(selection.start, firstShown);
    final to = math.min(math.min(selection.end, lastShown + 1), text.length);
    if (from >= to) return;

    // Everything below is in this layer's coordinates. The field's own boxes
    // already account for its scroll offset.
    final origin = globalToLocal(fieldOrigin);
    final width = _spaceWidthIn(field);
    final fill = Paint()..color = color;
    final canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..clipRect(origin & field.size);
    for (var at = from; at < to; at++) {
      // A blank line is a line break with nothing before it on its line.
      if (text.codeUnitAt(at) != _lineBreak) continue;
      if (at > 0 && text.codeUnitAt(at - 1) != _lineBreak) continue;
      final boxes = field.getBoxesForSelection(
        TextSelection(baseOffset: at, extentOffset: at + 1),
      );
      if (boxes.isEmpty) continue;
      final box = boxes.first;
      final left = box.direction == TextDirection.rtl
          ? box.right - width
          : box.left;
      canvas.drawRect(
        Rect.fromLTRB(left, box.top, left + width, box.bottom).shift(origin),
        fill,
      );
    }
    canvas.restore();
  }

  static const int _lineBreak = 0x0A;
}
