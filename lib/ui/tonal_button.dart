import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'keycap.dart';

/// The calm primary action: a sage label on its own quiet sage tint, flat,
/// with an optional keycap naming its shortcut.
///
/// New note, Share and Done are tonal buttons in the Riverbank design, and
/// one that is only an icon is the + beside the notes search.
class TonalButton extends StatelessWidget {
  const TonalButton({
    super.key,
    required this.onPressed,
    this.icon,
    this.label,
    this.shortcut,
    this.tooltip,
  }) : assert(icon != null || label != null),
       assert(
         label != null || tooltip != null,
         'A button that is only an icon needs a tooltip to be named by.',
       );

  /// Null disables the button.
  final VoidCallback? onPressed;
  final KapyIconData? icon;
  final String? label;

  /// The keys that do the same thing, in a chip after the label: ⌘N, esc.
  final String? shortcut;

  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final background = palette.tonalBackground;
    final foreground = palette.tonalForeground;
    final extent = AppControlMetrics.tonalButtonHeight;
    final icon = this.icon;
    final label = this.label;
    final shortcut = this.shortcut;

    final button = FilledButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.square(extent)),
        padding: WidgetStatePropertyAll(
          label == null
              ? EdgeInsets.zero
              : EdgeInsetsDirectional.only(
                  start: icon == null ? 12 : 9,
                  end: shortcut == null ? 12 : 6,
                ),
        ),
        visualDensity: VisualDensity.standard,
        tapTargetSize: AppControlMetrics.iconButtonTapTargetSize,
        elevation: const WidgetStatePropertyAll(0),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return palette.controlBackground;
          }
          if (states.contains(WidgetState.pressed)) {
            return Color.alphaBlend(
              foreground.withValues(alpha: 0.13),
              background,
            );
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return Color.alphaBlend(
              foreground.withValues(alpha: 0.07),
              background,
            );
          }
          return background;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? palette.textTertiary
              : foreground,
        ),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadii.control)),
          ),
        ),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: AppTypeScale.control,
            fontWeight: FontWeight.w700,
          ),
        ),
        animationDuration: const Duration(milliseconds: 120),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            KapyIcon(
              icon,
              size: AppControlMetrics.iconControl,
              strokeWidth: 2.2,
            ),
          if (icon != null && label != null) const SizedBox(width: 6),
          if (label != null) Text(label),
          if (shortcut != null) ...[
            const SizedBox(width: 6),
            ExcludeSemantics(child: Keycap(shortcut, tonal: true)),
          ],
        ],
      ),
    );

    final tooltip = this.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}
