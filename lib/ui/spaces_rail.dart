import 'dart:async';
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
import 'context_menu.dart';
import 'installed_version.dart';
import 'profile_avatar.dart';
import 'window_drag_area.dart';

/// What the notes list beside the spaces rail can show.
enum LibrarySpace {
  notes,
  tasks,
  drawings,
  shared;

  /// The space's name over the list while it shows the space: the rail's
  /// own word for it, except that the person's notes are "My notes".
  String get title => switch (this) {
    LibrarySpace.notes => 'My notes',
    LibrarySpace.tasks => 'Tasks',
    LibrarySpace.drawings => 'Drawings',
    LibrarySpace.shared => 'Shared',
  };
}

/// The column down the window's left edge: the spaces the notes list can
/// show, and at its foot the writing streak, settings and the account.
///
/// It holds what the list used to carry around its notes: the My Notes and
/// Shared with Me tabs, the way into settings, and the streak from the
/// heading over the list. Each still does what it did there. Hidden Notes and
/// the archive are not places of their own: they are the first group of the
/// notes filter.
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
    this.openTasks,
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

  /// How many tasks are on the list, counted on Tasks' badge. Null leaves
  /// Tasks off the rail, as a build with no task index has none.
  final int? openTasks;

  /// The run of days something has been written. Left out while there is no
  /// run to show: a zero would be a reproach rather than a record.
  final WritingStreak? streak;

  final ShortcutBinding? settingsShortcut;

  /// Puts a dot on settings while a release waits to be looked at. Null where
  /// an app store owns updates.
  final UpdateChecker? updates;

  /// Opens Account & sync. Null leaves the account off the rail, as a build
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
    final streak = this.streak;
    final onAccountPressed = this.onAccountPressed;
    final openTasks = this.openTasks;

    Widget destination(
      LibrarySpace destination, {
      required KapyIconData icon,
      required String label,
      String? semanticLabel,
      int badge = 0,
    }) => _RailItem(
      key: ValueKey('rail-${destination.name}'),
      icon: icon,
      label: label,
      selected: destination == space,
      onPressed: () => onSelected(destination),
      semanticLabel: semanticLabel,
      badge: badge,
    );

    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: width + MediaQuery.paddingOf(context).left,
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
              // The spaces scroll rather than overflow in the shortest window,
              // and the room under them drags the window.
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          children: [
                            const SizedBox(height: 8),
                            destination(
                              LibrarySpace.notes,
                              icon: KapyIcons.noteOutlined,
                              label: 'Notes',
                            ),
                            if (openTasks != null) ...[
                              const SizedBox(height: 16),
                              destination(
                                LibrarySpace.tasks,
                                icon: KapyIcons.tasksOutlined,
                                label: 'Tasks',
                                semanticLabel: switch (openTasks) {
                                  0 => 'Tasks',
                                  1 => 'Tasks, 1 open',
                                  _ => 'Tasks, $openTasks open',
                                },
                                badge: openTasks,
                              ),
                            ],
                            const SizedBox(height: 16),
                            destination(
                              LibrarySpace.drawings,
                              icon: KapyIcons.penRounded,
                              label: 'Drawings',
                            ),
                            if (invitations != null) ...[
                              const SizedBox(height: 16),
                              destination(
                                LibrarySpace.shared,
                                icon: KapyIcons.groupOutlined,
                                label: 'Shared',
                                semanticLabel: switch (invitations) {
                                  0 => 'Shared with me',
                                  1 => 'Shared with me, 1 invitation',
                                  _ =>
                                    'Shared with me, $invitations invitations',
                                },
                                badge: invitations,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: WindowDragArea(child: SizedBox.expand()),
                      ),
                    ],
                  ),
                ),
              ),
              if (streak != null && streak.days > 0) ...[
                StreakMark(key: const ValueKey('rail-streak'), streak: streak),
                const SizedBox(height: 7.5),
              ],
              _RailSettings(
                onPressed: onSettingsPressed,
                shortcut: settingsShortcut,
                updates: updates,
              ),
              if (onAccountPressed != null) ...[
                const SizedBox(height: 7.5),
                AccountAvatar(
                  key: const ValueKey('rail-account'),
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

/// The words on the rail: a space's name under its tile, and the streak's
/// run of days under its flame.
TextStyle _railLabel(Color color, {required bool strong}) => TextStyle(
  fontSize: AppTypeScale.caption,
  height: 16 / 12,
  fontWeight: AppWeight.font(strong ? AppWeight.button : AppWeight.body),
  fontVariations: AppWeight.wght(strong ? AppWeight.button : AppWeight.body),
  color: color,
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// One space on the rail: an icon on a tile with its name under it, the tile
/// in sage while the list shows the space.
class _RailItem extends StatefulWidget {
  const _RailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.semanticLabel,
    this.badge = 0,
  });

  final KapyIconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
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
        ? palette.textPrimary
        : palette.textSecondary;
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
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          KapyIcon(widget.icon, size: 20, color: ink),
          if (widget.badge > 0)
            Positioned(
              top: 2,
              right: 2,
              child: _Badge(
                key: ValueKey(
                  '${(widget.key! as ValueKey<String>).value}-badge',
                ),
                count: widget.badge,
              ),
            ),
        ],
      ),
    );

    return Semantics(
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
                const SizedBox(height: 4),
                Text(
                  widget.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: _railLabel(
                    selected || lit
                        ? palette.textPrimary
                        : palette.textSecondary,
                    strong: selected,
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

/// A count on a space's corner: invitations waiting under Shared, tasks
/// open under Tasks.
class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: 16,
      constraints: const BoxConstraints(minWidth: 16),
      // Inside the ring, which the decoration adds to it.
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.clay,
        borderRadius: BorderRadius.circular(AppRadii.control),
        // The rail's own colour, so the badge reads as cut out of the tile.
        border: Border.all(color: palette.railBackground, width: 2),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: AppTypeScale.micro,
          height: 12 / 11,
          fontWeight: AppWeight.font(AppWeight.button),
          fontVariations: AppWeight.wght(AppWeight.button),
          color: palette.sidebarBackground,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The writing streak: a flame and how many days in a row, lit in clay once
/// today has been written in, waiting in grey until then, flaring for a
/// moment as it catches. Over its count on the rail, beside it on a phone's
/// Home.
class StreakMark extends StatelessWidget {
  const StreakMark({super.key, required this.streak, this.inline = false});

  final WritingStreak streak;

  /// A phone's Home header: the flame before the count, at the header's size.
  final bool inline;

  /// What the tooltip says, and so what a screen reader hears.
  static String describe(WritingStreak streak) => streak.wroteToday
      ? '${streak.days}-day writing streak'
      : 'Write today to keep your ${streak.days}-day streak';

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final lit = streak.wroteToday ? 1.0 : 0.0;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final days = streak.days;

    return Semantics(
      container: true,
      child: Tooltip(
        message: describe(streak),
        triggerMode: TooltipTriggerMode.tap,
        child: ExcludeSemantics(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: lit, end: lit),
            duration: still ? Duration.zero : const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) {
              final ink = Color.lerp(
                palette.textTertiary,
                palette.textPrimary,
                t,
              )!;
              final flame = Transform.scale(
                scale: streak.wroteToday ? 1 + 0.3 * math.sin(math.pi * t) : 1,
                alignment: Alignment.bottomCenter,
                child: KapyIcon(
                  KapyIcons.fireOutlined,
                  size: 16,
                  color: Color.lerp(palette.textTertiary, palette.clay, t),
                ),
              );
              final label = Text(
                days == 1 ? '1 day' : '$days days',
                maxLines: 1,
                softWrap: false,
                style: inline
                    ? TextStyle(
                        fontFamily: AppFonts.ui,
                        fontSize: 13,
                        height: 16 / 13,
                        fontWeight: AppWeight.font(AppWeight.button),
                        fontVariations: AppWeight.wght(AppWeight.button),
                        color: ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )
                    : _railLabel(ink, strong: true),
              );
              return inline
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [flame, label],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [flame, const SizedBox(height: 4), label],
                    );
            },
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
                    size: 20,
                    color: palette.textSecondary,
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

/// Who is signed in, with a dot that says how sync is doing: the rail's way
/// to Account & sync, and a phone Home's way to Settings.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({
    super.key,
    required this.onPressed,
    this.label = 'Account & sync',
    this.user,
    this.syncStatus,
    this.target = _extent,
  });

  final VoidCallback onPressed;

  /// The square a tap lands in, the circle at its centre: 44 on a phone,
  /// where every target is.
  final double target;

  /// What a tap opens, for a screen reader, and the tooltip while nobody is
  /// signed in.
  final String label;
  final AccountUser? user;
  final SyncStatus? syncStatus;

  static const double _extent = 32;

  String? get _status => switch (syncStatus) {
    null => null,
    SyncStatus.idle => 'Synced',
    SyncStatus.syncing => 'Syncing…',
    SyncStatus.offline => 'Offline. Will retry',
    SyncStatus.signedOut => 'Checking your sign-in. Will retry',
    SyncStatus.locked => 'Locked',
    SyncStatus.outdated => 'Sync needs a newer version',
    SyncStatus.keysChanged => 'Waiting for your new passphrase',
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
      SyncStatus.offline || SyncStatus.keysChanged => palette.textTertiary,
      _ => Theme.of(context).colorScheme.error,
    };
    final photo = user?.image;

    final Widget face;
    if (user != null && photo != null && photo.startsWith('data:image/')) {
      face = ProfileAvatar(name: name, extent: _extent, image: photo);
    } else {
      final line = palette.raisedBorder;
      face = Container(
        width: _extent,
        height: _extent,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.raisedBackground ?? palette.controlBackground,
          border: line == null ? null : Border.all(color: line),
          shape: BoxShape.circle,
        ),
        child: user == null
            ? KapyIcon(
                KapyIcons.accountCircleOutlined,
                size: 18,
                color: palette.textTertiary,
              )
            : Text(
                avatarInitial(name),
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: AppTypeScale.control,
                  height: 1,
                  fontWeight: AppWeight.font(AppWeight.button),
                  fontVariations: AppWeight.wght(AppWeight.button),
                  color: palette.textPrimary,
                ),
              ),
      );
    }

    return Tooltip(
      message: [name.isEmpty ? label : name, ?status].join('\n'),
      child: Semantics(
        container: true,
        button: true,
        label: [label, ?status].join(', '),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          splashFactory: NoSplash.splashFactory,
          child: ExcludeSemantics(
            child: SizedBox.square(
              dimension: target,
              child: Center(
                child: SizedBox.square(
                  key: const ValueKey('account-circle'),
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
        ),
      ),
    );
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

/// A phone's way around: the rail's destinations along the bottom, Settings
/// at the end, and the + beside them. A tap on the + makes what [space] holds
/// (on Tasks it adds a task); a long press offers [createActions], the rest of
/// the desktop's New. iOS floats a quiet pill over [child]; Android uses
/// Material's navigation bar and a floating action button.
class PhoneSpaces extends StatelessWidget {
  const PhoneSpaces({
    super.key,
    required this.space,
    required this.onSelected,
    required this.onSettingsPressed,
    required this.createLabel,
    required this.onCreate,
    required this.createActions,
    required this.onCreateAction,
    required this.child,
    this.showTasks = true,
  });

  final LibrarySpace space;
  final ValueChanged<LibrarySpace> onSelected;
  final VoidCallback onSettingsPressed;

  /// What a tap on the + makes, such as "New note".
  final String createLabel;
  final VoidCallback onCreate;
  final List<KapyMenuAction> createActions;
  final ValueChanged<String> onCreateAction;
  final Widget child;
  final bool showTasks;

  static const double _barHeight = 56;
  static const double _barLift = 30;
  static const double _plusExtent = 56;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final items = <({LibrarySpace? to, KapyIconData icon, String label})>[
      (to: LibrarySpace.notes, icon: KapyIcons.noteOutlined, label: 'Notes'),
      if (showTasks)
        (to: LibrarySpace.tasks, icon: KapyIcons.tasksOutlined, label: 'Tasks'),
      (
        to: LibrarySpace.drawings,
        icon: KapyIcons.penRounded,
        label: 'Drawings',
      ),
      (to: null, icon: KapyIcons.settingsGearOutlined, label: 'Settings'),
    ];
    void choose(LibrarySpace? to) =>
        to == null ? onSettingsPressed() : onSelected(to);
    final plus = Builder(
      builder: (context) => _PlusButton(
        label: createLabel,
        onPressed: onCreate,
        onLongPress: () => _showCreateMenu(context),
      ),
    );

    if (AppPlatform.isAndroid) {
      final selected = items.indexWhere((item) => item.to == space);
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: child,
        floatingActionButton: plus,
        bottomNavigationBar: NavigationBar(
          key: const ValueKey('phone-bar'),
          selectedIndex: math.max(0, selected),
          backgroundColor: palette.railBackground,
          indicatorColor: palette.fillSelected,
          surfaceTintColor: Colors.transparent,
          onDestinationSelected: (index) => choose(items[index].to),
          destinations: [
            for (final item in items)
              NavigationDestination(
                key: ValueKey('bar-${item.to?.name ?? 'settings'}'),
                icon: KapyIcon(
                  item.icon,
                  size: 20,
                  color: palette.textTertiary,
                ),
                selectedIcon: KapyIcon(
                  item.icon,
                  size: 20,
                  color: palette.textPrimary,
                ),
                label: item.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: child,
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, _barLift),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: items.length > 4 ? 360 : 300,
                ),
                // Opaque, because it floats over the list.
                child: Container(
                  key: const ValueKey('phone-bar'),
                  height: _barHeight,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      palette.fillRest,
                      palette.sidebarBackground,
                    ),
                    borderRadius: BorderRadius.circular(_barHeight / 2),
                    border: Border.all(
                      color: palette.edge,
                      width: AppHairline.of(context),
                    ),
                  ),
                  child: Row(
                    children: [
                      for (final item in items)
                        Expanded(
                          child: _BarItem(
                            key: ValueKey('bar-${item.to?.name ?? 'settings'}'),
                            icon: item.icon,
                            label: item.label,
                            selected: item.to == space,
                            onPressed: () => choose(item.to),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            plus,
          ],
        ),
      ),
    );
  }

  /// The rest of New, rising from the + where the thumb already is.
  void _showCreateMenu(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || createActions.isEmpty) return;
    unawaited(
      showKapyContextMenu<String>(
        context: context,
        globalPosition: box.localToGlobal(Offset(box.size.width, 0)),
        items: [
          for (final action in createActions)
            PopupMenuItem(
              key: ValueKey('phone-new-${action.value}'),
              value: action.value,
              enabled: action.enabled,
              height: 44,
              child: KapyMenuActionRow(action, touch: true),
            ),
        ],
      ).then((choice) {
        if (choice != null) onCreateAction(choice);
      }),
    );
  }
}

/// One of the bar's destinations: its icon over its name in a 46 pt pill,
/// lifted a step while it is the one on screen.
class _BarItem extends StatelessWidget {
  const _BarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = selected ? palette.textPrimary : palette.textTertiary;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: selected ? palette.fillSelected : null,
              borderRadius: BorderRadius.circular(23),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                KapyIcon(icon, size: 20, color: ink),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  // The pill is a fixed 46 pt, as iOS's tab bar is, and
                  // keeps its labels near their size for the same
                  // reason: past this they no longer fit under the icon.
                  textScaler: MediaQuery.textScalerOf(
                    context,
                  ).clamp(maxScaleFactor: 1.3),
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 13 / 10.5,
                    fontWeight: AppWeight.font(
                      selected ? AppWeight.section : AppWeight.button,
                    ),
                    fontVariations: AppWeight.wght(
                      selected ? AppWeight.section : AppWeight.button,
                    ),
                    color: ink,
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

/// The phone's one main action: a round + in the accent.
class _PlusButton extends StatelessWidget {
  const _PlusButton({
    required this.label,
    required this.onPressed,
    required this.onLongPress,
  });

  final String label;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      onLongPressHint: 'More to make',
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('phone-new'),
        color: scheme.primary,
        shape: const CircleBorder(),
        elevation: AppPlatform.isAndroid ? 3 : 0,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          onLongPress: onLongPress,
          splashFactory: AppPlatform.isAndroid ? null : NoSplash.splashFactory,
          child: SizedBox.square(
            dimension: PhoneSpaces._plusExtent,
            child: Center(
              child: KapyIcon(
                KapyIcons.addRounded,
                size: 22,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
