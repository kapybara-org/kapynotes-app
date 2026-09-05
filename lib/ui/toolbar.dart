import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'app_logo.dart';
import 'compact_icon_button.dart';
import 'glass_surface.dart';
import 'kapy_header_mascot.dart';
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
    this.alwaysOnTop = false,
    this.onToggleAlwaysOnTop,
    this.alwaysOnTopShortcut,
    this.mascotController,
  });

  final VoidCallback onToggleSidebar;
  final VoidCallback onCreate;
  final bool sidebarVisible;
  final bool showActions;

  /// Whether the window is currently floating over other applications.
  final bool alwaysOnTop;

  /// Null on platforms with no such concept, which is how the pin stays off
  /// the toolbar on phones rather than sitting there doing nothing.
  final VoidCallback? onToggleAlwaysOnTop;

  /// The chord currently bound to the toggle, for the tooltip. Read from
  /// preferences rather than written here, because the binding is editable.
  final String? alwaysOnTopShortcut;

  /// Drives the optional animated mark without changing toolbar geometry.
  final KapyHeaderController? mascotController;

  static const double height = 48;

  /// Between the lockup and the pin, and mirrored on the other side.
  static const double _pinGap = 5;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // On a device with a status bar over the window, the toolbar's background
    // runs underneath it while its contents sit below.
    final topInset = MediaQuery.paddingOf(context).top;

    final pinned = onToggleAlwaysOnTop;

    return GlassSurface(
      color: palette.surfaceBackground.withValues(alpha: 0.94),
      blur: 10,
      border: Border(bottom: BorderSide(color: palette.separator, width: 0.5)),
      child: SizedBox(
        height: height + topInset,
        child: Stack(
          children: [
            // The bare drag surface. Everything above it either drags on its
            // own account or is a button, and anything that is neither falls
            // through to here — which is what keeps the empty stretches of the
            // toolbar draggable.
            Positioned.fill(
              top: topInset,
              child: const WindowDragArea(child: SizedBox.expand()),
            ),
            Positioned.fill(
              top: topInset,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Balances the pin on the other side, so the lockup keeps
                    // the exact centre of the toolbar rather than being
                    // shouldered off it — two tests hold that to half a pixel,
                    // and it is the reason the title bar reads as centred at
                    // any window width.
                    // Not gated on showActions: that hides the note actions
                    // while the drawer covers them, and the pin is about the
                    // window rather than the note.
                    if (pinned != null)
                      SizedBox(
                        width: AppControlMetrics.iconButtonExtent + _pinGap,
                      ),
                    // The lockup carries its own drag region rather than
                    // sitting inside one with the pin: DragToMoveArea waits
                    // out the double-tap timeout before it yields, so a button
                    // beneath it answers late on every single click.
                    WindowDragArea(
                      child: AppWordmark(
                        key: ValueKey('toolbar-app-wordmark'),
                        markSize: 19,
                        fontSize: 14.5,
                        spacing: 6.5,
                        mark: mascotController == null
                            ? null
                            : KapyHeaderMascot(
                                controller: mascotController!,
                                markSize: 19,
                              ),
                      ),
                    ),
                    if (pinned != null) ...[
                      const SizedBox(width: _pinGap),
                      _ToolbarButton(
                        icon: alwaysOnTop
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        tooltip: [
                          alwaysOnTop ? 'Stop keeping on top' : 'Keep on top',
                          ?alwaysOnTopShortcut,
                        ].join('  '),
                        selected: alwaysOnTop,
                        onPressed: pinned,
                      ),
                    ],
                  ],
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
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return CompactIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      selected: selected,
      foregroundColor: selected
          ? context.palette.textPrimary
          : context.palette.textSecondary,
      icon: Icon(icon, size: 17),
    );
  }
}
