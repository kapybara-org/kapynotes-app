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
import '../data/layout_prefs.dart' show LayoutPrefs, NotesGrouping;
import '../data/note.dart';
import '../data/shortcut_prefs.dart';
import '../sync/presence.dart';
import '../sync/safety.dart';
import '../sync/sharing.dart';
import '../sync/spaces.dart';
import '../sync/sync_api.dart' show SyncRefusedException;
import 'collaborator_colors.dart';
import 'compact_icon_button.dart';
import 'context_menu.dart';
import 'editor/note_footer.dart' show typingStatusText;
import 'editor_panes.dart';
import 'folders_ui.dart';
import 'join/joining_ui.dart' show joinedLine;
import 'member_avatars.dart';
import 'note_picks.dart';
import 'notes_grouping.dart';
import 'notes_list.dart';
import 'safety_dialogs.dart';
import 'sharing_sheet.dart';
import 'sidebar_timestamp.dart';
import 'tag_colours.dart';
import 'tag_ui.dart';
import 'tasks/task_marks.dart'
    show dayTitleStyle, handStyle, metaStyle, uiStyle;
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
/// people it is open to. The other list is everything shared, theirs and
/// other people's, grouped by who it is shared with.
enum SidebarTab { mine, shared }

/// Whether [tab] lists [note]. A note of the person's own that they share is
/// in both.
bool sidebarTabLists(SidebarTab tab, Note note, Sharing sharing) =>
    switch (tab) {
      SidebarTab.mine => sidebarTabOf(note, sharing) == SidebarTab.mine,
      SidebarTab.shared => note.isShared,
    };

/// The tab [note] belongs to, and is shown on when it is opened from
/// somewhere other than the list.
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

  /// On a phone, what New folder beside the search field (M02) bumps to
  /// have the tree name a new folder at its top. Null elsewhere.
  ValueNotifier<int>? newFolder,
});

/// What can be done to many picked notes at once.
enum PickedAction {
  openTabs,
  pin,
  unpin,
  hide,
  unhide,
  archive,
  restore,
  delete,
}

KapyIconData _pickedIcon(PickedAction action) => switch (action) {
  PickedAction.openTabs => KapyIcons.openExternalRounded,
  PickedAction.pin => KapyIcons.pinOutlined,
  PickedAction.unpin => KapyIcons.pinOutlined,
  PickedAction.hide => hiddenIcon,
  PickedAction.unhide => unhideIcon,
  PickedAction.archive => archiveIcon,
  PickedAction.restore => restoreIcon,
  PickedAction.delete => deleteIcon,
};

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
    this.onMoveSelect,
    this.onEnterSelected,
    this.onOpenToSide,
    this.openElsewhereIds = const {},
    this.ofPickedDay,
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
    this.searchShortcut,
    this.searchPlaceholder = 'Search',
    this.archiveShortcut,
    this.archiveMode = false,
    this.hiddenMode = false,
    this.onDelete,
    this.asksBeforeDeleting = true,
    this.onDeleteAll,
    this.picks,
    this.onPicked,
    this.collaborators = const {},
    this.onOpenPerson,
    this.onStartSharing,
    this.tab = SidebarTab.mine,
    this.onTabChanged,
    required this.windowBar,
    this.drawings = false,
    this.onNewDrawing,
    this.engine,
    this.now = DateTime.now,
    this.cards = false,
    this.phone = false,
    this.phoneTiles,
    this.filtersOpen = true,
    this.filtersActive = false,
    this.onFiltersToggled,
    this.controls,
    this.pinnedOnly = false,
    this.onPinnedOnlyChanged,
    this.grouping = NotesGrouping.byDate,
    this.ownDay,
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

  /// Whether a note is on the day last picked in the page's week, which
  /// lights it more quietly than the open one. Asked only of the rows built.
  final bool Function(Note note)? ofPickedDay;

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
  final ShortcutBinding? searchShortcut;

  /// What the search field reads at rest: "Search", or "Search or Ask Kapy
  /// AI" where ⌘K can ask.
  final String searchPlaceholder;

  /// The key that files the open note away, for the row's menu to name.
  ///
  /// Worth the two words it takes: nothing else announces the chord, and a
  /// shortcut nobody can find is a shortcut nobody uses. Read from the
  /// binding rather than written out, so a rebound key is not misnamed here.
  final ShortcutBinding? archiveShortcut;

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

  /// The notes picked to act on together. Null where none can be.
  final NotePicks? picks;

  /// Does an action to the picked notes on screen it applies to, given in
  /// the list's order.
  final void Function(PickedAction action, List<String> ids)? onPicked;

  /// Whoever else has each shared note open right now, by note. A row with
  /// somebody in it says so where its timestamp would be.
  final Map<String, List<Collaborator>> collaborators;

  /// Opens a person's page in Settings → Sharing, by address, from a heading
  /// in the Shared list. Null leaves the heading a label.
  final ValueChanged<String>? onOpenPerson;

  /// Opens Settings → Sharing on Share with someone, from the empty Shared
  /// list. Null leaves the button out.
  final VoidCallback? onStartSharing;

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
  final Widget windowBar;

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

  /// A phone's home: a large title over the list, the rest as rows that
  /// swipe, and a pull down for Quick find. Only beside a [windowBar], which
  /// is the phone's title.
  final bool phone;

  /// The tiles a phone's Folders puts over its tree: Drawings and Shared.
  final Widget? phoneTiles;

  /// The notes filter and the list/cards switch, under the search beside the
  /// rail: see [NotesListControls]. Null leaves them out, as the compact list
  /// does.
  final Widget? controls;

  /// Whether a phone's filter row is showing. The row is put away by default
  /// so the list keeps the room, and the button beside the search brings it
  /// back. Wide layouts always draw it.
  final bool filtersOpen;

  /// Whether a filter narrows the list while the row is put away, so the
  /// button can say so rather than leave a hidden filter a surprise.
  final bool filtersActive;

  /// Puts a phone's filter row away and brings it back. Null on a wide
  /// layout, where the row is always there and there is no button.
  final VoidCallback? onFiltersToggled;

  /// Whether the list is showing every pinned note, after View all, rather
  /// than the few most recent over the rest.
  final bool pinnedOnly;
  final ValueChanged<bool>? onPinnedOnlyChanged;

  /// How the list beside the rail groups what Pinned leaves.
  final NotesGrouping grouping;

  /// The day a note was given, where it has one: a note waiting for a later
  /// day stays out of the days until it comes.
  final DateTime? Function(Note note)? ownDay;

  /// How far back the filter reaches, for an empty list to say so and to
  /// offer any time again.
  final NotesWhen when;
  final ValueChanged<NotesWhen>? onWhenChanged;

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
    return ColoredBox(
      color: phone ? palette.paperColor : palette.sidebarColor,
      // Colour runs to the window edges; content stays clear of the status
      // bar, home indicator and any display cutout.
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            windowBar,
            SidebarSearchField(
              onSearch: onSearch,
              query: query,
              onClear: onClearQuery,
              shortcut: searchShortcut,
              placeholder: searchPlaceholder,
              phone: phone,
              trailing: phone && controls != null && onFiltersToggled != null
                  ? PhoneFiltersButton(
                      key: const ValueKey('phone-filters'),
                      active: filtersActive,
                      onPressed: onFiltersToggled!,
                    )
                  : switch (folders?.newFolder) {
                      final newFolder? when phone && _foldersTab =>
                        SizedBox.square(
                          dimension: 44,
                          child: CompactIconButton(
                            key: const ValueKey('phone-new-folder'),
                            tooltip: 'New folder',
                            semanticLabel: 'New folder',
                            extent: 44,
                            onPressed: () => newFolder.value++,
                            icon: KapyIcon(
                              KapyIcons.folderAddOutlined,
                              size: 18,
                              color: palette.textSecondary,
                            ),
                          ),
                        ),
                      _ => null,
                    },
            ),
            if (controls != null && !_foldersTab)
              if (phone && onFiltersToggled != null)
                // A phone keeps the filter row out of the way until the
                // button asks for it, and the list slides up to take its
                // room while it is put away.
                AnimatedSize(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: filtersOpen
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: controls,
                        )
                      : const SizedBox(width: double.infinity),
                )
              else
                Padding(
                  padding: phone
                      ? const EdgeInsets.only(bottom: 2)
                      : const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: controls,
                ),
            if (_picking || (archiveMode && notes.isNotEmpty))
              _pickBar(context),
            Expanded(
              child: _BelowInvitations(
                invitations:
                    !_specialMode &&
                        sharing != null &&
                        sharing!.invites.isNotEmpty &&
                        _onSharedTab
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
                      : _sweeps(_buildBesideRail(context)),
                ),
              ),
            ),
            if (folders?.onShown case final onShown?)
              NotesFoldersSwitch(folders: _foldersTab, onChanged: onShown),
          ],
        ),
      ),
    );
  }

  /// A note's card, or its row in the list view, away from the list: on a
  /// folder's page, with the face, clicks and menu it has here, giving only
  /// its time under a heading that names its day ([clockOnly]).
  Widget noteTile(Note note, {bool clockOnly = false}) => _row(
    note,
    shared: sharing != null && note.isShared,
    pinned: pinnedNoteIds.contains(note.id),
    style: cards ? NoteRowStyle.card : NoteRowStyle.row,
    clockOnly: clockOnly,
  );
}

extension on Sidebar {
  bool get _specialMode => archiveMode || hiddenMode;

  /// The tabs split the ordinary list only. The archive and Hidden Notes
  /// are folders of their own, and a build without an account has nobody
  /// else's notes to show.
  bool get _tabbed => sharing != null && !_specialMode && onTabChanged != null;

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

  Widget _buildEmpty(BuildContext context) {
    final onWhenChanged = this.onWhenChanged;
    if (query.trim().isEmpty && when != NotesWhen.anyTime) {
      return _SidebarEmpty(
        message: 'No ${drawings ? 'drawings' : 'notes'} ${when.phrase}',
        action: onWhenChanged == null
            ? null
            : TonalButton(
                key: const ValueKey('sidebar-empty-action'),
                label: NotesWhen.anyTime.label,
                onPressed: () => onWhenChanged(NotesWhen.anyTime),
              ),
      );
    }
    if (drawings && query.trim().isEmpty) {
      return _DrawingsEmpty(onNewDrawing: onNewDrawing);
    }
    final nothingShared = query.trim().isEmpty && _onSharedTab;
    final onStartSharing = this.onStartSharing;
    return _SidebarEmpty(
      message: query.trim().isEmpty
          ? archiveMode
                ? 'Archived Notes is empty'
                : hiddenMode
                ? 'Hidden Notes is empty'
                : _onSharedTab
                ? 'Nothing shared yet'
                : 'No notes yet'
          : drawings
          ? 'No matching drawings'
          : 'No matching notes',
      detail: nothingShared
          ? 'Pick notes and someone to share them with. Only the people you '
                'add, or anyone with a link you turn on, can see them.'
          : null,
      action: nothingShared && onStartSharing != null
          ? TonalButton(
              key: const ValueKey('sidebar-empty-share'),
              icon: KapyIcons.shareRounded,
              label: 'Share with someone',
              onPressed: onStartSharing,
            )
          : null,
    );
  }

  /// Whether the reader may change [note]: their own always, a shared one
  /// only where the space says so. The row's rule, and the keyboard's.
  bool _mayEdit(Note note) => sharing?.canEdit(note) ?? !note.isShared;

  /// Whether the reader may take [note] out of their notes: what they may
  /// change, and anything somebody else shares with them, view-only too.
  bool _mayRemove(Note note) => sharing?.mayRemove(note) ?? !note.isShared;

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
  List<Note> get _painted => _railOrder;

  List<String> get _order => [for (final note in _painted) note.id];

  /// The picked notes on screen, in the list's order. One picked in another
  /// list, or filtered out by a search, is not what an action here acts on.
  /// With [joining], that note too, as a right click on its row picks it
  /// before the menu opens.
  List<Note> _picked([String? joining]) => [
    for (final note in _painted)
      if (note.id == joining || (picks?.contains(note.id) ?? false)) note,
  ];

  /// What can be done to the picked notes, each with the ones it applies to:
  /// the row menu's own rules, note by note, so one a reader may only view
  /// is left out of what would change it.
  List<(PickedAction, List<Note>)> _pickedChoices([String? joining]) {
    final picked = _picked(joining);
    List<Note> those(bool Function(Note note) applies) =>
        picked.where(applies).toList();
    final unpinned = those((note) => !pinnedNoteIds.contains(note.id));
    return [
      if (onOpenInNewTab != null)
        (PickedAction.openTabs, those((note) => !tabbedIds.contains(note.id))),
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
      if (onDelete != null) (PickedAction.delete, those(_mayRemove)),
    ];
  }

  /// What an action says it does, under the line that counts the picked
  /// notes. One that leaves some of them out says how many it acts on. One
  /// note deletes as a row does, asking only if the reader still wants to be
  /// asked; more always ask.
  String _pickedLabel(PickedAction action, List<Note> notes, int picked) {
    final some = notes.length < picked ? ' ${_count(notes.length)}' : '';
    return switch (action) {
      PickedAction.openTabs => 'Open in tabs',
      PickedAction.pin => 'Pin$some',
      PickedAction.unpin => 'Unpin$some',
      PickedAction.hide => 'Move$some to Hidden Notes',
      PickedAction.unhide => 'Move$some to Notes',
      PickedAction.archive => 'Archive$some',
      PickedAction.restore => 'Restore$some',
      PickedAction.delete =>
        notes.length == 1
            ? _deleteLabel(notes.single)
            : notes.every(_theirs)
            ? 'Remove ${_count(notes.length)}…'
            : 'Delete ${_count(notes.length)}…',
    };
  }

  static String _count(int notes) => notes == 1 ? '1 note' : '$notes notes';

  /// The picked notes Tags… tags: all of them, as a row's Tags tags its note.
  List<String> _taggable(BuildContext context, [String? joining]) =>
      TagShelf.maybeOf(context) == null
      ? const []
      : [for (final note in _picked(joining)) note.id];

  /// The picked notes Move to folder… files: the ones a row would offer it on.
  List<String> _fileable([String? joining]) => [
    for (final note in _picked(joining))
      if (_files(note)) note.id,
  ];

  /// The menu a right click or long press on a row opens while notes are
  /// picked, with the row's note, [joining], among them, as the click picks
  /// it first: how many, then the row menu's groups. How to open them, what
  /// to do to them, and the ways out of the list.
  KapyMenu _pickedMenu(BuildContext context, String joining) {
    final picked = _picked(joining).length;
    final choices = {
      for (final (action, notes) in _pickedChoices(joining))
        if (notes.isNotEmpty) action: notes,
    };
    List<KapyMenuAction> those(List<PickedAction> actions) => [
      for (final action in actions)
        if (choices[action] case final notes?)
          KapyMenuAction(
            value: 'picked-${action.name}',
            label: _pickedLabel(action, notes, picked),
            icon: _pickedIcon(action),
            destructive: action == PickedAction.delete,
          ),
    ];
    return (
      heading: _count(picked),
      groups: [
        those(const [PickedAction.openTabs]),
        [
          ...those(const [PickedAction.pin, PickedAction.unpin]),
          if (_taggable(context, joining).isNotEmpty)
            const KapyMenuAction(
              value: 'picked-tags',
              label: 'Tags',
              icon: KapyIcons.tagRounded,
              hint: '›',
            ),
          if (_fileable(joining).isNotEmpty)
            const KapyMenuAction(
              value: 'picked-folder',
              label: 'Move to folder…',
              icon: KapyIcons.folderMoveOutlined,
            ),
          ...those(const [
            PickedAction.hide,
            PickedAction.unhide,
            PickedAction.restore,
          ]),
        ],
        those(const [PickedAction.archive, PickedAction.delete]),
      ],
    );
  }

  /// Does what the picked notes' menu names. Tags and Move to folder… open
  /// their pickers at [anchor]; the rest go to [onPicked].
  Future<void> _choosePicked(
    String value,
    BuildContext context,
    Offset anchor,
  ) async {
    if (value == 'picked-tags') {
      return showTagPickerAt(context, anchor, _taggable(context));
    }
    if (folders case final folders? when value == 'picked-folder') {
      return moveNotesToFolder(context, anchor, folders.store, _fileable());
    }
    for (final (action, notes) in _pickedChoices()) {
      if (value != 'picked-${action.name}' || notes.isEmpty) continue;
      onPicked?.call(action, [for (final note in notes) note.id]);
    }
  }

  /// [action] on the picked notes it applies to; null where it applies to
  /// none of them, which greys its button out.
  VoidCallback? _pickedAction(PickedAction action) {
    final onPicked = this.onPicked;
    if (onPicked == null) return null;
    for (final (each, notes) in _pickedChoices()) {
      if (each != action || notes.isEmpty) continue;
      return () => onPicked(action, [for (final note in notes) note.id]);
    }
    return null;
  }

  /// Over the list while notes are picked: how many, what can be done to
  /// them, and Done. Over the archive at rest, its Select and Delete all.
  ///
  /// With a pointer the bar holds the picked notes' menu, minus Open in tabs,
  /// where the list is wide enough for it; a narrower list keeps what most
  /// often happens to them and Delete, and the rest stay in their menu.
  /// Before anything is picked, as the archive's Select notes leaves it, it
  /// holds Select all instead. A touch screen keeps the shorter bar, with
  /// Select all until everything is picked, since it has no ⌘A to press.
  Widget _pickBar(BuildContext context) {
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
    final picked = _picked().length;
    final order = _order;
    final label = picked == 0 ? 'Select notes' : '$picked selected';
    final primary = archiveMode
        ? PickedAction.restore
        : hiddenMode
        ? PickedAction.unhide
        : PickedAction.archive;
    final choices = {
      for (final (action, notes) in _pickedChoices()) action: notes,
    };
    // Nothing to act on yet: no row of greyed buttons.
    List<Widget> those(List<PickedAction> actions) => [
      for (final action in actions)
        if (choices[action] case final notes? when picked > 0)
          _IconButton(
            key: ValueKey('picked-${action.name}'),
            icon: _pickedIcon(action),
            tooltip: _pickedLabel(
              action,
              notes.isEmpty ? _picked() : notes,
              picked,
            ),
            onPressed: _pickedAction(action),
          ),
    ];
    final selectAll = _IconButton(
      key: const ValueKey('pick-all'),
      icon: KapyIcons.selectAllRounded,
      tooltip: 'Select all',
      onPressed: () => picks.all(order),
    );
    final short = those([primary, PickedAction.delete]);
    if (!AppPlatform.hasPointer) {
      return _PickActions(
        label: label,
        buttons: [
          if (picked < order.length) selectAll,
          ...short,
          _IconButton(
            key: const ValueKey('pick-done'),
            icon: KapyIcons.closeRounded,
            tooltip: 'Done selecting',
            onPressed: picks.clear,
          ),
        ],
      );
    }
    final full = [
      ...those(const [PickedAction.pin, PickedAction.unpin]),
      if (_taggable(context).isNotEmpty)
        _pickerButton('picked-tags', KapyIcons.tagRounded, 'Tags'),
      if (_fileable().isNotEmpty)
        _pickerButton(
          'picked-folder',
          KapyIcons.folderMoveOutlined,
          'Move to folder…',
        ),
      ...those(const [
        PickedAction.hide,
        PickedAction.unhide,
        PickedAction.restore,
        PickedAction.archive,
        PickedAction.delete,
      ]),
    ];
    final done = TonalButton(
      key: const ValueKey('pick-done'),
      label: 'Done',
      onPressed: picks.clear,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: _PickActions.labelStyle(context)),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final needed =
            _PickActions.padding.horizontal +
            painter.width +
            full.length * (AppControlMetrics.iconButtonExtent + _pickGap) +
            _pickGap * 2 +
            TonalButton.widthOf(context, 'Done', icon: false);
        painter.dispose();
        final buttons = picked == 0
            ? [selectAll]
            : needed <= constraints.maxWidth
            ? full
            : short;
        return _PickActions(
          label: label,
          buttons: [
            for (final button in buttons) ...[
              const SizedBox(width: _pickGap),
              button,
            ],
            const SizedBox(width: _pickGap * 2),
            done,
          ],
        );
      },
    );
  }

  /// The room between the picked notes' bar buttons.
  static const double _pickGap = 6;

  /// One of the picked notes' bar buttons that opens a picker under itself.
  Widget _pickerButton(String value, KapyIconData icon, String tooltip) =>
      Builder(
        builder: (context) => _IconButton(
          key: ValueKey(value),
          icon: icon,
          tooltip: tooltip,
          onPressed: () {
            final box = context.findRenderObject() as RenderBox?;
            unawaited(
              _choosePicked(
                value,
                context,
                box?.localToGlobal(box.size.bottomLeft(Offset.zero)) ??
                    Offset.zero,
              ),
            );
          },
        ),
      );

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
    if (note == null || !_mayRemove(note)) return null;
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

  Widget _row(
    Note note, {
    required bool shared,
    bool pinned = false,
    NoteRowStyle style = NoteRowStyle.row,
    double inset = 0,
    bool clockOnly = false,
  }) => MetaData(
    metaData: NotePickTarget(note.id),
    child: _noteRow(
      note,
      shared: shared,
      pinned: pinned,
      style: style,
      inset: inset,
      clockOnly: clockOnly,
    ),
  );

  Widget _noteRow(
    Note note, {
    required bool shared,
    required bool pinned,
    required NoteRowStyle style,
    required double inset,
    bool clockOnly = false,
  }) => NoteRow(
    key: ValueKey(note.id),
    note: note,
    style: style,
    inset: inset,
    clockOnly: clockOnly,
    laterDay: clockOnly ? null : _laterDay(note),
    folders: _files(note) ? folders?.store : null,
    engine: engine,
    now: now,
    query: query,
    displayTime: displayTime,
    selected: note.id == selectedId,
    shared: shared,
    pinned: pinned,
    locked: lockedNoteIds.contains(note.id),
    collaborators: shared && !(phone && clockOnly)
        ? collaborators[note.id] ?? const []
        : const [],
    // Shared's own list leaves the faces off: its headings name them.
    shareGroup: phone && shared && !_onSharedTab
        ? sharing?.groupOf(note)
        : null,
    onTap: () => onSelect(note.id),
    onOpenToSide: onOpenToSide == null ? null : () => onOpenToSide!(note.id),
    openElsewhere: openElsewhereIds.contains(note.id),
    ofPickedDay: ofPickedDay?.call(note) ?? false,
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
    onDelete: onDelete == null || !_mayRemove(note)
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
    pickedActions: picks == null
        ? null
        : (context) => _pickedMenu(context, note.id),
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
  /// most recent, or five in a phone's scroller, unless View all or a search
  /// asks for every one. A list with no View all shows them all.
  List<Note> _shownPinned(SidebarNoteGroups groups) =>
      pinnedOnly || query.trim().isNotEmpty || onPinnedOnlyChanged == null
      ? groups.pinned
      : groups.pinned.take(phone ? 5 : 4).toList();

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
      for (final key in groups.groupOrder) ...groups.byGroup[key]!,
      ...groups.mine,
    ];
  }

  /// The heading over one group of the Shared list. A tap opens the page of
  /// the first person it names: the owner of a From group, and the first by
  /// name of a group of several, whose page lists the notes they share with
  /// the others too.
  Widget _groupHeading(SidebarNoteGroups groups, String key) {
    final notes = groups.byGroup[key]!;
    final group = groups.shareGroups[key];
    final onOpenPerson = this.onOpenPerson;
    return _ShareGroupHeader(
      key: ValueKey('share-group-$key'),
      group: group,
      title:
          group?.title ??
          sharing?.spaceOf(notes.first)?.titleFor(sharing!.userId) ??
          'Shared',
      present: {
        for (final note in notes)
          for (final person in collaborators[note.id] ?? const [])
            person.userId,
      },
      attention: {
        for (final note in notes) ?note.spaceId,
      }.any((id) => sharing?.trust.warningsFor(id).isNotEmpty ?? false),
      onTap: group == null || onOpenPerson == null
          ? null
          : () => onOpenPerson(group.people.first.email),
    );
  }

  /// The list beside the spaces rail: Pinned, then each shared space, then
  /// Notes, as sticky cards two to a row or as rows, fading out at the foot.
  Widget _buildBesideRail(BuildContext context) {
    final palette = context.palette;
    final groups = _noteGroups;
    final pinned = _shownPinned(groups);
    final rows = <WidgetBuilder>[];
    // A phone's Drawings is all thumbnails, two to a row.
    final cards = this.cards || (phone && drawings);
    final style = switch ((cards, drawings)) {
      (true, true) => NoteRowStyle.drawingCard,
      (true, false) => NoteRowStyle.card,
      (false, true) => NoteRowStyle.drawingRow,
      (false, false) => phone ? NoteRowStyle.touch : NoteRowStyle.row,
    };
    final margin = phone ? 20.0 : 16.0;
    final noun = drawings ? 'drawing' : 'note';
    final onPinnedOnlyChanged = this.onPinnedOnlyChanged;
    final onOpenPinned = phone && !drawings && onPinnedOnlyChanged != null
        ? () => onPinnedOnlyChanged(true)
        : null;

    void gap(double height) => rows.add((_) => SizedBox(height: height));

    void heading(Widget heading) {
      if (rows.isNotEmpty) gap(phone ? 22 : 24);
      rows.add(
        (_) => Padding(
          padding: EdgeInsets.symmetric(horizontal: margin),
          child: heading,
        ),
      );
      gap(
        phone
            ? 12
            : cards
            ? 8
            : 4,
      );
    }

    // A phone's pinned notes are cards whatever the list draws: a sideways
    // row on Home and two to a row on the Pinned page.
    Widget pinnedCard(Note note) => _row(
      note,
      shared: sharing != null && note.isShared,
      pinned: true,
      style: NoteRowStyle.phoneCard,
    );

    void section(
      Iterable<Note> notes, {
      bool pinned = false,
      bool clockOnly = false,
    }) {
      final list = notes.toList();
      Widget note(Note note) => _row(
        note,
        shared: sharing != null && note.isShared,
        pinned: pinned,
        style: style,
        clockOnly: clockOnly,
      );
      if (phone && !cards) {
        for (final (index, each) in list.indexed) {
          if (index > 0) {
            rows.add(
              (context) => Divider(
                height: AppHairline.of(context),
                thickness: AppHairline.of(context),
                indent: margin,
                endIndent: margin,
                color: context.palette.separator,
              ),
            );
          }
          rows.add((_) => note(each));
        }
        return;
      }
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
            padding: EdgeInsets.symmetric(horizontal: margin),
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
                KapyIcon(hiddenIcon, size: 14, color: palette.textTertiary),
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
    } else if (pinnedOnly && phone && !drawings) {
      // The Pinned page, under its own title: every pinned note as a card,
      // two to a row.
      const gutter = PhonePinnedCards.gap;
      gap(16);
      for (var index = 0; index < groups.pinned.length; index += 2) {
        if (index > 0) gap(gutter);
        final pair = groups.pinned.skip(index).take(2).toList();
        rows.add(
          (context) => Padding(
            padding: EdgeInsets.symmetric(horizontal: margin),
            child: SizedBox(
              height: PhoneCardFace.height(context),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: pinnedCard(pair.first)),
                  const SizedBox(width: gutter),
                  Expanded(
                    child: pair.length > 1
                        ? pinnedCard(pair.last)
                        : const SizedBox(),
                  ),
                ],
              ),
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
          leading: CompactIconButton(
            key: const ValueKey('sidebar-pinned-back'),
            tooltip: 'Back to all notes',
            extent: 22,
            foregroundColor: palette.textSecondary,
            onPressed: onPinnedOnlyChanged == null
                ? null
                : () => onPinnedOnlyChanged(false),
            icon: const KapyIcon(KapyIcons.arrowBackRounded, size: 16),
          ),
        ),
      );
      section(groups.pinned, pinned: true);
    } else if (phone) {
      // Home's Pinned, the one list with View all: up to five cards in a
      // sideways row. Elsewhere, Drawings, Shared or a folder, every pinned
      // note sits over the rest as the list draws it.
      if (onOpenPinned case final onOpenPinned? when pinned.isNotEmpty) {
        rows.add(
          (_) => Padding(
            // 16 over it with the list's own 4 at the top.
            padding: EdgeInsets.fromLTRB(margin, 12, margin, 10),
            child: Row(
              key: const ValueKey('sidebar-pinned-heading'),
              children: [
                Expanded(
                  child: _PhoneDayHeading(
                    lead: 'Pinned',
                    date: '${groups.pinned.length}',
                  ),
                ),
                ViewAllLink(
                  key: const ValueKey('sidebar-view-all-pinned'),
                  phone: true,
                  onPressed: onOpenPinned,
                ),
              ],
            ),
          ),
        );
        rows.add(
          (_) => PhonePinnedCards(
            key: const ValueKey('phone-pinned-cards'),
            margin: margin,
            children: [for (final note in pinned) pinnedCard(note)],
          ),
        );
      } else if (pinned.isNotEmpty) {
        heading(const _PhoneHeading('Pinned'));
        section(pinned, pinned: true);
      }
      for (final key in groups.groupOrder) {
        heading(_groupHeading(groups, key));
        section(groups.byGroup[key]!);
      }
      if (drawings) {
        // Drawings stay one grid of thumbnails, two to a row, which a day
        // heading would break into short rows.
        if (groups.mine.isNotEmpty) {
          heading(const _PhoneHeading('Recent'));
          section(groups.mine);
        }
      } else {
        // A day at a time, newest first, under the day the note was last
        // edited, each note giving its time alone, even while others have it
        // open.
        for (final day in _phoneDays(
          groups.mine,
          now: now(),
          displayTime: displayTime,
          ownDay: ownDay,
        )) {
          heading(_PhoneDayHeading(lead: day.lead, date: day.date));
          section(day.notes, clockOnly: true);
        }
      }
    } else {
      if (pinned.isNotEmpty) {
        heading(
          NotesListHeading(
            key: const ValueKey('sidebar-pinned-heading'),
            label: 'Pinned',
            count: groups.pinned.length,
            noun: noun,
            height: 16,
            trailing:
                pinned.length < groups.pinned.length &&
                    onPinnedOnlyChanged != null
                ? ViewAllLink(
                    key: const ValueKey('sidebar-view-all-pinned'),
                    onPressed: () => onPinnedOnlyChanged(true),
                  )
                : null,
          ),
        );
        section(pinned, pinned: true);
      }
      for (final key in groups.groupOrder) {
        heading(_groupHeading(groups, key));
        section(groups.byGroup[key]!);
      }
      final grouped = groupNotes(
        groups.mine,
        grouping,
        today: dayShown(now(), displayTime),
        displayTime: displayTime,
        firstTag: (note) => TagMarks.of(context, note.id).firstOrNull?.name,
        ownDay: ownDay,
      );
      for (final group in grouped) {
        heading(
          NotesGroupHeading(
            key: ValueKey('sidebar-group-${group.label}'),
            label: group.label,
            detail: group.detail,
          ),
        );
        section(group.notes, clockOnly: group.day != null);
      }
    }

    return _fading(
      context,
      ListView.builder(
        physics: phone ? const AlwaysScrollableScrollPhysics() : null,
        // A phone's list clears the floating bar and its +.
        padding: EdgeInsets.only(top: 4, bottom: phone ? 120 : 40),
        itemCount: rows.length,
        itemBuilder: (context, index) => rows[index](context),
      ),
    );
  }

  /// The day [note] was given, when that is a later one, for its row to name.
  DateTime? _laterDay(Note note) {
    final own = ownDay?.call(note);
    return waitsForLaterDay(own, dayShown(now(), displayTime)) ? own : null;
  }

  /// The Folders tab: the folder tree, then the notes in no folder.
  Widget _buildFolders(BuildContext context) {
    final folders = this.folders!;
    return _fading(
      context,
      FoldersTab(
        store: folders.store,
        notes: notes,
        open: folders.open,
        onOpen: folders.onOpen,
        inFront: folders.inFront,
        onTab: folders.onTab,
        header: phoneTiles,
        phone: phone,
        newFolder: folders.newFolder,
        looseHeading: phone ? (label) => _PhoneDayHeading(lead: label) : null,
        noteRow: (note, inset) => _row(
          note,
          shared: sharing != null && note.isShared,
          style: switch (inset) {
            null when phone => NoteRowStyle.touch,
            null => NoteRowStyle.loose,
            _ => NoteRowStyle.filed,
          },
          inset: inset ?? 0,
        ),
      ),
    );
  }

  /// [list] fading out at the foot of the list beside the rail.
  Widget _fading(BuildContext context, Widget list) {
    final palette = context.palette;
    final ground = phone ? palette.paperColor : palette.sidebarColor;
    return Stack(
      children: [
        if (phone) _PullToFind(onPulled: onSearch, child: list) else list,
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
                  colors: [ground.withValues(alpha: 0), ground],
                  stops: const [0, 0.85],
                ),
              ),
            ),
          ),
        ),
      ],
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
       // Behind the tabs the person's own shared notes sit among the rest
       // of theirs, and are gathered under their people only in Shared.
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
      // In the order the notes come, so the group with the latest change
      // leads. A note whose people this device cannot name yet keeps to its
      // own space.
      for (final note in remaining) {
        if (!note.isShared) continue;
        final group = sharing?.groupOf(note);
        final key = group?.key ?? 'space:${note.spaceId}';
        shareGroups.putIfAbsent(key, () => group);
        byGroup.putIfAbsent(key, () => []).add(note);
      }
    }
  }

  final List<Note> pinned;
  late final List<Note> mine;

  /// The shared notes under each heading, by [ShareGroup.key], in the order
  /// the headings come.
  final Map<String, List<Note>> byGroup = {};

  /// What each heading names; null for a note in a space nobody else is in
  /// yet, or one this device has not heard about.
  final Map<String, ShareGroup?> shareGroups = {};
  final bool hasSharedSections;

  Iterable<String> get groupOrder => byGroup.keys;

  List<Note> get displayOrder => [
    ...pinned,
    for (final key in groupOrder) ...byGroup[key]!,
    ...mine,
  ];
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

  static const padding = EdgeInsets.fromLTRB(12, 0, 8, 8);

  /// The count's style over the text around the bar, so that the bar
  /// measures the count in the face it reads in.
  static TextStyle labelStyle(BuildContext context) =>
      DefaultTextStyle.of(context).style.merge(
        TextStyle(
          fontSize: AppTypeScale.small,
          fontWeight: AppWeight.font(AppWeight.body),
          fontVariations: AppWeight.wght(AppWeight.body),
          color: context.palette.textSecondary,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle(context),
              ),
            ),
          ),
          ...buttons,
        ],
      ),
    );
  }
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
    this.onAskKapy,
    this.askKapyShortcut,
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
  /// New drawing has no keycap, as D08 draws it, and names the chord on
  /// hover.
  final ShortcutBinding? newNoteShortcut;
  final ShortcutBinding? hideShortcut;

  /// Opens Kapy AI's panel from the sparkle left of New note. Null leaves
  /// the sparkle out, as over Drawings and Tasks and while Kapy AI is off
  /// or not in this build.
  final VoidCallback? onAskKapy;
  final ShortcutBinding? askKapyShortcut;

  static const double height = 52;

  /// The narrowest desktop list that keeps the count and New's word: the
  /// list's own width, which a 1440 pt window gives it and where D01 and D03
  /// draw both, with the sparkle, New and the toggle side by side. Below it
  /// they fold away, and sooner wherever the reader's text size or a longer
  /// name leaves them no room. A tablet keeps 8 between the buttons and
  /// folds only for room.
  static const double fullWidth = LayoutPrefs.defaultSidebarWidth;

  /// New's name and chord on hover, as the page's + names it while this bar
  /// is hidden.
  static String newTooltip(String noun, ShortcutBinding? shortcut) =>
      ['New $noun', ?shortcut?.displayLabel].join('  ');

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    const handwritten = WritingFont.handwritten;
    final newNoteShortcut = this.newNoteShortcut;
    final hideShortcut = this.hideShortcut;
    final onAskKapy = this.onAskKapy;
    final askKapyShortcut = this.askKapyShortcut;
    final titleStyle = chromeStyle(
      size: AppTypeScale.spaceTitle,
      line: AppTypeScale.spaceTitle * 1.3,
      weight: AppWeight.button,
      color: palette.textPrimary,
      family: handwritten.fontFamily,
      fallback: handwritten.fontFamilyFallback,
      extra: handwritten.faceVariations,
    );
    final countText = [count, ?countLabel].join(' ');
    final countStyle = chromeStyle(
      size: AppTypeScale.small,
      line: 16,
      weight: AppWeight.body,
      color: palette.textTertiary,
      tabular: true,
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

    return Container(
      height: AppControlMetrics.scaleBar(context, height),
      foregroundDecoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.railBorder)),
      ),
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
                  final desktop = AppPlatform.hasPointer;
                  final gap = desktop ? 0 : 8;
                  final room =
                      constraints.maxWidth -
                      widthOf(title, titleStyle) -
                      8 -
                      gap -
                      32 -
                      (onAskKapy == null ? 0 : 32 + gap);
                  final chord = noun == 'drawing'
                      ? null
                      : newNoteShortcut?.keycapLabel;
                  bool fits({String? shortcut}) =>
                      room - 8 - widthOf(countText, countStyle) >=
                      TonalButton.widthOf(
                        context,
                        'New $noun',
                        shortcut: shortcut,
                        tall: true,
                      );
                  final label =
                      (!desktop ||
                          constraints.maxWidth + 2 * 16 >= fullWidth) &&
                      fits();
                  final keycap =
                      label && chord != null && fits(shortcut: chord);
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
                      if (onAskKapy != null)
                        CompactIconButton(
                          key: const ValueKey('sidebar-ask-kapy'),
                          tooltip: askKapyShortcut == null
                              ? 'Ask Kapy'
                              : 'Ask Kapy  ${askKapyShortcut.displayLabel}',
                          extent: 32,
                          radius: 8,
                          onPressed: onAskKapy,
                          icon: const KapyIcon(
                            KapyIcons.sparklesOutlined,
                            size: 16,
                          ),
                        ),
                      if (onAskKapy != null && !desktop)
                        const SizedBox(width: 8),
                      TonalButton(
                        key: const ValueKey('sidebar-new-note'),
                        tall: true,
                        icon: KapyIcons.addRounded,
                        label: label ? 'New $noun' : null,
                        quiet: true,
                        sageIcon: true,
                        shortcut: keycap ? newNoteShortcut?.keycapLabel : null,
                        // Without its keycap the button still teaches the
                        // chord, on hover.
                        tooltip: keycap
                            ? null
                            : newTooltip(noun, newNoteShortcut),
                        onPressed: onCreate,
                      ),
                      if (!desktop) const SizedBox(width: 8),
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

/// Invitations waiting for an answer, just under the search field.
///
/// Where they are seen: an invitation used to wait in Settings › Sharing,
/// which nobody opens to find out whether somebody has shared something with
/// them. Accepting from here opens Shared, where the notes arrive.
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
          child: const Text('Report…'),
        ),
        PopupMenuItem(
          key: ValueKey('invite-block-${invite.token}'),
          value: 'block',
          height: 36,
          // Phones ask first, as the member menu's Block… does.
          child: Text(
            AppPlatform.isMobile
                ? 'Block…'
                : 'Block ${invite.inviterDisplayName}',
          ),
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
        if (AppPlatform.isMobile) {
          final ok = await askFirst(
            context,
            title: 'Block ${invite.inviterDisplayName}?',
            body:
                'They can’t invite you again, and this invitation goes away. '
                'You can unblock them in Settings, under Blocked people.',
            action: 'Block',
          );
          if (ok == null || !mounted) return;
        }
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
              done: joinedLine,
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
      invite.role.accessLabel,
    ].join(' · ');
    final avatar = touch ? 32.0 : 28.0;
    final button = touch ? 36.0 : 28.0;
    final label = TextStyle(
      fontSize: touch ? 15 : 13,
      height: touch ? 20 / 15 : 18 / 13,
      fontWeight: AppWeight.font(AppWeight.button),
      fontVariations: AppWeight.wght(AppWeight.button),
    );
    final buttonStyle = TextButton.styleFrom(
      minimumSize: Size(0, button),
      tapTargetSize: touch
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: label,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          touch ? AppRadii.control : AppRadii.compact,
        ),
      ),
    );
    final initial = who.trim().isEmpty ? '?' : who.trim()[0].toUpperCase();
    return Padding(
      padding: touch
          ? const EdgeInsets.fromLTRB(16, 0, 16, 8)
          : const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        decoration: BoxDecoration(
          color: palette.textPrimary.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: avatar,
                  height: avatar,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: palette.textPrimary.withValues(alpha: 0.07),
                  ),
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: touch ? 14 : 12,
                      height: touch ? 18 / 14 : 16 / 12,
                      fontWeight: AppWeight.font(AppWeight.button),
                      fontVariations: AppWeight.wght(AppWeight.button),
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: label.copyWith(color: palette.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: touch ? 13 : 12,
                          height: touch ? 18 / 13 : 16 / 12,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (buttonContext) => CompactIconButton(
                    key: ValueKey('sidebar-invite-more-${invite.token}'),
                    tooltip: 'More',
                    extent: touch ? 32 : 28,
                    foregroundColor: palette.textSecondary,
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
                      KapyIcons.moreVerticalRounded,
                      size: AppControlMetrics.iconAdornment,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Side by side where they fit, stacked where the sidebar is
            // dragged too narrow for both.
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              overflowSpacing: 4,
              spacing: 4,
              children: [
                TextButton(
                  key: ValueKey('sidebar-invite-decline-${invite.token}'),
                  style: buttonStyle.copyWith(
                    foregroundColor: WidgetStatePropertyAll(
                      palette.textSecondary,
                    ),
                  ),
                  onPressed: busy ? null : onDecline,
                  child: const Text('Decline'),
                ),
                TextButton(
                  key: ValueKey('sidebar-invite-accept-${invite.token}'),
                  style: buttonStyle.copyWith(
                    foregroundColor: WidgetStatePropertyAll(
                      palette.textPrimary,
                    ),
                    backgroundColor: WidgetStatePropertyAll(
                      palette.textPrimary.withValues(alpha: 0.06),
                    ),
                  ),
                  onPressed: busy ? null : onAccept,
                  child: const Text('Accept'),
                ),
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
    this.shortcut,
    this.placeholder = 'Search',
    this.phone = false,
    this.trailing,
    this.field,
  });

  /// A phone's field: a quiet well, the entry to Quick find.
  final bool phone;

  /// A phone's text field in the well in place of the placeholder, for a
  /// page that narrows its own list as you type, as Tasks does. A tap
  /// elsewhere in the well calls [onSearch].
  final Widget? field;

  /// A phone's filter button, beside the well. It stands outside the well's
  /// own tap area, so pressing it never starts a search.
  final Widget? trailing;

  final VoidCallback onSearch;
  final String query;
  final VoidCallback? onClear;

  final ShortcutBinding? shortcut;
  final String placeholder;

  Widget? _end(CalcPalette palette, double extent) {
    final onClear = this.onClear;
    if (query.isNotEmpty && onClear != null) {
      // Inside the field's tap region, so Clear keeps the keyboard up.
      return TextFieldTapRegion(
        child: CompactIconButton(
          tooltip: 'Clear search',
          extent: extent,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: palette.textTertiary,
          onPressed: onClear,
          icon: KapyIcon(
            KapyIcons.cancelRounded,
            size: AppControlMetrics.iconAdornment,
          ),
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
        child: Text(
          shortcut.keycapLabel,
          key: const ValueKey('sidebar-search-shortcut'),
          style: TextStyle(
            fontFamily: AppFonts.mono,
            fontFamilyFallback: AppFonts.monoFallback,
            fontSize: 11,
            height: 14 / 11,
            fontWeight: AppWeight.font(AppWeight.body),
            fontVariations: AppWeight.wght(AppWeight.body),
            color: palette.textTertiary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final searching = query.isNotEmpty;
    final end = _end(palette, phone ? 32 : 20);
    if (!phone) {
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
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: palette.fillRest,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Row(
                  children: [
                    KapyIcon(
                      KapyIcons.searchRounded,
                      size: 14,
                      color: palette.textTertiary,
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

    final trailing = this.trailing;
    final field = this.field;
    final well = MouseRegion(
      cursor: SystemMouseCursors.text,
      child: Container(
        key: const ValueKey('sidebar-search-box'),
        // A phone's well is a 44 pt target, as every touch target is, and
        // grows with the text size rather than cutting the placeholder's
        // letters off.
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
        decoration: BoxDecoration(
          color: palette.fillRest,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Row(
          children: [
            KapyIcon(
              KapyIcons.searchRounded,
              size: 16,
              color: palette.textTertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child:
                  field ??
                  Text(
                    searching ? query : placeholder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
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
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, trailing == null ? 20 : 14, 6),
      child: Row(
        children: [
          Expanded(
            child: field != null
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onSearch,
                    child: well,
                  )
                : Semantics(
                    button: true,
                    label: searching ? 'Search, $query' : placeholder,
                    child: GestureDetector(
                      key: const ValueKey('sidebar-search-field'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onSearch,
                      child: well,
                    ),
                  ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }
}

/// The button beside a phone's search well. It opens the list's filters,
/// and it carries a dot while a filter out of sight narrows the list.
class PhoneFiltersButton extends StatelessWidget {
  const PhoneFiltersButton({
    super.key,
    required this.active,
    required this.onPressed,
    this.tooltip = 'Filters',
  });

  final bool active;
  final VoidCallback onPressed;

  /// What a screen reader and a long press say it does.
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Semantics(
            selected: active,
            child: CompactIconButton(
              tooltip: tooltip,
              extent: 44,
              onPressed: onPressed,
              icon: KapyIcon(
                KapyIcons.filterRounded,
                size: 18,
                color: active ? palette.textPrimary : palette.textSecondary,
              ),
            ),
          ),
          if (active)
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                key: const ValueKey('phone-filters-dot'),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: palette.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// How a [NoteRow] draws its note: the desktop list's row or sticky card
/// beside the spaces rail, a phone's row, or the Folders
/// tab's note in an open folder ([filed]) or in none ([loose]).
enum NoteRowStyle {
  row,
  card,
  phoneCard,
  drawingRow,
  drawingCard,
  touch,
  filed,
  loose,
}

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
    this.ofPickedDay = false,
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
    this.shareGroup,
    this.locked = false,
    this.selecting = false,
    this.checked = false,
    this.onToggleChecked,
    this.onCommandClick,
    this.onPickTo,
    this.pickedActions,
    this.onPickedAction,
    this.style = NoteRowStyle.row,
    this.inset = 0,
    this.clockOnly = false,
    this.laterDay,
    this.engine,
    this.now = DateTime.now,
    this.folders,
  });

  final Note note;
  final NoteRowStyle style;

  /// How far in a [NoteRowStyle.filed] note's icon sits in the folder tree.
  final double inset;

  /// Whether the row sits under a heading that already names its day, so it
  /// gives only the time it was last changed, unless others have it open.
  final bool clockOnly;

  /// The later day the note was given, which the row names in place of when
  /// it was changed, as no heading over it does.
  final DateTime? laterDay;

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

  /// Whether the note is on the day last picked in the page's week: lit as
  /// a hovered row is, and scrolled into view once it opens from there.
  final bool ofPickedDay;

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
  /// the note's own, for every picked note with this one among them, and
  /// what was chosen from it, with the row's context and where a picker it
  /// opens goes.
  final KapyMenu Function(BuildContext context)? pickedActions;
  final Future<void> Function(String value, BuildContext context, Offset at)?
  onPickedAction;

  /// Whether the note is in a shared space, which the row marks so a person
  /// typing knows somebody else can see it.
  final bool shared;

  /// Whoever else has the note open right now. While anybody does, the row
  /// says who in place of when it was last changed.
  final List<Collaborator> collaborators;

  /// Who a phone's row shows the note is shared with, at the end of its last
  /// line. Null leaves the faces off.
  final ShareGroup? shareGroup;

  /// Whether the note limit holds the note read-only.
  final bool locked;

  /// Where Move to folder… files the note. Null leaves it out of the menu.
  final FolderStore? folders;

  @override
  State<NoteRow> createState() => _NoteRowState();
}

class _NoteRowState extends State<NoteRow> {
  bool _hovering = false;

  bool get _openedFromDay => widget.selected && widget.ofPickedDay;

  @override
  void initState() {
    super.initState();
    if (_openedFromDay) _reveal();
  }

  @override
  void didUpdateWidget(NoteRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_openedFromDay && !(oldWidget.selected && oldWidget.ofPickedDay)) {
      _reveal();
    }
  }

  /// Scrolls the list so the row shows, once it is laid out.
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) unawaited(Scrollable.ensureVisible(context));
  });

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

  KapyMenu _menu() {
    if (widget.selecting) {
      return widget.pickedActions?.call(context) ??
          (heading: null, groups: const []);
    }
    // Named only where there is a keyboard to press it on: this same menu
    // opens on a long press on a phone, and a chord nobody there can type is
    // a line of noise beside the thing they came to tap.
    final archiveShortcut = AppPlatform.hasPointer
        ? widget.archiveShortcut
        : null;
    return (
      heading: null,
      groups: [
        [
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
        ],
        [
          if (widget.onTogglePin != null)
            KapyMenuAction(
              value: 'pin',
              label: widget.pinned ? 'Unpin note' : 'Pin note',
              icon: KapyIcons.pinOutlined,
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
              label: widget.shared
                  ? AppPlatform.isMobile
                        ? 'Sharing'
                        : 'Manage sharing'
                  : 'Share note',
              icon: KapyIcons.shareRounded,
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
        ],
        // The ways out of the list end the menu, the one that keeps the note
        // before the one that does not, and only deleting is in the warning
        // colour. The shortcut is named on whichever of them it does:
        // archiving in the list, deleting where the note is already archived
        // or hidden.
        [
          if (widget.onArchive != null)
            KapyMenuAction(
              value: 'archive',
              label: 'Archive note',
              icon: archiveIcon,
              hint: archiveShortcut?.keycapLabel,
            ),
          if (widget.onDelete != null)
            KapyMenuAction(
              value: 'delete',
              label: widget.deleteLabel,
              icon: deleteIcon,
              hint: widget.onArchive == null
                  ? archiveShortcut?.keycapLabel
                  : null,
              destructive: true,
            ),
        ],
      ],
    );
  }

  String _actionKey(String value) => '$value-note-${widget.note.id}';

  /// The menu as a sheet on a phone: what it acts on, the note's title
  /// unless the menu names its own, over every line of it.
  Future<String?> _showTouchActions(BuildContext context, KapyMenu menu) =>
      showModalBottomSheet<String>(
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
                          menu.heading ?? widget.note.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTypeScale.body,
                            fontWeight: AppWeight.font(AppWeight.body),
                            fontVariations: AppWeight.wght(AppWeight.body),
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      for (final action in menu.groups.expand((group) => group))
                        InkWell(
                          key: ValueKey(_actionKey(action.value)),
                          onTap: () =>
                              Navigator.of(sheetContext).pop(action.value),
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

  /// While picking, a menu is the picked notes', and the note it was opened
  /// on is one of them: a right click, a long press or an accessibility
  /// action on a row not picked yet picks it first.
  void _joinPicks() {
    if (widget.selecting && !widget.checked) widget.onToggleChecked?.call();
  }

  /// Right-click on desktop, long-press on touch, or the row's More button.
  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    _joinPicks();
    final menu = _menu();
    if (menu.groups.every((group) => group.isEmpty)) return;

    String? choice;
    if (AppPlatform.isMobile) {
      choice = await _showTouchActions(context, menu);
    } else {
      // A card is narrower than the menu, so beside the rail the menu keeps
      // to the whole list rather than to the note it belongs to.
      final row =
          (Scrollable.maybeOf(this.context)?.context ?? this.context)
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
        items: kapyMenuItems(menu, key: _actionKey),
      );
    }
    await _choose(choice, at: position);
  }

  /// Runs one of the row's menu choices. The menu offers them, and so does the
  /// row itself as accessibility actions, so both go through here.
  Future<void> _choose(String? choice, {Offset? at}) async {
    if (!mounted) return;
    Offset anchor() {
      final box = context.findRenderObject() as RenderBox?;
      return at ??
          (box == null
              ? Offset.zero
              : box.localToGlobal(box.size.bottomRight(Offset.zero)));
    }

    if (widget.selecting) {
      if (choice != null) {
        await widget.onPickedAction?.call(choice, context, anchor());
      }
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
    if (choice == 'tags' && context.mounted) {
      await showTagPickerAt(context, anchor(), [widget.note.id]);
    }
    if (widget.folders case final folders? when choice == 'folder' && mounted) {
      await moveNotesToFolder(context, anchor(), folders, [widget.note.id]);
    }
  }

  /// The desktop list's row or card, with its actions button while the
  /// pointer is over it.
  Widget _boardFace({required String? snippet, required bool hasMenu}) {
    final note = widget.note;
    final people = widget.collaborators;
    final card =
        widget.style == NoteRowStyle.card ||
        widget.style == NoteRowStyle.phoneCard ||
        widget.style == NoteRowStyle.drawingCard;
    String stamp({bool clock = true}) => switch (widget.laterDay) {
      final day? => SidebarTimestamp.briefDay(
        day,
        today: dayShown(widget.now(), widget.displayTime),
      ),
      null => SidebarTimestamp.glance(
        note.updatedAt,
        now: widget.now(),
        displayTime: widget.displayTime,
        today: card,
        clock: clock,
      ),
    };
    final day = card && people.isEmpty && widget.laterDay == null
        ? stamp(clock: false)
        : null;
    final date = people.isNotEmpty
        ? typingStatusText([
                for (final person in people)
                  if (person.typing) person.name,
              ]) ??
              presenceStatusText([for (final person in people) person.name])!
        : widget.clockOnly
        ? SidebarTimestamp.clock(widget.displayTime(note.updatedAt))
        : stamp();
    final glance = NoteGlance.of(note, widget.engine);
    final picking = widget.selecting ? widget.checked : null;
    // While picking, what is lit is what is picked: the open note keeps its
    // highlight only once it is one of them.
    final selected = widget.selected && !widget.selecting;
    final ringed = widget.openElsewhere && !widget.selected;
    final lit = _hovering || widget.ofPickedDay;
    final face = switch (widget.style) {
      NoteRowStyle.phoneCard => PhoneCardFace(
        note: note,
        glance: glance,
        date: date,
        day: day,
        selected: selected,
        locked: widget.locked,
        shared: widget.shared,
        picking: picking,
      ),
      NoteRowStyle.card => NoteCardFace(
        note: note,
        glance: glance,
        date: date,
        day: day,
        snippet: snippet,
        selected: selected,
        hovering: lit,
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
        hovering: lit,
        ringed: ringed,
        locked: widget.locked,
        shared: widget.shared,
        picking: picking,
      ),
      NoteRowStyle.drawingRow => DrawingListRowFace(
        note: note,
        date: date,
        selected: selected,
        hovering: lit,
        ringed: ringed,
        locked: widget.locked,
        shared: widget.shared,
        picking: picking,
      ),
      NoteRowStyle.filed => TreeNoteFace(
        note: note,
        inset: widget.inset,
        selected: widget.selected,
        hovering: lit,
        ringed: ringed,
      ),
      NoteRowStyle.loose => LooseNoteFace(
        note: note,
        date: date,
        selected: widget.selected,
        hovering: lit,
        ringed: ringed,
      ),
      NoteRowStyle.row || NoteRowStyle.touch => NoteListRowFace(
        touch: widget.style == NoteRowStyle.touch,
        note: note,
        glance: glance,
        date: date,
        snippet: snippet,
        people: switch (widget.shareGroup) {
          final group? => _SharePeople(group: group),
          null => null,
        },
        place: switch (widget.folders?.tree.pathOfNote(note.id)) {
          final path? when path.isNotEmpty => [
            for (final folder in path) folder.name,
          ].join(' › '),
          _ => null,
        },
        selected: selected,
        hovering: lit,
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

    final face = _boardFace(
      snippet: snippet,
      hasMenu: hasMenu && !widget.selecting,
    );

    final row = MouseRegion(
      // The row is the main click target in the sidebar; matching the
      // settings rows, which are InkWells and already say so.
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Semantics(
        container: true,
        button: true,
        selected: widget.selecting ? widget.checked : widget.selected,
        // Neither VoiceOver nor TalkBack can right-click or long-press a row
        // to reach its menu, so the menu's choices are actions on the row
        // itself. Same list, and the same pick first, so the two can never
        // drift.
        customSemanticsActions: {
          for (final action in _menu().groups.expand((group) => group))
            CustomSemanticsAction(label: action.label): () {
              _joinPicks();
              unawaited(_choose(action.value));
            },
        },
        child: GestureDetector(
          onTap: _open,
          onSecondaryTapDown: !hasMenu
              ? null
              : (details) => _showContextMenu(context, details.globalPosition),
          onLongPressStart: !hasMenu
              ? null
              : (details) => _showContextMenu(context, details.globalPosition),
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
    );
    if (widget.style == NoteRowStyle.touch && !widget.selecting) {
      final onTogglePin = widget.onTogglePin;
      final onArchive = widget.onArchive;
      return _SwipeActions(
        actions: [
          if (onTogglePin != null)
            (
              key: 'pin',
              label: widget.pinned ? 'Unpin' : 'Pin',
              icon: KapyIcons.pinOutlined,
              background: palette.clay,
              onPressed: onTogglePin,
            ),
          if (onArchive != null)
            (
              key: 'archive',
              label: 'Archive',
              icon: KapyIcons.archiveOutlined,
              background: palette.textSecondary,
              onPressed: onArchive,
            ),
        ],
        id: widget.note.id,
        child: row,
      );
    }
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

/// Who else is in a note, in as few words as the row has room for.
String? presenceStatusText(List<String> names) => switch (names.length) {
  0 => null,
  1 => '${names[0]} is here',
  2 => '${names[0]} and ${names[1]} are here',
  _ => '${names[0]} and ${names.length - 1} others are here',
};

/// The heading over a group of the Shared list: whose notes they are, and
/// their faces at the far end, ringed while they are in one of the notes.
/// The heading opens the page of the person it names in Settings → Sharing,
/// which is where what they can see is changed.
class _ShareGroupHeader extends StatelessWidget {
  const _ShareGroupHeader({
    super.key,
    required this.group,
    required this.title,
    this.present = const {},
    this.attention = false,
    this.onTap,
  });

  /// Null for notes whose people this device cannot name yet.
  final ShareGroup? group;
  final String title;

  /// Everyone in one of its notes right now, by account.
  final Set<String> present;

  /// A member's safety code changed and nobody has looked yet.
  final bool attention;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final brightness = palette.brightness;
    final people = group?.people ?? const <SharePerson>[];
    final heading = Row(
      children: [
        if (attention) ...[
          Tooltip(
            message: "A member's safety code changed",
            child: KapyIcon(
              KapyIcons.warningRounded,
              size: AppControlMetrics.iconInline,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(width: 5),
        ] else if (people.isEmpty) ...[
          KapyIcon(
            KapyIcons.groupOutlined,
            size: AppControlMetrics.iconInline,
            color: palette.textTertiary,
          ),
          const SizedBox(width: 5),
        ],
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              fontWeight: AppWeight.font(AppWeight.body),
              fontVariations: AppWeight.wght(AppWeight.body),
              letterSpacing: 0.3,
              color: palette.textTertiary,
            ),
          ),
        ),
        if (people.isNotEmpty) ...[
          const SizedBox(width: 8),
          AvatarStack(
            keyPrefix: 'share-group-avatar-${group!.key}',
            extent: SpacePeopleAvatars.headingExtent,
            avatars: [
              for (final person in people)
                StackedAvatar(
                  id: person.userId ?? person.email,
                  name: person.name,
                  image: person.image,
                  pending: person.isInvited,
                  highlight: present.contains(person.userId)
                      ? collaboratorColor(person.userId!, on: brightness)
                      : null,
                  tooltip: person.isInvited
                      ? '${person.name}\nInvited'
                      : '${person.name}\n${person.email}',
                ),
            ],
          ),
        ],
      ],
    );
    final here = [
      for (final person in people)
        if (present.contains(person.userId)) person.firstName,
    ];

    return Padding(
      // As much room under it as a section heading has, outside the part a
      // tap lights up.
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 7),
      child: Semantics(
        header: true,
        button: onTap != null,
        onTap: onTap,
        label: [
          title,
          ?presenceStatusText(here),
          if (attention) "A member's safety code changed",
        ].join('. '),
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
              fontSize: 16,
              height: 22 / 16,
              fontWeight: AppWeight.font(AppWeight.button),
              fontVariations: AppWeight.wght(
                AppWeight.button,
                extra: handwritten.fontVariations ?? const [],
              ),
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
                fontWeight: AppWeight.font(AppWeight.body),
                fontVariations: AppWeight.wght(AppWeight.body),
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

  /// The one way back, where a filter left the list empty, or the one way
  /// to start filling it.
  final Widget? action;

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
            action,
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

/// A day's notes on a phone's list, newest day first, under the heading
/// [SidebarTimestamp.phoneDay] gives the day. Days are counted by calendar
/// date, so a change of clocks never moves a note to another day, and a note
/// stamped later than now joins today's. A note given a later day stays out
/// until that day comes.
List<({String? lead, String date, List<Note> notes})> _phoneDays(
  List<Note> notes, {
  required DateTime now,
  required DateTime Function(DateTime) displayTime,
  DateTime? Function(Note note)? ownDay,
}) {
  final today = dayShown(now, displayTime);
  final days = <DateTime, List<Note>>{};
  for (final note in notes) {
    final own = ownDay?.call(note);
    if (waitsForLaterDay(own, today)) continue;
    final day = noteDay(note, displayTime, ownDay: own);
    // An edit from a clock ahead of this one counts as today's.
    (days[day.isAfter(today) ? today : day] ??= []).add(note);
  }
  final order = days.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in order)
      if (SidebarTimestamp.phoneDay(day, now: today) case (
        :final lead,
        :final date,
      ))
        (lead: lead, date: date, notes: days[day]!),
  ];
}

/// Who a shared note on a phone's row is open to: a face for each person,
/// with their initial, and an envelope for anyone who has not joined yet.
class _SharePeople extends StatelessWidget {
  const _SharePeople({required this.group});

  final ShareGroup group;

  static const double _extent = 16;
  static const double _step = _extent - 5;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final people = group.people.take(3).toList();
    return Semantics(
      label: group.title,
      child: ExcludeSemantics(
        child: SizedBox(
          width: _extent + (people.length - 1) * _step,
          height: _extent,
          child: Stack(
            children: [
              for (final (index, person) in people.indexed.toList().reversed)
                Positioned(
                  left: index * _step,
                  child: Container(
                    width: _extent,
                    height: _extent,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: palette.controlBackground,
                      shape: BoxShape.circle,
                      border: Border.all(color: palette.paperColor, width: 1.5),
                    ),
                    child: person.isInvited
                        ? KapyIcon(
                            KapyIcons.mailOutlined,
                            size: 9,
                            color: palette.textMuted,
                          )
                        : Text(
                            (person.name.trim().isEmpty
                                        ? person.email
                                        : person.name.trim())
                                    .characters
                                    .firstOrNull
                                    ?.toUpperCase() ??
                                '?',
                            textScaler: TextScaler.noScaling,
                            style: chromeStyle(
                              size: 9,
                              line: 10,
                              weight: 600,
                              color: palette.textPrimary,
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A day's heading on a phone's list, as Tasks draws its own: "Today" in
/// the serif, then the date 8 after it in small quiet sans. A day with no
/// name is headed by its date alone, in the serif, muted. Folders heads its
/// notes in no folder with it too (M02): the words alone, unmuted.
class _PhoneDayHeading extends StatelessWidget {
  const _PhoneDayHeading({required this.lead, this.date});

  final String? lead;
  final String? date;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final lead = this.lead;
    final date = this.date;
    return Semantics(
      header: true,
      label: [?lead, ?date].join(', '),
      excludeSemantics: true,
      child: lead == null || date == null
          ? Text(
              lead ?? date ?? '',
              key: const ValueKey('phone-day-heading'),
              style: dayTitleStyle(
                lead == null ? palette.textTertiary : palette.textPrimary,
              ),
            )
          : Row(
              key: const ValueKey('phone-day-heading'),
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              spacing: 8,
              children: [
                Text(lead, style: dayTitleStyle(palette.textPrimary)),
                Flexible(
                  child: Text(
                    date,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle(13, 16, palette.textTertiary),
                  ),
                ),
              ],
            ),
    );
  }
}

/// A phone Home's pinned notes: cards in a row that scrolls sideways, two in
/// full on screen and a sliver of the next, saying there is more.
class PhonePinnedCards extends StatelessWidget {
  const PhonePinnedCards({
    super.key,
    required this.margin,
    required this.children,
  });

  /// The list's own margin, which the first card lines up with.
  final double margin;
  final List<Widget> children;

  /// Between two cards, across and down.
  static const double gap = 8;

  /// How much of the third card shows past the second.
  static const double peek = 34;

  /// A card's width in a row [width] wide: two cards and the next one's
  /// sliver after the margin, 160 on a 390 phone.
  static double cardWidth(double width, double margin) =>
      (width - margin - 2 * gap - peek) / 2;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = cardWidth(constraints.maxWidth, margin);
      return SizedBox(
        height: PhoneCardFace.height(context),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: margin),
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(width: gap),
          itemBuilder: (_, index) =>
              SizedBox(width: width, child: children[index]),
        ),
      );
    },
  );
}

/// A heading over a phone's list: Pinned, where it has no View all, and
/// Recent.
class _PhoneHeading extends StatelessWidget {
  const _PhoneHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(
      label,
      style: uiStyle(
        13,
        18,
        FontWeight.w500,
        context.palette.textTertiary,
        axis: 520,
      ),
    ),
  );
}

/// A phone list's title: the space's name large in the hand face, its count
/// small beside it (M02, M03). The clay mark is Home's alone, under the title
/// its swipe has on screen.
class PhoneListTitle extends StatelessWidget {
  const PhoneListTitle({
    super.key,
    required this.title,
    this.count,
    this.onBack,
    this.trailing,
  });

  final String title;

  /// Left out where the page counts nothing, as Folders does.
  final int? count;

  /// Set for a page reached from Home or Folders, such as Shared or
  /// Drawings: its arrow goes back.
  final VoidCallback? onBack;

  /// At the row's end, such as the S that opens Settings.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBack = this.onBack;
    final heading = Semantics(
      header: true,
      label: count == null ? title : '$title, $count',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: Text(
              title,
              key: const ValueKey('phone-list-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: handStyle(26, 32, FontWeight.w600, palette.textPrimary),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: uiStyle(
                13,
                16,
                FontWeight.w400,
                palette.textTertiary,
                tabular: true,
              ),
            ),
          ],
        ],
      ),
    );
    final trailing = this.trailing;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        onBack == null ? 20 : 6,
        12,
        trailing == null ? 20 : 14,
        14,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onBack != null)
            IconButton(
              key: const ValueKey('page-back'),
              tooltip: 'Back',
              onPressed: onBack,
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              padding: EdgeInsets.zero,
              color: palette.textPrimary,
              icon: KapyIcon(KapyIcons.arrowBackRounded, size: 22),
            ),
          Expanded(child: heading),
          if (trailing != null) ...[const SizedBox(width: 6), trailing],
        ],
      ),
    );
  }
}

/// Opens Quick find when the list is pulled down past its top, once per
/// pull: iOS's bounce and Android's stretch alike.
class _PullToFind extends StatefulWidget {
  const _PullToFind({required this.onPulled, required this.child});

  final VoidCallback onPulled;
  final Widget child;

  static const double distance = 72;

  @override
  State<_PullToFind> createState() => _PullToFindState();
}

class _PullToFindState extends State<_PullToFind> {
  double _pull = 0;
  bool _fired = false;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    switch (notification) {
      case ScrollStartNotification():
        _pull = 0;
        _fired = false;
      case OverscrollNotification(:final overscroll, dragDetails: _?)
          when overscroll < 0:
        _pull -= overscroll;
      case ScrollUpdateNotification(:final metrics, dragDetails: _?):
        if (metrics.pixels < metrics.minScrollExtent) {
          _pull = metrics.minScrollExtent - metrics.pixels;
        }
      default:
    }
    if (!_fired && _pull >= _PullToFind.distance) {
      _fired = true;
      widget.onPulled();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      );
}

typedef _SwipeAction = ({
  String key,
  String label,
  KapyIconData icon,
  Color background,
  VoidCallback onPressed,
});

/// A phone row that slides left to show its actions, Pin and Archive,
/// which VoiceOver and TalkBack offer as actions on the row too.
class _SwipeActions extends StatefulWidget {
  const _SwipeActions({
    required this.id,
    required this.actions,
    required this.child,
  });

  final String id;
  final List<_SwipeAction> actions;
  final Widget child;

  static const double actionWidth = 76;

  @override
  State<_SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<_SwipeActions>
    with SingleTickerProviderStateMixin {
  late final _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  double get _extent => widget.actions.length * _SwipeActions.actionWidth;

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  void _settle(double velocity) {
    final open = velocity < -300 || (velocity <= 300 && _open.value > 0.5);
    unawaited(_open.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic));
  }

  void _run(_SwipeAction action) {
    _open.value = 0;
    action.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) return widget.child;
    final palette = context.palette;
    final foreground = palette.paperColor;
    return GestureDetector(
      onHorizontalDragUpdate: (details) =>
          _open.value -= details.primaryDelta! / _extent,
      onHorizontalDragEnd: (details) => _settle(details.primaryVelocity ?? 0),
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final action in widget.actions)
                    SizedBox(
                      width: _SwipeActions.actionWidth,
                      child: Material(
                        color: action.background,
                        child: InkWell(
                          key: ValueKey('swipe-${action.key}-${widget.id}'),
                          onTap: () => _run(action),
                          child: ExcludeSemantics(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              spacing: 4,
                              children: [
                                KapyIcon(
                                  action.icon,
                                  size: 20,
                                  color: foreground,
                                ),
                                Text(
                                  action.label,
                                  style: TextStyle(
                                    fontFamily: AppFonts.ui,
                                    fontSize: 12.5,
                                    fontWeight: AppWeight.font(
                                      AppWeight.button,
                                    ),
                                    fontVariations: AppWeight.wght(
                                      AppWeight.button,
                                    ),
                                    color: foreground,
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
            AnimatedBuilder(
              animation: _open,
              builder: (context, child) => Transform.translate(
                offset: Offset(-_open.value * _extent, 0),
                child: child,
              ),
              child: ListenableBuilder(
                listenable: _open,
                builder: (context, child) => _open.value == 0
                    ? child!
                    : GestureDetector(
                        onTap: () => _settle(1000),
                        behavior: HitTestBehavior.opaque,
                        child: AbsorbPointer(child: child),
                      ),
                child: ColoredBox(
                  color: palette.paperColor,
                  child: widget.child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
