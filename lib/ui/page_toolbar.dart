import 'dart:async';
import 'dart:math' as math;

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
import 'tonal_button.dart';
import 'toolbar.dart' show UpdateRestartButton;
import 'unloaded_pictures_status.dart';
import 'window_drag_area.dart';

/// The bar across the top of the page: where the open note lives, whether it
/// is saved, and what can be done with it.
///
/// While the notes list is hidden it also leads with the way back to the
/// list and a new note, which the list's own header offers otherwise. Its
/// empty stretches drag the window.
class PageToolbar extends StatelessWidget {
  const PageToolbar({
    super.key,
    required this.space,
    required this.listVisible,
    required this.onShowList,
    required this.onCreate,
    this.section,
    this.showListShortcut,
    this.noun = 'note',
    this.newNoteShortcut,
    this.noteOpen = false,
    this.syncStatus,
    this.unloadedPictures = 0,
    this.onShowUnloadedPicture,
    this.members = const [],
    this.present = const [],
    this.currentUserId = '',
    this.noteShared = false,
    this.onShare,
    this.pinned = false,
    this.onTogglePin,
    this.keepOnTop = false,
    this.onToggleKeepOnTop,
    this.keepOnTopShortcut,
    this.assistant,
    this.moreActions = const [],
    this.onMore,
    this.updates,
    this.center,
    this.actions,
  });

  /// The breadcrumb: the space the list is showing, then the open note's
  /// place in it, such as Pinned.
  final String space;
  final String? section;

  final bool listVisible;
  final VoidCallback onShowList;
  final String? showListShortcut;
  final VoidCallback onCreate;
  final String? newNoteShortcut;

  /// What New makes here: a note, or a drawing in Drawings.
  final String noun;

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

  final bool pinned;
  final VoidCallback? onTogglePin;

  /// Whether the window floats over other apps, and the toggle that turns it
  /// on or off. Null off the desktop, where there is no window to float; it
  /// belongs to the window, so every page of the main window carries it.
  final bool keepOnTop;
  final VoidCallback? onToggleKeepOnTop;
  final String? keepOnTopShortcut;

  /// Kapy AI's button, between Share and the pin. It keeps its own gap, so
  /// it can hide while Kapy AI is off without leaving one behind.
  final Widget? assistant;

  /// Everything else the page offers, under More. A page with no onMore has
  /// nothing to put there and shows no More at all.
  final List<KapyMenuAction> moreActions;
  final ValueChanged<String>? onMore;

  /// Offers "Update and restart" once a release has downloaded. Null where
  /// the app does not update itself.
  final UpdateChecker? updates;

  /// Centred in the bar's empty middle, such as Write | Draw on a new note,
  /// where its going leaves nothing else to move.
  final Widget? center;

  /// A page that is not a note puts its own actions where a note's saved
  /// state, Share and Pin go, and has no More.
  final List<Widget>? actions;

  static const double height = 56;

  /// Narrower than this, Saved steps aside for the breadcrumb.
  static const double _savedWidth = 460;

  /// The same for the count of pictures that didn't load, which stands in for
  /// Saved and is up to 125 wider.
  static const double _unloadedPicturesWidth = _savedWidth + 125;

  /// Narrower than this, Share is its icon alone, so the window's own buttons
  /// (Keep on top, More) still fit beside it.
  static const double _shareLabelWidth = 420;

  /// Narrower than this, "Update and restart" shortens to "Update".
  static const double _updateLabelWidth = 680;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final actionExtent = AppPlatform.hasPointer
        ? 32.0
        : AppControlMetrics.iconButtonExtent;
    final showListShortcut = this.showListShortcut;
    final newNoteShortcut = this.newNoteShortcut;
    final updates = this.updates;
    final center = this.center;
    // The window's own button takes room from Saved, so Saved gives way
    // that much sooner.
    final onTop = onToggleKeepOnTop == null ? 0.0 : actionExtent + 6;

    return Container(
      key: const ValueKey('page-toolbar'),
      height: AppControlMetrics.scaleBar(context, height),
      color: palette.isGlass ? palette.paperColor : null,
      child: Stack(
        children: [
          const Positioned.fill(
            child: WindowDragArea(child: SizedBox.expand()),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, right: 16),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  if (!listVisible) ...[
                    CompactIconButton(
                      key: const ValueKey('page-show-list'),
                      tooltip: ['Show notes', ?showListShortcut].join('  '),
                      extent: AppControlMetrics.tonalButtonHeight,
                      radius: AppRadii.control,
                      onPressed: onShowList,
                      icon: KapyIcon(
                        KapyIcons.menuOpenRounded,
                        size: AppControlMetrics.iconAction,
                        strokeWidth: 1.7,
                      ),
                    ),
                    const SizedBox(width: 4),
                    TonalButton(
                      key: const ValueKey('page-new-note'),
                      icon: KapyIcons.addRounded,
                      tooltip: ['New $noun', ?newNoteShortcut].join('  '),
                      onPressed: onCreate,
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 1,
                      height: 16,
                      child: ColoredBox(color: palette.controlBorder),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, slot) => Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: WindowDragArea(
                                child: _Breadcrumb(
                                  space: space,
                                  section: section,
                                ),
                              ),
                            ),
                          ),
                          if (actions == null && members.isNotEmpty)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: math.min(
                                  slot.maxWidth,
                                  constraints.maxWidth / 3,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  left: 8,
                                  right: 6,
                                ),
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
                  if (actions case final actions?) ...[
                    if (updates != null)
                      UpdateRestartButton(
                        updates: updates,
                        wide: constraints.maxWidth >= _updateLabelWidth + onTop,
                      ),
                    ...actions,
                  ] else ...[
                    if (updates != null)
                      UpdateRestartButton(
                        updates: updates,
                        wide: constraints.maxWidth >= _updateLabelWidth + onTop,
                      ),
                    if (noteOpen &&
                        constraints.maxWidth >=
                            onTop +
                                (unloadedPictures > 0
                                    ? _unloadedPicturesWidth
                                    : _savedWidth)) ...[
                      if (unloadedPictures > 0)
                        UnloadedPicturesStatus(
                          count: unloadedPictures,
                          onPressed: onShowUnloadedPicture,
                        )
                      else
                        _SaveStatus(syncStatus),
                      const SizedBox(width: 6),
                    ],
                    TonalButton(
                      key: const ValueKey('page-share'),
                      tall: true,
                      icon: KapyIcons.personAddRounded,
                      label: constraints.maxWidth >= _shareLabelWidth
                          ? 'Share'
                          : null,
                      tooltip: noteShared
                          ? 'Manage sharing'
                          : constraints.maxWidth >= _shareLabelWidth
                          ? null
                          : 'Share',
                      onPressed: onShare,
                    ),
                    const SizedBox(width: 6),
                    ?assistant,
                    CompactIconButton(
                      key: const ValueKey('page-pin'),
                      tooltip: pinned ? 'Unpin note' : 'Pin note',
                      extent: actionExtent,
                      radius: 10,
                      foregroundColor: pinned ? palette.clay : null,
                      onPressed: onTogglePin,
                      icon: KapyIcon(
                        KapyIcons.pinOutlined,
                        size: AppControlMetrics.iconAction,
                        strokeWidth: 1.9,
                      ),
                    ),
                  ],
                  if (onToggleKeepOnTop case final toggle?) ...[
                    const SizedBox(width: 6),
                    CompactIconButton(
                      key: const ValueKey('page-keep-on-top'),
                      tooltip: [
                        keepOnTop ? 'Keep on top: on' : 'Keep on top',
                        ?keepOnTopShortcut,
                      ].join('  '),
                      extent: actionExtent,
                      radius: 10,
                      selected: keepOnTop,
                      selectedBackground: palette.tonalBackground,
                      foregroundColor: keepOnTop
                          ? palette.tonalForeground
                          : null,
                      onPressed: toggle,
                      icon: KapyIcon(
                        KapyIcons.keepOnTop,
                        size: AppControlMetrics.iconAction,
                        strokeWidth: 1.9,
                      ),
                    ),
                  ],
                  if (onMore case final onMore?) ...[
                    const SizedBox(width: 6),
                    Builder(
                      builder: (buttonContext) => CompactIconButton(
                        key: const ValueKey('page-more'),
                        tooltip: 'More',
                        extent: actionExtent,
                        radius: 10,
                        onPressed: moreActions.isEmpty
                            ? null
                            : () => _showMore(buttonContext, onMore),
                        icon: KapyIcon(
                          KapyIcons.moreRounded,
                          size: AppControlMetrics.iconAction,
                          strokeWidth: 2.2,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (center != null) Center(child: center),
        ],
      ),
    );
  }

  /// Opens under More, its right edge on the button's.
  void _showMore(BuildContext context, ValueChanged<String> onMore) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    unawaited(
      showKapyContextMenu<String>(
        context: context,
        globalPosition: box.localToGlobal(
          Offset(box.size.width, box.size.height + 4),
        ),
        items: [
          for (final action in moreActions)
            PopupMenuItem(
              key: ValueKey('page-more-${action.value}'),
              value: action.value,
              enabled: action.enabled,
              height: 36,
              child: KapyMenuActionRow(action, touch: false),
            ),
        ],
      ).then((choice) {
        if (choice != null) onMore(choice);
      }),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.space, required this.section});

  final String space;
  final String? section;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      fontSize: AppTypeScale.control,
      height: 16 / 13,
      color: palette.textTertiary,
    );
    final section = this.section;
    // Too narrow to read, it steps aside rather than overflow.
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < _minWidth
          ? const SizedBox.shrink()
          : _row(style, palette, section),
    );
  }

  static const double _minWidth = 48;

  Widget _row(TextStyle style, CalcPalette palette, String? section) {
    return Row(
      key: const ValueKey('page-breadcrumb'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            space,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        if (section != null) ...[
          const SizedBox(width: 8),
          ExcludeSemantics(
            child: Text('/', style: style.copyWith(color: palette.textDivider)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              section,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(
                fontWeight: FontWeight.w600,
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Saved, or what is keeping the note from being saved everywhere yet.
///
/// Every keystroke is written to this device as it is typed, so a note on
/// the page is always saved here; with an account it says whether the other
/// devices have it too.
class _SaveStatus extends StatelessWidget {
  const _SaveStatus(this.status);

  final SyncStatus? status;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (icon, label, tooltip) = switch (status) {
      SyncStatus.syncing => (KapyIcons.cloudRounded, 'Syncing', null),
      SyncStatus.offline => (
        KapyIcons.cloudOffRounded,
        'Offline',
        'Saved on this device. It syncs once you are back online.',
      ),
      SyncStatus.keysChanged => (
        KapyIcons.cloudRounded,
        'Saved',
        'Saved on this device. It syncs once you enter your new passphrase.',
      ),
      _ => (KapyIcons.cloudRounded, 'Saved', null),
    };
    final row = Padding(
      key: const ValueKey('page-saved'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KapyIcon(
            icon,
            size: 15,
            strokeWidth: 1.8,
            color: palette.textTertiary,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: AppTypeScale.body,
              height: 16 / 12.5,
              fontWeight: FontWeight.w500,
              color: palette.textTertiary,
            ),
          ),
        ],
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip, child: row);
  }
}
