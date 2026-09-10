import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/appearance.dart';
import '../core/theme.dart';

/// A lightweight, code-drawn sheet behind the editor.
///
/// The fibers are deterministic, so the paper never shimmers between frames.
///
/// Only the marks are painted here. The colour under them belongs to the
/// editor's page, which also runs under the gutter and its divider; painting
/// it twice was harmless while it was opaque and would double up the moment
/// transparency thinned it.
class NotebookPaper extends StatelessWidget {
  const NotebookPaper({
    super.key,
    required this.child,
    this.style = PaperStyle.notepad,
    this.lineHeight = 0,
    this.topInset = 0,
    this.scroll,
  });

  final Widget child;
  final PaperStyle style;

  /// One visual row, as the editor lays it out. Uniform, because the field
  /// forces its strut — which is the only reason ruling can be drawn without
  /// measuring every line.
  final double lineHeight;

  /// The field's top padding: where the first row starts.
  final double topInset;

  /// The field's scroll position. The sheet does not scroll — it sits behind
  /// the viewport — so ruling has to be moved under the text by hand, or it
  /// would sit still while the writing slid over it.
  ///
  /// Handed over whole rather than as a number so the painter can repaint
  /// from it directly. A scroll that rebuilt this widget would rebuild the
  /// text field it wraps, once a frame, for the sake of some hairlines.
  final ScrollController? scroll;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _PaperTexturePainter(
          fiber: palette.paperFiber,
          ruling: palette.paperRuling,
          style: style,
          lineHeight: lineHeight,
          topInset: topInset,
          // Only ruling moves with the text; fibres are the same sheet
          // wherever it is scrolled to.
          scroll: style == PaperStyle.ruled ? scroll : null,
        ),
        child: child,
      ),
    );
  }
}

class _PaperTexturePainter extends CustomPainter {
  _PaperTexturePainter({
    required this.fiber,
    required this.ruling,
    required this.style,
    required this.lineHeight,
    required this.topInset,
    required this.scroll,
  }) : super(repaint: scroll);

  final Color fiber;
  final Color ruling;
  final PaperStyle style;
  final double lineHeight;
  final double topInset;
  final ScrollController? scroll;

  double get _scrollOffset {
    final scroll = this.scroll;
    return scroll != null && scroll.hasClients ? scroll.offset : 0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    switch (style) {
      case PaperStyle.plain:
        return;
      case PaperStyle.notepad:
        _paintFibres(canvas, size);
      case PaperStyle.ruled:
        _paintRuling(canvas, size);
    }
  }

  void _paintFibres(Canvas canvas, Size size) {
    if (fiber.a == 0) return;
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

  /// One line under each row of writing, wherever the writing happens to be.
  ///
  /// Drawn from the first row down rather than from the top of the sheet, so
  /// the ruling lands under the text rather than through it. A line sits on
  /// the row's bottom edge, half a pixel up: a hairline centred on the
  /// boundary would be split between two rows by antialiasing and read as
  /// twice as thick.
  void _paintRuling(Canvas canvas, Size size) {
    // Nothing to align to before the editor has measured itself. Better a
    // blank sheet for one frame than ruling at a pitch it is about to change.
    if (lineHeight <= 0 || ruling.a == 0) return;
    final paint = Paint()
      ..color = ruling
      ..strokeWidth = 0.7
      ..strokeCap = StrokeCap.square;

    // The first row's bottom edge, brought back into view coordinates.
    var y = topInset + lineHeight - _scrollOffset;
    // Rows above the viewport are skipped rather than drawn and clipped: a
    // long note scrolled a long way would otherwise cost a line per row of
    // everything above it.
    if (y < 0) y += ((-y) / lineHeight).ceil() * lineHeight;
    for (; y < size.height; y += lineHeight) {
      canvas.drawLine(Offset(0, y - 0.5), Offset(size.width, y - 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PaperTexturePainter oldDelegate) =>
      fiber != oldDelegate.fiber ||
      ruling != oldDelegate.ruling ||
      style != oldDelegate.style ||
      lineHeight != oldDelegate.lineHeight ||
      topInset != oldDelegate.topInset;
}
