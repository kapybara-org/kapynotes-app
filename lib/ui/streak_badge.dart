import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/writing_streak.dart';

/// The writing streak, as a flame and a number.
///
/// Lit while today is one of the days: a red flame on a warm wash, which
/// flares for a moment when the first thing of the day is written. Until then
/// the same flame waits in grey with its core gone out — the run is still
/// alive, and the badge says so, but it is asking for today.
class StreakBadge extends StatelessWidget {
  const StreakBadge({super.key, required this.streak});

  final WritingStreak streak;

  /// Pitched per appearance rather than shared: the red that reads on the
  /// dark sidebar is too light to hold its contrast on the paper one.
  static const _darkInk = Color(0xFFFF7A5C);
  static const _lightInk = Color(0xFFC4352B);

  /// What the badge means, for its tooltip and for a screen reader.
  static String describe(WritingStreak streak) => streak.wroteToday
      ? '${streak.days}-day writing streak'
      : 'Write today to keep your ${streak.days}-day streak';

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = palette.brightness == Brightness.dark ? _darkInk : _lightInk;
    final lit = streak.wroteToday ? 1.0 : 0.0;
    final message = describe(streak);
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    // The message is what a screen reader hears, rather than a number, and it
    // needs a node of its own to be heard at all: merged into a heading that
    // already carries a tooltip, only the first of the two survives.
    return Semantics(
      container: true,
      child: Tooltip(
        message: message,
        // A phone has no hover to find this by, and a tap on the badge has
        // nothing else to do.
        triggerMode: TooltipTriggerMode.tap,
        child: ExcludeSemantics(
          child: TweenAnimationBuilder<double>(
            // From wherever it is to [lit]. Nothing moves on the first build,
            // so a heading scrolled back into view does not flare again.
            tween: Tween(begin: lit, end: lit),
            duration: still ? Duration.zero : const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) => Container(
              padding: const EdgeInsets.fromLTRB(5, 2, 7, 2),
              decoration: BoxDecoration(
                color: Color.lerp(
                  palette.hover,
                  ink.withValues(alpha: 0.14),
                  t,
                ),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.scale(
                    // Flares on the way up only. A run that is waiting on a
                    // new day goes quiet without a fuss.
                    scale: streak.wroteToday
                        ? 1 + 0.3 * math.sin(math.pi * t)
                        : 1,
                    alignment: Alignment.bottomCenter,
                    child: StreakFlame(
                      size: MediaQuery.textScalerOf(
                        context,
                      ).scale(AppTypeScale.caption + 2),
                      lit: t,
                      unlitColor: palette.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${streak.days}',
                    style: TextStyle(
                      fontSize: AppTypeScale.caption,
                      fontWeight: FontWeight.w400,
                      height: 1.2,
                      color: Color.lerp(palette.textTertiary, ink, t),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A flame: a red body around a hot yellow core.
///
/// Drawn rather than taken from the icon font, which paints a glyph in one
/// colour, and a flame in one colour reads as a warning sign as often as a
/// fire. [lit] fades it to [unlitColor] with the core gone out — the outline
/// of the same flame, so the two states read as one thing that has caught.
class StreakFlame extends StatelessWidget {
  const StreakFlame({
    super.key,
    required this.size,
    this.lit = 1,
    required this.unlitColor,
  });

  final double size;

  /// 1 burning, 0 out, and a blend between for the moment it catches.
  final double lit;
  final Color unlitColor;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _FlamePainter(lit: lit, unlitColor: unlitColor),
  );
}

class _FlamePainter extends CustomPainter {
  _FlamePainter({required this.lit, required this.unlitColor});

  final double lit;
  final Color unlitColor;

  // Drawn on a 24-unit square, like the icon font, and scaled to fit.
  static const double _grid = 24;

  /// The outer flame: a round belly, a tall tongue leaning left and a
  /// smaller lick off its right shoulder.
  static final Path _body = Path()
    ..moveTo(12, 22.6)
    ..cubicTo(7.4, 22.6, 4, 19.4, 4, 15)
    ..cubicTo(4, 11.6, 6.1, 9, 8, 6.8)
    ..cubicTo(9.3, 5.3, 10.1, 3.4, 10, 1.4)
    ..cubicTo(13.6, 3, 15.9, 6.1, 16.4, 9.4)
    ..cubicTo(17.2, 8.6, 17.7, 7.4, 17.8, 6.2)
    ..cubicTo(19.4, 8.1, 20, 11.1, 20, 15)
    ..cubicTo(20, 19.4, 16.6, 22.6, 12, 22.6)
    ..close();

  /// The hot centre, low in the belly where a real flame burns brightest.
  static final Path _core = Path()
    ..moveTo(12, 21)
    ..cubicTo(9.7, 21, 8.2, 19.5, 8.2, 17.4)
    ..cubicTo(8.2, 15.4, 9.6, 14, 10.6, 12.7)
    ..cubicTo(11.2, 11.9, 11.6, 11, 11.7, 10)
    ..cubicTo(13.8, 11.3, 15.8, 13.8, 15.8, 17.2)
    ..cubicTo(15.8, 19.4, 14.3, 21, 12, 21)
    ..close();

  /// The flame gone out: the body with the core taken away, so the shape
  /// that is left is the outline of the one that burns.
  static final Path _embers = Path.combine(
    PathOperation.difference,
    _body,
    _core,
  );

  static const _bodyTip = Color(0xFFFF6A3D);
  static const _bodyBase = Color(0xFFE0282E);
  static const _coreTip = Color(0xFFFFA23A);
  static const _coreBase = Color(0xFFFFDD7A);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _grid, size.height / _grid);
    const bounds = Rect.fromLTWH(0, 0, _grid, _grid);

    if (lit < 1) {
      canvas.drawPath(
        _embers,
        Paint()..color = unlitColor.withMultipliedAlpha(1 - lit),
      );
    }
    if (lit > 0) {
      Shader fire(Color tip, Color base) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [tip.withMultipliedAlpha(lit), base.withMultipliedAlpha(lit)],
      ).createShader(bounds);
      canvas
        ..drawPath(_body, Paint()..shader = fire(_bodyTip, _bodyBase))
        ..drawPath(_core, Paint()..shader = fire(_coreTip, _coreBase));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FlamePainter oldDelegate) =>
      oldDelegate.lit != lit || oldDelegate.unlitColor != unlitColor;
}
