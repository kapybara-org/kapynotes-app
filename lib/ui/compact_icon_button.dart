import 'package:material_ui/material_ui.dart';

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
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final extent = AppControlMetrics.iconButtonExtent;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        child: IconButton(
          onPressed: onPressed,
          icon: icon,
          color: foregroundColor ?? palette.textSecondary,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(width: extent, height: extent),
          visualDensity: VisualDensity.standard,
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size.square(extent)),
            maximumSize: WidgetStatePropertyAll(Size.square(extent)),
            tapTargetSize: AppControlMetrics.iconButtonTapTargetSize,
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return Colors.transparent;
              }
              if (states.contains(WidgetState.pressed)) {
                return scheme.primary.withValues(alpha: 0.10);
              }
              if (selected) return palette.selectedBackground;
              if (states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)) {
                return palette.hover;
              }
              return Colors.transparent;
            }),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ),
      ),
    );
  }
}
