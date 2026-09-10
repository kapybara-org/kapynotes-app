import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The look every panel that floats over the app shares — tooltips, popovers,
/// the keyword explainer — and the text context they do not otherwise have.
///
/// The text context is the important half. An entry inserted straight into
/// the root overlay is not a descendant of any route, so there is no
/// `Material` above it and therefore no `DefaultTextStyle` either. What is
/// left is Flutter's fallback: red type, underlined twice in yellow. A `Text`
/// naming only its size and colour *merges* with that rather than replacing
/// it, so the colour looked right and the underline came along — which is
/// exactly the stray double line that turned up under these panels.
///
/// Flat, like everything else here: the app sets a transparent shadow colour
/// and zero elevation on dialogs and menus, and a panel that floated on a
/// shadow would be the one thing in it pretending to have height. A hairline
/// border does the separating instead.
class FloatingSurface extends StatelessWidget {
  const FloatingSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    this.constraints,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;

  /// One radius for everything that floats, matching the settings cards. A
  /// panel that is nearly the same shape as the app's other surfaces is a
  /// panel nobody notices, which is the whole job.
  static const double radius = 10;

  /// The style a floating panel's text starts from.
  ///
  /// Complete rather than partial — `decoration` included — because the point
  /// is to stop inheriting the fallback rather than to sit on top of it.
  static TextStyle textStyle(BuildContext context) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
        color: context.palette.textPrimary,
        decoration: TextDecoration.none,
      );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DefaultTextStyle(
      style: textStyle(context),
      child: Container(
        constraints: constraints,
        padding: padding,
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: palette.controlBorder, width: 0.5),
        ),
        child: child,
      ),
    );
  }
}
