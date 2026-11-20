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
    this.ghost = false,
    this.sageIcon = false,
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

  /// A button with no fill until the pointer is over it: the crisp design's
  /// way of leaving a page one main action instead of several.
  final bool ghost;

  /// A ghost button whose icon carries the sage that marks the page's main
  /// action, as New note's plus does.
  final bool sageIcon;

  /// How wide a button with an icon, [label] and, if given, [shortcut]'s
  /// keycap lays out at the reader's text size, for a bar that has to choose
  /// what to show before it builds.
  static double widthOf(
    BuildContext context,
    String label, {
    String? shortcut,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _labelStyle(context)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final text = painter.width;
    painter.dispose();
    return 9 +
        AppControlMetrics.iconControl +
        6 +
        text +
        (shortcut == null
            ? 12
            : 6 + Keycap.widthOf(context, shortcut, tonal: true) + 6);
  }

  static TextStyle? _labelStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge?.copyWith(
        fontSize: AppTypeScale.control,
        fontWeight: FontWeight.w500,
        fontVariations: AppWeight.variations(AppWeight.rowTitle),
      );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final icon = this.icon;
    final label = this.label;
    final shortcut = this.shortcut;
    final pointer = AppPlatform.hasPointer;
    final fine = pointer && (tall || label == null);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          KapyIcon(
            icon,
            size: fine ? 15 : AppControlMetrics.iconControl,
            strokeWidth: fine ? 2 : 2.2,
            color: ghost && sageIcon ? palette.accent : null,
          ),
        if (icon != null && label != null) const SizedBox(width: 6),
        if (label != null) Text(label),
        if (shortcut != null) ...[
          const SizedBox(width: 6),
          ExcludeSemantics(child: Keycap(shortcut, tonal: true)),
        ],
      ],
    );

    final shape = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(
        Size.square(tall && pointer ? 32 : AppControlMetrics.tonalButtonHeight),
      ),
      shape: tall
          ? const WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.all(
                  Radius.circular(AppRadii.control),
                ),
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
      textStyle: WidgetStatePropertyAll(_labelStyle(context)),
    );

    final Widget button;
    if (ghost) {
      button = TextButton(
        onPressed: onPressed,
        style:
            TextButton.styleFrom(
              minimumSize: shape.minimumSize?.resolve({}),
              shape: shape.shape?.resolve({}),
              padding: shape.padding?.resolve({}),
              textStyle: _labelStyle(context),
              foregroundColor: palette.textSecondary,
            ).merge(
              ButtonStyle(
                backgroundColor: KapyTheme.fillStates(
                  Colors.transparent,
                  ink: palette.textPrimary,
                  disabled: Colors.transparent,
                ),
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.disabled)
                      ? palette.textTertiary
                      : palette.textSecondary,
                ),
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              ),
            ),
        child: content,
      );
    } else {
      button = FilledButton(
        onPressed: onPressed,
        style: shape.copyWith(
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
        ),
        child: content,
      );
    }

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
