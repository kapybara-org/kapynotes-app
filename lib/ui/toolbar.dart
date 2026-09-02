import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'app_logo.dart';
import 'compact_icon_button.dart';
import 'glass_surface.dart';
import 'window_drag_area.dart';

/// The app's unified title bar: centered identity and global note actions.
///
/// On macOS this doubles as the window's drag region, since the app uses a
/// hidden title bar.
class NoteToolbar extends StatelessWidget {
  const NoteToolbar({
    super.key,
    required this.onToggleSidebar,
    required this.onCreate,
    this.sidebarVisible = true,
    this.showActions = true,
  });

  final VoidCallback onToggleSidebar;
  final VoidCallback onCreate;
  final bool sidebarVisible;
  final bool showActions;

  static const double height = 48;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // On a device with a status bar over the window, the toolbar's background
    // runs underneath it while its contents sit below.
    final topInset = MediaQuery.paddingOf(context).top;

    return GlassSurface(
      color: palette.surfaceBackground.withValues(alpha: 0.94),
      blur: 10,
      border: Border(bottom: BorderSide(color: palette.separator, width: 0.5)),
      child: SizedBox(
        height: height + topInset,
        child: Stack(
          children: [
            Positioned.fill(
              top: topInset,
              child: WindowDragArea(
                child: const Center(
                  child: AppWordmark(
                    key: ValueKey('toolbar-app-wordmark'),
                    markSize: 19,
                    fontSize: 14.5,
                    spacing: 6.5,
                  ),
                ),
              ),
            ),
            if (showActions)
              Positioned(
                top: topInset,
                right: 9,
                height: height,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ToolbarButton(
                      icon: Icons.add_rounded,
                      tooltip: AppPlatform.isMacOS
                          ? 'New note  ⌘N'
                          : 'New note  Ctrl+N',
                      onPressed: onCreate,
                    ),
                    const SizedBox(width: 2),
                    _ToolbarButton(
                      icon: Icons.menu_rounded,
                      tooltip: sidebarVisible ? 'Hide notes' : 'Show notes',
                      onPressed: onToggleSidebar,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CompactIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      foregroundColor: context.palette.textSecondary,
      icon: Icon(icon, size: 17),
    );
  }
}
