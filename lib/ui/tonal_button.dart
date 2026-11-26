import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'keycap.dart';

/// The calm primary action: a sage label on its own quiet sage tint, flat,
/// with an optional keycap naming its shortcut.
///
/// New note and Done are tonal buttons in the Riverbank design, and one that
/// is only an icon is the + beside the notes search. A [quiet] one, like the
/// page's Share, keeps the same shape with no fill until the pointer is on
/// it. It is the theme's filled button in other colours: its shape,
/// elevation and timing come from the theme, and only its colours, size and
/// weight are its own.
class TonalButton extends StatelessWidget {
  const TonalButton({
    super.key,
    required this.onPressed,
    this.icon,
    this.label,
    this.shortcut,
    this.tooltip,
    this.tall = false,
    this.quiet = false,
    this.sageIcon = false,
    this.neutral = false,
  }) : assert(icon != null || label != null),
       assert(!(neutral && quiet), 'A button is neutral or quiet, not both.'),
       assert(!sageIcon || quiet, 'Only a quiet button carries a sage icon.'),
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

  /// r3's 32-tall control, for the bars over the notes list and the page:
  /// radius 8, 12 at either end and a 16 icon 4 from its label.
  final bool tall;

  /// Grey text on no fill, filled only under the pointer: an action that is
  /// there when wanted without competing with the page's main one.
  final bool quiet;

  /// A quiet button that is the page's main action, as New note is: its
  /// icon carries the sage and its words the text's own ink.
  final bool sageIcon;

  /// Grey rather than sage, with its key in plain faint mono: the way out of
  /// a dialog, as Settings' Done is, which should not read as its main
  /// action.
  final bool neutral;

  /// How wide a button with [label], an icon unless [icon] is false and, if
  /// given, [shortcut]'s keycap lays out at the reader's text size, for a bar
  /// that has to choose what to show before it builds.
  static double widthOf(
    BuildContext context,
    String label, {
    bool icon = true,
    String? shortcut,
    bool tall = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _labelStyle(context)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final text = painter.width;
    painter.dispose();
    final bar = tall && AppPlatform.hasPointer;
    return (!icon
            ? 12
            : bar
            ? 12 + 16 + 4
            : 9 + AppControlMetrics.iconControl + 6) +
        text +
        (shortcut == null
            ? 12
            : 6 + Keycap.widthOf(context, shortcut, tonal: true) + 6);
  }

  static TextStyle? _labelStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge?.copyWith(
        fontSize: AppTypeScale.control,
        fontWeight: AppWeight.font(AppWeight.regular),
        fontVariations: AppWeight.wght(AppWeight.regular),
      );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final icon = this.icon;
    final label = this.label;
    final shortcut = this.shortcut;
    final pointer = AppPlatform.hasPointer;
    final bar = tall && pointer;
    final fine = pointer && (tall || label == null);

    final button = FilledButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(
          Size.square(bar ? 32 : AppControlMetrics.tonalButtonHeight),
        ),
        shape: tall
            ? const WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
              )
            : null,
        padding: WidgetStatePropertyAll(
          label == null
              ? EdgeInsets.zero
              : EdgeInsetsDirectional.only(
                  start: icon == null || tall ? 12 : 9,
                  end: shortcut == null
                      ? 12
                      : neutral
                      ? 10
                      : 6,
                ),
        ),
        backgroundColor: quiet
            ? KapyTheme.fillStates(
                Colors.transparent,
                ink: palette.textPrimary,
                disabled: Colors.transparent,
              )
            : neutral
            ? KapyTheme.fillStates(
                palette.fillSelected,
                ink: palette.textPrimary,
                disabled: palette.controlBackground,
              )
            : KapyTheme.fillStates(
                palette.tonalBackground,
                ink: palette.tonalForeground,
                disabled: palette.controlBackground,
              ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? palette.textTertiary
              : sageIcon || neutral
              ? palette.textPrimary
              : quiet
              ? palette.textSecondary
              : palette.tonalForeground,
        ),
        textStyle: WidgetStatePropertyAll(_labelStyle(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            KapyIcon(
              icon,
              size: bar
                  ? 16
                  : fine
                  ? 15
                  : AppControlMetrics.iconControl,
              color: sageIcon ? palette.accentText : null,
            ),
          if (icon != null && label != null) SizedBox(width: bar ? 4 : 6),
          if (label != null) Text(label),
          if (shortcut != null) ...[
            SizedBox(width: neutral ? 8 : 6),
            ExcludeSemantics(
              child: Keycap(shortcut, tonal: !neutral, plain: neutral),
            ),
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
