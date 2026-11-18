import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'keycap.dart';

/// The calm primary action: a sage label on its own quiet sage tint, flat,
/// with an optional keycap naming its shortcut.
///
/// New note, Share and Done are tonal buttons in the Riverbank design, and
/// one that is only an icon is the + beside the notes search. It is the
/// theme's filled button in other colours: its shape, elevation and timing
/// come from the theme, and only its colours, size and weight are its own.
class TonalButton extends StatelessWidget {
  const TonalButton({
    super.key,
    required this.onPressed,
    this.icon,
    this.label,
    this.shortcut,
    this.tooltip,
    this.tall = false,
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

  /// The page toolbar's Share: two points taller, with rounder corners and a
  /// finer icon than the notes list's New note.
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final icon = this.icon;
    final label = this.label;
    final shortcut = this.shortcut;
    final pointer = AppPlatform.hasPointer;
    final fine = pointer && (tall || label == null);

    final button = FilledButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(
          Size.square(
            tall && pointer ? 32 : AppControlMetrics.tonalButtonHeight,
          ),
        ),
        shape: tall
            ? const WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                ),
              )
            : null,
        padding: WidgetStatePropertyAll(
          label == null
              ? EdgeInsets.zero
              : EdgeInsetsDirectional.only(
                  start: icon == null
                      ? 12
                      : tall
                      ? 10
                      : 9,
                  end: shortcut == null ? 12 : 6,
                ),
        ),
        backgroundColor: KapyTheme.fillStates(
          palette.tonalBackground,
          ink: palette.tonalForeground,
          disabled: palette.controlBackground,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? palette.textTertiary
              : palette.tonalForeground,
        ),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: AppTypeScale.control,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            KapyIcon(
              icon,
              size: fine ? 15 : AppControlMetrics.iconControl,
              strokeWidth: fine ? 2 : 2.2,
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
    if (tooltip == null) return button;
    if (label != null || !AppPlatform.isDesktop) {
      return Tooltip(message: tooltip, child: button);
    }
    return MergeSemantics(
      child: Tooltip(
        message: tooltip,
        child: Semantics(label: tooltip, child: button),
      ),
    );
  }
}
