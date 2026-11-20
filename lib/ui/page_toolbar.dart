import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/update_checker.dart';
import '../sync/presence.dart';
import '../sync/spaces.dart';
import '../sync/sync_service.dart' show SyncStatus;
import 'compact_icon_button.dart';
import 'context_menu.dart';
import 'member_avatars.dart';
import 'note_tabs.dart' show clickOpensTabBehind;
import 'tonal_button.dart';
import 'toolbar.dart' show UpdateRestartButton;
import 'unloaded_pictures_status.dart';
import 'window_drag_area.dart';

/// One level of a page's path: a folder, which opens from the path, or a
/// name such as a drawing's.
typedef PagePlace = ({String name, String? folderId});

/// Where a page is: its place on the rail, such as My notes, then the folders
/// down to the open note's, or a drawing's or a day's name.
class PagePath {
  const PagePath({
    required this.icon,
    required this.root,
    this.levels = const [],
  });

  final KapyIconData icon;
  final String root;

  /// Outermost first. The last is where the page is.
  final List<PagePlace> levels;

  /// The whole path in words, as hovering it shows it.
  String get spoken =>
      [root, for (final level in levels) level.name].join(' › ');
}

/// What Saved says for [status], with its icon and what hovering it adds.
///
/// Every keystroke is written to this device as it is typed, so a note on
/// the page is always saved here; with an account it says whether the other
/// devices have it too.
({KapyIconData icon, String label, String? tooltip}) savedState(
  SyncStatus? status,
) => switch (status) {
  SyncStatus.syncing => (
    icon: KapyIcons.cloudRounded,
    label: 'Syncing',
    tooltip: null,
  ),
  SyncStatus.offline => (
    icon: KapyIcons.cloudOffRounded,
    label: 'Offline',
    tooltip: 'Saved on this device. It syncs once you are back online.',
  ),
  SyncStatus.keysChanged => (
    icon: KapyIcons.cloudRounded,
    label: 'Saved',
    tooltip:
        'Saved on this device. It syncs once you enter your new passphrase.',
  ),
  _ => (icon: KapyIcons.cloudRounded, label: 'Saved', tooltip: null),
};

TextStyle _figtree(double size, double line, FontWeight weight, Color color) =>
    chromeStyle(
      size: size,
      line: line,
      weight: AppWeight.axisOf(weight),
      color: color,
    );

/// The bar across the top of the page: where the page is, the page's days
/// where it has them, then what can be done there, with Kapy AI at the far
/// end.
///
/// While the notes list is hidden it leads with the way back to the list.
/// Its empty stretches drag the window.
class PageToolbar extends StatelessWidget {
  const PageToolbar({
    super.key,
    required this.path,
    this.days,
    required this.listVisible,
    required this.onShowList,
    this.showListShortcut,
    this.onOpenFolder,
    this.noteOpen = false,
    this.syncStatus,
    this.unloadedPictures = 0,
    this.onShowUnloadedPicture,
    this.members = const [],
    this.present = const [],
    this.currentUserId = '',
    this.noteShared = false,
    this.onShare,
    this.assistant,
    this.moreActions = const [],
    this.onMore,
    this.updates,
    this.actions,
    this.back,
  });

  final PagePath path;

  /// The page's days, between the path and the actions with as much room on
  /// either side: the week, or with compact one button for the day on a page
  /// too narrow for it. They have the room the collaborators leave, and fit
  /// themselves to it. Null on a page that has no days.
  final Widget Function(bool compact)? days;

  /// Shows a folder from the path in this tab, or with behind in a new tab
  /// behind it.
  final void Function(String folderId, {required bool behind})? onOpenFolder;

  final bool listVisible;
  final VoidCallback onShowList;
  final String? showListShortcut;

  /// Whether there is a note on the page for Saved to speak for.
  final bool noteOpen;

  /// Null without an account, where every note is saved on this device alone.
  final SyncStatus? syncStatus;

  /// How many of the open note's pictures didn't load. While there are any,
  /// the bar counts them in place of Saved, and pressing the count calls
  /// [onShowUnloadedPicture].
  final int unloadedPictures;
  final VoidCallback? onShowUnloadedPicture;

  final List<SpaceMember> members;
  final List<Collaborator> present;
  final String currentUserId;
  final bool noteShared;

  /// Null greys Share rather than removing it, so the buttons beside it stay
  /// put as the selection comes and goes.
  final VoidCallback? onShare;

  /// Kapy AI's button, last in the bar behind a hairline. It hides with its
  /// hairline while Kapy AI is off.
  final Widget? assistant;

  /// Everything else the page offers, under More. A page with no onMore has
  /// nothing to put there and shows no More at all.
  final List<KapyMenuAction> moreActions;
  final void Function(String value, Offset at)? onMore;

  /// Offers "Update and restart" once a release has downloaded. Null where
  /// the app does not update itself.
  final UpdateChecker? updates;

  /// A page that is not a note puts its own actions where a note's Saved
  /// and Share go.
  final List<Widget>? actions;

  /// A phone's way back to the list the page was pushed over, named for that
  /// list, in place of the path and the list's controls.
  final ({String to, VoidCallback onPressed})? back;

  static const double height = 72;

  /// Narrower than this, the path keeps its icon, a fold and its last level,
  /// and the week gives way to one button for the day.
  static const double _fullWidth = 720;

  /// A phone's page bar: the back button and the note's actions, each 44.
  static const double phoneHeight = 44;

  static const _phonePadding = EdgeInsets.only(left: 4, right: 6);

  /// Narrower than this, Saved moves to the note's date line and the path
  /// keeps only its last level.
  static const double _savedWidth = 560;

  /// The count of pictures that didn't load stands in for Saved and is up to
  /// 125 wider, so it gives way that much sooner.
  static const double _unloadedPicturesWidth = _savedWidth + 125;

  /// Whether a page [width] wide has room in the bar for Saved, or for the
  /// count of [unloadedPictures] that stands in for it. Where it hasn't,
  /// Saved goes on the note's date line instead.
  static bool savedFits(double width, {required int unloadedPictures}) =>
      width >= (unloadedPictures > 0 ? _unloadedPicturesWidth : _savedWidth);

  /// Narrower than this, "Update and restart" shortens to "Update".
  static const double _updateLabelWidth = 680;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final extent = AppPlatform.hasPointer
        ? 32.0
        : AppControlMetrics.iconButtonExtent;
    final showListShortcut = this.showListShortcut;
    final days = this.days;
    final back = this.back;
    return Container(
      key: const ValueKey('page-toolbar'),
      height: AppControlMetrics.scaleBar(
        context,
        back == null ? height : phoneHeight,
      ),
      color: palette.isGlass ? palette.paperColor : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final avatars = actions == null && members.isNotEmpty;
          return Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(
                child: WindowDragArea(child: SizedBox.expand()),
              ),
              Padding(
                padding: back == null
                    ? EdgeInsets.fromLTRB(listVisible ? 16 : 8, 8, 16, 0)
                    : _phonePadding,
                child: Row(
                  children: [
                    if (back == null && !listVisible) ...[
                      CompactIconButton(
                        key: const ValueKey('page-show-list'),
                        tooltip: ['Show notes', ?showListShortcut].join('  '),
                        extent: extent,
                        radius: 8,
                        onPressed: onShowList,
                        icon: const KapyIcon(
                          KapyIcons.menuOpenRounded,
                          size: 16,
                          strokeWidth: 1.8,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, slot) => Row(
                          children: [
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, rest) => Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Flexible(
                                      child: back == null
                                          ? _Path(
                                              path: path,
                                              form: width >= _fullWidth
                                                  ? _PathForm.full
                                                  : width >= _savedWidth
                                                  ? _PathForm.short
                                                  : _PathForm.last,
                                              onOpenFolder: onOpenFolder,
                                            )
                                          : _BackButton(
                                              to: back.to,
                                              onPressed: back.onPressed,
                                            ),
                                    ),
                                    if (days != null) ...[
                                      ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: rest.maxWidth,
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            left: 16,
                                          ),
                                          child: days(width < _fullWidth),
                                        ),
                                      ),
                                      const SizedBox.shrink(),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (avatars)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: math.min(slot.maxWidth, width / 3),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 16),
                                  child: MemberAvatars(
                                    members: members,
                                    present: present,
                                    currentUserId: currentUserId,
                                    onPressed: onShare,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(width: avatars ? 8 : 16),
                    ..._actions(width, extent),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Saved, Share and More, 8 apart, then Kapy AI.
  List<Widget> _actions(double width, double extent) {
    final updates = this.updates;
    final actions = this.actions;
    final onMore = this.onMore;
    return [
      if (updates != null)
        UpdateRestartButton(
          updates: updates,
          wide: width >= _updateLabelWidth,
          gap: 8,
        ),
      if (actions != null)
        ...actions
      else ...[
        if (noteOpen &&
            savedFits(width, unloadedPictures: unloadedPictures)) ...[
          if (unloadedPictures > 0)
            UnloadedPicturesStatus(
              count: unloadedPictures,
              onPressed: onShowUnloadedPicture,
            )
          else
            _Saved(syncStatus),
          const SizedBox(width: 8),
        ],
        TonalButton(
          key: const ValueKey('page-share'),
          tall: true,
          label: 'Share',
          tooltip: noteShared ? 'Manage sharing' : null,
          onPressed: onShare,
        ),
      ],
      if (onMore != null) ...[
        if (actions == null || actions.isNotEmpty) const SizedBox(width: 8),
        Builder(
          builder: (buttonContext) => CompactIconButton(
            key: const ValueKey('page-more'),
            tooltip: 'More',
            extent: extent,
            radius: 8,
            onPressed: moreActions.isEmpty
                ? null
                : () => _showMore(buttonContext, onMore),
            icon: const KapyIcon(
              KapyIcons.moreRounded,
              size: 16,
              strokeWidth: 2.2,
            ),
          ),
        ),
      ],
      ?assistant,
    ];
  }

  /// Opens under More, its right edge on the button's. A choice that opens
  /// a list of its own opens it there too.
  void _showMore(
    BuildContext context,
    void Function(String value, Offset at) onMore,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset(box.size.width, box.size.height + 4));
    unawaited(
      showKapyContextMenu<String>(
        context: context,
        globalPosition: at,
        items: [
          for (final action in moreActions)
            PopupMenuItem(
              key: ValueKey('page-more-${action.value}'),
              value: action.value,
              enabled: action.enabled,
              // A phone's sheet gives each action a 44 pt target.
              height: AppPlatform.hasPointer ? 36 : 44,
              child: KapyMenuActionRow(action, touch: false),
            ),
        ],
      ).then((choice) {
        if (choice != null) onMore(choice, at);
      }),
    );
  }
}

/// How much of the path a page's width leaves room for.
enum _PathForm {
  /// The root and the last two levels, with anything between folded.
  full,

  /// The root's icon, everything but the last level folded, then the last.
  short,

  /// The last level alone, after its icon.
  last,
}

/// The page's path, on one line that never wraps: the root's icon and name,
/// then each level after a chevron. Folders open from it.
class _Path extends StatefulWidget {
  const _Path({required this.path, required this.form, this.onOpenFolder});

  final PagePath path;
  final _PathForm form;
  final void Function(String folderId, {required bool behind})? onOpenFolder;

  @override
  State<_Path> createState() => _PathState();
}

class _PathState extends State<_Path> {
  /// Whether the folded levels' menu is open, which turns "…" tonal.
  bool _folding = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final path = widget.path;
    final levels = path.levels;
    final form = widget.form;
    final cap = form == _PathForm.full ? 200.0 : 160.0;
    final above = _figtree(13, 16, FontWeight.w400, palette.textTertiary);
    final here = _figtree(13, 16, FontWeight.w500, palette.textPrimary);
    final last = levels.lastOrNull;
    final base = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    var long = false;
    var fixed = 24.0;
    var line = 0.0;

    Widget icon(KapyIconData data) => KapyIcon(
      data,
      size: 16,
      strokeWidth: 1.8,
      color: palette.textSecondary,
    );
    Widget chevron() {
      fixed += 20;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: KapyIcon(
          KapyIcons.chevronRightRounded,
          size: 12,
          strokeWidth: 1.8,
          color: palette.textTertiary,
        ),
      );
    }

    // Each name's share of a tight line is its width, so the line shrinks
    // evenly and a short name is never cut to make room for a long one.
    Widget level(String name, TextStyle style, [String? folderId]) {
      painter
        ..text = TextSpan(text: name, style: base.merge(style))
        ..layout();
      long |= painter.width > cap;
      final width = math.min(painter.width, cap);
      line += width;
      return Flexible(
        flex: math.max(1, width.ceil()),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: cap),
          child: _Level(
            name: name,
            style: style,
            folderId: folderId,
            onOpen: widget.onOpenFolder,
          ),
        ),
      );
    }

    Widget fold(Iterable<PagePlace> hidden) {
      fixed += 24;
      return _fold(hidden.toList());
    }

    final children = switch (form) {
      _PathForm.last => [
        icon(last?.folderId == null ? path.icon : KapyIcons.folderOutlined),
        const SizedBox(width: 8),
        if (last != null)
          level(last.name, here, last.folderId)
        else
          level(path.root, here),
      ],
      _PathForm.short => [
        icon(path.icon),
        const SizedBox(width: 8),
        if (levels.length > 1) ...[
          fold(levels.take(levels.length - 1)),
          chevron(),
        ],
        if (last != null)
          level(last.name, here, last.folderId)
        else
          level(path.root, here),
      ],
      _PathForm.full => [
        icon(path.icon),
        const SizedBox(width: 8),
        level(path.root, levels.isEmpty ? here : above),
        if (levels.length > 2) ...[
          chevron(),
          fold(levels.take(levels.length - 2)),
        ],
        for (final place in levels.skip(math.max(0, levels.length - 2))) ...[
          chevron(),
          level(place.name, place == last ? here : above, place.folderId),
        ],
      ],
    };
    painter.dispose();
    final row = Row(
      key: const ValueKey('page-path'),
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    final hidden = long || levels.length > (form == _PathForm.full ? 2 : 0);
    // Too narrow to read even one name, it steps aside rather than overflow.
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < fixed + 24
          ? const SizedBox.shrink()
          : hidden || fixed + line > constraints.maxWidth
          ? Tooltip(message: path.spoken, child: row)
          : row,
    );
  }

  /// "…" for the levels the path leaves out, opening them as a menu.
  Widget _fold(List<PagePlace> hidden) {
    final palette = context.palette;
    return Builder(
      builder: (buttonContext) => TextButton(
        key: const ValueKey('page-path-fold'),
        onPressed: () => _showFold(buttonContext, hidden),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 24),
          fixedSize: const Size.fromHeight(24),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          backgroundColor: _folding
              ? palette.tonalBackground
              : palette.controlBackground,
          foregroundColor: _folding
              ? palette.tonalForeground
              : palette.textSecondary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: _folding
                ? BorderSide.none
                : BorderSide(color: palette.controlBorder),
          ),
          textStyle: _figtree(13, 16, FontWeight.w600, palette.textSecondary),
        ),
        child: const Text('…', semanticsLabel: 'Folders in between'),
      ),
    );
  }

  /// Lists [hidden] 8 under "…", each a level further in, and opens the one
  /// picked as a click on the path would.
  Future<void> _showFold(BuildContext context, List<PagePlace> hidden) async {
    final box = context.findRenderObject() as RenderBox?;
    final onOpen = widget.onOpenFolder;
    if (box == null || onOpen == null) return;
    final palette = context.palette;
    setState(() => _folding = true);
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: box.localToGlobal(Offset(0, box.size.height + 8)),
      items: [
        for (final (depth, place) in hidden.indexed)
          if (place.folderId case final folderId?)
            PopupMenuItem(
              key: ValueKey('page-path-$folderId'),
              value: folderId,
              height: 32,
              child: Padding(
                padding: EdgeInsets.only(left: 12.0 * depth),
                child: Row(
                  children: [
                    KapyIcon(
                      KapyIcons.folderOutlined,
                      size: 16,
                      strokeWidth: 1.8,
                      color: palette.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        place.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _figtree(
                          13,
                          16,
                          FontWeight.w400,
                          palette.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
    if (!mounted) return;
    setState(() => _folding = false);
    if (choice != null) onOpen(choice, behind: clickOpensTabBehind());
  }
}

/// One name on the path. A folder's opens it: in this tab on a click, or in
/// a tab behind on ⌘-click (Ctrl-click elsewhere) or a middle click.
class _Level extends StatelessWidget {
  const _Level({
    required this.name,
    required this.style,
    this.folderId,
    this.onOpen,
  });

  final String name;
  final TextStyle style;
  final String? folderId;
  final void Function(String folderId, {required bool behind})? onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    final folderId = this.folderId;
    final onOpen = this.onOpen;
    if (folderId == null || onOpen == null) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) {
            onOpen(folderId, behind: true);
          }
        },
        child: GestureDetector(
          key: ValueKey('page-path-open-$folderId'),
          behavior: HitTestBehavior.opaque,
          onTap: () => onOpen(folderId, behind: clickOpensTabBehind()),
          child: Semantics(button: true, child: text),
        ),
      ),
    );
  }
}

/// Saved, or what is keeping the note from being saved everywhere yet.
class _Saved extends StatelessWidget {
  const _Saved(this.status);

  final SyncStatus? status;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final saved = savedState(status);
    final row = Row(
      key: const ValueKey('page-saved'),
      mainAxisSize: MainAxisSize.min,
      children: [
        KapyIcon(
          saved.icon,
          size: 16,
          strokeWidth: 1.8,
          color: palette.textTertiary,
        ),
        const SizedBox(width: 4),
        Text(
          saved.label,
          maxLines: 1,
          style: _figtree(12, 16, FontWeight.w500, palette.textTertiary),
        ),
      ],
    );
    return switch (saved.tooltip) {
      final tooltip? => Tooltip(message: tooltip, child: row),
      null => row,
    };
  }
}

/// Back to the list: "‹ Notes" on iOS, and on Android Material's arrow
/// alone, as the system back gesture names nothing either.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.to, required this.onPressed});

  final String to;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (AppPlatform.isAndroid) {
      return IconButton(
        key: const ValueKey('page-back'),
        tooltip: 'Back',
        onPressed: onPressed,
        color: palette.textPrimary,
        icon: KapyIcon(KapyIcons.arrowBackRounded, size: 22, strokeWidth: 1.9),
      );
    }
    return Semantics(
      button: true,
      label: 'Back to $to',
      excludeSemantics: true,
      child: TextButton(
        key: const ValueKey('page-back'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.only(right: 8),
          foregroundColor: palette.accentText,
          splashFactory: NoSplash.splashFactory,
          overlayColor: Colors.transparent,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KapyIcon(
              KapyIcons.chevronLeftRounded,
              size: 24,
              strokeWidth: 2,
              color: palette.accentText,
            ),
            Text(
              to,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypeScale.body,
                fontWeight: FontWeight.w500,
                color: palette.accentText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
