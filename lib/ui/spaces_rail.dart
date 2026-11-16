import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/window_chrome.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import '../data/writing_streak.dart';
import '../sync/auth_api.dart';
import '../sync/sync_service.dart';
import 'installed_version.dart';
import 'profile_avatar.dart';
import 'sidebar.dart' show archiveIcon;
import 'streak_badge.dart';
import 'window_drag_area.dart';

/// What the notes list beside the spaces rail can show.
enum LibrarySpace {
  notes,
  drawings,
  shared,
  hidden,
  archive;

  /// The space's name over the list while it shows the space: the rail's
  /// own word for it, except that the person's notes are "My notes".
  String get title => switch (this) {
    LibrarySpace.notes => 'My notes',
    LibrarySpace.drawings => 'Drawings',
    LibrarySpace.shared => 'Shared',
    LibrarySpace.hidden => 'Hidden',
    LibrarySpace.archive => 'Archive',
  };
}

/// The column down the window's left edge: the spaces the notes list can
/// show, and at its foot the writing streak, settings and the account.
///
/// It holds what the list used to carry around its notes: the My Notes and
/// Shared with Me tabs, the Hidden Notes and archive rows, the way into
/// settings, and the streak from the heading over the list. Each still does
/// what it did there.
///
/// On macOS it starts under the traffic lights, keeping their strip clear and
/// letting the window be dragged by it. Windows draws its controls in a title
/// bar of its own, so there the rail starts at the top.
class SpacesRail extends StatelessWidget {
  const SpacesRail({
    super.key,
    required this.space,
    required this.onSelected,
    required this.onSettingsPressed,
    this.invitations,
    this.showHidden = false,
    this.hiddenShortcut,
    this.streak,
    this.settingsShortcut,
    this.updates,
    this.onAccountPressed,
    this.user,
    this.syncStatus,
  });

  /// The space the list is showing.
  final LibrarySpace space;
  final ValueChanged<LibrarySpace> onSelected;
  final VoidCallback onSettingsPressed;

  /// How many invitations are waiting under Shared, counted on its badge.
  ///
  /// Null leaves Shared off the rail. Until an account is unlocked there are
  /// no other people's notes to show, as the tabs this replaces had nothing
  /// for their second half.
  final int? invitations;

  /// Whether Hidden Notes has a place on the rail: while the setting that
  /// shows the folder is on and something is in it, and whenever the list is
  /// showing it.
  final bool showHidden;

  /// The chord that shows or hides Hidden Notes' place, taught by its
  /// tooltip.
  final ShortcutBinding? hiddenShortcut;

  /// The run of days something has been written. Left out while there is no
  /// run to show: a zero would be a reproach rather than a record.
  final WritingStreak? streak;

  final ShortcutBinding? settingsShortcut;

  /// Puts a dot on settings while a release waits to be looked at. Null where
  /// an app store owns updates.
  final UpdateChecker? updates;

  /// Opens Profile & sync. Null leaves the account off the rail, as a build
  /// with no sync server has no account to show.
  final VoidCallback? onAccountPressed;

  /// Who is signed in, for the avatar. Null while nobody is.
  final AccountUser? user;

  /// How sync is doing, for the dot on the avatar. Null while nothing syncs:
  /// signed out, or not unlocked yet.
  final SyncStatus? syncStatus;

  static const double width = 76;

  /// The strip macOS draws the traffic lights in. As tall as the bar over the
  /// notes list, so the two read as one title bar across the window.
  static const double titleBarHeight = 52;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final invitations = this.invitations;
    final hiddenShortcut = this.hiddenShortcut;
    final streak = this.streak;
    final onAccountPressed = this.onAccountPressed;

    Widget destination(
      LibrarySpace destination, {
      required KapyIconData icon,
      required String label,
      String? tooltip,
      String? semanticLabel,
      int badge = 0,
    }) => _RailItem(
      key: ValueKey('rail-${destination.name}'),
      icon: icon,
      label: label,
      selected: destination == space,
      onPressed: () => onSelected(destination),
      tooltip: tooltip,
      semanticLabel: semanticLabel,
      badge: badge,
    );

    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: palette.railBackground,
          border: Border(right: BorderSide(color: palette.railBorder)),
        ),
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              if (WindowChrome.overlaysContent)
                const WindowDragArea(
                  child: SizedBox(
                    width: double.infinity,
                    height: titleBarHeight,
                  ),
                ),
              const SizedBox(height: 6),
              destination(
                LibrarySpace.notes,
                icon: KapyIcons.noteOutlined,
                label: 'Notes',
              ),
              const SizedBox(height: 4),
              destination(
                LibrarySpace.drawings,
                icon: KapyIcons.penRounded,
                label: 'Drawings',
              ),
              if (invitations != null) ...[
                const SizedBox(height: 4),
                destination(
                  LibrarySpace.shared,
                  icon: KapyIcons.groupOutlined,
                  label: 'Shared',
                  semanticLabel: switch (invitations) {
                    0 => 'Shared with me',
                    1 => 'Shared with me, 1 invitation',
                    _ => 'Shared with me, $invitations invitations',
                  },
                  badge: invitations,
                ),
              ],
              if (showHidden) ...[
                const SizedBox(height: 4),
                destination(
                  LibrarySpace.hidden,
                  icon: KapyIcons.lockRounded,
                  label: 'Hidden',
                  tooltip: hiddenShortcut == null
                      ? 'Hidden Notes'
                      : 'Hidden Notes · ${hiddenShortcut.displayLabel}',
                  semanticLabel: 'Hidden Notes',
                ),
              ],
              const SizedBox(height: 4),
              destination(
                LibrarySpace.archive,
                icon: archiveIcon,
                label: 'Archive',
                semanticLabel: 'Archived Notes',
              ),
              const Expanded(child: WindowDragArea(child: SizedBox.expand())),
              if (streak != null && streak.days > 0) ...[
                _RailStreak(key: const ValueKey('rail-streak'), streak: streak),
                const SizedBox(height: 7.5),
              ],
              _RailSettings(
                onPressed: onSettingsPressed,
                shortcut: settingsShortcut,
                updates: updates,
              ),
              if (onAccountPressed != null) ...[
                const SizedBox(height: 7.5),
                _RailAccount(
                  onPressed: onAccountPressed,
                  user: user,
                  syncStatus: syncStatus,
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// One space on the rail: an icon on a tile with its name under it, the tile
/// in sage while the list shows the space.
class _RailItem extends StatefulWidget {
  const _RailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.tooltip,
    this.semanticLabel,
    this.badge = 0,
  });

  final KapyIconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final String? tooltip;
  final String? semanticLabel;

  /// A count on the tile's corner, drawn while it is above zero.
  final int badge;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selected = widget.selected;
    final lit = _hovered || _focused;
    final ink = selected
        ? palette.tonalForeground
        : lit
        ? palette.textSecondary
        : palette.textTertiary;
    final touch = !AppPlatform.hasPointer;

    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      width: touch ? 48 : 44,
      height: touch ? 44 : 40,
      decoration: BoxDecoration(
        color: selected
            ? palette.tonalBackground
            : palette.hover.withValues(alpha: lit ? 1 : 0),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          KapyIcon(widget.icon, size: 19, strokeWidth: 1.7, color: ink),
          if (widget.badge > 0)
            Positioned(top: 2, right: 2, child: _Badge(count: widget.badge)),
        ],
      ),
    );

    final item = Semantics(
      container: true,
      button: true,
      selected: selected,
      label: widget.semanticLabel ?? widget.label,
      child: InkWell(
        onTap: widget.onPressed,
        onHover: (value) => setState(() => _hovered = value),
        onFocusChange: (value) => setState(() => _focused = value),
        mouseCursor: SystemMouseCursors.click,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        child: ExcludeSemantics(
          child: SizedBox(
            width: SpacesRail.width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                tile,
                const SizedBox(height: 5),
                Text(
                  widget.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? palette.textPrimary
                        : lit
                        ? palette.textSecondary
                        : palette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final tooltip = widget.tooltip;
    return tooltip == null ? item : Tooltip(message: tooltip, child: item);
  }
}

/// How many invitations are waiting, on Shared's corner.
class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const ValueKey('rail-shared-badge'),
      height: 17,
      constraints: const BoxConstraints(minWidth: 17),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.clay,
        borderRadius: BorderRadius.circular(9),
        // The rail's own colour, so the badge reads as cut out of the tile.
        border: Border.all(color: palette.railBackground, width: 2),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: AppTypeScale.micro,
          height: 1,
          fontWeight: FontWeight.w600,
          color: palette.sidebarBackground,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The writing streak: a flame over how many days in a row.
///
/// The same run [StreakBadge] shows in a list's heading, and it behaves the
/// same way: lit in clay once today has been written in, waiting in grey
/// until then, flaring for a moment as it catches.
class _RailStreak extends StatelessWidget {
  const _RailStreak({super.key, required this.streak});

  final WritingStreak streak;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final lit = streak.wroteToday ? 1.0 : 0.0;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final days = streak.days;

    return Semantics(
      container: true,
      child: Tooltip(
        message: StreakBadge.describe(streak),
        triggerMode: TooltipTriggerMode.tap,
        child: ExcludeSemantics(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: lit, end: lit),
            duration: still ? Duration.zero : const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(
                  scale: streak.wroteToday
                      ? 1 + 0.3 * math.sin(math.pi * t)
                      : 1,
                  alignment: Alignment.bottomCenter,
                  child: KapyIcon(
                    KapyIcons.fireOutlined,
                    size: 18,
                    strokeWidth: 1.7,
                    color: Color.lerp(palette.textTertiary, palette.clay, t),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  days == 1 ? '1 day' : '$days days',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Color.lerp(
                      palette.textTertiary,
                      palette.textPrimary,
                      t,
                    ),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The way into settings, with a dot while a release waits to be looked at.
class _RailSettings extends StatelessWidget {
  const _RailSettings({required this.onPressed, this.shortcut, this.updates});

  final VoidCallback onPressed;
  final ShortcutBinding? shortcut;
  final UpdateChecker? updates;

  @override
  Widget build(BuildContext context) {
    final shortcut = this.shortcut;
    return InstalledVersion(
      updates: updates,
      builder: (context, version, updateWaiting) {
        final palette = context.palette;
        final name = shortcut == null
            ? 'Settings'
            : 'Settings · ${shortcut.displayLabel}';
        final detail = [
          if (version.isNotEmpty) 'v$version',
          if (updateWaiting) 'Update available',
        ].join(' · ');
        return Tooltip(
          message: detail.isEmpty ? name : '$name\n$detail',
          child: Semantics(
            container: true,
            button: true,
            // The dot is the one part of this a screen reader cannot see.
            label: updateWaiting ? 'Settings, update available' : 'Settings',
            child: _RailButton(
              key: const ValueKey('rail-settings'),
              onPressed: onPressed,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  KapyIcon(
                    KapyIcons.settingsGearOutlined,
                    size: 19,
                    strokeWidth: 1.7,
                    color: palette.textTertiary,
                  ),
                  if (updateWaiting)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _Dot(
                        key: const ValueKey('rail-update-badge'),
                        color: palette.clay,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Who is signed in, with a dot that says how sync is doing. Opens Profile
/// & sync.
class _RailAccount extends StatelessWidget {
  const _RailAccount({required this.onPressed, this.user, this.syncStatus});

  final VoidCallback onPressed;
  final AccountUser? user;
  final SyncStatus? syncStatus;

  static const double _extent = 32;

  String? get _status => switch (syncStatus) {
    null => null,
    SyncStatus.idle => 'Synced',
    SyncStatus.syncing => 'Syncing…',
    SyncStatus.offline => 'Offline. Will retry',
    SyncStatus.signedOut => 'Session expired. Sign in again',
    SyncStatus.locked => 'Locked',
    SyncStatus.outdated => 'Sync needs a newer version',
    SyncStatus.failed => 'Sync failed',
  };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final user = this.user;
    final name = user == null
        ? ''
        : user.name.isNotEmpty
        ? user.name
        : user.email;
    final status = _status;
    // Sage while notes are going where they should, grey while the network
    // is away, and the theme's error once it needs the reader.
    final dot = switch (syncStatus) {
      null => null,
      SyncStatus.idle ||
      SyncStatus.syncing => Theme.of(context).colorScheme.primary,
      SyncStatus.offline => palette.textTertiary,
      _ => Theme.of(context).colorScheme.error,
    };
    final photo = user?.image;

    final Widget face;
    if (user != null && photo != null && photo.startsWith('data:image/')) {
      face = ProfileAvatar(
        seed: user.id,
        name: name,
        extent: _extent,
        image: photo,
      );
    } else {
      face = Container(
        width: _extent,
        height: _extent,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.controlBackground,
          shape: BoxShape.circle,
        ),
        child: user == null
            ? KapyIcon(
                KapyIcons.accountCircleOutlined,
                size: 18,
                color: palette.textTertiary,
              )
            : Text(
                _initial(name),
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: AppTypeScale.control,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
      );
    }

    return Tooltip(
      message: [name.isEmpty ? 'Profile & sync' : name, ?status].join('\n'),
      child: Semantics(
        container: true,
        button: true,
        label: ['Profile & sync', ?status].join(', '),
        child: InkWell(
          key: const ValueKey('rail-account'),
          onTap: onPressed,
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          splashFactory: NoSplash.splashFactory,
          child: ExcludeSemantics(
            child: SizedBox.square(
              dimension: _extent,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  face,
                  if (dot != null)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: _Dot(
                        key: const ValueKey('rail-sync-dot'),
                        color: dot,
                        diameter: 10,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _initial(String value) {
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (char.trim().isNotEmpty) return char.toUpperCase();
    }
    return '?';
  }
}

/// A round control at the rail's foot: the glyph alone until it is hovered.
class _RailButton extends StatelessWidget {
  const _RailButton({super.key, required this.onPressed, required this.child});

  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onPressed,
    borderRadius: BorderRadius.circular(AppRadii.control),
    hoverColor: context.palette.hover,
    focusColor: context.palette.hover,
    highlightColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    mouseCursor: SystemMouseCursors.click,
    child: ExcludeSemantics(
      child: SizedBox.square(dimension: 32, child: child),
    ),
  );
}

/// A small mark on a control's corner, ringed in the rail's colour so it
/// reads as set into the control rather than laid over it.
class _Dot extends StatelessWidget {
  const _Dot({super.key, required this.color, this.diameter = 9});

  final Color color;
  final double diameter;

  @override
  Widget build(BuildContext context) => Container(
    width: diameter,
    height: diameter,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: context.palette.railBackground, width: 2),
    ),
  );
}
