import 'dart:async';

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
    required this.onMore,
    this.section,
    this.showListShortcut,
    this.noun = 'note',
    this.newNoteShortcut,
    this.noteOpen = false,
    this.syncStatus,
    this.members = const [],
    this.present = const [],
    this.currentUserId = '',
    this.noteShared = false,
    this.onShare,
    this.pinned = false,
    this.onTogglePin,
    this.moreActions = const [],
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

  final List<SpaceMember> members;
  final List<Collaborator> present;
  final String currentUserId;
  final bool noteShared;

  /// Null greys Share rather than removing it, so the buttons beside it stay
  /// put as the selection comes and goes.
  final VoidCallback? onShare;

  final bool pinned;
  final VoidCallback? onTogglePin;

  /// Everything else the page offers, under More.
  final List<KapyMenuAction> moreActions;
  final ValueChanged<String> onMore;

  /// Offers "Update and restart" once a release has downloaded. Null where
  /// the app does not update itself.
  final UpdateChecker? updates;

  /// Centred in the bar's empty middle, such as Write | Draw on a new note,
  /// where its going leaves nothing else to move.
  final Widget? center;

  /// A page that is not a note puts its own actions where a note's saved
  /// state, Share and Pin go. More stays.
  final List<Widget>? actions;

  static const double height = 56;

  /// Narrower than this, Saved steps aside for the breadcrumb.
  static const double _savedWidth = 460;

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
                      radius: 8,
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
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: WindowDragArea(
                        child: _Breadcrumb(space: space, section: section),
                      ),
                    ),
                  ),
                  if (actions case final actions?) ...[
                    if (updates != null)
                      UpdateRestartButton(
                        updates: updates,
                        wide: constraints.maxWidth >= _updateLabelWidth,
                      ),
                    ...actions,
                  ] else ...[
                    if (members.isNotEmpty)
                      Flexible(
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
                    if (updates != null)
                      UpdateRestartButton(
                        updates: updates,
                        wide: constraints.maxWidth >= _updateLabelWidth,
                      ),
                    if (noteOpen && constraints.maxWidth >= _savedWidth) ...[
                      _SaveStatus(syncStatus),
                      const SizedBox(width: 6),
                    ],
                    TonalButton(
                      key: const ValueKey('page-share'),
                      tall: true,
                      icon: KapyIcons.personAddRounded,
                      label: 'Share',
                      tooltip: noteShared ? 'Manage sharing' : null,
                      onPressed: onShare,
                    ),
                    const SizedBox(width: 6),
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
                  const SizedBox(width: 6),
                  Builder(
                    builder: (buttonContext) => CompactIconButton(
                      key: const ValueKey('page-more'),
                      tooltip: 'More',
                      extent: actionExtent,
                      radius: 10,
                      onPressed: moreActions.isEmpty
                          ? null
                          : () => _showMore(buttonContext),
                      icon: KapyIcon(
                        KapyIcons.moreRounded,
                        size: AppControlMetrics.iconAction,
                        strokeWidth: 2.2,
                      ),
                    ),
                  ),
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
  void _showMore(BuildContext context) {
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
