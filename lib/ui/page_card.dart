import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The page the open note is written on: a rounded sheet a step lighter than
/// the window, which clips whatever is on it to its corners.
///
/// In glass mode the sheet is only its edge. Everything on it paints its own
/// translucent paper, the page toolbar included, so a fill here would thicken
/// the glass under all of it, and a shadow would show through the page as a
/// dark slab.
class PageCard extends StatelessWidget {
  const PageCard({super.key, required this.child});

  final Widget child;

  static const double radius = 20;
  static const double borderWidth = 1.5;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final glass = palette.isGlass;
    return DecoratedBox(
      key: const ValueKey('page-card'),
      decoration: BoxDecoration(
        color: glass ? null : palette.paperColor,
        borderRadius: const BorderRadius.all(Radius.circular(radius)),
        border: Border.all(color: palette.pageBorder, width: borderWidth),
        boxShadow: glass
            ? null
            : [
                BoxShadow(
                  color: palette.shadowAt(0x40),
                  offset: Offset(0, 1),
                  blurRadius: 2,
                ),
                BoxShadow(
                  color: palette.shadowAt(0x66),
                  offset: Offset(0, 16),
                  blurRadius: 32,
                  spreadRadius: -20,
                ),
              ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(borderWidth),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(
            Radius.circular(radius - borderWidth),
          ),
          child: child,
        ),
      ),
    );
  }
}
