import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/writing_streak.dart';

/// The writing run beside a list's heading: the rail's clay line flame and
/// the number of days, quiet until today's writing lights it.
class StreakBadge extends StatelessWidget {
  const StreakBadge({super.key, required this.streak});

  final WritingStreak streak;

  static String describe(WritingStreak streak) => streak.wroteToday
      ? '${streak.days}-day writing streak'
      : 'Write today to keep your ${streak.days}-day streak';

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final lit = streak.wroteToday ? 1.0 : 0.0;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    // The message is what a screen reader hears, rather than a number, and it
    // needs a node of its own to be heard at all: merged into a heading that
    // already carries a tooltip, only the first of the two survives.
    return Semantics(
      container: true,
      child: Tooltip(
        message: describe(streak),
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
            builder: (context, t, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(
                  // Flares on the way up only. A run that is waiting on a
                  // new day goes quiet without a fuss.
                  scale: streak.wroteToday
                      ? 1 + 0.3 * math.sin(math.pi * t)
                      : 1,
                  alignment: Alignment.bottomCenter,
                  child: KapyIcon(
                    KapyIcons.fireOutlined,
                    size: MediaQuery.textScalerOf(
                      context,
                    ).scale(AppControlMetrics.iconInline + 2),
                    color: Color.lerp(palette.textTertiary, palette.clay, t),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${streak.days}',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                    color: Color.lerp(
                      palette.textTertiary,
                      palette.textPrimary,
                      t,
                    ),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
