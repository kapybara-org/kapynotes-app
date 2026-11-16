import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'kapy_cursor_peek.dart';

/// The page the open note is written on: a rounded sheet a step lighter than
/// the window, with Kapy peeking in from its bottom-right corner.
///
/// Its corners clip whatever is on it, Kapy included, so he reads as standing
/// behind the page's edge rather than over the note.
class PageCard extends StatelessWidget {
  const PageCard({super.key, required this.child});

  final Widget child;

  static const double radius = 20;
  static const double borderWidth = 1.5;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    const shape = BorderRadius.all(Radius.circular(radius));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.paperColor,
        borderRadius: shape,
        border: Border.all(color: palette.pageBorder, width: borderWidth),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            offset: Offset(0, 1),
            blurRadius: 2,
          ),
          BoxShadow(
            color: Color(0x66000000),
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
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              Positioned(
                right: -9,
                bottom: -3,
                width: 60,
                height: 113,
                child: IgnorePointer(
                  child: Image.asset(
                    KapyCursorPeek.assetPath,
                    key: const ValueKey('page-kapy'),
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
