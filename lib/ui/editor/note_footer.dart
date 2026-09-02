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
  final bool boldActive;
  final bool italicActive;
  final bool bulletsActive;
  final bool checklistActive;
  final NoteParagraphStyle? paragraphStyle;
  final bool showSettingsButton;

  static const double height = 40;

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
          return SizedBox(
            height: height,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (showSettingsButton)
                  Positioned(
                    left: 8,
                    child: FooterSettingsButton(onPressed: onSettingsPressed),
                  ),
                ExcludeFocus(
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
                    ],
                  ),
                ),
                // A note with no calculations has nothing to total, so the
                // footer drops the readout instead of showing a hollow zero.
                if (total case final total?)
                  Positioned(
                    right: 10,
                    width: totalWidth,
                    child: Text.rich(
                      key: const ValueKey('note-total'),
                      TextSpan(
                        text: compactTotal ? 'Σ ' : 'Total: ',
                        style: TextStyle(
                          fontSize: 11.25,
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
          fontSize: style == NoteParagraphStyle.heading ? 13 : 11.5,
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
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return CompactIconButton(
      tooltip: tooltip,
      selected: active,
      foregroundColor: active ? palette.textPrimary : palette.textTertiary,
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
    );
  }
}

/// The shared settings affordance used by the note and sidebar footers.
class FooterSettingsButton extends StatelessWidget {
  const FooterSettingsButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CompactIconButton(
    key: const ValueKey('note-settings'),
    onPressed: onPressed,
    icon: const Icon(Icons.settings_outlined, size: 16),
    tooltip: 'Settings',
    foregroundColor: context.palette.textTertiary,
  );
}
