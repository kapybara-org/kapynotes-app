import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/editor_font.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../calc/engine.dart';
import '../data/folders.dart';
import '../data/layout_prefs.dart' show NotesGrouping;
import '../data/note.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import '../data/writing_streak.dart';
import '../sync/presence.dart';
import '../sync/safety.dart';
import '../sync/sharing.dart';
import '../sync/spaces.dart';
import '../sync/sync_api.dart' show SyncRefusedException;
import 'app_logo.dart';
import 'collaborator_colors.dart';
import 'compact_icon_button.dart';
import 'control_surface.dart';
import 'context_menu.dart';
import 'editor/note_footer.dart' show typingStatusText;
import 'editor_panes.dart';
import 'folders_ui.dart';
import 'installed_version.dart';
import 'keycap.dart';
import 'member_avatars.dart';
import 'note_picks.dart';
import 'notes_grouping.dart';
import 'notes_list.dart';
import 'safety_dialogs.dart';
import 'sidebar_timestamp.dart';
import 'streak_badge.dart';
import 'tag_colours.dart';
import 'tag_ui.dart';
import 'tonal_button.dart';
import 'window_drag_area.dart';

/// What putting a note away looks like, everywhere it is offered: the filing
/// box the spaces rail draws for the Archive.
///
/// A bare box once sent people looking for a delete that was not there, so
/// the box never stands alone: the rail names it Archive, the note menu says
/// Archive note, and the toast says where the note went. Destruction is
/// [deleteIcon], the crossed-out bin, the pairing mail clients use for the
/// same two ideas.
const KapyIconData archiveIcon = KapyIcons.archiveOutlined;

/// Taking a note out of the archive and back into the list.
///
/// Not `restore_from_trash`, which would have been the tidier pair: at the
/// 14pt the sidebar draws these at, a bin with an arrow in it and a bin with a
/// cross in it are the same shape, and the two sit side by side on every
/// archived row. An arrow turning back is legible at any size and cannot be
/// mistaken for a deletion.
const KapyIconData restoreIcon = KapyIcons.restoreRounded;

/// Gone for good, from here and from every device that syncs.
const KapyIconData deleteIcon = KapyIcons.deleteForeverOutlined;

/// The protected folder and the action that moves a note into it.
const KapyIconData hiddenIcon = KapyIcons.lockRounded;

/// Returns a note from Hidden Notes to the ordinary list.
const KapyIconData unhideIcon = KapyIcons.unlockRounded;

/// The two halves of a signed-in library.
///
/// A note belongs to whoever owns the space it is in. The person's own notes,
/// shared or not, are one list: sharing a note does not make it any less
/// theirs, so it stays where they left it and only gains the faces of the
/// people it is open to. Notes other people own are the other list.
enum SidebarTab { mine, shared }

/// Which tab [note] is listed under.
///
/// A shared note in a space this device has not heard the details of yet is
/// counted as somebody else's: the owner's own spaces are always known here,
/// since this device made them or was told about them when they were made.
SidebarTab sidebarTabOf(Note note, Sharing sharing) {
  if (!note.isShared) return SidebarTab.mine;
  final space = sharing.spaceOf(note);
  return space != null && space.ownerId == sharing.userId
      ? SidebarTab.mine
      : SidebarTab.shared;
}

/// The person's folders as the list beside the rail shows them: [shown]
/// puts the folder tree in place of the notes, [onShown] is the Notes |
/// Folders switch, left out where the list holds no folders (Drawings,
/// Shared, Archive and Hidden Notes), [open] and [onOpen] are the folders
/// open in the tree, and [inFront] and [onTab] are the folder the tab in
/// front shows and how a folder comes into a tab, left out without tabs.
typedef SidebarFolders = ({
  FolderStore store,
  bool shown,
  ValueChanged<bool>? onShown,
  Set<String> open,
  void Function(String folderId, bool open) onOpen,
  String? inFront,
  void Function(String folderId, {required bool behind})? onTab,
});

/// What can be done to many picked notes at once.
enum PickedAction { pin, unpin, hide, unhide, archive, restore, delete }

KapyIconData _pickedIcon(PickedAction action) => switch (action) {
  PickedAction.pin => KapyIcons.pinOutlined,
  PickedAction.unpin => KapyIcons.pinRounded,
  PickedAction.hide => hiddenIcon,
  PickedAction.unhide => unhideIcon,
  PickedAction.archive => archiveIcon,
  PickedAction.restore => restoreIcon,
  PickedAction.delete => deleteIcon,
};

/// The heading the notes waiting for a later day fold under.
const String _upcoming = 'Upcoming';

/// The note list, under the field that opens search.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.notes,
    this.pinnedNoteIds = const {},
    this.lockedNoteIds = const {},
    required this.selectedId,
    required this.query,
    required this.displayTime,
    required this.onSearch,
    required this.onSelect,
    this.onClearQuery,
    this.onCreate,
    this.onMoveSelect,
    this.onEnterSelected,
    this.onOpenToSide,
    this.openElsewhereIds = const {},
    this.onOpenInNewTab,
    this.onOpenSelectedInNewTab,
    this.tabbedIds = const {},
    this.onArchive,
    this.onRestore,
    this.onHide,
    this.onUnhide,
    this.onTogglePin,
    this.onShare,
    this.sharing,
    this.onSettingsPressed,
    this.searchShortcut,
    this.searchPlaceholder = 'Search',
    this.settingsShortcut,
    this.archiveShortcut,
    this.updates,
    this.archiveMode = false,
    this.hiddenMode = false,
    this.onDelete,
    this.asksBeforeDeleting = true,
    this.onDeleteAll,
    this.picks,
    this.onPicked,
    this.streak,
    this.collaborators = const {},
    this.onOpenSpace,
    this.tab = SidebarTab.mine,
    this.onTabChanged,
    this.windowBar,
    this.drawings = false,
    this.onNewDrawing,
    this.engine,
    this.now = DateTime.now,
    this.cards = false,
    this.controls,
    this.pinnedOnly = false,
    this.onPinnedOnlyChanged,
    this.grouping = NotesGrouping.byDate,
    this.onGroupingChanged,
    this.ownDay,
    this.upcomingOpen = false,
    this.onUpcomingToggled,
    this.when = NotesWhen.anyTime,
    this.onWhenChanged,
    this.folders,
  });

  /// The notes to list, already narrowed to [tab] while the tabs are shown.
  final List<Note> notes;
  final Set<String> pinnedNoteIds;

  /// Notes the note limit holds read-only, marked so the reason is visible
  /// before one is opened.
  final Set<String> lockedNoteIds;
  final String? selectedId;

  /// The search the ⌘K menu carried into Archive, which the list is narrowed
  /// to; empty everywhere else.
  final String query;
  final DateTime Function(DateTime) displayTime;

  /// Opens the ⌘K menu, from the field over the list.
  final VoidCallback onSearch;

  /// Drops [query]. Null leaves the field without its ✕.
  final VoidCallback? onClearQuery;
  final ValueChanged<String> onSelect;

  /// Makes a note from the + beside the search field. Null leaves the + out,
  /// as beside the spaces rail, where the window bar has New note.
  final VoidCallback? onCreate;

  /// Selects a row reached by sidebar arrow keys without committing its MRU
  /// position. Null uses [onSelect], as compact layouts do.
  final ValueChanged<String>? onMoveSelect;

  /// Hands the selected desktop note from the list to its editor. Null on
  /// layouts where choosing a row already leaves the sidebar.
  final VoidCallback? onEnterSelected;

  /// Puts a note in a pane beside the focused one, and is what lets rows be
  /// dragged onto the panes. Null in the compact and archive layouts, where
  /// there is only ever one note on screen.
  final ValueChanged<String>? onOpenToSide;

  /// Notes open in a pane other than the focused one. Their rows are ringed,
  /// so the list says what is already on screen before a click there would
  /// only move the focus to it.
  final Set<String> openElsewhereIds;

  /// Opens a note in a tab of its own behind the one in front: ⌘-click or
  /// Ctrl-click, a middle click, or the menu. Null in the compact and archive
  /// layouts, which have no tabs.
  final ValueChanged<String>? onOpenInNewTab;

  /// ⌘↵ or Ctrl+Enter while the list holds the keyboard: the highlighted note
  /// goes to a tab of its own.
  final VoidCallback? onOpenSelectedInNewTab;

  /// Notes open in a tab, in front or behind. A new tab for one of them would
  /// only be a second tab for the same note, so their menus leave it out.
  final Set<String> tabbedIds;
  final ValueChanged<String>? onArchive;
  final ValueChanged<String>? onRestore;
  final ValueChanged<String>? onHide;
  final ValueChanged<String>? onUnhide;
  final ValueChanged<String>? onTogglePin;

  /// Null where there is nothing to share to: a build without a server.
  /// The row then shows no share affordance rather than one that opens onto
  /// an error.
  final ValueChanged<String>? onShare;

  /// Names the spaces shared notes are in. Null until the account is
  /// unlocked; the list then reads exactly as it did before sharing existed.
  final Sharing? sharing;
  final VoidCallback? onSettingsPressed;
  final ShortcutBinding? searchShortcut;

  /// What the search field reads at rest: "Search", or "Search or Ask Kapy
  /// AI" where ⌘K can ask.
  final String searchPlaceholder;
  final ShortcutBinding? settingsShortcut;

  /// The key that files the open note away, for the row's menu to name.
  ///
  /// Worth the two words it takes: nothing else announces the chord, and a
  /// shortcut nobody can find is a shortcut nobody uses. Read from the
  /// binding rather than written out, so a rebound key is not misnamed here.
  final ShortcutBinding? archiveShortcut;

  /// Drives the Update badge beside the installed version. Null where the app
  /// store owns updates; the version still comes from the installed package.
  final UpdateChecker? updates;
  final bool archiveMode;
  final bool hiddenMode;

  /// Throws one note away for good, or takes one somebody else shares out of
  /// the reader's notes.
  final ValueChanged<String>? onDelete;

  /// Whether [onDelete] asks first, which its menu item says with an
  /// ellipsis.
  final bool asksBeforeDeleting;

  /// Empties the archive.
  final VoidCallback? onDeleteAll;

  /// The notes picked to act on together. Null where none can be. While
  /// any are picked, Back lets go of them rather than leaving the list.
  final NotePicks? picks;

  /// Does an action to the picked notes on screen it applies to, given in
  /// the list's order.
  final void Function(PickedAction action, List<String> ids)? onPicked;

  /// The run of days something has been written, shown at the end of the
  /// heading over the person's own notes. Null leaves it out.
  final WritingStreak? streak;

  /// Whoever else has each shared note open right now, by note. A row with
  /// somebody in it says so where its timestamp would be.
  final Map<String, List<Collaborator>> collaborators;

  /// Opens a shared space's people from its heading. Null leaves the heading
  /// a label.
  final ValueChanged<String>? onOpenSpace;

  /// Whose notes the list is showing. Only read while the tabs are shown:
  /// with an account unlocked, outside the archive and Hidden Notes.
  final SidebarTab tab;

  /// Switches tabs. Null leaves the tabs out, as a build without an account
  /// has nothing to put in the second one.
  final ValueChanged<SidebarTab>? onTabChanged;

  /// The bar across the top of the list in the wide window, where the spaces
  /// rail stands beside it: see [SidebarWindowBar].
  ///
  /// The rail holds what the list would otherwise carry, so with a window bar
  /// the tabs are left out while [tab] still narrows the list, and
  /// invitations wait under Shared, where the rail's badge points. Without
  /// one, the list is the compact layout's drawer, under the wordmark.
  final Widget? windowBar;

  /// Whether the list is the Drawings space: every item a drawing, shown by
  /// a thumbnail of it, with no media filter to narrow it by.
  final bool drawings;

  /// Starts a drawing from the empty Drawings space.
  final VoidCallback? onNewDrawing;

  /// Works out the sums a card or row shows under a note's title.
  final CalcEngine? engine;

  /// The clock a note's "Today" and "Sat" are told by.
  final DateTime Function() now;

  /// Whether the list beside the rail draws sticky cards rather than rows.
  final bool cards;

  /// The notes filter and the list/cards switch, under the search beside the
  /// rail: see [NotesListControls]. Null leaves them out, as the compact list
  /// does.
  final Widget? controls;

  /// Whether the list is showing every pinned note, after See all, rather
  /// than the four most recent over the rest.
  final bool pinnedOnly;
  final ValueChanged<bool>? onPinnedOnlyChanged;

  /// How the list beside the rail groups what Pinned leaves, and the menu
  /// on its first heading that changes it; without one there is no menu.
  final NotesGrouping grouping;
  final ValueChanged<NotesGrouping>? onGroupingChanged;

  /// The day a note was given, where it has one: those waiting for a later
  /// day fold into Upcoming above the day they were last edited.
  final DateTime? Function(Note note)? ownDay;

  /// Whether the Upcoming fold is open, and what opens it: closed until then.
  final bool upcomingOpen;
  final VoidCallback? onUpcomingToggled;

  /// How far back the filter reaches, for an empty list to say so and to
  /// offer any time again.
  final WhenFilter when;
  final ValueChanged<WhenFilter>? onWhenChanged;

  /// The person's folders: the Folders tab, and Move to folder… on their own
  /// notes. Null leaves folders out. While the tree shows, [notes] are the
  /// notes it files.
  final SidebarFolders? folders;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final controls = this.controls;

    // Solid, rather than the GlassSurface the toolbar and footer use: the
    // notes list stays put whatever the window is doing behind it. See
    // [CalcPalette.sidebarColor].
    final list = ColoredBox(
      color: palette.sidebarColor,
      // Colour runs to the window edges; content stays clear of the status
      // bar, home indicator and any display cutout.
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            windowBar ?? const _Header(),
            if (_showsTabs)
              _SidebarTabs(
                tab: tab,
                invitations: sharing!.invites.length,
                onChanged: onTabChanged!,
              ),
            SidebarSearchField(
              onSearch: onSearch,
              query: query,
              onClear: onClearQuery,
              onCreate: onCreate,
              shortcut: searchShortcut,
              placeholder: searchPlaceholder,
              belowTabs: _showsTabs,
              besideRail: _besideRail,
            ),
            if (controls != null && !_foldersTab)
              Padding(
                padding: _besideRail
                    ? const EdgeInsets.fromLTRB(16, 0, 16, 12)
                    : const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: controls,
              ),
            if (_picking || (archiveMode && notes.isNotEmpty)) _pickBar(),
            Expanded(
              child: _BelowInvitations(
                invitations:
                    !_specialMode &&
                        sharing != null &&
                        sharing!.invites.isNotEmpty &&
                        (!_besideRail || _onSharedTab)
                    ? _Invitations(
                        sharing: sharing!,
                        onJoined: onTabChanged == null
                            ? null
                            : () => onTabChanged!(SidebarTab.shared),
                      )
                    : null,
                child: _NoteListKeys(
                  onMoveSelected: _moveSelected,
                  onEnterSelected: onEnterSelected,
                  onOpenSelectedInNewTab: onOpenSelectedInNewTab,
                  onArchiveSelected: _archiveSelected,
                  onDeleteSelected: _deleteSelected,
                  onPickAll: picks == null || notes.isEmpty
                      ? null
                      : () => picks!.all(_order),
                  onExtendPick: picks == null || notes.isEmpty
                      ? null
                      : (delta) =>
                            picks!.step(_order, delta, open: _highlighted?.id),
                  onStopPicking: _picking ? picks!.clear : null,
                  archiveShortcut: archiveShortcut,
                  child: _foldersTab
                      ? _buildFolders(context)
                      : notes.isEmpty
                      ? _buildEmpty(context)
                      : _sweeps(
                          _besideRail
                              ? _buildBesideRail(context)
                              : _grouped
                              ? _buildGrouped(context)
                              : _buildUngrouped(context),
                        ),
                ),
              ),
            ),
            if (folders?.onShown case final onShown?)
              NotesFoldersSwitch(folders: _foldersTab, onChanged: onShown),
            if (onSettingsPressed != null)
              _SidebarFooter(
                onSettingsPressed: onSettingsPressed!,
                settingsShortcut: settingsShortcut,
                updates: updates,
              ),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: !_picking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) picks?.clear();
      },
      child: list,
    );
  }

  /// A note's card, or its row in the list view, away from the list: on a
  /// folder's page, with the face, clicks and menu it has here.
  Widget noteTile(Note note) => _row(
    note,
    shared: sharing != null && note.isShared,
    pinned: pinnedNoteIds.contains(note.id),
    style: cards ? NoteRowStyle.card : NoteRowStyle.row,
  );
}

extension on Sidebar {
  bool get _specialMode => archiveMode || hiddenMode;

  /// The tabs split the ordinary list only. The archive and Hidden Notes
  /// are folders of their own, and a build without an account has nobody
  /// else's notes to show.
  bool get _tabbed => sharing != null && !_specialMode && onTabChanged != null;

  bool get _besideRail => windowBar != null;

  /// The rail beside the list switches between the two halves itself.
  bool get _showsTabs => _tabbed && !_besideRail;

  bool get _onSharedTab => _tabbed && tab == SidebarTab.shared;

  bool get _foldersTab => folders?.shown ?? false;

  /// Whether Move to folder… files [note]: one of the person's own notes,
  /// which the Folders tab lists. Folders hold notes only, and an archived
  /// or Hidden note never shows in one.
  bool _files(Note note) =>
      folders != null &&
      !_specialMode &&
      !note.isDrawing &&
      (sharing == null || sidebarTabOf(note, sharing!) == SidebarTab.mine);

  bool get _hasPinned =>
      !_specialMode && notes.any((note) => pinnedNoteIds.contains(note.id));

  /// Sections appear once there is something meaningful to group, and over the
  /// whole list, whose heading is where the count of notes and the streak
  /// live. A search or the archive with no pins or shared notes in it stays
  /// exactly as quiet as the list was before any of these existed.
  bool get _grouped =>
      _hasPinned ||
      _summarised ||
      (_tabbed
          ? _onSharedTab && notes.isNotEmpty
          : sharing != null && notes.any((note) => note.isShared));

  /// Whether the heading over the person's own notes counts them and carries
  /// the streak: over the whole list only. A search result is not the
  /// library, the archive is where notes go once they are done with, and
  /// other people's notes are not the person's writing.
  bool get _summarised =>
      !_specialMode && !_onSharedTab && query.trim().isEmpty;

  Widget _buildEmpty(BuildContext context) {
    final onWhenChanged = this.onWhenChanged;
    if (query.trim().isEmpty && when != NotesWhen.anyTime) {
      return _SidebarEmpty(
        message: 'No ${drawings ? 'drawings' : 'notes'} ${when.phrase}',
        action: onWhenChanged == null
            ? null
            : (
                label: NotesWhen.anyTime.label,
                onPressed: () => onWhenChanged(NotesWhen.anyTime),
              ),
      );
    }
    if (drawings && query.trim().isEmpty) {
      return _DrawingsEmpty(onNewDrawing: onNewDrawing);
    }
    return _SidebarEmpty(
      message: query.trim().isEmpty
          ? archiveMode
                ? 'Archived Notes is empty'
                : hiddenMode
                ? 'Hidden Notes is empty'
                : _onSharedTab
                ? 'Nothing shared with you yet'
                : 'No notes yet'
          : drawings
          ? 'No matching drawings'
          : 'No matching notes',
      detail: query.trim().isEmpty && _onSharedTab
          ? 'Notes other people share with you appear here'
          : null,
    );
  }

  Widget _buildUngrouped(BuildContext context) {
    final extent = AppControlMetrics.scaleBar(
      context,
      AppControlMetrics.sidebarNoteRowExtent,
    );
    Widget rowBuilder(BuildContext context, int index) => SizedBox(
      height: extent,
      child: _row(
        notes[index],
        shared: sharing != null && notes[index].isShared,
      ),
    );

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      itemCount: notes.length,
      itemBuilder: rowBuilder,
    );
  }

  /// Whether the reader may change [note]: their own always, a shared one
  /// only where the space says so. The row's rule, and the keyboard's.
  bool _mayEdit(Note note) => sharing?.canEdit(note) ?? !note.isShared;

  /// What a row's delete says it does. A note somebody else owns only leaves
  /// the reader's notes, as the question that follows says; their own goes
  /// for good, which the archive spells out beside Restore. The ellipsis is
  /// the question, and goes with it.
  String _deleteLabel(Note note) {
    final label = _theirs(note)
        ? 'Remove note'
        : _specialMode
        ? 'Delete permanently'
        : 'Delete note';
    return asksBeforeDeleting ? '$label…' : label;
  }

  /// Whether [note] is somebody else's, shared with the reader: a delete only
  /// takes it out of their notes.
  bool _theirs(Note note) {
    final space = sharing?.spaceOf(note);
    return space != null && space.isTeam && !space.isOwner;
  }

  bool get _picking => picks?.on ?? false;

  /// The notes in the order their rows are painted, which is the order the
  /// arrows walk and a range of picks runs across.
  List<Note> get _painted => _besideRail
      ? _railOrder
      : _grouped
      ? _noteGroups.displayOrder
      : notes;

  List<String> get _order => [for (final note in _painted) note.id];

  /// The picked notes on screen, in the list's order. One picked in another
  /// list, or filtered out by a search, is not what an action here acts on.
  List<Note> get _picked => [
    for (final note in _painted)
      if (picks?.contains(note.id) ?? false) note,
  ];

  /// What can be done to the picked notes, each with the ones it applies to:
  /// the row menu's own rules, note by note, so one a reader may only view
  /// is left out of what would change it.
  List<(PickedAction, List<Note>)> get _pickedChoices {
    final picked = _picked;
    List<Note> those(bool Function(Note note) applies) =>
        picked.where(applies).toList();
    final unpinned = those((note) => !pinnedNoteIds.contains(note.id));
    return [
      if (onTogglePin != null)
        unpinned.isEmpty
            ? (PickedAction.unpin, picked)
            : (PickedAction.pin, unpinned),
      if (!_specialMode && onHide != null)
        (PickedAction.hide, those((note) => !note.isShared && _mayEdit(note))),
      if (archiveMode && onRestore != null)
        (PickedAction.restore, those(_mayEdit)),
      if (hiddenMode && onUnhide != null)
        (PickedAction.unhide, those(_mayEdit)),
      if (!_specialMode && onArchive != null)
        (PickedAction.archive, those(_mayEdit)),
      if (onDelete != null) (PickedAction.delete, those(_mayEdit)),
    ];
  }

  /// What an action says it does, and to how many, in the width of a menu.
  /// One note deletes as a row does, asking only if the reader still wants
  /// to be asked; more always ask.
  String _pickedLabel(PickedAction action, List<Note> notes) {
    final many = notes.length > 1;
    final count = many ? '${notes.length} notes' : 'note';
    return switch (action) {
      PickedAction.pin => 'Pin $count',
      PickedAction.unpin => 'Unpin $count',
      PickedAction.hide => many ? 'Hide $count' : 'Move to Hidden Notes',
      PickedAction.unhide =>
        many ? 'Move ${notes.length} to Notes' : 'Move to Notes',
      PickedAction.archive => 'Archive $count',
      PickedAction.restore => 'Restore $count',
      PickedAction.delete =>
        !many
            ? _deleteLabel(notes.single)
            : notes.every(_theirs)
            ? 'Remove $count…'
            : 'Delete $count…',
    };
  }

  /// The menu a right click or long press opens on picked notes.
  List<KapyMenuAction> _pickedMenu() => [
    for (final (action, notes) in _pickedChoices)
      if (notes.isNotEmpty)
        KapyMenuAction(
          value: 'picked-${action.name}',
          label: _pickedLabel(action, notes),
          icon: _pickedIcon(action),
          destructive:
              action == PickedAction.archive || action == PickedAction.delete,
        ),
  ];

  void _choosePicked(String value) {
    for (final (action, notes) in _pickedChoices) {
      if (value != 'picked-${action.name}' || notes.isEmpty) continue;
      onPicked?.call(action, [for (final note in notes) note.id]);
    }
  }

  /// [action] on the picked notes it applies to; null where it applies to
  /// none of them, which greys its button out.
  VoidCallback? _pickedAction(PickedAction action) {
    final onPicked = this.onPicked;
    if (onPicked == null) return null;
    for (final (each, notes) in _pickedChoices) {
      if (each != action || notes.isEmpty) continue;
      return () => onPicked(action, [for (final note in notes) note.id]);
    }
    return null;
  }

  /// Over the list while notes are picked: how many, and what most often
  /// happens to them. The rest is in their menu. Over the archive at rest,
  /// its Select and Delete all.
  Widget _pickBar() {
    final picks = this.picks;
    if (picks == null || !picks.on) {
      return _PickActions(
        label: 'Archived Notes',
        buttons: [
          _IconButton(
            key: const ValueKey('archive-start-selecting'),
            icon: KapyIcons.checklistRounded,
            tooltip: 'Select notes',
            onPressed: picks?.start,
          ),
          _IconButton(
            key: const ValueKey('archive-delete-all'),
            icon: KapyIcons.deleteSweepOutlined,
            tooltip: 'Delete all',
            onPressed: onDeleteAll,
          ),
        ],
      );
    }
    final picked = _picked.length;
    final order = _order;
    final (primary, primaryTip) = archiveMode
        ? (PickedAction.restore, 'Restore selected')
        : hiddenMode
        ? (PickedAction.unhide, 'Move selected to Notes')
        : (PickedAction.archive, 'Archive selected');
    final offered = {for (final (action, _) in _pickedChoices) action};
    return _PickActions(
      label: picked == 0 ? 'Select notes' : '$picked selected',
      buttons: [
        if (picked < order.length)
          _IconButton(
            key: const ValueKey('pick-all'),
            icon: KapyIcons.selectAllRounded,
            tooltip: 'Select all',
            onPressed: () => picks.all(order),
          ),
        if (offered.contains(primary))
          _IconButton(
            key: ValueKey('picked-${primary.name}'),
            icon: _pickedIcon(primary),
            tooltip: primaryTip,
            onPressed: _pickedAction(primary),
          ),
        if (offered.contains(PickedAction.delete))
          _IconButton(
            key: const ValueKey('picked-delete'),
            icon: deleteIcon,
            tooltip: 'Delete selected',
            onPressed: _pickedAction(PickedAction.delete),
          ),
        _IconButton(
          key: const ValueKey('pick-done'),
          icon: KapyIcons.closeRounded,
          tooltip: 'Done selecting',
          onPressed: picks.clear,
        ),
      ],
    );
  }

  /// A ⌘-click, or a Ctrl-click off a Mac, on a note while nothing is
  /// picked: the one place that decides what it does. Where notes open in
  /// tabs it opens the note in a tab behind, as a browser does, and a note
  /// with a tab already stays where it is. Elsewhere, as in the archive, it
  /// starts picking with the open note and this one, as Finder does.
  void _commandClick(Note note) {
    if (onOpenInNewTab case final openInNewTab?) {
      if (!tabbedIds.contains(note.id)) openInNewTab(note.id);
      return;
    }
    picks!.toggle(note.id, open: _highlighted?.id);
  }

  /// Lets a mouse press dragged down the rows pick every note it crosses.
  Widget _sweeps(Widget list) {
    final picks = this.picks;
    if (picks == null || !AppPlatform.hasPointer) return list;
    return NoteSweep(
      onStart: picks.sweepFrom,
      onUpdate: (id) => picks.sweepTo(_order, id),
      child: list,
    );
  }

  /// The note a keypress acts on: the highlighted one, as long as the list on
  /// screen is really showing it. A selection a search has filtered out, or
  /// one left behind in the other list, is not what the reader is looking at
  /// and must not be what a key removes.
  Note? get _highlighted {
    final id = selectedId;
    if (id == null) return null;
    for (final note in notes) {
      if (note.id == id) return note;
    }
    return null;
  }

  /// Files the highlighted note away: what the archive shortcut does in the
  /// list, mirroring the glyph the row itself offers, or files away every
  /// picked note while there are picks. Null where there is nothing to file.
  VoidCallback? get _archiveSelected {
    if (_specialMode || onArchive == null) return null;
    if (_picking) return _pickedAction(PickedAction.archive);
    final note = _highlighted;
    if (note == null || !_mayEdit(note)) return null;
    return () => onArchive!(note.id);
  }

  /// Throws it away for good, or every picked note while there are picks.
  /// Archive and Hidden Notes only: in the list the key files the note away
  /// instead, which keeps it.
  VoidCallback? get _deleteSelected {
    if (!_specialMode) return null;
    if (_picking) return _pickedAction(PickedAction.delete);
    if (onDelete == null) return null;
    final note = _highlighted;
    if (note == null || !_mayEdit(note)) return null;
    return () => onDelete!(note.id);
  }

  /// Moves the highlight in the same order the rows are painted.
  ///
  /// This is deliberately owned by the sidebar rather than the window-wide
  /// next-note shortcut: sections can lift pinned and shared notes out of the
  /// store's order, and an arrow key must follow what is visibly above or
  /// below the current row.
  void _moveSelected(int delta) {
    if (_picking) return;
    final ordered = _painted;
    if (ordered.length < 2) return;
    final current = ordered.indexWhere((note) => note.id == selectedId);
    final next = current < 0
        ? (delta > 0 ? 0 : ordered.length - 1)
        : (current + delta) % ordered.length;
    (onMoveSelect ?? onSelect)(ordered[next].id);
  }

  /// The space whose people a shared row shows at its end: wherever the row
  /// is not already under that space's own heading, which shows them.
  Space? _peopleOf(Note note, {required bool shared, required bool pinned}) {
    if (!shared || !_tabbed || (_onSharedTab && !pinned)) return null;
    return sharing?.spaceOf(note);
  }

  Widget _row(
    Note note, {
    required bool shared,
    bool pinned = false,
    NoteRowStyle style = NoteRowStyle.compact,
    int depth = 0,
  }) => MetaData(
    metaData: NotePickTarget(note.id),
    child: _noteRow(
      note,
      shared: shared,
      pinned: pinned,
      style: style,
      depth: depth,
    ),
  );

  Widget _noteRow(
    Note note, {
    required bool shared,
    required bool pinned,
    required NoteRowStyle style,
    required int depth,
  }) => NoteRow(
    key: ValueKey(note.id),
    note: note,
    style: style,
    depth: depth,
    folders: _files(note) ? folders?.store : null,
    engine: engine,
    now: now,
    query: query,
    displayTime: displayTime,
    selected: note.id == selectedId,
    shared: shared,
    pinned: pinned,
    locked: lockedNoteIds.contains(note.id),
    collaborators: shared ? collaborators[note.id] ?? const [] : const [],
    sharedWith: _peopleOf(note, shared: shared, pinned: pinned),
    currentUserId: sharing?.userId ?? '',
    onTap: () => onSelect(note.id),
    onOpenToSide: onOpenToSide == null ? null : () => onOpenToSide!(note.id),
    openElsewhere: openElsewhereIds.contains(note.id),
    onOpenInNewTab: onOpenInNewTab == null
        ? null
        : () => onOpenInNewTab!(note.id),
    tabbed: tabbedIds.contains(note.id),
    onTogglePin: onTogglePin == null ? null : () => onTogglePin!(note.id),
    archiveShortcut: archiveShortcut,
    onShare: _specialMode || onShare == null ? null : () => onShare!(note.id),
    onArchive: _specialMode || onArchive == null || !_mayEdit(note)
        ? null
        : () => onArchive!(note.id),
    onRestore: !archiveMode || onRestore == null || !_mayEdit(note)
        ? null
        : () => onRestore!(note.id),
    onHide: _specialMode || note.isShared || onHide == null || !_mayEdit(note)
        ? null
        : () => onHide!(note.id),
    onUnhide: !hiddenMode || onUnhide == null || !_mayEdit(note)
        ? null
        : () => onUnhide!(note.id),
    onDelete: onDelete == null || !_mayEdit(note)
        ? null
        : () => onDelete!(note.id),
    deleteLabel: _deleteLabel(note),
    selecting: _picking,
    checked: picks?.contains(note.id) ?? false,
    onToggleChecked: picks == null ? null : () => picks!.toggle(note.id),
    onCommandClick: picks == null && onOpenInNewTab == null
        ? null
        : () => _commandClick(note),
    onPickTo: picks == null || !AppPlatform.hasPointer
        ? null
        : () => picks!.extendTo(_order, note.id, open: _highlighted?.id),
    pickedActions: picks == null ? null : _pickedMenu,
    onPickedAction: _choosePicked,
  );

  /// Pinned notes lead, then the shared spaces, then everything else.
  ///
  /// Shared notes come before your own because they are the ones that move
  /// without you: a space you are in changes while you are not looking, and
  /// the list is where you would find out. Your own notes are where you left
  /// them, so they can wait at the bottom.
  ///
  /// A note appears once. Pinning lifts it out of whichever section it would
  /// otherwise have been in rather than repeating it there.
  SidebarNoteGroups get _noteGroups => SidebarNoteGroups(
    notes: notes,
    pinnedNoteIds: pinnedNoteIds,
    sharing: sharing,
    specialMode: _specialMode,
    tab: _tabbed ? tab : null,
  );

  /// The pinned notes the list beside the rail shows over the rest: the four
  /// most recent, unless See all or a search asks for every one.
  List<Note> _shownPinned(SidebarNoteGroups groups) =>
      pinnedOnly || query.trim().isNotEmpty
      ? groups.pinned
      : groups.pinned.take(_pinnedPreview).toList();

  static const _pinnedPreview = 4;

  List<Note> get _railOrder {
    if (folders case final folders? when folders.shown) {
      final (:tree, :loose) = folderLines(
        folders.store.tree,
        notes,
        folders.open,
      );
      return [
        for (final line in tree)
          if (line case NoteLine(:final note)) note,
        ...loose,
      ];
    }
    final groups = _noteGroups;
    if (pinnedOnly) return groups.pinned;
    return [
      ..._shownPinned(groups),
      for (final id in groups.spaceOrder) ...groups.bySpace[id]!,
      ...groups.mine,
    ];
  }

  /// The list beside the spaces rail: Pinned, then each shared space, then
  /// Notes, as sticky cards two to a row or as rows, fading out at the foot.
  Widget _buildBesideRail(BuildContext context) {
    final palette = context.palette;
    final groups = _noteGroups;
    final pinned = _shownPinned(groups);
    final rows = <WidgetBuilder>[];
    final style = switch ((cards, drawings)) {
      (true, true) => NoteRowStyle.drawingCard,
      (true, false) => NoteRowStyle.card,
      (false, true) => NoteRowStyle.drawingRow,
      (false, false) => NoteRowStyle.row,
    };
    final noun = drawings ? 'drawing' : 'note';
    final onPinnedOnlyChanged = this.onPinnedOnlyChanged;

    void gap(double height) => rows.add((_) => SizedBox(height: height));

    void heading(Widget heading) {
      if (rows.isNotEmpty) gap(24);
      rows.add(
        (_) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: heading,
        ),
      );
      gap(cards ? 8 : 4);
    }

    void section(Iterable<Note> notes, {bool pinned = false}) {
      final list = notes.toList();
      Widget note(Note note) => _row(
        note,
        shared: sharing != null && note.isShared,
        pinned: pinned,
        style: style,
      );
      if (!cards) {
        for (final (index, each) in list.indexed) {
          if (index > 0) gap(2);
          rows.add(
            (_) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: note(each),
            ),
          );
        }
        return;
      }
      for (var index = 0; index < list.length; index += 2) {
        if (index > 0) gap(12);
        final pair = list.skip(index).take(2).toList();
        rows.add(
          (context) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: AppControlMetrics.scaleBar(
                context,
                drawings ? DrawingCardFace.height : NoteCardFace.height,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: note(pair.first)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: pair.length > 1 ? note(pair.last) : const SizedBox(),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    final pin = KapyIcon(
      KapyIcons.pinOutlined,
      size: 16,
      strokeWidth: 1.9,
      color: palette.clay,
    );
    if (_specialMode) {
      section(notes);
      if (hiddenMode) {
        gap(12);
        rows.add(
          (_) => Padding(
            key: const ValueKey('sidebar-hidden-locks-again'),
            padding: const EdgeInsets.fromLTRB(20, 6, 18, 0),
            child: Row(
              children: [
                KapyIcon(
                  hiddenIcon,
                  size: 13,
                  strokeWidth: 1.8,
                  color: palette.textTertiary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Locks again when you leave Hidden',
                    style: TextStyle(
                      fontSize: AppTypeScale.small,
                      height: 16 / AppTypeScale.small,
                      color: palette.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } else if (pinnedOnly) {
      heading(
        NotesListHeading(
          label: 'Pinned',
          count: groups.pinned.length,
          noun: noun,
          height: 22,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CompactIconButton(
                key: const ValueKey('sidebar-pinned-back'),
                tooltip: 'Back to all notes',
                extent: 22,
                foregroundColor: palette.textSecondary,
                onPressed: onPinnedOnlyChanged == null
                    ? null
                    : () => onPinnedOnlyChanged(false),
                icon: const KapyIcon(
                  KapyIcons.chevronLeftRounded,
                  size: 13,
                  strokeWidth: 2,
                ),
              ),
              const SizedBox(width: 6),
              pin,
            ],
          ),
        ),
      );
      section(groups.pinned, pinned: true);
    } else {
      if (pinned.isNotEmpty) {
        heading(
          NotesListHeading(
            key: const ValueKey('sidebar-pinned-heading'),
            label: 'Pinned',
            count: groups.pinned.length,
            noun: noun,
            height: 16,
            leading: pin,
            trailing:
                pinned.length < groups.pinned.length &&
                    onPinnedOnlyChanged != null
                ? SeeAllLink(
                    key: const ValueKey('sidebar-see-all-pinned'),
                    onPressed: () => onPinnedOnlyChanged(true),
                  )
                : null,
          ),
        );
        section(pinned, pinned: true);
      }
      for (final id in groups.spaceOrder) {
        heading(
          _SpaceHeader(
            key: ValueKey('space-header-$id'),
            space: sharing?.spaceById(id),
            currentUserId: sharing?.userId ?? '',
            present: {
              for (final note in groups.bySpace[id]!)
                for (final person in collaborators[note.id] ?? const [])
                  person.userId,
            },
            attention:
                id != null &&
                (sharing?.trust.warningsFor(id).isNotEmpty ?? false),
            onTap: id == null || onOpenSpace == null
                ? null
                : () => onOpenSpace!(id),
          ),
        );
        section(groups.bySpace[id]!);
      }
      final onGroupingChanged = this.onGroupingChanged;
      final grouped = groupNotes(
        groups.mine,
        grouping,
        today: dayShown(now(), displayTime),
        displayTime: displayTime,
        firstTag: (note) => TagMarks.of(context, note.id).firstOrNull?.name,
        ownDay: ownDay,
      );
      // The menu goes on the first heading that is not the fold, so it stays
      // where it always was.
      final menuAt = grouped.indexWhere((group) => group.label != _upcoming);
      for (final (index, group) in grouped.indexed) {
        final fold = group.label == _upcoming;
        heading(
          NotesGroupHeading(
            key: ValueKey('sidebar-group-${group.label}'),
            label: group.label,
            detail: group.detail,
            folded: fold ? !upcomingOpen : null,
            onTap: fold ? onUpcomingToggled : null,
            trailing: index == menuAt && onGroupingChanged != null
                ? NotesGroupingMenu(
                    grouping: grouping,
                    onChanged: onGroupingChanged,
                  )
                : null,
          ),
        );
        if (!fold || upcomingOpen) section(group.notes);
      }
    }

    return _fading(
      context,
      ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 40),
        itemCount: rows.length,
        itemBuilder: (context, index) => rows[index](context),
      ),
    );
  }

  /// The Folders tab: the folder tree, then the notes in no folder.
  Widget _buildFolders(BuildContext context) {
    final folders = this.folders!;
    final today = dayShown(now(), displayTime);
    final upcoming = [
      for (final note in notes)
        if (ownDay?.call(note) case final day? when day.isAfter(today)) note,
    ];
    return _fading(
      context,
      FoldersTab(
        store: folders.store,
        notes: notes,
        open: folders.open,
        onOpen: folders.onOpen,
        inFront: folders.inFront,
        onTab: folders.onTab,
        upcoming: upcoming,
        noteRow: (note, depth) => _row(
          note,
          shared: sharing != null && note.isShared,
          style: depth == null ? NoteRowStyle.loose : NoteRowStyle.filed,
          depth: depth ?? 0,
        ),
      ),
    );
  }

  /// [list] fading out at the foot of the list beside the rail.
  Widget _fading(BuildContext context, Widget list) {
    final palette = context.palette;
    return Stack(
      children: [
        list,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 64,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    palette.sidebarColor.withValues(alpha: 0),
                    palette.sidebarColor,
                  ],
                  stops: const [0, 0.85],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGrouped(BuildContext context) {
    final groups = _noteGroups;
    final pinned = groups.pinned;
    final mine = groups.mine;
    final bySpace = groups.bySpace;
    final order = groups.spaceOrder;
    final hasSharedSections = groups.hasSharedSections;
    final extent = AppControlMetrics.scaleBar(
      context,
      AppControlMetrics.sidebarNoteRowExtent,
    );
    // Pinned ones included: the number is how many notes are theirs, not how
    // many happen to sit under the heading. Behind the tabs every note in
    // this list is theirs, shared or not.
    final ownCount = hasSharedSections && !_tabbed
        ? notes.where((note) => !note.isShared).length
        : notes.length;
    final summary = _summarised && ownCount > 0;

    // The order of the list as data, so that only the rows on screen are
    // built. One pin used to turn the whole list into a widget per note,
    // which for a long library is most of the sidebar's memory for nothing
    // anybody can see.
    final entries = <_GroupedEntry>[
      if (pinned.isNotEmpty) ...[
        const _GroupedLabel(
          _SectionLabel(label: 'Pinned', icon: KapyIcons.pinOutlined),
        ),
        for (final note in pinned)
          _GroupedNote(
            note,
            shared: sharing != null && note.isShared,
            pinned: true,
          ),
      ],
      for (final id in order) ...[
        _GroupedLabel(
          _SpaceHeader(
            key: ValueKey('space-header-$id'),
            space: sharing?.spaceById(id),
            currentUserId: sharing?.userId ?? '',
            present: {
              for (final note in bySpace[id]!)
                for (final person in collaborators[note.id] ?? const [])
                  person.userId,
            },
            attention:
                id != null &&
                (sharing?.trust.warningsFor(id).isNotEmpty ?? false),
            onTap: id == null || onOpenSpace == null
                ? null
                : () => onOpenSpace!(id),
          ),
        ),
        for (final note in bySpace[id]!) _GroupedNote(note, shared: true),
      ],
      // Kept when every note of theirs is pinned, as a heading with nothing
      // under it, rather than the count and the streak leaving with the notes.
      if (mine.isNotEmpty || summary) ...[
        _GroupedLabel(
          _SectionLabel(
            label: drawings
                ? 'Drawings'
                : hasSharedSections && !_tabbed
                ? 'My notes'
                : 'Notes',
            count: summary ? ownCount : null,
            streak: summary && !drawings ? streak : null,
          ),
        ),
        for (final note in mine)
          _GroupedNote(note, shared: sharing != null && note.isShared),
      ],
    ];

    Widget entryBuilder(BuildContext context, int index) =>
        switch (entries[index]) {
          _GroupedLabel(:final label) => label,
          _GroupedNote(:final note, :final shared, :final pinned) => SizedBox(
            height: extent,
            child: _row(note, shared: shared, pinned: pinned),
          ),
        };

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      itemCount: entries.length,
      itemBuilder: entryBuilder,
    );
  }
}

/// The keys the note list answers for the note it has highlighted.
///
/// A focus of its own rather than a binding over the whole window, because
/// the same arrows have to go on moving the caret while somebody is typing:
/// the only thing that tells the two apart is where the keyboard is pointed.
/// Pressing anywhere in the list points it here, and the search field above
/// is outside this subtree, so it keeps its own keys untouched.
///
/// Left out on touch, which has no Delete key and would only lose its
/// on-screen keyboard to this.
class _NoteListKeys extends StatefulWidget {
  const _NoteListKeys({
    required this.onMoveSelected,
    required this.onEnterSelected,
    required this.onOpenSelectedInNewTab,
    required this.onArchiveSelected,
    required this.onDeleteSelected,
    required this.onPickAll,
    required this.onExtendPick,
    required this.onStopPicking,
    required this.archiveShortcut,
    required this.child,
  });

  /// Walks the highlight by one visible row. Negative is up, positive down.
  final ValueChanged<int> onMoveSelected;

  /// ⌘A, or Ctrl+A off a Mac: picks every note in the list. Null where
  /// nothing can be picked, which leaves the chord to whoever else wants it.
  final VoidCallback? onPickAll;

  /// Shift with ↑ or ↓: the picked range one row further that way.
  final ValueChanged<int>? onExtendPick;

  /// Esc while notes are picked, which lets them go. Null otherwise, so Esc
  /// goes on to whatever it closes.
  final VoidCallback? onStopPicking;

  /// Moves focus from the selected row into its editor.
  final VoidCallback? onEnterSelected;

  /// Puts the selected row's note in a tab of its own: ⌘↵, or Ctrl+Enter.
  final VoidCallback? onOpenSelectedInNewTab;

  /// Files the highlighted note away, exactly as its own glyph does. Null
  /// where nothing in the list can be archived.
  final VoidCallback? onArchiveSelected;

  /// Throws it away for good: Archive and Hidden Notes only, behind the
  /// question the menu item asks, unless the reader said not to ask.
  final VoidCallback? onDeleteSelected;

  /// The one press that removes the highlighted note: the same shortcut the
  /// editor answers, so it means one thing wherever the keyboard is. Null
  /// where the reader has cleared it, and then no key removes a note here.
  final ShortcutBinding? archiveShortcut;

  final Widget child;

  @override
  State<_NoteListKeys> createState() => _NoteListKeysState();
}

class _NoteListKeysState extends State<_NoteListKeys> {
  final FocusNode _node = FocusNode(debugLabel: 'Notes list');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  /// Whether [event] is the archive shortcut, the press this list answers by
  /// removing the note it has picked.
  ///
  /// Never Delete on its own, on any platform. Any press in the list hands it
  /// the keyboard, a click on the note already open included, and nothing on
  /// screen says so: the caret just goes out. A Delete meant for the note's
  /// text then filed the whole note away.
  ///
  /// Only the press, never the repeat: a key held down must not empty the
  /// list.
  bool _removes(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final shortcut = widget.archiveShortcut;
    return shortcut != null &&
        shortcut.activator.accepts(event, HardwareKeyboard.instance);
  }

  /// Bare vertical arrows belong to the list while it holds the keyboard.
  /// Repeats are welcome here: holding an arrow is how long lists are walked.
  static int? _movement(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return null;
    }
    return switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      _ => null,
    };
  }

  /// ⌘↵ on a Mac, Ctrl+Enter elsewhere: a browser's open in a new tab.
  static bool _opensInNewTab(KeyEvent event) {
    if (event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter)) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    return (AppPlatform.isMacOS
            ? keyboard.isMetaPressed && !keyboard.isControlPressed
            : keyboard.isControlPressed && !keyboard.isMetaPressed) &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
  }

  /// Shift with a vertical arrow, and no other modifier: how far the picked
  /// range grows. Repeats too, as a held arrow walks the list.
  static int? _extension(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isShiftPressed ||
        keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return null;
    }
    return switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      _ => null,
    };
  }

  /// ⌘A on a Mac, Ctrl+A elsewhere, alone.
  static bool _picksAll(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyA) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    final command = AppPlatform.isMacOS
        ? keyboard.isMetaPressed && !keyboard.isControlPressed
        : keyboard.isControlPressed && !keyboard.isMetaPressed;
    return command && !keyboard.isShiftPressed && !keyboard.isAltPressed;
  }

  static bool _entersEditor(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    return !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
  }

  /// Not past a question the press put on screen: the dialog has the
  /// keyboard until it is answered, and hands it back here itself.
  void _keepFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        _node.requestFocus();
      }
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_opensInNewTab(event)) {
      final open = widget.onOpenSelectedInNewTab;
      if (open == null) return KeyEventResult.ignored;
      open();
      _keepFocus();
      return KeyEventResult.handled;
    }

    if (_entersEditor(event)) {
      final enter = widget.onEnterSelected;
      if (enter == null) return KeyEventResult.ignored;
      enter();
      return KeyEventResult.handled;
    }

    final pickAll = widget.onPickAll;
    if (pickAll != null && _picksAll(event)) {
      pickAll();
      return KeyEventResult.handled;
    }

    final extendPick = widget.onExtendPick;
    final extension = _extension(event);
    if (extendPick != null && extension != null) {
      extendPick(extension);
      return KeyEventResult.handled;
    }

    final stopPicking = widget.onStopPicking;
    if (stopPicking != null &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      stopPicking();
      return KeyEventResult.handled;
    }

    final movement = _movement(event);
    if (movement != null) {
      widget.onMoveSelected(movement);
      // A newly mounted editor may ask for autofocus as the note changes.
      // The arrow came from the list, so leave the keyboard here for the next
      // press instead of turning it into caret movement halfway through.
      _keepFocus();
      return KeyEventResult.handled;
    }

    if (!_removes(event)) return KeyEventResult.ignored;

    // A delete that asks first leaves the keyboard to its question; one the
    // reader told not to ask goes at once, and the next note's editor must
    // not take the keyboard for the next press.
    final delete = widget.onDeleteSelected;
    if (delete != null) {
      delete();
      _keepFocus();
      return KeyEventResult.handled;
    }

    final archive = widget.onArchiveSelected;
    if (archive == null) return KeyEventResult.ignored;
    archive();
    // Archiving the open note moves the caret into whichever note takes its
    // place, which is right when the note was archived from the editor and
    // wrong when the press came from here: the next arrow would move that
    // note's caret instead of walking the list. Asking for the keyboard back
    // afterwards is answered after that, post-frame callbacks running in the
    // order they were asked for.
    _keepFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!AppPlatform.hasPointer) return widget.child;
    return Focus(
      focusNode: _node,
      // Reached by pressing in the list, never by Tab: a stop in the ring
      // that draws nothing when it arrives is a stop nobody can explain.
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        // A listener rather than a gesture, so every tap still reaches the
        // row it was aimed at. Taken once the press has reached everything
        // else: the note being typed in lets go of the keyboard when pressed
        // outside of, and that must not undo this. Not past a menu the press
        // put on screen.
        onPointerDown: (_) => scheduleMicrotask(() {
          if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
            _node.requestFocus();
          }
        }),
        child: widget.child,
      ),
    );
  }
}

/// One line of the grouped sidebar: a heading, or a note under one.
sealed class _GroupedEntry {
  const _GroupedEntry();
}

class _GroupedLabel extends _GroupedEntry {
  const _GroupedLabel(this.label);

  final Widget label;
}

class _GroupedNote extends _GroupedEntry {
  const _GroupedNote(this.note, {required this.shared, this.pinned = false});

  final Note note;
  final bool shared;
  final bool pinned;
}

/// The note-only shape of the grouped list, shared by painting and keyboard
/// navigation so the row above on screen is also the row Arrow Up selects.
class SidebarNoteGroups {
  SidebarNoteGroups({
    required List<Note> notes,
    required Set<String> pinnedNoteIds,
    required Sharing? sharing,
    required bool specialMode,
    SidebarTab? tab,
  }) : pinned = specialMode
           ? const []
           : notes.where((note) => pinnedNoteIds.contains(note.id)).toList(),
       // Behind the tabs the person's own shared notes sit among the rest,
       // and only other people's are gathered under their spaces.
       hasSharedSections = switch (tab) {
         SidebarTab.mine => false,
         SidebarTab.shared => sharing != null && notes.isNotEmpty,
         null => sharing != null && notes.any((note) => note.isShared),
       } {
    final pinnedIds = pinned.map((note) => note.id).toSet();
    final remaining = notes
        .where((note) => !pinnedIds.contains(note.id))
        .toList();
    mine = hasSharedSections
        ? remaining.where((note) => !note.isShared).toList()
        : remaining;
    if (hasSharedSections) {
      for (final note in remaining) {
        if (note.isShared) {
          bySpace.putIfAbsent(note.spaceId, () => []).add(note);
        }
      }
    }
    spaceOrder = <String?>[
      if (sharing != null)
        for (final space in sharing.teams)
          if (bySpace.containsKey(space.id)) space.id,
      for (final id in bySpace.keys)
        if (sharing == null || !sharing.teams.any((space) => space.id == id))
          id,
    ];
  }

  final List<Note> pinned;
  late final List<Note> mine;
  final Map<String?, List<Note>> bySpace = {};
  late final List<String?> spaceOrder;
  final bool hasSharedSections;

  List<Note> get displayOrder => [
    ...pinned,
    for (final id in spaceOrder) ...bySpace[id]!,
    ...mine,
  ];
}

/// A heading over a group of notes. Small and quiet: the notes are the
/// content, this only says whose they are.
///
/// The one over the person's own notes also says how many there are and, at
/// its far end, how many days in a row they have written.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.label,
    this.icon,
    this.count,
    this.streak,
  });

  final String label;
  final KapyIconData? icon;

  /// How many notes the heading stands for, beside its name.
  final int? count;

  /// Shown only while there is a run to show: a zero would be a reproach
  /// rather than a record.
  final WritingStreak? streak;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final icon = this.icon;
    final count = this.count;
    final streak = this.streak;
    return Padding(
      // Room under the heading, so it reads as the head of the notes rather
      // than as the top line of the first one.
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Row(
        children: [
          if (icon != null) ...[
            KapyIcon(
              icon,
              size: AppControlMetrics.iconInline,
              color: palette.textTertiary,
            ),
            const SizedBox(width: 5),
          ],
          // The count stays against the name and the streak holds the far
          // edge; on a narrow sidebar the name gives way first.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.3,
                      color: palette.textTertiary,
                    ),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  _NoteCount(count: count),
                ],
              ],
            ),
          ),
          if (streak != null && streak.days > 0) ...[
            const SizedBox(width: 8),
            StreakBadge(key: const ValueKey('sidebar-streak'), streak: streak),
          ],
        ],
      ),
    );
  }
}

/// How many notes a heading stands for.
///
/// A number on a quiet chip rather than "24 notes": it sits against a heading
/// that already says what is being counted, the way a mail folder's does.
class _NoteCount extends StatelessWidget {
  const _NoteCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // The tooltip is what a screen reader hears: "3 notes", where the bare
    // figure would be read as just a number.
    return Tooltip(
      message: count == 1 ? '1 note' : '$count notes',
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('sidebar-note-count'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: palette.hover,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              fontWeight: FontWeight.w400,
              height: 1.2,
              color: palette.textTertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({
    required this.onSettingsPressed,
    this.settingsShortcut,
    this.updates,
  });

  final VoidCallback onSettingsPressed;
  final ShortcutBinding? settingsShortcut;
  final UpdateChecker? updates;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: AppControlMetrics.scaleBar(
        context,
        AppControlMetrics.footerHeight,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: palette.separator,
            width: AppHairline.of(context),
          ),
        ),
      ),
      child: InstalledVersion(
        updates: updates,
        builder: (context, version, updateWaiting) => _SettingsEntry(
          key: const ValueKey('sidebar-settings'),
          onPressed: onSettingsPressed,
          version: version,
          hasUpdate: updateWaiting,
          shortcut: settingsShortcut,
        ),
      ),
    );
  }
}

/// The bar over the list while notes are picked, and over the archive at
/// rest: what it holds, then what can be done with it.
///
/// Never over the ordinary notes at rest. A bar that stayed there would be a
/// bar of dangerous buttons over the notes people actually keep.
///
/// Icons rather than words on the right, because the sidebar can be dragged
/// down to 150pt and the count on the left is the part that must stay
/// readable when it is: four at most, and whatever else picked notes can do
/// is in their menu.
class _PickActions extends StatelessWidget {
  const _PickActions({required this.label, required this.buttons});

  final String label;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTypeScale.small,
                  fontWeight: FontWeight.w400,
                  color: context.palette.textSecondary,
                ),
              ),
            ),
          ),
          ...buttons,
        ],
      ),
    );
  }
}

/// The way out of the notes list and into settings.
///
/// A labelled row rather than a bare gear. The sidebar is never narrower than
/// 150pt, so there has always been room for the word, and a tooltip is a poor
/// substitute for one: it needs a pointer to hover, which is exactly what the
/// phone build does not have. Naming it also lets the row match the notes
/// above it instead of reading as a stray control under them.
class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({
    super.key,
    required this.onPressed,
    this.version = '',
    this.hasUpdate = false,
    this.shortcut,
  });

  final VoidCallback onPressed;
  final String version;
  final bool hasUpdate;
  final ShortcutBinding? shortcut;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tooltip = shortcut == null
        ? 'Settings'
        : 'Settings · ${shortcut!.displayLabel}';
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        // The dot is the one part of this a screen reader cannot see.
        label: hasUpdate ? 'Settings, update available' : 'Settings',
        child: ExcludeSemantics(
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  KapyIcon(
                    KapyIcons.settingsOutlined,
                    size: AppControlMetrics.footerIconControl,
                    color: palette.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Settings',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.control,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                  if (version.isNotEmpty)
                    Text(
                      key: const ValueKey('sidebar-app-version'),
                      'v$version',
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: AppTypeScale.small,
                        fontWeight: FontWeight.w400,
                        color: palette.textTertiary,
                      ),
                    ),
                  if (hasUpdate) ...[
                    const SizedBox(width: 6),
                    Container(
                      key: const ValueKey('sidebar-update-badge'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: palette.selectedBackground,
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        border: Border.all(
                          color: palette.chipCurrency.withValues(alpha: 0.35),
                          width: AppHairline.of(context),
                        ),
                      ),
                      child: Text(
                        'Update',
                        style: TextStyle(
                          fontSize: AppPlatform.isWindows
                              ? AppTypeScale.micro
                              : 10,
                          fontWeight: FontWeight.w400,
                          color: palette.chipCurrency,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: AppControlMetrics.scaleBar(
      context,
      AppControlMetrics.toolbarHeight,
    ),
    child: Center(
      child: AppWordmark(
        markSize: AppControlMetrics.wordmarkMark,
        fontSize: AppTypeScale.wordmark,
        spacing: 6.5,
      ),
    ),
  );
}

/// The bar across the top of the notes list in the wide window: the name of
/// the space the list is showing and how many notes it holds, New note, and
/// the way to put the list away.
///
/// It sits level with the traffic lights over the rail beside it, and like a
/// title bar it drags the window wherever nothing on it is a button.
class SidebarWindowBar extends StatelessWidget {
  const SidebarWindowBar({
    super.key,
    required this.title,
    required this.count,
    required this.onCreate,
    required this.onHide,
    this.noun = 'note',
    this.newNoteShortcut,
    this.hideShortcut,
    this.countLabel,
  });

  final String title;

  /// Said after the count, as Tasks says "10 open". Without it the figure
  /// stands alone.
  final String? countLabel;

  /// What the space holds and New makes: a note, or a drawing in Drawings.
  final String noun;

  /// How many notes the space holds, whatever a search has narrowed the list
  /// to.
  final int count;
  final VoidCallback onCreate;
  final VoidCallback onHide;

  /// Printed on New note's keycap, so the chord is learnt from the button.
  final ShortcutBinding? newNoteShortcut;
  final ShortcutBinding? hideShortcut;

  static const double height = 52;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    const handwritten = WritingFont.handwritten;
    final newNoteShortcut = this.newNoteShortcut;
    final hideShortcut = this.hideShortcut;
    final titleStyle = TextStyle(
      fontFamily: handwritten.fontFamily,
      fontFamilyFallback: handwritten.fontFamilyFallback,
      fontVariations: handwritten.fontVariations,
      fontSize: AppTypeScale.spaceTitle,
      height: 24 / 20,
      fontWeight: FontWeight.w500,
      color: palette.textPrimary,
    );
    final countText = [count, ?countLabel].join(' ');
    final countStyle = TextStyle(
      fontSize: AppTypeScale.small,
      height: 16 / 12,
      fontWeight: FontWeight.w500,
      color: palette.textTertiary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    double widthOf(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    return SizedBox(
      height: AppControlMetrics.scaleBar(context, height),
      child: Stack(
        children: [
          const Positioned.fill(
            child: WindowDragArea(child: SizedBox.expand()),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // New note gives up its keycap and then its word and the
                  // count, so the space's name keeps its room on a list
                  // dragged narrow. Everything is measured as it prints, at
                  // the reader's text size and with this platform's chord.
                  final room =
                      constraints.maxWidth -
                      widthOf(title, titleStyle) -
                      8 -
                      8 -
                      32;
                  final chord = newNoteShortcut?.keycapLabel;
                  bool fits({String? shortcut}) =>
                      room - 8 - widthOf(countText, countStyle) >=
                      TonalButton.widthOf(
                        context,
                        'New $noun',
                        shortcut: shortcut,
                        tall: true,
                      );
                  final keycap = chord != null && fits(shortcut: chord);
                  final label = fits();
                  return Row(
                    children: [
                      Expanded(
                        // Its own drag region, because text takes the pointer
                        // before the bar's can.
                        child: WindowDragArea(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Flexible(
                                child: Semantics(
                                  header: true,
                                  child: Text(
                                    title,
                                    key: const ValueKey('sidebar-space-title'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle,
                                  ),
                                ),
                              ),
                              if (label) ...[
                                const SizedBox(width: 8),
                                // The tooltip is what a screen reader hears:
                                // "3 notes", where the bare figure would be
                                // read as just a number.
                                Tooltip(
                                  message: [
                                    count == 1 ? '1 $noun' : '$count ${noun}s',
                                    ?countLabel,
                                  ].join(' '),
                                  child: Text(
                                    countText,
                                    key: const ValueKey('sidebar-space-count'),
                                    maxLines: 1,
                                    style: countStyle,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TonalButton(
                        key: const ValueKey('sidebar-new-note'),
                        tall: true,
                        icon: KapyIcons.addRounded,
                        label: label ? 'New $noun' : null,
                        shortcut: keycap ? newNoteShortcut?.keycapLabel : null,
                        // Without its keycap the button still teaches the
                        // chord, on hover.
                        tooltip: keycap
                            ? null
                            : [
                                'New $noun',
                                ?newNoteShortcut?.displayLabel,
                              ].join('  '),
                        onPressed: onCreate,
                      ),
                      const SizedBox(width: 8),
                      CompactIconButton(
                        key: const ValueKey('sidebar-hide'),
                        tooltip: hideShortcut == null
                            ? 'Hide notes'
                            : 'Hide notes  ${hideShortcut.displayLabel}',
                        extent: 32,
                        radius: 8,
                        onPressed: onHide,
                        icon: KapyIcon(
                          KapyIcons.menuOpenRounded,
                          size: AppControlMetrics.iconAction,
                          strokeWidth: 1.7,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// My Notes and Shared with Me, as one segmented control at the top of the
/// list.
///
/// Two segments rather than two more sections, because a shared library
/// grows two ways at once and a single list made the person's own notes the
/// ones at the bottom. A dot on the second segment says an invitation is
/// waiting, for the moment the notice under the search field is scrolled
/// past or missed.
class _SidebarTabs extends StatelessWidget {
  const _SidebarTabs({
    required this.tab,
    required this.invitations,
    required this.onChanged,
  });

  final SidebarTab tab;
  final int invitations;
  final ValueChanged<SidebarTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    return Padding(
      // The search field's gutter, so the two line up edge to edge.
      padding: touch
          ? const EdgeInsets.fromLTRB(10, 9, 10, 0)
          : const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Container(
        key: const ValueKey('sidebar-tabs'),
        height: touch ? 34 : 28,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: palette.hover,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Row(
          children: [
            Expanded(
              child: _SidebarTabButton(
                key: const ValueKey('sidebar-tab-mine'),
                label: 'My Notes',
                selected: tab == SidebarTab.mine,
                onTap: () => onChanged(SidebarTab.mine),
              ),
            ),
            Expanded(
              child: _SidebarTabButton(
                key: const ValueKey('sidebar-tab-shared'),
                label: 'Shared with Me',
                selected: tab == SidebarTab.shared,
                waiting: invitations,
                onTap: () => onChanged(SidebarTab.shared),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarTabButton extends StatelessWidget {
  const _SidebarTabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.waiting = 0,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Invitations waiting behind this tab, drawn as a dot.
  final int waiting;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: switch (waiting) {
        0 => label,
        1 => '$label, 1 invitation',
        _ => '$label, $waiting invitations',
      },
      child: ExcludeSemantics(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: selected ? null : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: selected
                    ? palette.surfaceBackground
                    : palette.surfaceBackground.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(AppRadii.compact),
                border: Border.all(
                  color: selected
                      ? palette.controlBorder
                      : palette.controlBorder.withValues(alpha: 0),
                  width: AppHairline.of(context),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.small,
                        fontWeight: selected
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: selected
                            ? palette.textPrimary
                            : palette.textSecondary,
                      ),
                    ),
                  ),
                  if (waiting > 0) ...[
                    const SizedBox(width: 5),
                    Container(
                      key: const ValueKey('sidebar-tab-invitation-dot'),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Invitations waiting for an answer, just under the search field.
///
/// Where they are seen: an invitation used to wait in Settings › Sharing,
/// which nobody opens to find out whether somebody has shared something with
/// them. Accepting from here opens Shared with Me, where the notes arrive.
///
/// Report and Block stay one tap away behind the card's menu, as they are in
/// Settings: an invitation is somebody else's words arriving unasked, and the
/// stores expect the way to refuse them to sit wherever they are shown.
class _Invitations extends StatefulWidget {
  const _Invitations({required this.sharing, this.onJoined});

  final Sharing sharing;

  /// Shows the notes an accepted invitation brings.
  final VoidCallback? onJoined;

  @override
  State<_Invitations> createState() => _InvitationsState();
}

class _InvitationsState extends State<_Invitations> {
  /// The invitation being answered. One at a time, so a second tap cannot
  /// race the first to the server.
  String? _busy;

  Future<void> _act(
    PendingInvite invite,
    Future<void> Function() action, {
    required String waiting,
    required String done,
    bool joins = false,
  }) async {
    if (_busy != null) return;
    setState(() => _busy = invite.token);
    final sharing = widget.sharing;
    final onJoined = widget.onJoined;
    var progress = Toast.showProgress(context, waiting);
    try {
      try {
        await action();
      } on SyncRefusedException catch (error) {
        if (error.code != termsRequiredCode || !mounted) rethrow;
        // Reading the rules is not work in progress, so the spinner stops
        // until they are agreed to and the answer goes through again.
        progress.dismiss();
        final accepted = await showSharingTermsSheet(context, sharing: sharing);
        if (!accepted || !mounted) return;
        progress = Toast.showProgress(context, waiting);
        await action();
      }
      progress.success(done);
      // Answered, the invitation leaves the list and may take this card with
      // it, so the switch does not wait on it being mounted.
      if (joins) onJoined?.call();
    } catch (error) {
      progress.error(describeSharingError(error));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _more(PendingInvite invite, Offset position) async {
    final sharing = widget.sharing;
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: position,
      items: [
        PopupMenuItem(
          key: ValueKey('invite-report-${invite.token}'),
          value: 'report',
          height: 36,
          child: const Text('Report'),
        ),
        PopupMenuItem(
          key: ValueKey('invite-block-${invite.token}'),
          value: 'block',
          height: 36,
          child: Text('Block ${invite.inviterDisplayName}'),
        ),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'report':
        await showReportDialog(
          context,
          sharing: sharing,
          target: ReportTarget.invitation(
            token: invite.token,
            email: invite.invitedBy,
          ),
        );
      case 'block':
        await _act(
          invite,
          () => sharing.blockPerson(invite.invitedBy),
          waiting: 'Blocking…',
          done: 'Blocked ${invite.inviterDisplayName}',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sharing = widget.sharing;
    return Column(
      key: const ValueKey('sidebar-invitations'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final invite in sharing.invites)
          _InvitationCard(
            key: ValueKey('sidebar-invite-${invite.token}'),
            invite: invite,
            busy: _busy != null,
            onAccept: () => _act(
              invite,
              () => sharing.acceptInvite(invite.token),
              waiting: 'Joining…',
              done: 'Joined. Notes appear once they sync',
              joins: true,
            ),
            onDecline: () => _act(
              invite,
              () => sharing.declineInvite(invite.token),
              waiting: 'Declining…',
              done: 'Invitation declined',
            ),
            onMore: (position) => unawaited(_more(invite, position)),
          ),
      ],
    );
  }
}

class _InvitationCard extends StatelessWidget {
  const _InvitationCard({
    super.key,
    required this.invite,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
    required this.onMore,
  });

  final PendingInvite invite;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final ValueChanged<Offset> onMore;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    final who = invite.inviterDisplayName;
    final title = invite.hasGeneratedSpaceName
        ? '$who invited you to share notes'
        : '$who invited you to ${invite.spaceName}';
    // The address stays on an invitation: it comes from somebody who may be
    // a stranger, and a name is only what they call themselves.
    final detail = [
      if (invite.invitedByName != null) invite.invitedBy,
      '${invite.role.accessLabel} access',
    ].join(' · ');
    final compact = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: Size(0, touch ? 34 : 26),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: TextStyle(fontSize: AppTypeScale.small),
    );
    return Padding(
      padding: touch
          ? const EdgeInsets.fromLTRB(10, 0, 10, 8)
          : const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(
            color: palette.controlBorder,
            width: AppHairline.of(context),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: KapyIcon(
                    KapyIcons.mailOutlined,
                    size: AppControlMetrics.iconControl,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.small,
                          height: 1.3,
                          color: palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.caption,
                          color: palette.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (buttonContext) => CompactIconButton(
                    key: ValueKey('sidebar-invite-more-${invite.token}'),
                    tooltip: 'More',
                    extent: AppControlMetrics.fieldAdornmentSlot,
                    foregroundColor: palette.textTertiary,
                    onPressed: busy
                        ? null
                        : () {
                            final box =
                                buttonContext.findRenderObject() as RenderBox?;
                            onMore(
                              box == null
                                  ? Offset.zero
                                  : box.localToGlobal(
                                      box.size.bottomRight(Offset.zero),
                                    ),
                            );
                          },
                    icon: KapyIcon(
                      KapyIcons.moreRounded,
                      size: AppControlMetrics.iconAdornment,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Side by side where they fit, stacked where the sidebar is
            // dragged too narrow for both.
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              overflowSpacing: 4,
              children: [
                TextButton(
                  key: ValueKey('sidebar-invite-decline-${invite.token}'),
                  style: compact,
                  onPressed: busy ? null : onDecline,
                  child: const Text('Decline'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  key: ValueKey('sidebar-invite-accept-${invite.token}'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: Size(0, touch ? 34 : 26),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: TextStyle(fontSize: AppTypeScale.small),
                  ),
                  onPressed: busy ? null : onAccept,
                  child: const Text('Accept'),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The note list, under whatever invitations are waiting.
///
/// The cards scroll by themselves once they would take more than half the
/// height, so a few invitations in a short window cannot push the list, and
/// the footer under it, off the screen.
class _BelowInvitations extends StatelessWidget {
  const _BelowInvitations({required this.invitations, required this.child});

  final Widget? invitations;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final invitations = this.invitations;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (invitations != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: constraints.maxHeight / 2),
              child: SingleChildScrollView(child: invitations),
            ),
          Expanded(key: const ValueKey('sidebar-note-list'), child: child),
        ],
      ),
    );
  }
}

/// The field at the top of every section's list. It opens the ⌘K menu,
/// which does the searching; the list itself is never narrowed from here.
///
/// The one search a list keeps is the menu's way into Archive, which shows
/// here as [query] with a ✕ that drops it.
class SidebarSearchField extends StatelessWidget {
  const SidebarSearchField({
    super.key,
    required this.onSearch,
    this.query = '',
    this.onClear,
    this.onCreate,
    this.shortcut,
    this.placeholder = 'Search',
    this.belowTabs = false,
    this.besideRail = false,
  });

  final VoidCallback onSearch;
  final String query;
  final VoidCallback? onClear;

  /// Sits under the tabs rather than the title bar, and needs less room
  /// above it to read as part of the same header.
  final bool belowTabs;

  /// Drawn as the list beside the spaces rail draws it: a deeper field with
  /// its shortcut on a keycap.
  final bool besideRail;

  /// The + beside the field. Null leaves it out.
  final VoidCallback? onCreate;
  final ShortcutBinding? shortcut;
  final String placeholder;

  Widget? _end(CalcPalette palette, double extent) {
    final onClear = this.onClear;
    if (query.isNotEmpty && onClear != null) {
      return CompactIconButton(
        tooltip: 'Clear search',
        extent: extent,
        foregroundColor: palette.textTertiary,
        onPressed: onClear,
        icon: KapyIcon(
          KapyIcons.cancelRounded,
          size: AppControlMetrics.iconAdornment,
        ),
      );
    }
    final shortcut = this.shortcut;
    if (shortcut == null || !AppPlatform.hasPointer) return null;
    return Tooltip(
      message: '$placeholder · ${shortcut.displayLabel}',
      child: Semantics(
        label: 'Search shortcut ${shortcut.displayLabel}',
        excludeSemantics: true,
        child: Keycap(shortcut.keycapLabel),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final searching = query.isNotEmpty;
    if (besideRail) {
      final end = _end(palette, 20);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Semantics(
          button: true,
          label: searching ? 'Search, $query' : placeholder,
          child: GestureDetector(
            key: const ValueKey('sidebar-search-field'),
            behavior: HitTestBehavior.opaque,
            onTap: onSearch,
            child: MouseRegion(
              cursor: SystemMouseCursors.text,
              child: Container(
                key: const ValueKey('sidebar-search-box'),
                height: 40,
                padding: const EdgeInsets.only(left: 12, right: 8),
                decoration: BoxDecoration(
                  color: palette.surfaceBackground,
                  border: Border.all(color: palette.controlBorder),
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                  boxShadow: [
                    BoxShadow(
                      color: palette.shadowAt(0x4D),
                      offset: Offset(0, 1),
                      blurRadius: 2,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    KapyIcon(
                      KapyIcons.searchRounded,
                      size: 16,
                      strokeWidth: 1.8,
                      color: palette.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        searching ? query : placeholder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 16 / 13,
                          color: searching
                              ? palette.textPrimary
                              : palette.textTertiary,
                        ),
                      ),
                    ),
                    ?end,
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final end = _end(palette, AppControlMetrics.fieldAdornmentSlot);
    return Padding(
      // On a desktop the field keeps the sidebar's 12pt gutter, the edge the
      // footer and archive actions hold, and the same room under the title
      // bar. The list's own top padding makes up the gap beneath it.
      padding: AppPlatform.hasPointer
          ? EdgeInsets.fromLTRB(12, belowTabs ? 8 : 12, 12, 8)
          : EdgeInsets.fromLTRB(10, belowTabs ? 8 : 9, 10, 9),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: searching ? 'Search, $query' : placeholder,
              child: GestureDetector(
                key: const ValueKey('sidebar-search-field'),
                behavior: HitTestBehavior.opaque,
                onTap: onSearch,
                child: InputDecorator(
                  isEmpty: !searching,
                  decoration: kapyFieldDecoration(
                    context,
                    hintText: placeholder,
                    hintStyle: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textTertiary,
                    ),
                    prefixIcon: Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: KapyIcon(
                        KapyIcons.searchRounded,
                        size: AppControlMetrics.iconSearch,
                        color: palette.textTertiary,
                      ),
                    ),
                    prefixIconConstraints: BoxConstraints(
                      minWidth: AppControlMetrics.fieldAdornmentSlot + 2,
                      minHeight: AppControlMetrics.fieldAdornmentSlot,
                    ),
                    suffixIcon: end == null || searching
                        ? end
                        : Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: Center(widthFactor: 1, child: end),
                          ),
                    suffixIconConstraints: BoxConstraints(
                      minWidth: AppControlMetrics.fieldAdornmentSlot,
                      minHeight: AppControlMetrics.fieldAdornmentSlot,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      vertical: AppControlMetrics.fieldVerticalPadding,
                    ),
                  ),
                  child: Text(
                    query,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (onCreate case final onCreate?) ...[
            const SizedBox(width: 6),
            TonalButton(
              key: const ValueKey('sidebar-new-note'),
              icon: KapyIcons.addRounded,
              tooltip: 'New note',
              onPressed: onCreate,
            ),
          ],
        ],
      ),
    );
  }
}

/// How a [NoteRow] draws its note: the compact list's row, the desktop
/// list's row or sticky card beside the spaces rail, or the Folders tab's
/// note in an open folder ([filed]) or in none ([loose]).
enum NoteRowStyle { compact, row, card, drawingRow, drawingCard, filed, loose }

/// One row in the note list.
class NoteRow extends StatefulWidget {
  const NoteRow({
    super.key,
    required this.note,
    required this.query,
    required this.displayTime,
    required this.selected,
    required this.onTap,
    this.onOpenToSide,
    this.openElsewhere = false,
    this.onOpenInNewTab,
    this.tabbed = false,
    this.onShare,
    this.onArchive,
    this.onRestore,
    this.onHide,
    this.onUnhide,
    this.onDelete,
    this.deleteLabel = 'Delete note…',
    this.onTogglePin,
    this.archiveShortcut,
    this.pinned = false,
    this.shared = false,
    this.collaborators = const [],
    this.sharedWith,
    this.currentUserId = '',
    this.locked = false,
    this.selecting = false,
    this.checked = false,
    this.onToggleChecked,
    this.onCommandClick,
    this.onPickTo,
    this.pickedActions,
    this.onPickedAction,
    this.style = NoteRowStyle.compact,
    this.depth = 0,
    this.engine,
    this.now = DateTime.now,
    this.folders,
  });

  final Note note;
  final NoteRowStyle style;

  /// How deep a [NoteRowStyle.filed] note sits in the folder tree.
  final int depth;

  /// Works out the sum a card or row shows under the title.
  final CalcEngine? engine;

  /// The clock the card's date is told by.
  final DateTime Function() now;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final bool selected;
  final VoidCallback onTap;

  /// Opens the note in a pane beside the focused one: from the menu, with
  /// Option- or Alt-click, and by dragging the row onto the panes.
  final VoidCallback? onOpenToSide;

  /// Whether the note is already open in a pane other than the focused one.
  final bool openElsewhere;

  /// Opens the note in a tab of its own behind the one in front: a middle
  /// click and the menu. A ⌘-click asks [onCommandClick]. Null where there
  /// are no tabs.
  final VoidCallback? onOpenInNewTab;

  /// Whether the note is open in a tab already, in front or behind.
  final bool tabbed;
  final VoidCallback? onShare;
  final VoidCallback? onArchive;
  final VoidCallback? onRestore;
  final VoidCallback? onHide;
  final VoidCallback? onUnhide;

  /// Throws the note away for good, or takes one somebody else shares out of
  /// the reader's notes.
  final VoidCallback? onDelete;

  /// What [onDelete]'s menu item says.
  final String deleteLabel;
  final VoidCallback? onTogglePin;

  /// The chord that archives the open note, named in the menu beside the
  /// item that does the same thing. Null leaves the item unannotated.
  final ShortcutBinding? archiveShortcut;

  final bool pinned;

  /// Whether the list is picking notes rather than opening them. Every row
  /// shows a box instead of its actions, and a tap ticks it.
  final bool selecting;

  /// Whether this row is one of the picked ones.
  final bool checked;

  /// Picks the note or lets it go while notes are being picked: what any
  /// click on it does then, with ⌘ or Ctrl or without. On a phone its menu's
  /// Select starts picking with it.
  final VoidCallback? onToggleChecked;

  /// A click with ⌘ (Ctrl off a Mac) while nothing is picked.
  final VoidCallback? onCommandClick;

  /// A click with Shift: picks every note from the last one picked, or the
  /// open one, to this.
  final VoidCallback? onPickTo;

  /// While picking, the menu a right click or long press opens instead of
  /// the note's own, for every picked note, and what was chosen from it.
  final List<KapyMenuAction> Function()? pickedActions;
  final ValueChanged<String>? onPickedAction;

  /// Whether the note is in a shared space, which the row marks so a person
  /// typing knows somebody else can see it.
  final bool shared;

  /// Whoever else has the note open right now. While anybody does, the row
  /// says who in place of when it was last changed.
  final List<Collaborator> collaborators;

  /// The space whose people the row shows after its timestamp, as a small
  /// stack of faces. Null where a heading above already shows them, or the
  /// note is nobody's but the reader's.
  final Space? sharedWith;

  /// The reader, left out of [sharedWith]'s faces.
  final String currentUserId;

  /// Whether the note limit holds the note read-only.
  final bool locked;

  /// Where Move to folder… files the note. Null leaves it out of the menu.
  final FolderStore? folders;

  @override
  State<NoteRow> createState() => _NoteRowState();
}

class _NoteRowState extends State<NoteRow> {
  bool _hovering = false;

  /// Not for a note already on screen: a note is only ever open once, so
  /// beside itself is nowhere it can go.
  bool get _canOpenToSide =>
      widget.onOpenToSide != null &&
      !widget.selecting &&
      !widget.selected &&
      !widget.openElsewhere;

  bool get _canOpenInNewTab =>
      widget.onOpenInNewTab != null && !widget.selecting && !widget.tabbed;

  /// A click opens the note where the focus is. Option- or Alt-click opens it
  /// beside that instead, the way a code editor's file list does. Shift picks
  /// the range from the open note, as a file list does, and while notes are
  /// picked any other click picks too. A click with ⌘ or Ctrl while nothing
  /// is picked goes to [NoteRow.onCommandClick].
  void _open() {
    final keyboard = HardwareKeyboard.instance;
    final pickTo = widget.onPickTo;
    if (pickTo != null && keyboard.isShiftPressed) return pickTo();
    if (widget.selecting) return (widget.onToggleChecked ?? widget.onTap)();
    final commandClick = widget.onCommandClick;
    final command = AppPlatform.isMacOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (commandClick != null && command && AppPlatform.hasPointer) {
      return commandClick();
    }
    if (_canOpenToSide && keyboard.isAltPressed) {
      widget.onOpenToSide!();
      return;
    }
    widget.onTap();
  }

  List<KapyMenuAction> _availableActions() {
    if (widget.selecting) return widget.pickedActions?.call() ?? const [];
    // Named only where there is a keyboard to press it on: this same menu
    // opens on a long press on a phone, and a chord nobody there can type is
    // a line of noise beside the thing they came to tap.
    final archiveShortcut = AppPlatform.hasPointer
        ? widget.archiveShortcut
        : null;
    return [
      if (AppPlatform.isMobile && widget.onToggleChecked != null)
        const KapyMenuAction(
          value: 'select',
          label: 'Select',
          icon: KapyIcons.checklistRounded,
        ),
      if (_canOpenInNewTab)
        KapyMenuAction(
          value: 'open-tab',
          label: 'Open in new tab',
          icon: KapyIcons.openExternalRounded,
          hint: AppPlatform.isMacOS ? '⌘↵' : 'Ctrl+Enter',
        ),
      if (_canOpenToSide)
        KapyMenuAction(
          value: 'open-side',
          label: 'Open to the side',
          icon: KapyIcons.viewColumnOutlined,
          hint: AppPlatform.isMacOS ? '⌥ Click' : 'Alt+Click',
        ),
      if (widget.onTogglePin != null)
        KapyMenuAction(
          value: 'pin',
          label: widget.pinned ? 'Unpin note' : 'Pin note',
          icon: widget.pinned ? KapyIcons.pinRounded : KapyIcons.pinOutlined,
        ),
      if (TagShelf.maybeOf(context) != null)
        const KapyMenuAction(
          value: 'tags',
          label: 'Tags',
          icon: KapyIcons.tagRounded,
          hint: '›',
        ),
      if (widget.folders != null)
        const KapyMenuAction(
          value: 'folder',
          label: 'Move to folder…',
          icon: KapyIcons.folderMoveOutlined,
        ),
      if (widget.onShare != null)
        KapyMenuAction(
          value: 'share',
          label: widget.shared ? 'Manage sharing' : 'Share note',
          icon: KapyIcons.peopleOutlined,
        ),
      if (widget.onHide != null)
        const KapyMenuAction(
          value: 'hide',
          label: 'Move to Hidden Notes',
          icon: hiddenIcon,
        ),
      if (widget.onRestore != null)
        const KapyMenuAction(
          value: 'restore',
          label: 'Restore note',
          icon: restoreIcon,
        ),
      if (widget.onUnhide != null)
        const KapyMenuAction(
          value: 'unhide',
          label: 'Move to Notes',
          icon: unhideIcon,
        ),
      // The ways out of the list end the menu, in the warning colour, the one
      // that keeps the note before the one that does not. The shortcut is
      // named on whichever of them it does: archiving in the list, deleting
      // where the note is already archived or hidden.
      if (widget.onArchive != null)
        KapyMenuAction(
          value: 'archive',
          label: 'Archive note',
          icon: archiveIcon,
          hint: archiveShortcut?.displayLabel,
          destructive: true,
        ),
      if (widget.onDelete != null)
        KapyMenuAction(
          value: 'delete',
          label: widget.deleteLabel,
          icon: deleteIcon,
          hint: widget.onArchive == null ? archiveShortcut?.displayLabel : null,
          destructive: true,
        ),
    ];
  }

  String _actionKey(String value) => '$value-note-${widget.note.id}';

  Future<String?> _showTouchActions(
    BuildContext context,
    List<KapyMenuAction> actions,
  ) => showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (sheetContext) {
      final palette = sheetContext.palette;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.dialog),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 34,
                      height: 4,
                      decoration: BoxDecoration(
                        color: palette.controlBorder,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                    child: Text(
                      widget.note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.body,
                        fontWeight: FontWeight.w400,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                  for (final action in actions)
                    InkWell(
                      key: ValueKey(_actionKey(action.value)),
                      onTap: () => Navigator.of(sheetContext).pop(action.value),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        child: KapyMenuActionRow(action, touch: true),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  /// Right-click on desktop, long-press on touch, or the row's More button.
  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    // While picking, the menu is the picked notes', and the note it was
    // opened on is one of them.
    if (widget.selecting && !widget.checked) widget.onToggleChecked?.call();
    final actions = _availableActions();
    if (actions.isEmpty) return;

    String? choice;
    if (AppPlatform.isMobile) {
      choice = await _showTouchActions(context, actions);
    } else {
      // A card is narrower than the menu, so beside the rail the menu keeps
      // to the whole list rather than to the note it belongs to.
      final row =
          (widget.style == NoteRowStyle.compact
                      ? this.context
                      : Scrollable.maybeOf(this.context)?.context ??
                            this.context)
                  .findRenderObject()
              as RenderBox?;
      final rowOrigin = row?.localToGlobal(Offset.zero);
      final preferredBounds = row == null || rowOrigin == null
          ? null
          : Rect.fromLTWH(
              rowOrigin.dx,
              0,
              row.size.width,
              MediaQuery.sizeOf(context).height,
            );
      choice = await showKapyContextMenu<String>(
        context: context,
        globalPosition: position,
        preferredGlobalBounds: preferredBounds,
        items: [
          for (final action in actions)
            PopupMenuItem(
              key: ValueKey(_actionKey(action.value)),
              value: action.value,
              height: 36,
              child: KapyMenuActionRow(action, touch: false),
            ),
        ],
      );
    }
    await _choose(choice, at: position);
  }

  /// Does what a choice from the menu names, whether it came from the menu, at
  /// [at], or from VoiceOver, which has no pointer and gets the row's corner.
  Future<void> _choose(String? choice, {Offset? at}) async {
    if (!mounted) return;
    if (widget.selecting) {
      if (choice != null) widget.onPickedAction?.call(choice);
      return;
    }
    if (choice == 'select') widget.onToggleChecked?.call();
    if (choice == 'archive') widget.onArchive?.call();
    if (choice == 'restore') widget.onRestore?.call();
    if (choice == 'hide') widget.onHide?.call();
    if (choice == 'unhide') widget.onUnhide?.call();
    if (choice == 'delete') widget.onDelete?.call();
    if (choice == 'share') widget.onShare?.call();
    if (choice == 'pin') widget.onTogglePin?.call();
    if (choice == 'open-side') widget.onOpenToSide?.call();
    if (choice == 'open-tab') widget.onOpenInNewTab?.call();
    Offset anchor() {
      final box = context.findRenderObject() as RenderBox?;
      return at ??
          (box == null
              ? Offset.zero
              : box.localToGlobal(box.size.bottomRight(Offset.zero)));
    }

    if (choice == 'tags' && context.mounted) {
      await showTagPickerAt(context, anchor(), widget.note.id);
    }
    if (widget.folders case final folders? when choice == 'folder' && mounted) {
      await moveNoteToFolder(context, anchor(), folders, widget.note.id);
    }
  }

  /// The desktop list's row or card, with its actions button while the
  /// pointer is over it.
  Widget _boardFace({required String? snippet, required bool hasMenu}) {
    final note = widget.note;
    final people = widget.collaborators;
    final card =
        widget.style == NoteRowStyle.card ||
        widget.style == NoteRowStyle.drawingCard;
    String stamp({bool clock = true}) => SidebarTimestamp.glance(
      note.updatedAt,
      now: widget.now(),
      displayTime: widget.displayTime,
      today: card,
      clock: clock,
    );
    final day = card && people.isEmpty ? stamp(clock: false) : null;
    final date = people.isEmpty
        ? stamp()
        : typingStatusText([
                for (final person in people)
                  if (person.typing) person.name,
              ]) ??
              presenceStatusText([for (final person in people) person.name])!;
    final glance = NoteGlance.of(note, widget.engine);
    final picking = widget.selecting ? widget.checked : null;
    // While picking, what is lit is what is picked: the open note keeps its
    // highlight only once it is one of them.
    final selected = widget.selected && !widget.selecting;
    final ringed = widget.openElsewhere && !widget.selected;
    final face = switch (widget.style) {
      NoteRowStyle.card => NoteCardFace(
        note: note,
        glance: glance,
        date: date,
        day: day,
        snippet: snippet,
        selected: selected,
        hovering: _hovering,
        ringed: ringed,
        locked: widget.locked,
        shared: widget.shared,
        picking: picking,
      ),
      NoteRowStyle.drawingCard => DrawingCardFace(
        note: note,
        date: date,
        day: day,
        selected: selected,
        hovering: _hovering,
        ringed: ringed,
        locked: widget.locked,
        shared: widget.shared,
        picking: picking,
      ),
      NoteRowStyle.drawingRow => DrawingListRowFace(
        note: note,
        date: date,
        selected: selected,
        hovering: _hovering,
        ringed: ringed,
        locked: widget.locked,
        shared: widget.shared,
        picking: picking,
      ),
      NoteRowStyle.filed => TreeNoteFace(
        note: note,
        depth: widget.depth,
        selected: widget.selected,
        hovering: _hovering,
        ringed: ringed,
      ),
      NoteRowStyle.loose => LooseNoteFace(
        note: note,
        date: date,
        selected: widget.selected,
        hovering: _hovering,
        ringed: ringed,
      ),
      NoteRowStyle.row || NoteRowStyle.compact => NoteListRowFace(
        note: note,
        glance: glance,
        date: date,
        snippet: snippet,
        place: switch (widget.folders?.tree.pathOfNote(note.id)) {
          final path? when path.isNotEmpty => [
            for (final folder in path) folder.name,
          ].join(' › '),
          _ => null,
        },
        selected: selected,
        hovering: _hovering,
        ringed: ringed,
        locked: widget.locked,
        shared: widget.shared,
        picking: picking,
      ),
    };
    if (!hasMenu || !_hovering) return face;
    return Stack(
      children: [
        face,
        Positioned(
          top: 4,
          right: 4,
          child: Builder(
            builder: (buttonContext) => _RowAction(
              key: ValueKey('note-actions-${note.id}'),
              icon: KapyIcons.moreVerticalRounded,
              tooltip: 'Note actions',
              onPressed: () => _showActionsFromButton(buttonContext),
            ),
          ),
        ),
      ],
    );
  }

  void _showActionsFromButton(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final position = box == null
        ? Offset.zero
        : box.localToGlobal(Offset(box.size.width, box.size.height));
    unawaited(_showContextMenu(context, position));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    // While searching, show the line that actually matched instead of the
    // timestamp, so the reason for the hit remains visible.
    final snippet = widget.query.trim().isEmpty
        ? null
        : widget.note.matchSnippet(widget.query.trim());

    final foreground = palette.textPrimary;
    final secondary = palette.textSecondary;
    final hasMenu = widget.selecting
        ? widget.pickedActions != null
        : widget.onTogglePin != null ||
              _canOpenToSide ||
              widget.onArchive != null ||
              widget.onRestore != null ||
              widget.onHide != null ||
              widget.onUnhide != null ||
              widget.onDelete != null ||
              widget.onShare != null;

    final compact = widget.style == NoteRowStyle.compact;
    final face = compact
        ? AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: (widget.selecting ? widget.checked : widget.selected)
                  ? palette.selectedBackground
                  : (_hovering ? palette.hover : Colors.transparent),
              borderRadius: BorderRadius.circular(AppRadii.compact),
            ),
            // Open in another pane: ringed rather than filled, so it reads
            // as on screen without competing with the focused note's row.
            // Painted over the row rather than around it, so nothing moves.
            foregroundDecoration: widget.openElsewhere && !widget.selected
                ? BoxDecoration(
                    border: Border.all(color: palette.selectedBorder),
                    borderRadius: BorderRadius.circular(AppRadii.compact),
                  )
                : null,
            child: Row(
              children: [
                if (widget.selecting) ...[
                  KapyIcon(
                    widget.checked
                        ? KapyIcons.checkCircleRounded
                        : KapyIcons.circleOutlined,
                    size: AppControlMetrics.iconControl,
                    color: widget.checked
                        ? Theme.of(context).colorScheme.primary
                        : palette.textTertiary,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.control,
                          fontWeight: FontWeight.w400,
                          color: foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (snippet != null)
                        Text(
                          snippet,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTypeScale.caption,
                            color: secondary,
                          ),
                        )
                      else
                        _UpdatedAtMetadata(
                          updatedAt: widget.note.updatedAt,
                          displayTime: widget.displayTime,
                          shared: widget.shared,
                          locked: widget.locked,
                          collaborators: widget.collaborators,
                          sharedWith: widget.sharedWith,
                          currentUserId: widget.currentUserId,
                        ),
                    ],
                  ),
                ),
                // One discoverable affordance owns every secondary action.
                // It stays visible on every platform; right-click and long
                // press remain shortcuts to the same labeled choices.
                if (!widget.selecting && hasMenu) ...[
                  const SizedBox(width: 4),
                  Builder(
                    builder: (buttonContext) => _RowAction(
                      key: ValueKey('note-actions-${widget.note.id}'),
                      icon: KapyIcons.moreVerticalRounded,
                      tooltip: 'Note actions',
                      onPressed: () => _showActionsFromButton(buttonContext),
                    ),
                  ),
                ],
              ],
            ),
          )
        : _boardFace(snippet: snippet, hasMenu: hasMenu && !widget.selecting);

    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 1 : 0),
      child: MouseRegion(
        // The row is the main click target in the sidebar; matching the
        // settings rows, which are InkWells and already say so.
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Semantics(
          container: true,
          button: true,
          selected: widget.selecting ? widget.checked : widget.selected,
          // VoiceOver cannot right-click, and the row's ⋯ button is easy to
          // miss, so its menu's choices are actions on the row itself. Same
          // list, so the two can never drift.
          customSemanticsActions: {
            for (final action in _availableActions())
              CustomSemanticsAction(label: action.label): () =>
                  unawaited(_choose(action.value)),
          },
          child: GestureDetector(
            onTap: _open,
            onSecondaryTapDown: !hasMenu
                ? null
                : (details) =>
                      _showContextMenu(context, details.globalPosition),
            onLongPressStart: !hasMenu
                ? null
                : (details) =>
                      _showContextMenu(context, details.globalPosition),
            behavior: HitTestBehavior.opaque,
            child: Listener(
              // A middle click opens the note in a tab behind, as a
              // browser's middle click opens a link.
              onPointerDown: (event) {
                if (event.buttons == kMiddleMouseButton && _canOpenInNewTab) {
                  widget.onOpenInNewTab!();
                }
              },
              child: face,
            ),
          ),
        ),
      ),
    );
    // Dragged onto the panes, to open beside a note there or in its place.
    // Only where there is a pointer to drag with and panes to take it.
    if (widget.onOpenToSide == null ||
        widget.selecting ||
        !AppPlatform.hasPointer) {
      return row;
    }
    return NoteDraggable(
      data: NoteDragData(noteId: widget.note.id, title: widget.note.title),
      child: row,
    );
  }
}

/// The single trailing action on a note row.
///
class _RowAction extends StatelessWidget {
  const _RowAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CompactIconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: KapyIcon(icon, size: AppControlMetrics.iconAdornment),
    foregroundColor: context.palette.textTertiary,
  );
}

class _UpdatedAtMetadata extends StatelessWidget {
  const _UpdatedAtMetadata({
    required this.updatedAt,
    required this.displayTime,
    this.shared = false,
    this.collaborators = const [],
    this.sharedWith,
    this.currentUserId = '',
    this.locked = false,
  });

  final DateTime updatedAt;
  final DateTime Function(DateTime) displayTime;
  final bool shared;
  final List<Collaborator> collaborators;
  final Space? sharedWith;
  final String currentUserId;
  final bool locked;

  /// Small enough to sit on the caption line without making the row taller.
  static double get faceExtent => AppControlMetrics.iconInline + 2;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (collaborators.isNotEmpty) return _presence(context);
    final timestamp = SidebarTimestamp.format(
      updatedAt,
      displayTime: displayTime,
    );
    final space = sharedWith;
    final people = space?.peoplePhrase(currentUserId);
    // The faces say it is shared, and with whom, so the row keeps the clock
    // every other row has instead of the people glyph.
    final faces = space != null && people != null;
    final what = [
      if (locked) 'Read-only',
      if (faces) 'Shared with $people' else if (shared) 'Shared',
    ];
    return Semantics(
      label: what.isEmpty
          ? 'Updated $timestamp'
          : '${what.join(', ')}, updated $timestamp',
      child: ExcludeSemantics(
        child: Row(
          children: [
            KapyIcon(
              locked
                  ? KapyIcons.lockRounded
                  : shared && !faces
                  ? KapyIcons.peopleOutlined
                  : KapyIcons.scheduleRounded,
              size: AppControlMetrics.iconInline,
              color: palette.textTertiary,
            ),
            const SizedBox(width: 4),
            // The time keeps its place against the icon and the faces follow
            // it; on a narrow sidebar the time gives way first.
            Flexible(
              child: Text(
                timestamp,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  color: palette.textSecondary,
                ),
              ),
            ),
            if (faces) ...[
              const SizedBox(width: 6),
              SpacePeopleAvatars(
                key: const ValueKey('note-row-people'),
                space: space,
                currentUserId: currentUserId,
                extent: faceExtent,
                maxAvatars: 3,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// "Priya is here", or "Priya is typing...", in the colours of their
  /// carets: which shared note has company, readable from the list.
  Widget _presence(BuildContext context) {
    final palette = context.palette;
    final typists = [
      for (final person in collaborators)
        if (person.typing) person.name,
    ];
    final text =
        typingStatusText(typists) ??
        presenceStatusText([for (final person in collaborators) person.name])!;
    // One dot per person, up to two, overlapping inside the slot the clock
    // icon takes on every other row, so the text lines up with theirs.
    final slot = AppControlMetrics.iconInline;
    final dot = slot * 0.55;
    final shown = collaborators.take(2).toList();
    final step = shown.length < 2 ? 0.0 : slot - dot;
    final start = (slot - dot - step) / 2;
    return Semantics(
      label: 'Shared, $text',
      child: ExcludeSemantics(
        child: Row(
          key: const ValueKey('note-row-presence'),
          children: [
            SizedBox(
              width: slot,
              height: dot,
              child: Stack(
                children: [
                  for (var i = shown.length - 1; i >= 0; i--)
                    Positioned(
                      left: start + i * step,
                      child: Container(
                        width: dot,
                        height: dot,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: collaboratorColor(
                            shown[i].userId,
                            on: palette.brightness,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  fontWeight: FontWeight.w400,
                  color: palette.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Who else is in a note, in as few words as the row has room for.
String? presenceStatusText(List<String> names) => switch (names.length) {
  0 => null,
  1 => '${names[0]} is here',
  2 => '${names[0]} and ${names[1]} are here',
  _ => '${names[0]} and ${names.length - 1} others are here',
};

List<SpaceMember> _spaceMembersForAccessList(Space space) {
  final members = space.members.toList()
    ..sort((a, b) {
      if (a.isOwner != b.isOwner) return a.isOwner ? -1 : 1;
      return a.joinedAt.compareTo(b.joinedAt);
    });
  return members;
}

List<SpaceInvite> _spaceInvitesForAccessList(Space space) {
  final invites = space.invites.toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return invites;
}

String _spaceMemberAccessLine(SpaceMember member, String currentUserId) =>
    '${member.displayName}'
    '${member.userId == currentUserId ? ' (you)' : ''}'
    ' · ${member.role.accessLabel}';

String _spaceAccessTooltip(Space space, String currentUserId) {
  final members = _spaceMembersForAccessList(space);
  final invites = _spaceInvitesForAccessList(space);
  return [
    'People with access',
    for (final member in members) _spaceMemberAccessLine(member, currentUserId),
    if (invites.isNotEmpty) ...[
      '',
      invites.length == 1
          ? 'Invited, not joined yet'
          : 'Invited, not joined yet (${invites.length})',
      for (final invite in invites)
        '${invite.email} · ${invite.role.accessLabel}',
    ],
  ].join('\n');
}

String _spaceAccessSemantics(Space space, String currentUserId) => [
  'People with access',
  for (final member in _spaceMembersForAccessList(space))
    _spaceMemberAccessLine(member, currentUserId),
  for (final invite in _spaceInvitesForAccessList(space))
    '${invite.email}, invited but not joined, ${invite.role.accessLabel}',
].join('. ');

/// The heading over a shared space's notes: who it is shared with, and their
/// faces at the far end.
///
/// An owner sees "Shared with Priya and 4 others" while a recipient sees
/// "Shared by Priya", unless somebody gave the space a name of its own. The
/// heading opens the space, which is where its people are managed.
class _SpaceHeader extends StatelessWidget {
  const _SpaceHeader({
    super.key,
    required this.space,
    required this.currentUserId,
    this.present = const {},
    this.attention = false,
    this.onTap,
  });

  /// Null for a space this device has not heard the details of yet.
  final Space? space;
  final String currentUserId;

  /// Everyone in one of its notes right now, by account.
  final Set<String> present;

  /// A member's key changed and nobody has looked yet.
  final bool attention;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final space = this.space;
    final title = space?.titleFor(currentUserId) ?? 'Shared';
    final people = space?.peopleExcept(currentUserId) ?? const <SpacePerson>[];
    final accessTooltip = space == null
        ? null
        : _spaceAccessTooltip(space, currentUserId);
    final heading = Row(
      children: [
        if (attention) ...[
          Tooltip(
            message: "A member's key changed",
            child: KapyIcon(
              KapyIcons.warningRounded,
              size: AppControlMetrics.iconInline,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(width: 5),
        ] else if (people.isEmpty) ...[
          KapyIcon(
            KapyIcons.peopleOutlined,
            size: AppControlMetrics.iconInline,
            color: palette.textTertiary,
          ),
          const SizedBox(width: 5),
        ],
        Expanded(
          child: accessTooltip == null
              ? Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.3,
                    color: palette.textTertiary,
                  ),
                )
              : Tooltip(
                  key: ValueKey('space-access-tooltip-${space!.id}'),
                  message: accessTooltip,
                  textAlign: TextAlign.left,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.3,
                      color: palette.textTertiary,
                    ),
                  ),
                ),
        ),
        if (space != null && people.isNotEmpty) ...[
          const SizedBox(width: 8),
          SpacePeopleAvatars(
            space: space,
            currentUserId: currentUserId,
            present: present,
          ),
        ],
      ],
    );

    return Padding(
      // As much room under it as a section heading has, outside the part a
      // tap lights up.
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 7),
      child: Semantics(
        header: true,
        button: onTap != null,
        onTap: onTap,
        label: space == null
            ? title
            : '$title. ${_spaceAccessSemantics(space, currentUserId)}',
        child: ExcludeSemantics(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadii.compact),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 6, 3),
              child: heading,
            ),
          ),
        ),
      ),
    );
  }
}

/// The Drawings space with nothing in it: what will go here, and the way to
/// start.
class _DrawingsEmpty extends StatelessWidget {
  const _DrawingsEmpty({required this.onNewDrawing});

  final VoidCallback? onNewDrawing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    const handwritten = WritingFont.handwritten;
    final onNewDrawing = this.onNewDrawing;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 96, 24, 24),
      child: Column(
        children: [
          Transform.rotate(
            angle: -3 * math.pi / 180,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: palette.editorBackground,
                border: Border.all(color: palette.separator),
                borderRadius: BorderRadius.circular(AppRadii.dialog),
              ),
              alignment: Alignment.center,
              child: KapyIcon(
                KapyIcons.penRounded,
                size: 30,
                strokeWidth: 1.5,
                color: palette.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'No drawings yet',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: handwritten.fontFamily,
              fontFamilyFallback: handwritten.fontFamilyFallback,
              fontVariations: handwritten.fontVariations,
              fontSize: 16,
              height: 22 / 16,
              fontWeight: FontWeight.w500,
              color: palette.textSubheading,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: 220,
            child: Text(
              'Sketches, diagrams and wireframes live here, apart from your '
              'notes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                height: 18 / 13,
                fontWeight: FontWeight.w400,
                color: palette.textTertiary,
              ),
            ),
          ),
          if (onNewDrawing != null) ...[
            const SizedBox(height: 16),
            TonalButton(
              key: const ValueKey('sidebar-empty-new-drawing'),
              icon: KapyIcons.addRounded,
              label: 'New drawing',
              onPressed: onNewDrawing,
            ),
          ],
        ],
      ),
    );
  }
}

class _SidebarEmpty extends StatelessWidget {
  const _SidebarEmpty({required this.message, this.detail, this.action});

  final String message;

  /// A quieter line under [message], saying what will fill the space.
  final String? detail;

  /// The one way back, where a filter left the list empty.
  final ({String label, VoidCallback onPressed})? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTypeScale.body,
              color: context.palette.textTertiary,
            ),
          ),
          if (detail case final detail?) ...[
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                color: context.palette.textTertiary,
              ),
            ),
          ],
          if (action case final action?) ...[
            const SizedBox(height: 12),
            TonalButton(
              key: const ValueKey('sidebar-empty-action'),
              label: action.label,
              onPressed: action.onPressed,
            ),
          ],
        ],
      ),
    ),
  );
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String tooltip;

  /// Null greys the button out rather than removing it, so a bar of actions
  /// keeps its shape while some of them have nothing to act on.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CompactIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: KapyIcon(icon, size: AppControlMetrics.iconAction),
      foregroundColor: onPressed == null
          ? context.palette.textTertiary
          : context.palette.textSecondary,
    );
  }
}
