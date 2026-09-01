import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'glass_surface.dart';
import 'window_drag_area.dart';

/// The main pane's title bar: note title and note actions.
///
/// On macOS this doubles as the window's drag region, since the app uses a
/// hidden title bar.
class NoteToolbar extends StatelessWidget {
  const NoteToolbar({
    super.key,
    required this.title,
    required this.onToggleSidebar,
    required this.onCreate,
    required this.onDelete,
    this.sidebarVisible = true,
    this.showSidebarToggle = true,
    this.leading,
    this.leadingInset = 0,
  });

  final String title;
  final VoidCallback onToggleSidebar;
  final VoidCallback onCreate;
  final VoidCallback? onDelete;
  final bool sidebarVisible;
  final bool showSidebarToggle;
  final Widget? leading;

  /// Space to keep clear on the left for OS window controls.
  final double leadingInset;

  static const double height = 48;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // On a device with a status bar over the window, the toolbar's background
    // runs underneath it while its contents sit below.
    final topInset = MediaQuery.paddingOf(context).top;

    return GlassSurface(
      color: palette.surfaceBackground.withValues(alpha: 0.74),
      blur: 28,
      border: Border(bottom: BorderSide(color: palette.separator, width: 0.5)),
      child: SizedBox(
        height: height + topInset,
        child: Padding(
          padding: EdgeInsets.only(
            top: topInset,
            left: 9 + leadingInset,
            right: 9,
          ),
          child: Row(
            children: [
              if (leading != null) leading!,
              if (showSidebarToggle)
                _ToolbarButton(
                  icon: sidebarVisible
                      ? Icons.menu_open_rounded
                      : Icons.menu_rounded,
                  tooltip: sidebarVisible ? 'Hide sidebar' : 'Show sidebar',
                  onPressed: onToggleSidebar,
                ),
              const SizedBox(width: 7),
              // Only the inert stretch of the toolbar is window chrome, so the
              // buttons either side of it stay instantly responsive.
              Expanded(
                child: WindowDragArea(
                  child: SizedBox(
                    height: double.infinity,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _ToolbarButton(
                icon: Icons.add_rounded,
                tooltip: AppPlatform.isMacOS
                    ? 'New note  ⌘N'
                    : 'New note  Ctrl+N',
                onPressed: onCreate,
              ),
              const SizedBox(width: 2),
              NoteActionsMenu(onDelete: onDelete),
            ],
          ),
        ),
      ),
    );
  }
}

class NoteActionsMenu extends StatelessWidget {
  const NoteActionsMenu({super.key, required this.onDelete});

  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final error = Theme.of(context).colorScheme.error;

    return PopupMenuButton<String>(
      enabled: onDelete != null,
      tooltip: 'Note actions',
      position: PopupMenuPosition.under,
      icon: const Icon(Icons.more_horiz_rounded),
      iconSize: 18,
      iconColor: palette.textSecondary,
      padding: EdgeInsets.zero,
      splashRadius: 17,
      borderRadius: BorderRadius.circular(10),
      constraints: const BoxConstraints(minWidth: 180),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.square(32)),
        maximumSize: const WidgetStatePropertyAll(Size.square(32)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.11);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return palette.hover;
          }
          return Colors.transparent;
        }),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      onSelected: (value) {
        if (value == 'delete') onDelete?.call();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 16, color: error),
              const SizedBox(width: 10),
              Text('Delete Note', style: TextStyle(fontSize: 13, color: error)),
            ],
          ),
        ),
      ],
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
    final palette = context.palette;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        color: palette.textSecondary,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
