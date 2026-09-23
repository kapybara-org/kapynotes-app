import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:material_ui/material_ui.dart';

import '../../data/note_drawing.dart';
import 'drawing_geometry.dart';

/// Paints a drawing: a dot grid in screen space, then every element in
/// canvas space under the viewport's pan and zoom, then selection on top.
class DrawingPainter extends CustomPainter {
  DrawingPainter({
    required this.elements,
    required this.hidden,
    required this.extra,
    required this.selection,
    required this.marquee,
    required this.pan,
    required this.zoom,
    required this.ink,
    required this.grid,
    required this.accent,
    required this.textStyle,
  });

  final List<DrawElement> elements;

  /// Drawn by something else this frame: the text being edited, the
  /// elements being dragged or erased.
  final Set<String> hidden;

  /// Drawn on top: the shape being drawn and the dragged copies.
  final List<DrawElement> extra;
  final List<Rect> selection;
  final Rect? marquee;
  final Offset pan;
  final double zoom;
  final Color ink;
  final Color grid;
  final Color accent;
  final TextStyle textStyle;

  static const double _gridSpacing = 24;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);

    canvas.save();
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(zoom);
    for (final element in elements) {
      if (!hidden.contains(element.id)) paintElement(canvas, element);
    }
    for (final element in extra) {
      paintElement(canvas, element);
    }

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / zoom
      ..color = accent;
    for (final box in selection) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          box.inflate(6 / zoom),
          Radius.circular(4 / zoom),
        ),
        outline,
      );
    }
    final area = marquee;
    if (area != null) {
      canvas.drawRect(area, Paint()..color = accent.withValues(alpha: 0.08));
      canvas.drawRect(area, outline);
    }
    canvas.restore();
  }

  void _paintGrid(Canvas canvas, Size size) {
    var spacing = _gridSpacing * zoom;
    // Zoomed far out, a dot every 24 units is a grey wash. Thin it instead.
    while (spacing < 12) {
      spacing *= 4;
    }
    final paint = Paint()
      ..color = grid
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final startX = pan.dx % spacing;
    final startY = pan.dy % spacing;
    final points = <Offset>[];
    for (var x = startX; x < size.width; x += spacing) {
      for (var y = startY; y < size.height; y += spacing) {
        points.add(Offset(x, y));
      }
    }
    canvas.drawPoints(PointMode.points, points, paint);
  }

  void paintElement(Canvas canvas, DrawElement element) {
    final color = element.color == null ? ink : Color(element.color!);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = element.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (element.kind) {
      case DrawKind.pen:
        canvas.drawPath(penPath(element), stroke);
      case DrawKind.rect:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            element.bounds,
            Radius.circular(math.min(8, element.bounds.shortestSide / 4)),
          ),
          stroke,
        );
      case DrawKind.ellipse:
        canvas.drawOval(element.bounds, stroke);
      case DrawKind.line:
        canvas.drawLine(element.pointAt(0), element.pointAt(1), stroke);
      case DrawKind.arrow:
        final from = element.pointAt(0);
        final to = element.pointAt(1);
        canvas.drawLine(from, to, stroke);
        final length = (to - from).distance;
        if (length > 0) {
          final head = math.min(length / 2, 10 + element.width * 2.5);
          final angle = (to - from).direction;
          canvas.drawPath(
            Path()
              ..moveTo(
                to.dx + head * math.cos(angle + math.pi * 5 / 6),
                to.dy + head * math.sin(angle + math.pi * 5 / 6),
              )
              ..lineTo(to.dx, to.dy)
              ..lineTo(
                to.dx + head * math.cos(angle - math.pi * 5 / 6),
                to.dy + head * math.sin(angle - math.pi * 5 / 6),
              ),
            stroke,
          );
        }
      case DrawKind.text:
        final painter = layoutDrawText(
          element,
          textStyle.copyWith(color: color),
        );
        painter.paint(canvas, element.pointAt(0));
        painter.dispose();
    }
  }

  /// A smooth stroke: quadratic curves through the midpoints between samples,
  /// so a pen line has no corners at the points the pointer happened to be
  /// sampled at.
  static Path penPath(DrawElement element) {
    final path = Path();
    final count = element.pointCount;
    if (count == 0) return path;
    final first = element.pointAt(0);
    path.moveTo(first.dx, first.dy);
    if (count == 1 || (count == 2 && element.pointAt(1) == first)) {
      // A dot: a zero-length line still gets round caps.
      path.lineTo(first.dx + 0.01, first.dy);
      return path;
    }
    for (var i = 1; i < count - 1; i++) {
      final point = element.pointAt(i);
      final mid = (point + element.pointAt(i + 1)) / 2;
      path.quadraticBezierTo(point.dx, point.dy, mid.dx, mid.dy);
    }
    final last = element.pointAt(count - 1);
    path.lineTo(last.dx, last.dy);
    return path;
  }

  @override
  bool shouldRepaint(DrawingPainter old) =>
      !identical(old.elements, elements) ||
      old.hidden.length != hidden.length ||
      !hidden.containsAll(old.hidden) ||
      old.extra.length != extra.length ||
      !_sameElements(old.extra, extra) ||
      old.selection.length != selection.length ||
      !_sameRects(old.selection, selection) ||
      old.marquee != marquee ||
      old.pan != pan ||
      old.zoom != zoom ||
      old.ink != ink ||
      old.grid != grid ||
      old.accent != accent ||
      old.textStyle != textStyle;

  static bool _sameElements(List<DrawElement> a, List<DrawElement> b) {
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
