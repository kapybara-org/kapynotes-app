import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The page the open note is written on: a rounded sheet a step lighter than
/// the window, which clips whatever is on it to its corners.
class PageCard extends StatelessWidget {
  const PageCard({super.key, required this.child});

  final Widget child;

  static const double radius = 20;
  static const double borderWidth = 1.5;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      key: const ValueKey('page-card'),
      decoration: BoxDecoration(
        color: palette.paperColor,
        borderRadius: const BorderRadius.all(Radius.circular(radius)),
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
          child: child,
        ),
      ),
    );
  }
}
