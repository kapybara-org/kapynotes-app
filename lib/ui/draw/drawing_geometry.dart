import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../data/note_drawing.dart';

extension OffsetList on Offset {
  List<double> get asList => [dx, dy];
}

/// Text on the canvas, laid out the one way both the painter and hit testing
/// measure it.
TextPainter layoutDrawText(DrawElement element, TextStyle style) => TextPainter(
  text: TextSpan(
    text: element.text,
    style: style.copyWith(fontSize: element.fontSize),
  ),
  textDirection: TextDirection.ltr,
)..layout();

final Expando<Rect> _textBounds = Expando();

/// An element's box on the canvas. Text is measured; the rest is geometry.
Rect elementBounds(DrawElement element) {
  if (element.kind != DrawKind.text) return element.bounds;
  return _textBounds[element] ??= () {
    final painter = layoutDrawText(element, const TextStyle(height: 1.25));
    final origin = element.pointAt(0);
    final box = origin & painter.size;
    painter.dispose();
    return box;
  }();
}

Rect? drawingBounds(Iterable<DrawElement> elements) {
  Rect? all;
  for (final element in elements) {
    final box = elementBounds(element).inflate(element.width);
    all = all == null ? box : all.expandToInclude(box);
  }
  return all;
}

/// The topmost element under [at], within [tolerance] of a stroke.
///
/// Outlines count, insides do not: the shapes here are unfilled, and a
/// rectangle drawn around a word must not stop the word from being picked.
DrawElement? hitTestElements(
  Iterable<DrawElement> elements,
  Offset at,
  double tolerance,
) {
  final list = elements.toList();
  for (var i = list.length - 1; i >= 0; i--) {
    if (hitsElement(list[i], at, tolerance)) return list[i];
  }
  return null;
}

bool hitsElement(DrawElement element, Offset at, double tolerance) {
  final reach = tolerance + element.width / 2;
  if (!elementBounds(element).inflate(reach).contains(at)) return false;
  switch (element.kind) {
    case DrawKind.text:
      return true;
    case DrawKind.pen:
      if (element.pointCount == 1) {
        return (element.pointAt(0) - at).distance <= reach;
      }
      for (var i = 1; i < element.pointCount; i++) {
        if (distanceToSegment(at, element.pointAt(i - 1), element.pointAt(i)) <=
            reach) {
          return true;
        }
      }
      return false;
    case DrawKind.line || DrawKind.arrow:
      return distanceToSegment(at, element.pointAt(0), element.pointAt(1)) <=
          reach;
    case DrawKind.rect:
      final box = element.bounds;
      final corners = [
        box.topLeft,
        box.topRight,
        box.bottomRight,
        box.bottomLeft,
      ];
      for (var i = 0; i < 4; i++) {
        if (distanceToSegment(at, corners[i], corners[(i + 1) % 4]) <= reach) {
          return true;
        }
      }
      return false;
    case DrawKind.ellipse:
      final box = element.bounds;
      final rx = box.width / 2, ry = box.height / 2;
      if (rx < 1 || ry < 1) {
        return distanceToSegment(at, box.topLeft, box.bottomRight) <= reach;
      }
      // Distance to an ellipse has no closed form; scaling the radial error
      // by the smaller radius is close enough for a pointer.
      final dx = (at.dx - box.center.dx) / rx;
      final dy = (at.dy - box.center.dy) / ry;
      final radial = math.sqrt(dx * dx + dy * dy);
      return (radial - 1).abs() * math.min(rx, ry) <= reach;
  }
}

double distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lengthSquared).clamp(
    0.0,
    1.0,
  );
  return (p - (a + ab * t)).distance;
}

/// Where the far end of a shape goes. Shift squares a box and snaps a line to
/// the nearest 45°, the way every drawing tool does.
Offset constrainEnd(
  DrawKind kind,
  Offset start,
  Offset end, {
  required bool shift,
}) {
  if (!shift) return end;
  final delta = end - start;
  switch (kind) {
    case DrawKind.rect || DrawKind.ellipse:
      final side = math.max(delta.dx.abs(), delta.dy.abs());
      return start +
          Offset(
            side * (delta.dx < 0 ? -1 : 1),
            side * (delta.dy < 0 ? -1 : 1),
          );
    case DrawKind.line || DrawKind.arrow:
      final angle = (delta.direction / (math.pi / 4)).round() * (math.pi / 4);
      return start + Offset.fromDirection(angle, delta.distance);
    case DrawKind.pen || DrawKind.text:
      return end;
  }
}
