import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The app's outlined field treatment for forms and search controls.
///
/// This is deliberately opt-in. The note editor is also implemented with a
/// text field, but it is a writing surface and must never acquire form chrome.
InputDecoration kapyFieldDecoration(
  BuildContext context, {
  String? hintText,
  TextStyle? hintStyle,
  Widget? prefixIcon,
  BoxConstraints? prefixIconConstraints,
  Widget? suffixIcon,
  BoxConstraints? suffixIconConstraints,
  EdgeInsetsGeometry? contentPadding,
  Color? fillColor,
}) {
  final palette = context.palette;
  final error = Theme.of(context).colorScheme.error;
  OutlineInputBorder border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: color, width: width),
      );

  return InputDecoration(
    hintText: hintText,
    hintStyle: hintStyle,
    isDense: true,
    filled: true,
    fillColor: fillColor ?? palette.controlBackground,
    contentPadding:
        contentPadding ??
        EdgeInsets.symmetric(
          horizontal: 12,
          vertical: AppControlMetrics.fieldVerticalPadding,
        ),
    prefixIcon: prefixIcon,
    prefixIconConstraints: prefixIconConstraints,
    suffixIcon: suffixIcon,
    suffixIconConstraints: suffixIconConstraints,
    border: border(palette.controlBorder),
    enabledBorder: border(palette.controlBorder),
    disabledBorder: border(palette.controlBorder.withValues(alpha: 0.55)),
    focusedBorder: border(palette.selectedBorder, width: 1.25),
    errorBorder: border(error.withValues(alpha: 0.8)),
    focusedErrorBorder: border(error, width: 1.25),
  );
}

/// A flat, rounded group for related controls.
///
/// Dialog sections and settings groups use the same quiet surface so the app
/// has one visual grammar. The one-pixel outline supplies separation without
/// adding elevation or a shadow.
class KapyControlSurface extends StatelessWidget {
  const KapyControlSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = AppRadii.surface,
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final content = padding == EdgeInsets.zero
        ? child
        : Padding(padding: padding, child: child);

    return Material(
      color: color ?? palette.controlBackground,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: borderColor ?? palette.controlBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}
