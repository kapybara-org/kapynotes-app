import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/window_chrome.dart';
import '../sync/spaces.dart';
import 'app_logo.dart';
import 'compact_icon_button.dart';
import 'glass_surface.dart';
import 'kapy_header_mascot.dart';
import 'member_avatars.dart';
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
    this.onShare,
    this.sidebarVisible = true,
    this.showActions = true,
    this.alwaysOnTop = false,
    this.onToggleAlwaysOnTop,
    this.alwaysOnTopShortcut,
    this.mascotController,
    this.members = const [],
    this.currentUserId = '',
    this.noteShared = false,
  });

  final VoidCallback onToggleSidebar;
  final VoidCallback onCreate;

  /// Shares the note that is open. Null while nothing is selected, which
  /// leaves the action in place but greyed rather than moving the ones beside
  /// it every time the selection changes.
  final VoidCallback? onShare;

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

  /// Everyone the open note is shared with. Empty on a personal note, which
  /// is what keeps that note's title bar as quiet as it has always been.
  final List<SpaceMember> members;

  /// Whose account this is, so one avatar can read "You".
  final String currentUserId;

  /// Whether the open note lives in a shared space, which is what the share
  /// action's wording turns on.
  final bool noteShared;

  static double get height => AppControlMetrics.toolbarHeight;

  /// Between the lockup and the pin, and mirrored on the other side.
  static const double _pinGap = 5;

  /// Between an edge action and the window's edge.
  static const double _edgeGap = 9;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // On a device with a status bar over the window, the toolbar's background
    // runs underneath it while its contents sit below.
    final topInset = MediaQuery.paddingOf(context).top;
    // Grows with Dynamic Type so the wordmark is never cropped by its own bar.
    final barHeight = AppControlMetrics.scaleBar(context, height);

    final pinned = onToggleAlwaysOnTop;

    return GlassSurface(
      color: palette.surfaceBackground.withMultipliedAlpha(0.94),
      border: Border(bottom: BorderSide(color: palette.separator, width: 0.5)),
      child: SizedBox(
        height: barHeight + topInset,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              // The bare drag surface. Everything above it either drags on its
              // own account or is a button, and anything that is neither falls
              // through to here — which is what keeps the empty stretches of
              // the toolbar draggable.
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
                      // shouldered off it — two tests hold that to half a
                      // pixel, and it is the reason the title bar reads as
                      // centred at any window width.
                      // Not gated on showActions: that hides the note actions
                      // while the drawer covers them, and the pin is about the
                      // window rather than the note.
                      if (pinned != null)
                        SizedBox(
                          width: AppControlMetrics.iconButtonExtent + _pinGap,
                        ),
                      // The lockup carries its own drag region rather than
                      // sitting inside one with the pin: DragToMoveArea waits
                      // out the double-tap timeout before it yields, so a
                      // button beneath it answers late on every single click.
                      WindowDragArea(
                        child: AppWordmark(
                          key: const ValueKey('toolbar-app-wordmark'),
                          markSize: AppControlMetrics.wordmarkMark,
                          fontSize: AppTypeScale.wordmark,
                          spacing: 6.5,
                          mark: mascotController == null
                              ? null
                              : KapyHeaderMascot(
                                  controller: mascotController!,
                                  markSize: AppControlMetrics.wordmarkMark,
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
              // Both clusters sit over the lockup rather than under it: on a
              // bar too narrow for all three, a button the reader can press
              // beats a wordmark they have already read.
              if (showActions) ...[
                Positioned(
                  top: topInset,
                  left: _leadingInset,
                  // Stops short of the lockup instead of running under it. The
                  // avatars inside give up circles, then names, to fit.
                  right: constraints.maxWidth / 2 + _centreReserve,
                  height: barHeight,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _leading(),
                  ),
                ),
                Positioned(
                  top: topInset,
                  right: _edgeGap,
                  height: barHeight,
                  child: _trailing(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Where the leading cluster starts: clear of the traffic lights on macOS,
  /// and a matching beat from the window edge everywhere else.
  static double get _leadingInset =>
      WindowChrome.overlaysContent ? WindowChrome.trafficLightsWidth : _edgeGap;

  /// Half the lockup, plus air.
  ///
  /// Estimated from the type size rather than measured: its only job is to
  /// keep a long roster from reaching the wordmark, so erring wide costs a
  /// name or an avatar and erring narrow would cost a collision.
  static double get _centreReserve =>
      (AppControlMetrics.wordmarkMark + 6.5 + AppTypeScale.wordmark * 6.4) / 2 +
      12;

  /// The drawer's button, and whoever the open note is shared with.
  ///
  /// The menu leads on every platform, so the drawer opens from the same
  /// corner everywhere. macOS paints its traffic lights over that corner, so
  /// the button starts after them rather than under them — see
  /// [_leadingInset], which is the whole of the difference there.
  Widget _leading() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _menuButton(),
        if (members.isNotEmpty)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: MemberAvatars(
                members: members,
                currentUserId: currentUserId,
                onPressed: onShare,
              ),
            ),
          ),
      ],
    );
  }

  Widget _trailing() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToolbarButton(
          icon: Icons.add_rounded,
          tooltip: AppPlatform.isMacOS ? 'New note  ⌘N' : 'New note  Ctrl+N',
          onPressed: onCreate,
        ),
        const SizedBox(width: 2),
        _ToolbarButton(
          icon: Icons.people_outline_rounded,
          tooltip: noteShared ? 'Sharing' : 'Share note',
          onPressed: onShare,
        ),
      ],
    );
  }

  Widget _menuButton() => _ToolbarButton(
    icon: Icons.menu_rounded,
    tooltip: sidebarVisible ? 'Hide notes' : 'Show notes',
    onPressed: onToggleSidebar,
  );
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

  /// Null greys the action out rather than removing it.
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return CompactIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      selected: selected,
      foregroundColor: onPressed == null
          ? palette.textTertiary
          : selected
          ? palette.textPrimary
          : palette.textSecondary,
      icon: Icon(icon, size: AppControlMetrics.iconAction),
    );
  }
}
