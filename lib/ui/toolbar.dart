import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/update_checker.dart';
import '../sync/presence.dart';
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
    this.onSettingsPressed,
    this.onShare,
    this.assistant,
    this.sidebarVisible = true,
    this.sidebarShortcut,
    this.settingsShortcut,
    this.showActions = true,
    this.newNoteShortcut,
    this.mascotController,
    this.members = const [],
    this.present = const [],
    this.currentUserId = '',
    this.noteShared = false,
    this.updates,
  });

  final VoidCallback onToggleSidebar;
  final VoidCallback onCreate;
  final VoidCallback? onSettingsPressed;

  /// Shares the note that is open. Null while nothing is selected, which
  /// leaves the action in place but greyed rather than moving the ones beside
  /// it every time the selection changes.
  final VoidCallback? onShare;

  /// Kapy AI's button, first of the note's actions. It keeps its own gap, so
  /// it can hide while Kapy AI is off without leaving one behind.
  final Widget? assistant;

  final bool sidebarVisible;

  /// The user's current chord for showing or hiding the notes list.
  /// Kept beside the action so a hover teaches the shortcut in either the
  /// wide sidebar or compact drawer layout.
  final String? sidebarShortcut;

  /// The current chord for opening Settings, taught by the adjacent gear.
  final String? settingsShortcut;
  final bool showActions;

  /// The current chord for a new note, taught by the + button's tooltip.
  final String? newNoteShortcut;

  /// Drives the optional animated mark without changing toolbar geometry.
  final KapyHeaderController? mascotController;

  /// Everyone the open note is shared with. Empty on a personal note, which
  /// is what keeps that note's title bar as quiet as it has always been.
  final List<SpaceMember> members;

  /// Whoever else has the open note up right now, drawn first and ringed in
  /// the colour of their caret.
  final List<Collaborator> present;

  /// Whose account this is, so one avatar can read "You".
  final String currentUserId;

  /// Whether the open note lives in a shared space, which is what the share
  /// action's wording turns on.
  final bool noteShared;

  /// Offers "Update and restart" once a release has downloaded. Null where
  /// the app does not update itself.
  final UpdateChecker? updates;

  /// Wide enough for the update button to say what it does in full. Below
  /// this it would run into the centred lockup, so it shortens to "Update".
  static const double _updateLabelWidth = 680;

  static double get height => AppControlMetrics.toolbarHeight;

  /// Between an edge action and the bar's edge.
  static const double _edgeGap = 9;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // On a device with a status bar over the window, the toolbar's background
    // runs underneath it while its contents sit below.
    final topInset = MediaQuery.paddingOf(context).top;
    // Grows with Dynamic Type so the wordmark is never cropped by its own bar.
    final barHeight = AppControlMetrics.scaleBar(context, height);

    return GlassSurface(
      color: palette.surfaceBackground.withMultipliedAlpha(0.94),
      border: Border(
        bottom: BorderSide(
          color: palette.separator,
          width: AppHairline.of(context),
        ),
      ),
      child: SizedBox(
        height: barHeight + topInset,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final desiredLeadingRight =
                constraints.maxWidth / 2 + _centreReserve;
            final fixedLeadingWidth =
                AppControlMetrics.iconButtonSlotExtent *
                    (onSettingsPressed == null ? 1 : 2) +
                (onSettingsPressed == null ? 0 : 2);
            final leadingRight = math.max(
              0.0,
              math.min(
                desiredLeadingRight,
                constraints.maxWidth - _edgeGap - fixedLeadingWidth,
              ),
            );

            return Stack(
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
                        // The lockup carries its own drag region:
                        // DragToMoveArea waits out the double-tap timeout
                        // before it yields, so a button beneath it answers late
                        // on every single click.
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
                    left: _edgeGap,
                    // Stops short of the lockup when there is room. On the
                    // narrowest phones, reserve the two fixed actions first;
                    // avatars still give up circles, then names, to fit.
                    right: leadingRight,
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
                    child: _trailing(
                      wide: constraints.maxWidth >= _updateLabelWidth,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

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
  /// The menu leads on every platform, so the notes list opens from the same
  /// corner everywhere.
  Widget _leading() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _menuButton(),
        if (onSettingsPressed != null) ...[
          const SizedBox(width: 2),
          _ToolbarButton(
            key: const ValueKey('toolbar-settings'),
            icon: KapyIcons.settingsOutlined,
            tooltip: ['Settings', ?settingsShortcut].join('  '),
            onPressed: onSettingsPressed,
          ),
        ],
        if (members.isNotEmpty)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: MemberAvatars(
                members: members,
                present: present,
                currentUserId: currentUserId,
                onPressed: onShare,
              ),
            ),
          ),
      ],
    );
  }

  Widget _trailing({required bool wide}) {
    final updates = this.updates;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (updates != null) UpdateRestartButton(updates: updates, wide: wide),
        ?assistant,
        _ToolbarButton(
          icon: KapyIcons.addRounded,
          tooltip: ['New note', ?newNoteShortcut].join('  '),
          onPressed: onCreate,
        ),
        const SizedBox(width: 2),
        _ToolbarButton(
          icon: KapyIcons.peopleOutlined,
          tooltip: noteShared ? 'Sharing' : 'Share note',
          onPressed: onShare,
        ),
      ],
    );
  }

  Widget _menuButton() => _ToolbarButton(
    key: const ValueKey('toolbar-notes-toggle'),
    icon: KapyIcons.menuRounded,
    tooltip: [
      sidebarVisible ? 'Hide notes' : 'Show notes',
      ?sidebarShortcut,
    ].join('  '),
    onPressed: onToggleSidebar,
  );
}

/// "Update and restart", the whole of an update once a release has downloaded
/// and passed its checks.
///
/// In the title bar because the title bar is always there: the notes list
/// starts every launch closed, so a button inside it would first need the
/// list opened. Draws nothing at all until there is something to install,
/// and listens to the checker itself, so a download counting up its percent
/// rebuilds this and not the page under it.
class UpdateRestartButton extends StatelessWidget {
  const UpdateRestartButton({
    super.key,
    required this.updates,
    required this.wide,
  });

  final UpdateChecker updates;
  final bool wide;

  Future<void> _install(BuildContext context) async {
    if (await updates.installAndRestart() || !context.mounted) return;
    Toast.show(
      context,
      updates.downloadError ?? 'Could not install the update',
      icon: KapyIcons.errorOutlined,
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      final staged = updates.staged;
      if (staged == null) return const SizedBox.shrink();
      final palette = context.palette;
      final installing = updates.isInstalling;
      final label = installing
          ? 'Restarting…'
          : wide
          ? 'Update and restart'
          : 'Update';
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Tooltip(
          message: 'Install Kapy Notes ${staged.version} and restart',
          child: TextButton.icon(
            key: const ValueKey('toolbar-update-restart'),
            onPressed: installing ? null : () => unawaited(_install(context)),
            icon: KapyIcon(
              KapyIcons.systemUpdateRounded,
              size: 14,
              color: installing ? palette.textTertiary : palette.chipCurrency,
            ),
            label: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                fontWeight: FontWeight.w500,
                fontVariations: AppWeight.variations(AppWeight.rowTitle),
              ),
            ),
            style: TextButton.styleFrom(
              foregroundColor: palette.chipCurrency,
              disabledForegroundColor: palette.textTertiary,
              backgroundColor: palette.selectedBackground,
              minimumSize: Size(0, AppControlMetrics.iconButtonExtent),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              shape: StadiumBorder(
                side: BorderSide(
                  color: palette.chipCurrency.withValues(alpha: 0.35),
                  width: AppHairline.of(context),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String tooltip;

  /// Null greys the action out rather than removing it.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return CompactIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      foregroundColor: onPressed == null
          ? palette.textTertiary
          : palette.textSecondary,
      icon: KapyIcon(icon, size: AppControlMetrics.iconAction),
    );
  }
}
