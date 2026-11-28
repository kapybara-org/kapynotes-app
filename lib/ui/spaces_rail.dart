import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../core/window_chrome.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import '../data/writing_streak.dart';
import '../sync/auth_api.dart';
import '../sync/sync_service.dart';
import 'context_menu.dart';
import 'focus_ring.dart';
import 'installed_version.dart';
import 'phone_home_header.dart' show PhoneTitleBar;
import 'profile_avatar.dart';
import 'sidebar.dart' show SidebarSearchField;
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
    this.tasks = false,
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

  /// Whether Tasks is on the rail: a build with no task index has none. It
  /// carries no count, as D01 draws it; only Shared has a badge.
  final bool tasks;

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

    return FocusTraversalGroup(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: width + MediaQuery.paddingOf(context).left,
          decoration: BoxDecoration(
            color: palette.railBackground,
            border: Border(
              right: BorderSide(
                color: palette.paneEdge,
                width: AppHairline.of(context),
              ),
            ),
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
                              if (tasks) ...[
                                const SizedBox(height: 8),
                                destination(
                                  LibrarySpace.tasks,
                                  icon: KapyIcons.tasksOutlined,
                                  label: 'Tasks',
                                ),
                              ],
                              const SizedBox(height: 8),
                              destination(
                                LibrarySpace.drawings,
                                icon: KapyIcons.penRounded,
                                label: 'Drawings',
                              ),
                              if (invitations != null) ...[
                                const SizedBox(height: 8),
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
                  StreakMark(
                    key: const ValueKey('rail-streak'),
                    streak: streak,
                  ),
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
      ),
    );
  }
}

/// The words on the rail: a space's name under its icon, and the streak's
/// run of days under its flame. 11 on a Mac, a floor above that elsewhere.
TextStyle _railLabel(Color color) => chromeStyle(
  size: 11.5,
  line: 14,
  weight: AppWeight.regular,
  color: color,
  tabular: true,
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selected = widget.selected;
    final lit = _hovered;
    final ink = selected || lit ? palette.textPrimary : palette.textSecondary;

    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: selected
            ? palette.selectedBackground
            : lit
            ? palette.hover
            : null,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              KapyIcon(widget.icon, size: 22, color: ink),
              const SizedBox(height: 5),
              Text(
                widget.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: _railLabel(ink),
              ),
            ],
          ),
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
        mouseCursor: SystemMouseCursors.click,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        child: ExcludeSemantics(
          child: SizedBox(
            width: SpacesRail.width,
            child: Center(
              child: FocusRingTarget(radius: AppRadii.control, child: tile),
            ),
          ),
        ),
      ),
    );
  }
}

/// A count on a space's corner: invitations waiting under Shared.
class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 18,
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: waitingMarker,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        boxShadow: [
          BoxShadow(color: context.palette.railBackground, spreadRadius: 2),
        ],
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textScaler: TextScaler.noScaling,
        style: chromeStyle(
          size: 11,
          line: 18,
          weight: AppWeight.semibold,
          color: const Color(0xFFFFFFFF),
          tabular: true,
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
              final ink = palette.textTertiary;
              final flame = Transform.scale(
                scale: streak.wroteToday ? 1 + 0.3 * math.sin(math.pi * t) : 1,
                alignment: Alignment.bottomCenter,
                child: KapyIcon(
                  KapyIcons.fireOutlined,
                  size: inline ? 14 : 16,
                  color: Color.lerp(palette.textTertiary, palette.accent, t),
                ),
              );
              final label = Text(
                days == 1 ? '1 day' : '$days days',
                maxLines: 1,
                softWrap: false,
                style: inline
                    ? chromeStyle(
                        size: 13,
                        line: 16,
                        weight: AppWeight.regular,
                        color: ink,
                        tabular: true,
                      )
                    : _railLabel(ink),
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
                    size: 18,
                    color: palette.textSecondary,
                  ),
                  if (updateWaiting)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _Dot(
                        key: const ValueKey('rail-update-badge'),
                        color: Theme.of(context).colorScheme.error,
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
      face = Container(
        width: _extent,
        height: _extent,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
        ).copyWith(color: palette.controlBackground),
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
                  fontWeight: AppWeight.font(AppWeight.regular),
                  fontVariations: AppWeight.wght(AppWeight.regular),
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

/// The tabs along a phone's bar (M01): Notes, which holds Home and the Tasks
/// title beside it, Folders, which holds Drawings, and Kapy AI.
enum PhoneTab { notes, folders, kapyAi }

/// A phone's way around: Notes, Folders and Kapy AI along the bottom, and the
/// + on its own beside them. A tap on the + makes what the page on screen
/// holds (on Tasks it adds a task); a long press offers [createActions], the
/// rest of the desktop's New. Both phones float the same quiet pill over
/// [child] (M01), Android's just clear of its own navigation.
class PhoneSpaces extends StatefulWidget {
  const PhoneSpaces({
    super.key,
    required this.tab,
    required this.onSelected,
    required this.createLabel,
    required this.onCreate,
    required this.createActions,
    required this.onCreateAction,
    required this.child,
    this.showKapyAi = true,
    this.foldersDot = false,
  });

  final PhoneTab tab;
  final ValueChanged<PhoneTab> onSelected;

  /// What a tap on the + makes, such as "New note".
  final String createLabel;
  final VoidCallback onCreate;
  final List<KapyMenuAction> createActions;
  final ValueChanged<String> onCreateAction;
  final Widget child;

  /// Whether the build carries Kapy AI, for its tab.
  final bool showKapyAi;

  /// Whether something waits in Shared, which Folders holds: a clay dot on
  /// its icon from every tab, as Shared's tile counts it.
  final bool foldersDot;

  static const double _barHeight = 58;
  static const double _barLift = 30;
  static const double _plusExtent = 58;

  /// From the bottom of the screen to the pill: M01's 30 on an iPhone, over
  /// its home indicator, and on Android 8 above the system's navigation,
  /// whether three buttons or the gesture handle, but never lower than 30.
  static double _lift(BuildContext context) => AppPlatform.isAndroid
      ? math.max(_barLift, MediaQuery.viewPaddingOf(context).bottom + 8)
      : _barLift;

  @override
  State<PhoneSpaces> createState() => _PhoneSpacesState();
}

class _PhoneSpacesState extends State<PhoneSpaces>
    with SingleTickerProviderStateMixin {
  final _bar = GlobalKey();
  final _page = GlobalKey();

  /// The tab left, as it was last drawn, fading out over the one chosen
  /// below its header and search well. Those are the same frame on every
  /// tab, so their words change at once rather than showing both tabs' at
  /// half strength, and only the page under them crossfades (KAP-462).
  ui.Image? _leaving;
  late final _fade =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 150),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _dropLeaving();
      });

  @override
  void dispose() {
    _fade.dispose();
    _leaving?.dispose();
    super.dispose();
  }

  void _dropLeaving() {
    final leaving = _leaving;
    if (leaving == null) return;
    setState(() => _leaving = null);
    leaving.dispose();
  }

  void _select(PhoneTab tab) {
    if (tab != widget.tab && !MediaQuery.disableAnimationsOf(context)) {
      final page = _page.currentContext?.findRenderObject();
      // Taken between frames, so the page is as it was last drawn; a debug
      // build skips the fade on the rare tap that lands mid-repaint.
      if (page is RenderRepaintBoundary &&
          !(kDebugMode && page.debugNeedsPaint)) {
        _leaving?.dispose();
        _leaving = page.toImageSync(
          pixelRatio: View.of(context).devicePixelRatio,
        );
        _fade.forward(from: 0);
      }
    }
    widget.onSelected(tab);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final items = <({PhoneTab to, KapyIconData icon, String label})>[
      (to: PhoneTab.notes, icon: KapyIcons.noteOutlined, label: 'Notes'),
      (to: PhoneTab.folders, icon: KapyIcons.folderOutlined, label: 'Folders'),
      if (widget.showKapyAi)
        (
          to: PhoneTab.kapyAi,
          icon: KapyIcons.sparklesOutlined,
          label: 'Kapy AI',
        ),
    ];
    // The + reaches as high as anything here, so toasts keep above it.
    final plus = ToastClearance(
      child: Builder(
        builder: (context) => _PlusButton(
          key: const ValueKey('phone-new'),
          label: widget.createLabel,
          onPressed: widget.onCreate,
          onLongPress: () => _showCreateMenu(context),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(key: _page, child: widget.child),
          if (_leaving case final leaving?)
            IgnorePointer(
              child: ClipRect(
                clipper: _Below(
                  MediaQuery.paddingOf(context).top +
                      PhoneTitleBar.height +
                      SidebarSearchField.phoneExtent(
                        MediaQuery.textScalerOf(context),
                      ),
                ),
                child: FadeTransition(
                  opacity: ReverseAnimation(_fade),
                  child: RawImage(
                    image: leaving,
                    scale: View.of(context).devicePixelRatio,
                    fit: BoxFit.fill,
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, PhoneSpaces._lift(context)),
        child: Row(
          children: [
            Expanded(
              key: _bar,
              // Opaque, because it floats over the list.
              child: Container(
                key: const ValueKey('phone-bar'),
                height: PhoneSpaces._barHeight,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: palette.cardBackground,
                  borderRadius: BorderRadius.circular(
                    PhoneSpaces._barHeight / 2,
                  ),
                ),
                child: Row(
                  children: [
                    for (final item in items)
                      Expanded(
                        child: _BarItem(
                          key: ValueKey('bar-${item.to.name}'),
                          icon: item.icon,
                          label: item.label,
                          selected: item.to == widget.tab,
                          dot: item.to == PhoneTab.folders && widget.foldersDot,
                          onPressed: () => _select(item.to),
                        ),
                      ),
                  ],
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

  /// The rest of New (M05): the page dims behind it, all but the bar, and
  /// the + turns into a × that closes it, as a tap anywhere else does.
  void _showCreateMenu(BuildContext context) {
    final plus = _globalRect(context);
    final bar = _bar.currentContext;
    if (plus == null || bar == null || widget.createActions.isEmpty) return;
    unawaited(
      Navigator.of(context, rootNavigator: true)
          .push(
            _CreateMenuRoute(
              actions: widget.createActions,
              plus: plus,
              bar: _globalRect(bar)!,
            ),
          )
          .then((choice) {
            if (choice != null) widget.onCreateAction(choice);
          }),
    );
  }

  static Rect? _globalRect(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

/// What lies below [top]: the page under a tab's header and search well.
class _Below extends CustomClipper<Rect> {
  const _Below(this.top);

  final double top;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, top, size.width, size.height);

  @override
  bool shouldReclip(_Below oldClipper) => oldClipper.top != top;
}

/// One of the bar's destinations: its icon over its name in a 46 pt pill,
/// lifted a step while it is the one on screen, and a 7 pt clay dot on the
/// icon's corner while something new waits there.
class _BarItem extends StatelessWidget {
  const _BarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.dot = false,
  });

  final KapyIconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = selected ? palette.textPrimary : palette.textSecondary;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: dot ? '$label, new in Shared' : label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: selected ? palette.controlBackground : null,
              borderRadius: BorderRadius.circular(24),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    KapyIcon(icon, size: 22, color: ink),
                    if (dot)
                      Positioned(
                        top: -1,
                        right: -2,
                        child: Container(
                          key: const ValueKey('bar-folders-dot'),
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: waitingMarker,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
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
                    fontSize: 11.5,
                    height: 14 / 11.5,
                    fontWeight: AppWeight.font(AppWeight.regular),
                    fontVariations: AppWeight.wght(AppWeight.regular),
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

/// The phone's one main action: a round + in the accent, or the × that
/// closes New's menu while it is open.
class _PlusButton extends StatelessWidget {
  const _PlusButton({
    super.key,
    required this.label,
    this.icon = KapyIcons.addRounded,
    required this.onPressed,
    this.onLongPress,
  });

  final String label;
  final KapyIconData icon;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      label: label,
      onLongPressHint: onLongPress == null ? null : 'More to make',
      excludeSemantics: true,
      onTap: onPressed,
      onLongPress: onLongPress,
      child: Material(
        color: palette.accentFill,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          onLongPress: onLongPress,
          splashFactory: NoSplash.splashFactory,
          child: SizedBox.square(
            dimension: PhoneSpaces._plusExtent,
            child: Center(
              child: KapyIcon(icon, size: 24, color: palette.onAccent),
            ),
          ),
        ),
      ),
    );
  }
}

/// New's menu over a phone (M05): a card of what the + makes above it, the
/// page dimmed behind all but the bar, and a × over the + that closes it.
class _CreateMenuRoute extends PopupRoute<String> {
  _CreateMenuRoute({
    required this.actions,
    required this.plus,
    required this.bar,
  });

  final List<KapyMenuAction> actions;

  /// Where the + and the bar are on screen.
  final Rect plus;
  final Rect bar;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Close';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final palette = context.palette;
    final screen = MediaQuery.sizeOf(context);
    void close() => Navigator.of(context).pop();
    return Stack(
      children: [
        Positioned.fill(
          child: ExcludeSemantics(
            child: GestureDetector(
              key: const ValueKey('phone-new-dim'),
              behavior: HitTestBehavior.opaque,
              onTap: close,
              child: CustomPaint(
                painter: _DimPainter(
                  color: palette.scrim,
                  hole: RRect.fromRectAndRadius(
                    bar,
                    const Radius.circular(PhoneSpaces._barHeight / 2),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: screen.width - plus.right,
          bottom: screen.height - plus.top + 12,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 200,
              maxWidth: math.max(200, plus.right - 16),
            ),
            child: IntrinsicWidth(
              child: Material(
                key: const ValueKey('phone-new-menu'),
                color: palette.cardBackground,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final action in actions)
                        Semantics(
                          button: true,
                          enabled: action.enabled,
                          label: action.label,
                          excludeSemantics: true,
                          onTap: action.enabled
                              ? () => Navigator.of(context).pop(action.value)
                              : null,
                          child: InkWell(
                            key: ValueKey('phone-new-${action.value}'),
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                            onTap: action.enabled
                                ? () => Navigator.of(context).pop(action.value)
                                : null,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 44),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: Row(
                                  spacing: 10,
                                  children: [
                                    KapyIcon(
                                      action.icon,
                                      size: 18,
                                      color: palette.textSecondary,
                                    ),
                                    Expanded(
                                      child: Text(
                                        action.label,
                                        style: TextStyle(
                                          fontSize: 15,
                                          height: 20 / 15,
                                          color: palette.textPrimary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fromRect(
          rect: plus,
          child: _PlusButton(
            key: const ValueKey('phone-new-close'),
            label: 'Close',
            icon: KapyIcons.closeRounded,
            onPressed: close,
          ),
        ),
      ],
    );
  }
}

/// The dim behind New's menu, all but the bar, which stays as it was.
class _DimPainter extends CustomPainter {
  const _DimPainter({required this.color, required this.hole});

  final Color color;
  final RRect hole;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(hole),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.color != color || old.hole != hole;
}
