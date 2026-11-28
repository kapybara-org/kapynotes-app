import 'dart:math' as math;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A line of [items] with [dot] between neighbours, as a Wrap lays them. An
/// item that moves to the next line leaves its dot behind, so no line starts
/// or ends on one.
class DottedWrap extends MultiChildRenderObjectWidget {
  DottedWrap({
    super.key,
    required Widget dot,
    required this.gap,
    required List<Widget> items,
  }) : super(
         children: [
           for (final (index, item) in items.indexed) ...[
             if (index > 0) dot,
             item,
           ],
         ],
       );

  /// The room either side of a dot.
  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDottedWrap(gap);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderDottedWrap).gap = gap;
  }
}

class _DottedParentData extends ContainerBoxParentData<RenderBox> {
  bool shown = true;
}

class _RenderDottedWrap extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _DottedParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _DottedParentData> {
  _RenderDottedWrap(this._gap);

  double _gap;
  double get gap => _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DottedParentData) {
      child.parentData = _DottedParentData();
    }
  }

  /// Where each child goes, null for a dot with no neighbour after it on its
  /// line, and the size they make together. Children alternate item, dot,
  /// item.
  (List<Offset?>, Size) _flow(List<Size> sizes, double maxWidth) {
    final offsets = List<Offset?>.filled(sizes.length, null);
    var x = 0.0;
    var y = 0.0;
    var lineHeight = 0.0;
    var width = 0.0;
    var first = 0;
    void endLine(int end) {
      for (var j = first; j < end; j++) {
        if (offsets[j] case final offset?) {
          offsets[j] = Offset(
            offset.dx,
            y + (lineHeight - sizes[j].height) / 2,
          );
        }
      }
      width = math.max(width, x);
      y += lineHeight;
      x = 0;
      lineHeight = 0;
      first = end;
    }

    for (var i = 0; i < sizes.length; i += 2) {
      if (i > first) {
        final dot = sizes[i - 1];
        if (x + _gap * 2 + dot.width + sizes[i].width <=
            maxWidth + precisionErrorTolerance) {
          offsets[i - 1] = Offset(x + _gap, 0);
          x += _gap * 2 + dot.width;
          lineHeight = math.max(lineHeight, dot.height);
        } else {
          endLine(i);
        }
      }
      offsets[i] = Offset(x, 0);
      x += sizes[i].width;
      lineHeight = math.max(lineHeight, sizes[i].height);
    }
    if (sizes.isNotEmpty) endLine(sizes.length);
    return (offsets, Size(width, y));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final loose = BoxConstraints(maxWidth: constraints.maxWidth);
    final sizes = [
      for (var child = firstChild; child != null; child = childAfter(child))
        child.getDryLayout(loose),
    ];
    return constraints.constrain(_flow(sizes, constraints.maxWidth).$2);
  }

  @override
  void performLayout() {
    final loose = BoxConstraints(maxWidth: constraints.maxWidth);
    final children = getChildrenAsList();
    final sizes = <Size>[];
    for (final child in children) {
      child.layout(loose, parentUsesSize: true);
      sizes.add(child.size);
    }
    final (offsets, size) = _flow(sizes, constraints.maxWidth);
    for (final (index, child) in children.indexed) {
      final data = child.parentData! as _DottedParentData;
      data.shown = offsets[index] != null;
      data.offset = offsets[index] ?? Offset.zero;
    }
    this.size = constraints.constrain(size);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _DottedParentData;
      if (data.shown) context.paintChild(child, offset + data.offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (var child = lastChild; child != null; child = childBefore(child)) {
      final data = child.parentData! as _DottedParentData;
      if (!data.shown) continue;
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, transformed) =>
            child!.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if ((child.parentData! as _DottedParentData).shown) visitor(child);
    }
  }
}
