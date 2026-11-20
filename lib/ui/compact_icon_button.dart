import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';

/// The app-wide icon action used in toolbars, footers, and sidebars.
///
/// Its painted hover and selection surface stays compact on pointer devices,
/// while touch platforms keep the larger target supplied by the theme.
class CompactIconButton extends StatelessWidget {
  const CompactIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.foregroundColor,
    this.extent,
    this.width,
    this.radius = 6,
    this.tapTargetSize,
    this.selectedBackground,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final Color? foregroundColor;
  final double? extent;

  /// How wide it is where that differs from [extent]: the arrows beside the
  /// page's days are narrower than they are tall.
  final double? width;

  /// The corner of the surface it paints on hover, focus and selection.
  final double radius;

  /// Overrides the platform's tap target, for a row that has measured its
  /// buttons edge to edge and cannot afford padding around each one.
  final MaterialTapTargetSize? tapTargetSize;

  /// The surface while [selected], in place of the palette's selection: the
  /// drawing dock marks its tool in the tonal sage.
  final Color? selectedBackground;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final extent = this.extent ?? AppControlMetrics.iconButtonExtent;
    final size = Size(width ?? extent, extent);

    return MergeSemantics(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          label: AppPlatform.isDesktop ? tooltip : null,
          selected: selected,
          child: IconButton(
            onPressed: onPressed,
            icon: icon,
            color: foregroundColor ?? palette.textSecondary,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tight(size),
            visualDensity: VisualDensity.standard,
            style: ButtonStyle(
              minimumSize: WidgetStatePropertyAll(size),
              maximumSize: WidgetStatePropertyAll(size),
              tapTargetSize:
                  tapTargetSize ?? AppControlMetrics.iconButtonTapTargetSize,
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.disabled)) {
                  return Colors.transparent;
                }
                if (states.contains(WidgetState.pressed)) {
                  return scheme.primary.withValues(alpha: 0.10);
                }
                if (selected) {
                  return selectedBackground ?? palette.selectedBackground;
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)) {
                  return palette.hover;
                }
                return Colors.transparent;
              }),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              side: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.focused)) {
                  return BorderSide(color: palette.selectedBorder, width: 1);
                }
                return BorderSide.none;
              }),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
