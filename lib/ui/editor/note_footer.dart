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
  /// equally inset. Matching the two numbers would make the total look closer
  /// to the edge than the gear, which is the sort of thing you see without
  /// being able to name.
  static const double _edgeInset = 8;
  static const double _textEdgeInset = 10;

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
          final totalWidth = ((constraints.maxWidth - 200) / 2 - 18).clamp(
            40.0,
            180.0,
          );
          // The formatting controls sit in the true centre of the bar, which
          // only holds if whatever flanks them claims the same width on both
          // sides. A Stack used to give them that centring for free, and gave
          // away collision detection with it: at 44pt targets a seven-button
          // row is wider than the gap between the gear and the total, and the
          // three simply drew on top of each other.
          final settingsSlot = showSettingsButton
              ? AppControlMetrics.iconButtonExtent + _edgeInset
              : 0.0;
          final totalSlot = total == null ? 0.0 : totalWidth + _textEdgeInset;

          // Equal flanks put the controls in the true centre of the bar, which
          // is what the layout wants and what a desktop window has room for.
          // A phone does not always: at 44pt targets the row is wider than
          // what is left after reserving the total's width twice over, and
          // insisting on the symmetry is what pushed the last button under the
          // total. So the symmetry is a preference, not a rule — when it does
          // not fit, each side claims only what it uses and the controls
          // centre in the gap between them instead. The row is a known number
          // of fixed squares, so this needs no measuring pass.
          final rowWidth =
              (showIndentControls ? 7 : 5) * AppControlMetrics.iconButtonExtent;
          final symmetric = math.max(settingsSlot, totalSlot);
          final centresInBar = constraints.maxWidth - 2 * symmetric >= rowWidth;
          final leftSlot = centresInBar ? symmetric : settingsSlot;
          final rightSlot = centresInBar ? symmetric : totalSlot;
          return SizedBox(
            height: AppControlMetrics.scaleBar(context, height),
            child: Row(
              children: [
                SizedBox(
                  width: leftSlot,
                  child: showSettingsButton
                      ? Padding(
                          padding: const EdgeInsets.only(left: _edgeInset),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FooterSettingsButton(
                              onPressed: onSettingsPressed,
                            ),
                          ),
                        )
                      : null,
                ),
                // Centred while the controls fit, scrolling once they do not.
                // That second case is reachable on a narrow phone with the
                // nesting buttons showing, and again at any width once the
                // reader turns Dynamic Type up.
                Expanded(
                  child: _CentredOrScrolling(
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
                            tooltip: 'Bold · ${boldShortcut.displayLabel}',
                            active: boldActive,
                            onPressed: onBoldPressed,
                          ),
                          _FormatButton(
                            key: const ValueKey('format-italic'),
                            icon: Icons.format_italic_rounded,
                            tooltip: 'Italic · ${italicShortcut.displayLabel}',
                            active: italicActive,
                            onPressed: onItalicPressed,
                          ),
                          _FormatButton(
                            key: const ValueKey('format-bullets'),
                            icon: Icons.format_list_bulleted_rounded,
                            tooltip:
                                'Bulleted list · ${bulletsShortcut.displayLabel}',
                            active: bulletsActive,
                            onPressed: onBulletsPressed,
                          ),
                          _FormatButton(
                            key: const ValueKey('format-checklist'),
                            icon: Icons.checklist_rounded,
                            tooltip:
                                'Checklist · ${checklistShortcut.displayLabel}',
                            active: checklistActive,
                            onPressed: onChecklistPressed,
                          ),
                          if (showIndentControls) ...[
                            _FormatButton(
                              key: const ValueKey('format-outdent'),
                              icon: Icons.format_indent_decrease_rounded,
                              tooltip: 'Move out · Shift + Tab',
                              active: false,
                              onPressed: canOutdent ? onOutdentPressed : null,
                            ),
                            _FormatButton(
                              key: const ValueKey('format-indent'),
                              icon: Icons.format_indent_increase_rounded,
                              tooltip: 'Move in · Tab',
                              active: false,
                              onPressed: canIndent ? onIndentPressed : null,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                // A note with no calculations has nothing to total, so the
                // footer drops the readout instead of showing a hollow zero.
                SizedBox(
                  width: rightSlot,
                  child: total == null
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(right: _textEdgeInset),
                          child: Text.rich(
                            key: const ValueKey('note-total'),
                            TextSpan(
                              text: compactTotal ? 'Σ ' : 'Total: ',
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
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Centres its child in the space available, and scrolls it instead of
/// clipping it when there is not enough.
class _CentredOrScrolling extends StatelessWidget {
  const _CentredOrScrolling({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: Center(child: child),
      ),
    ),
  );
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
