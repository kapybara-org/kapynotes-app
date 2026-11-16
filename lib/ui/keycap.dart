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
        borderRadius: const BorderRadius.all(Radius.circular(5)),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: AppFonts.mono,
            fontFamilyFallback: AppFonts.monoFallback,
            fontSize: tonal ? AppTypeScale.micro : AppTypeScale.keycap,
            fontWeight: FontWeight.w500,
            height: 1.1,
            leadingDistribution: TextLeadingDistribution.even,
            letterSpacing: 0,
            color: tonal ? palette.tonalKeyText : palette.keycapText,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
