import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/shortcut_prefs.dart';
import '../compact_icon_button.dart';
import '../glass_surface.dart';
import 'editor_formatting.dart';

/// Persistent note status bar inspired by the compact footer in Numi.
class NoteFooter extends StatelessWidget {
  const NoteFooter({
    super.key,
    required this.total,
    required this.paragraphStyleShortcut,
    required this.boldShortcut,
    required this.italicShortcut,
    required this.bulletsShortcut,
    required this.checklistShortcut,
    required this.onSettingsPressed,
    required this.onParagraphStylePressed,
    required this.onBoldPressed,
    required this.onItalicPressed,
    required this.onBulletsPressed,
    required this.onChecklistPressed,
    required this.onIndentPressed,
    required this.onOutdentPressed,
    required this.showIndentControls,
    required this.canIndent,
    required this.canOutdent,
    required this.boldActive,
    required this.italicActive,
    required this.bulletsActive,
    required this.checklistActive,
    required this.paragraphStyle,
    this.showSettingsButton = true,
  });

  final String? total;
  final ShortcutBinding paragraphStyleShortcut;
  final ShortcutBinding boldShortcut;
  final ShortcutBinding italicShortcut;
  final ShortcutBinding bulletsShortcut;
  final ShortcutBinding checklistShortcut;
  final VoidCallback onSettingsPressed;
  final VoidCallback onParagraphStylePressed;
  final VoidCallback onBoldPressed;
  final VoidCallback onItalicPressed;
  final VoidCallback onBulletsPressed;
  final VoidCallback onChecklistPressed;

  /// Nesting only appears once the caret is on a list line. The row shares its
  /// width with the total readout, and on a narrow phone two permanent extra
  /// buttons would crowd it for the sake of controls that would do nothing.
  final VoidCallback onIndentPressed;
  final VoidCallback onOutdentPressed;
  final bool showIndentControls;
  final bool canIndent;
  final bool canOutdent;
  final bool boldActive;
  final bool italicActive;
  final bool bulletsActive;
  final bool checklistActive;
  final NoteParagraphStyle? paragraphStyle;
  final bool showSettingsButton;

  static double get height => AppControlMetrics.footerHeight;

  /// Gap between the bar's edge and the control nearest it.
  ///
  /// The two sides differ by design. An icon button paints a hover surface
  /// wider than its glyph, so its optical edge already sits inside its box; a
  /// text run has no such padding and needs the margin spelled out to look
  /// equally inset.
  static const double _edgeInset = 8;
  static const double _textEdgeInset = 10;

  /// Between the gear and the formatting cluster. They are different in kind —
  /// one leaves the note, the rest change the text — and butted together they
  /// would read as one group of six.
  static const double _groupGap = 14;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GlassSurface(
      color: palette.surfaceBackground.withValues(alpha: 0.94),
      blur: 10,
      border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Wide phones still need the shorter label beside five formatting
          // controls and a grouped currency value. Desktop keeps its existing
          // label until the window reaches the genuinely narrow breakpoint.
          final compactTotal =
              constraints.maxWidth < (AppPlatform.isMobile ? 520 : 420);

          // The controls start at the left edge and grow rightward, which is
          // the whole point of not centring them: the nesting buttons appear
          // the moment the caret lands on a list line, and a centred row that
          // grows from five squares to seven slides everything already in it
          // sideways by a full button — 44pt under a thumb. Tap Bullets and
          // Bold would leave from under the finger that just pressed it.
          final gearSlot = showSettingsButton
              ? AppControlMetrics.iconButtonExtent + _groupGap
              : 0.0;
          final rowWidth =
              (showIndentControls ? 7 : 5) * AppControlMetrics.iconButtonExtent;
          final fixed =
              _edgeInset + gearSlot + rowWidth + _groupGap + _textEdgeInset;
          // Whatever is genuinely left over, up to a readable maximum. The
          // floor is what makes the controls scroll instead of the readout
          // shrinking to nothing on a narrow phone with nesting showing.
          final totalSlot = total == null
              ? 0.0
              : (constraints.maxWidth - fixed).clamp(40.0, 180.0);

          return SizedBox(
            height: AppControlMetrics.scaleBar(context, height),
            child: Row(
              children: [
                const SizedBox(width: _edgeInset),
                if (showSettingsButton) ...[
                  FooterSettingsButton(onPressed: onSettingsPressed),
                  const SizedBox(width: _groupGap),
                ],
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(
                      0,
                      constraints.maxWidth -
                          _edgeInset -
                          gearSlot -
                          totalSlot -
                          _groupGap -
                          _textEdgeInset,
                    ),
                  ),
                  // Scrolls only when it cannot fit, which a narrow phone with
                  // the nesting controls showing still cannot. Left-anchored,
                  // so what is on screen stays where it was.
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: ExcludeFocus(
                      child: Row(
                        key: const ValueKey('note-formatting-controls'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _StyleCycleButton(
                            style: paragraphStyle,
                            shortcut: paragraphStyleShortcut,
                            onPressed: onParagraphStylePressed,
                          ),
                          _FormatButton(
                            key: const ValueKey('format-bold'),
                            icon: Icons.format_bold_rounded,
                            tooltip: 'Bold \u00b7 ${boldShortcut.displayLabel}',
                            active: boldActive,
                            onPressed: onBoldPressed,
                          ),
                          _FormatButton(
                            key: const ValueKey('format-italic'),
                            icon: Icons.format_italic_rounded,
                            tooltip:
                                'Italic \u00b7 ${italicShortcut.displayLabel}',
                            active: italicActive,
                            onPressed: onItalicPressed,
                          ),
                          _FormatButton(
                            key: const ValueKey('format-bullets'),
                            icon: Icons.format_list_bulleted_rounded,
                            tooltip:
                                'Bulleted list \u00b7 ${bulletsShortcut.displayLabel}',
                            active: bulletsActive,
                            onPressed: onBulletsPressed,
                          ),
                          _FormatButton(
                            key: const ValueKey('format-checklist'),
                            icon: Icons.checklist_rounded,
                            tooltip:
                                'Checklist \u00b7 ${checklistShortcut.displayLabel}',
                            active: checklistActive,
                            onPressed: onChecklistPressed,
                          ),
                          if (showIndentControls) ...[
                            _FormatButton(
                              key: const ValueKey('format-outdent'),
                              icon: Icons.format_indent_decrease_rounded,
                              tooltip: 'Move out \u00b7 Shift + Tab',
                              active: false,
                              onPressed: canOutdent ? onOutdentPressed : null,
                            ),
                            _FormatButton(
                              key: const ValueKey('format-indent'),
                              icon: Icons.format_indent_increase_rounded,
                              tooltip: 'Move in \u00b7 Tab',
                              active: false,
                              onPressed: canIndent ? onIndentPressed : null,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                // Everything between the controls and the readout. The only
                // flexible thing in the row, so the total is pinned right
                // however wide the window is.
                const Spacer(),
                // A note with no calculations has nothing to total, so the
                // footer drops the readout instead of showing a hollow zero.
                if (total case final total?) ...[
                  SizedBox(
                    width: totalSlot,
                    child: Text.rich(
                      key: const ValueKey('note-total'),
                      TextSpan(
                        text: compactTotal ? '\u03a3 ' : 'Total: ',
                        style: TextStyle(
                          fontSize: AppTypeScale.caption,
                          fontWeight: FontWeight.w500,
                          color: palette.textTertiary,
                        ),
                        children: [
                          TextSpan(
                            text: total,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: palette.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  const SizedBox(width: _textEdgeInset),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StyleCycleButton extends StatelessWidget {
  const _StyleCycleButton({
    required this.style,
    required this.shortcut,
    required this.onPressed,
  });

  final NoteParagraphStyle? style;
  final ShortcutBinding shortcut;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final active = style != null && style != NoteParagraphStyle.text;
    final label = switch (style) {
      NoteParagraphStyle.heading => 'H',
      NoteParagraphStyle.subtitle => 'S',
      _ => 'Aa',
    };
    return CompactIconButton(
      key: const ValueKey('format-style'),
      tooltip:
          'Text style: ${style?.label ?? 'Mixed'} · ${shortcut.displayLabel}',
      selected: active,
      foregroundColor: active ? palette.textPrimary : palette.textTertiary,
      onPressed: onPressed,
      icon: Text(
        label,
        style: TextStyle(
          fontSize: style == NoteParagraphStyle.heading
              ? AppTypeScale.control
              : AppTypeScale.caption,
          fontWeight: style == NoteParagraphStyle.heading
              ? FontWeight.w700
              : FontWeight.w600,
          fontStyle: style == NoteParagraphStyle.subtitle
              ? FontStyle.italic
              : FontStyle.normal,
        ),
      ),
    );
  }
}

class _FormatButton extends StatelessWidget {
  const _FormatButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool active;

  /// Null disables the button, which is how the nesting controls show that a
  /// list is already at the margin or at the deepest level.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = switch ((active, onPressed == null)) {
      (_, true) => palette.textTertiary.withValues(alpha: 0.38),
      (true, _) => palette.textPrimary,
      _ => palette.textTertiary,
    };
    return CompactIconButton(
      tooltip: tooltip,
      selected: active,
      foregroundColor: foreground,
      onPressed: onPressed,
      icon: Icon(icon, size: AppControlMetrics.iconAction),
    );
  }
}

/// The shared settings affordance used by the note and sidebar footers.
class FooterSettingsButton extends StatelessWidget {
  const FooterSettingsButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'Settings',
  });

  final VoidCallback onPressed;

  /// Overridden to carry the update notice, since the dot beside the gear is
  /// the one part of it a screen reader cannot see.
  final String tooltip;

  @override
  Widget build(BuildContext context) => CompactIconButton(
    key: const ValueKey('note-settings'),
    onPressed: onPressed,
    icon: Icon(Icons.settings_outlined, size: AppControlMetrics.iconControl),
    tooltip: tooltip,
    foregroundColor: context.palette.textTertiary,
  );
}
