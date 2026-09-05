import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The single in-app rendering of the Kapy Notes brand mark.
class AppLogo extends StatelessWidget {
  const AppLogo({
    super.key,
    required this.size,
    this.excludeFromSemantics = false,
  });

  static const assetPath = 'assets/branding/kapy_notes_logo.png';

  final double size;
  final bool excludeFromSemantics;

  @override
  Widget build(BuildContext context) => Image.asset(
    assetPath,
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.medium,
    isAntiAlias: true,
    excludeFromSemantics: excludeFromSemantics,
    semanticLabel: excludeFromSemantics ? null : 'Kapy Notes',
  );
}

/// Horizontal brand lockup used when there is room for the full product name.
class AppWordmark extends StatelessWidget {
  const AppWordmark({
    super.key,
    required this.markSize,
    required this.fontSize,
    this.spacing = 8,
    this.textColor,
    this.excludeFromSemantics = false,
    this.mark,
  });

  static const name = 'Kapy Notes';

  final double markSize;
  final double fontSize;
  final double spacing;
  final Color? textColor;
  final bool excludeFromSemantics;

  /// Replaces only the fixed-size mark while preserving the lockup geometry.
  final Widget? mark;

  @override
  Widget build(BuildContext context) {
    final lockup = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mark == null)
          AppLogo(size: markSize, excludeFromSemantics: true)
        else
          SizedBox.square(dimension: markSize, child: mark),
        SizedBox(width: spacing),
        Text(
          name,
          maxLines: 1,
          style: TextStyle(
            color: textColor ?? context.palette.textPrimary,
            fontFamily: 'OdinRounded',
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1,
            letterSpacing: -0.15,
          ),
        ),
      ],
    );

    if (excludeFromSemantics) return ExcludeSemantics(child: lockup);
    return Semantics(
      label: name,
      image: true,
      child: ExcludeSemantics(child: lockup),
    );
  }
}
