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
import 'day_strip.dart' show PlaceDays;
import 'member_avatars.dart';
import 'note_tabs.dart' show clickOpensTabBehind;
import 'page_card.dart';
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

/// The band across the top of the page, on one line: the month at the top
/// left of a page with days, its week centred on the page, and what can be
/// done there on the right, ending with Kapy AI and More. A page with no
/// days has its path at the top left instead.
///
/// While the notes list is hidden it leads with the way back to the list.
/// Its empty stretches drag the window.
class PageToolbar extends StatelessWidget {
  const PageToolbar({
    super.key,
    this.path,
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
  }) : assert(path != null || days != null || back != null);

  /// Where a page with no days is, at the top left.
  final PagePath? path;

  /// The page's days, which put their month at the top left and their week
  /// in the middle through the place they are given. With compact, one
  /// button for the day stands in the month's place and the week gives way.
  /// Null on a page that has no days, which shows its [path] instead.
  final Widget Function(bool compact, PlaceDays place)? days;

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

  /// Kapy AI's button, behind a hairline before More. It hides with its
  /// hairline while Kapy AI is off.
  final Widget? assistant;

  /// Everything else the page offers, under More at the bar's far end. A
  /// page with no onMore has nothing to put there and shows no More at all.
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

  /// The band is 52 from the page's top, the page card's edge included, so
  /// it lines up with the list's bar beside it.
  static const double height = 52 - PageCard.borderWidth;

  /// The top left's slot and the actions', each from its edge of the page
  /// with its inset: the week sits centred between them, 12 clear of each.
  static const double slot = 208;

  /// Where the top left's words start, and where the actions end.
  static const double _start = 18;
  static const double _end = 12;

  /// Narrower than this, the path keeps its icon, a fold and its last level,
  /// and the days give way to one button for the day.
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
          // The month's button starts 8 before its words, and the way back
          // to the list sits 8 in.
          Widget band(Widget lead, [Widget? week]) => CustomMultiChildLayout(
            delegate: _Band(
              start: !listVisible
                  ? 8
                  : days == null
                  ? _start
                  : _start - 8,
            ),
            children: [
              LayoutId(
                id: _Slot.lead,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!listVisible) ...[
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
                    Flexible(child: lead),
                  ],
                ),
              ),
              if (week != null) LayoutId(id: _Slot.week, child: week),
              LayoutId(
                id: _Slot.actions,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _actions(width, extent),
                ),
              ),
            ],
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(
                child: WindowDragArea(child: SizedBox.expand()),
              ),
              if (back != null)
                Padding(
                  padding: _phonePadding,
                  child: _phoneBar(back, width, extent),
                )
              else if (days != null)
                days(width < _fullWidth, band)
              else
                band(
                  _Path(
                    path: path!,
                    form: width >= _fullWidth
                        ? _PathForm.full
                        : width >= _savedWidth
                        ? _PathForm.short
                        : _PathForm.last,
                    onOpenFolder: onOpenFolder,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// A phone's bar, outside the desktop's band, as Phone v2 has it: the way
  /// back at the left, the collaborators after it, then the note's actions.
  Widget _phoneBar(
    ({String to, VoidCallback onPressed}) back,
    double width,
    double extent,
  ) => Row(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, slot) => Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _BackButton(to: back.to, onPressed: back.onPressed),
                ),
              ),
              if (actions == null && members.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(
                      slot.maxWidth,
                      (width - _phonePadding.horizontal) / 3,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, right: 6),
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
      ..._actions(width, extent),
    ],
  );

  /// The collaborators, giving way first, then Saved and Share 8 apart,
  /// Kapy AI behind its hairline, and More last. A phone's bar keeps Phone
  /// v2's: Share's icon, then Kapy AI and More.
  List<Widget> _actions(double width, double extent) {
    final updates = this.updates;
    final actions = this.actions;
    final onMore = this.onMore;
    final assistant = this.assistant;
    Widget more(
      void Function(String value, Offset at) onMore, {
      required double radius,
      required double size,
      required KapyIconData icon,
    }) => Builder(
      builder: (buttonContext) => CompactIconButton(
        key: const ValueKey('page-more'),
        tooltip: 'More',
        extent: extent,
        radius: radius,
        onPressed: moreActions.isEmpty
            ? null
            : () => _showMore(buttonContext, onMore),
        icon: KapyIcon(icon, size: size, strokeWidth: 2.2),
      ),
    );
    if (back != null) {
      return [
        TonalButton(
          key: const ValueKey('page-share'),
          tall: true,
          icon: KapyIcons.personAddRounded,
          tooltip: noteShared ? 'Manage sharing' : 'Share',
          onPressed: onShare,
        ),
        const SizedBox(width: 6),
        ?assistant,
        if (onMore != null)
          more(
            onMore,
            radius: 10,
            size: AppControlMetrics.iconAction,
            icon: KapyIcons.moreRounded,
          ),
      ];
    }
    return [
      if (actions == null && members.isNotEmpty)
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width / 3),
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: MemberAvatars(
                members: members,
                present: present,
                currentUserId: currentUserId,
                onPressed: onShare,
              ),
            ),
          ),
        ),
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
      ?assistant,
      if (onMore != null) ...[
        if (assistant != null)
          const SizedBox(width: 4)
        else if (actions == null || actions.isNotEmpty)
          const SizedBox(width: 8),
        more(onMore, radius: 8, size: 16, icon: KapyIcons.moreVerticalRounded),
      ],
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

enum _Slot { lead, week, actions }

/// The band's one line, every part centred down it: the lead from [start],
/// the actions ending [PageToolbar._end] from the right, and the week
/// centred on the page between two equal slots, each [PageToolbar.slot] or
/// as wide as the lead or the actions need, with 12 clear of each.
class _Band extends MultiChildLayoutDelegate {
  _Band({required this.start});

  final double start;

  static const double _clear = 12;

  @override
  void performLayout(Size size) {
    double middle(Size child) => (size.height - child.height) / 2;
    final end = size.width - PageToolbar._end;
    final actions = layoutChild(
      _Slot.actions,
      BoxConstraints.loose(Size(math.max(0, end - start), size.height)),
    );
    positionChild(_Slot.actions, Offset(end - actions.width, middle(actions)));
    final lead = layoutChild(
      _Slot.lead,
      BoxConstraints.loose(
        Size(math.max(0, end - actions.width - 16 - start), size.height),
      ),
    );
    positionChild(_Slot.lead, Offset(start, middle(lead)));
    if (!hasChild(_Slot.week)) return;
    final slot = math.max(
      PageToolbar.slot,
      math.max(start + lead.width, size.width - end + actions.width),
    );
    final week = layoutChild(
      _Slot.week,
      BoxConstraints.loose(
        Size(math.max(0, size.width - 2 * (slot + _clear)), size.height),
      ),
    );
    positionChild(
      _Slot.week,
      Offset((size.width - week.width) / 2, middle(week)),
    );
  }

  @override
  bool shouldRelayout(_Band oldDelegate) => oldDelegate.start != start;
}

/// A note's folders in a light line above its title, outermost first, on a
/// page whose top left has its days: "Work › Clients › Acme". They open as
/// the path's do, and a deep one folds its middle into "…".
class NotePathLine extends StatelessWidget {
  const NotePathLine({
    super.key,
    required this.folders,
    required this.onOpenFolder,
  });

  final List<PagePlace> folders;
  final void Function(String folderId, {required bool behind}) onOpenFolder;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: EditorMetrics.pathRow,
    child: _Path(
      path: PagePath(icon: KapyIcons.folderOutlined, root: '', levels: folders),
      form: _PathForm.line,
      onOpenFolder: onOpenFolder,
    ),
  );
}

/// How much of the path shows: in the bar, as much as the page's width
/// leaves room for, and above a note's title, its folders.
enum _PathForm {
  /// The root and the last two levels, with anything between folded.
  full,

  /// The root's icon, everything but the last level folded, then the last.
  short,

  /// The last level alone, after its icon.
  last,

  /// The folders alone, quiet and with no icon, in the line above a note's
  /// title: up to three, or the first and the last two with those between
  /// folded.
  line,
}

/// The page's path, on one line that never wraps: in the bar the root's icon
/// and name, then each level after a chevron, and above a note's title its
/// folders alone. Folders open from it.
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
    final light = form == _PathForm.line;
    final keyName = light ? 'note-path' : 'page-path';
    final cap = form == _PathForm.full || light ? 200.0 : 160.0;
    final above = light
        ? _figtree(12, 16, FontWeight.w400, palette.textTertiary)
        : _figtree(13, 16, FontWeight.w400, palette.textTertiary);
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
      fixed += light ? 24 : 20;
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: light ? 6 : 4),
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
            keyName: keyName,
            onOpen: widget.onOpenFolder,
          ),
        ),
      );
    }

    Widget fold(Iterable<PagePlace> hidden) {
      fixed += 24;
      return _fold(hidden.toList(), keyName: keyName, light: light);
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
      _PathForm.line => [
        for (final (index, place) in levels.indexed)
          if (levels.length <= 3 || index == 0) ...[
            if (index > 0) chevron(),
            level(place.name, above, place.folderId),
          ] else if (index >= levels.length - 2) ...[
            if (index == levels.length - 2) ...[
              chevron(),
              fold(levels.sublist(1, index)),
            ],
            chevron(),
            level(place.name, above, place.folderId),
          ],
      ],
    };
    painter.dispose();
    final row = Row(
      key: ValueKey(keyName),
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    final hidden =
        long ||
        levels.length >
            switch (form) {
              _PathForm.full => 2,
              _PathForm.line => 3,
              _ => 0,
            };
    final spoken = light
        ? [for (final level in levels) level.name].join(' › ')
        : path.spoken;
    // Too narrow to read even one name, it steps aside rather than overflow.
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < fixed + 24
          ? const SizedBox.shrink()
          : hidden || fixed + line > constraints.maxWidth
          ? Tooltip(message: spoken, child: row)
          : row,
    );
  }

  /// "…" for the levels the path leaves out, opening them as a menu; in the
  /// light line, as tall as the line.
  Widget _fold(
    List<PagePlace> hidden, {
    required String keyName,
    required bool light,
  }) {
    final palette = context.palette;
    final height = light ? 16.0 : 24.0;
    return Builder(
      builder: (buttonContext) => TextButton(
        key: ValueKey('$keyName-fold'),
        onPressed: () => _showFold(buttonContext, hidden, keyName: keyName),
        style: TextButton.styleFrom(
          minimumSize: Size(0, height),
          fixedSize: Size.fromHeight(height),
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
          textStyle: light
              ? _figtree(12, 16, FontWeight.w600, palette.textSecondary)
              : _figtree(13, 16, FontWeight.w600, palette.textSecondary),
        ),
        child: const Text('…', semanticsLabel: 'Folders in between'),
      ),
    );
  }

  /// Lists [hidden] 8 under "…", each a level further in, and opens the one
  /// picked as a click on the path would.
  Future<void> _showFold(
    BuildContext context,
    List<PagePlace> hidden, {
    required String keyName,
  }) async {
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
              key: ValueKey('$keyName-$folderId'),
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
    required this.keyName,
    this.folderId,
    this.onOpen,
  });

  final String name;
  final TextStyle style;

  /// What the path's keys start with: page-path in the bar, note-path in
  /// the line above a note's title.
  final String keyName;
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
          key: ValueKey('$keyName-open-$folderId'),
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
