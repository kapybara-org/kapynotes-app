import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// A key printed the way the keyboard prints it: ⌘F, /, esc.
///
/// One look for every shortcut the app shows beside a control, so a hint
/// reads as a key to press rather than as more text to read.
class Keycap extends StatelessWidget {
  const Keycap(this.label, {super.key, this.tonal = false});

  final String label;

  /// The chip inside a tonal button: in the button's own sage, borderless
  /// and a step smaller, so it reads as part of the button rather than as a
  /// second control beside it.
  final bool tonal;

  /// How wide a keycap printing [label] is, padding and border included, at
  /// the reader's text size, for a layout that has to know before it builds
  /// one.
  static double widthOf(
    BuildContext context,
    String label, {
    bool tonal = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: _style(tonal: tonal),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return tonal ? width + 2 * 5 : math.max(20, width + 2 * 6 + 2);
  }

  static TextStyle _style({required bool tonal, Color? color}) => TextStyle(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: tonal ? AppTypeScale.micro : AppTypeScale.keycap,
    fontWeight: AppWeight.font(AppWeight.rowTitle),
    fontVariations: AppWeight.wght(AppWeight.rowTitle),
    height: 1.1,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
    color: color,
    decoration: TextDecoration.none,
  );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      constraints: tonal
          ? const BoxConstraints(minHeight: 18)
          : const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: tonal
          ? const EdgeInsets.symmetric(horizontal: 5, vertical: 2)
          : const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tonal ? palette.tonalKeyBackground : palette.keycapBackground,
        border: tonal ? null : Border.all(color: palette.keycapBorder),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.small)),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          textAlign: TextAlign.center,
          style: _style(
            tonal: tonal,
            color: tonal ? palette.tonalKeyText : palette.keycapText,
          ),
        ),
      ),
    );
  }
}
