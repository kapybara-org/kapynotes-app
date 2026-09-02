import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// A lightweight, code-drawn sheet behind the editor.
///
/// The fibers are deterministic, so the paper never shimmers between frames.
/// There is deliberately no ruling or margin line: the texture should feel
/// like plain notepad stock without competing with the writing.
class NotebookPaper extends StatelessWidget {
  const NotebookPaper({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _PaperTexturePainter(
          background: palette.editorBackground,
          fiber: palette.paperFiber,
        ),
        child: child,
      ),
    );
  }
}

class _PaperTexturePainter extends CustomPainter {
  const _PaperTexturePainter({required this.background, required this.fiber});

  final Color background;
  final Color fiber;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    if (size.isEmpty) return;

    final random = math.Random(0x4B415059);
    final count = (size.width * size.height / 7600).round().clamp(20, 150);
    final paint = Paint()
      ..color = fiber
      ..strokeWidth = 0.55
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < count; i++) {
      final start = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final length = 1.2 + random.nextDouble() * 3.8;
      final angle = (random.nextDouble() - 0.5) * 0.5;
      final end =
          start + Offset(math.cos(angle) * length, math.sin(angle) * length);
      canvas.drawLine(start, end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PaperTexturePainter oldDelegate) =>
      background != oldDelegate.background || fiber != oldDelegate.fiber;
}
