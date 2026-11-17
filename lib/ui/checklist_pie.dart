import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// How far a note's checklist has got, as a clock face: a thin ring with a
/// wedge filling clockwise from twelve o'clock, and a disc with a check once
/// every box is ticked. It moves to a new share rather than jumping.
class ChecklistPie extends StatelessWidget {
  const ChecklistPie({
    super.key,
    required this.done,
    required this.total,
    required this.fill,
    required this.check,
    this.size = 14,
  });

  final int done;
  final int total;

  /// The wedge and the full disc, and the check drawn on that disc. The ring
  /// is the switch's off track, which still shows on the page.
  final Color fill;
  final Color check;

  /// Its width and height. Drawn at 14; anything else scales the ring, the
  /// wedge's inset and the check with it.
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$done of $total done',
    child: TweenAnimationBuilder<double>(
      tween: Tween(end: total == 0 ? 0 : done / total),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, share, _) => CustomPaint(
        size: Size.square(size),
        painter: _PiePainter(
          share,
          track: context.palette.switchTrackOff,
          fill: fill,
          check: check,
        ),
      ),
    ),
  );
}

class _PiePainter extends CustomPainter {
  _PiePainter(
    this.share, {
    required this.track,
    required this.fill,
    required this.check,
  });

  final double share;
  final Color track;
  final Color fill;
  final Color check;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final scale = size.shortestSide / 14;
    if (share >= 1) {
      canvas.drawCircle(center, radius, Paint()..color = fill);
      canvas.drawPath(
        Path()
          ..moveTo(3.9 * scale, 7.2 * scale)
          ..lineTo(6.1 * scale, 9.3 * scale)
          ..lineTo(10.1 * scale, 4.9 * scale),
        Paint()
          ..color = check
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 * scale
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      return;
    }
    canvas.drawCircle(
      center,
      radius - 0.75 * scale,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * scale,
    );
    if (share <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 2 * scale),
      -math.pi / 2,
      share * 2 * math.pi,
      true,
      Paint()..color = fill,
    );
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.share != share ||
      old.track != track ||
      old.fill != fill ||
      old.check != check;
}
