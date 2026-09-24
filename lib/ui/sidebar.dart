import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
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
import 'editor/note_footer.dart';
import 'editor_panes.dart';
import 'member_avatars.dart';
import 'safety_dialogs.dart';
import 'sidebar_timestamp.dart';
import 'streak_badge.dart';

/// What throwing a note away looks like, everywhere it is offered.
///
/// A bin rather than a filing box. Nothing else in the app removes a note, so
/// the Archive *is* where notes go when you are done with them, and a box that
/// reads as "file this away" sent people looking for a delete that was not
/// there. The archive is still not destruction — [deleteIcon] is — which is
/// why the two are the ordinary bin and the crossed-out one, the pairing every
/// mail client uses for the same two ideas.
const KapyIconData archiveIcon = KapyIcons.deleteOutlined;

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

/// Mobile starts at the notes, with the protected folder one pull above them.
///
/// A scroll position is session state, so every fresh app launch conceals the
/// row again without turning its visibility into a saved preference.
const _mobileNotesCenterKey = ValueKey<String>('sidebar-mobile-notes-start');

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

/// The note list, with search.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.notes,
    this.pinnedNoteIds = const {},
    this.lockedNoteIds = const {},
    required this.selectedId,
    required this.query,
    required this.displayTime,
    required this.onQueryChanged,
    required this.onSelect,
    required this.onCreate,
    this.onMoveSelect,
    this.onEnterSelected,
    this.onOpenToSide,
    this.openElsewhereIds = const {},
    this.onArchive,
    this.onRestore,
    this.onHide,
    this.onUnhide,
    this.onTogglePin,
    this.onArchiveToggle,
    this.onHiddenToggle,
    this.onShare,
    this.sharing,
    this.onSettingsPressed,
    this.searchShortcut,
    this.settingsShortcut,
    this.archiveShortcut,
    this.hiddenShortcut,
    this.updates,
    this.searchFocusNode,
    this.showHeader = true,
    this.archiveMode = false,
    this.hiddenMode = false,
    this.archivedCount = 0,
    this.hiddenCount = 0,
    this.showHiddenFolder = false,
    this.onDelete,
    this.onDeleteAll,
    this.selecting = false,
    this.checkedIds = const {},
    this.onToggleChecked,
    this.onStartSelecting,
    this.onCancelSelecting,
    this.onCheckAll,
    this.onDeleteChecked,
    this.onRestoreChecked,
    this.streak,
    this.collaborators = const {},
    this.onOpenSpace,
    this.tab = SidebarTab.mine,
    this.onTabChanged,
  });

  /// The notes to list, already narrowed to [tab] while the tabs are shown.
  final List<Note> notes;
  final Set<String> pinnedNoteIds;

  /// Notes the note limit holds read-only, marked so the reason is visible
  /// before one is opened.
  final Set<String> lockedNoteIds;
  final String? selectedId;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;

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
  final ValueChanged<String>? onArchive;
  final ValueChanged<String>? onRestore;
  final ValueChanged<String>? onHide;
  final ValueChanged<String>? onUnhide;
  final ValueChanged<String>? onTogglePin;
  final VoidCallback? onArchiveToggle;
  final VoidCallback? onHiddenToggle;

  /// Null where there is nothing to share to: a build without a server.
  /// The row then shows no share affordance rather than one that opens onto
  /// an error.
  final ValueChanged<String>? onShare;

  /// Names the spaces shared notes are in. Null until the account is
  /// unlocked; the list then reads exactly as it did before sharing existed.
  final Sharing? sharing;
  final VoidCallback? onSettingsPressed;
  final ShortcutBinding? searchShortcut;
  final ShortcutBinding? settingsShortcut;

  /// The key that files the open note away, for the row's menu to name.
  ///
  /// Worth the two words it takes: nothing else announces the chord, and a
  /// shortcut nobody can find is a shortcut nobody uses. Read from the
  /// binding rather than written out, so a rebound key is not misnamed here.
  final ShortcutBinding? archiveShortcut;
  final ShortcutBinding? hiddenShortcut;

  /// Drives the Update badge beside the installed version. Null where the app
  /// store owns updates; the version still comes from the installed package.
  final UpdateChecker? updates;
  final FocusNode? searchFocusNode;
  final bool showHeader;
  final bool archiveMode;
  final bool hiddenMode;
  final int archivedCount;
  final int hiddenCount;
  final bool showHiddenFolder;

  /// Throws one note away for good. Only ever supplied in the archive.
  final ValueChanged<String>? onDelete;

  /// Empties the archive.
  final VoidCallback? onDeleteAll;

  /// Whether the list is picking notes rather than opening them.
  final bool selecting;
  final Set<String> checkedIds;
  final ValueChanged<String>? onToggleChecked;
  final VoidCallback? onStartSelecting;
  final VoidCallback? onCancelSelecting;
  final VoidCallback? onCheckAll;
  final VoidCallback? onDeleteChecked;
  final VoidCallback? onRestoreChecked;

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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    // Solid, rather than the GlassSurface the toolbar and footer use: the
    // notes list stays put whatever the window is doing behind it. See
    // [CalcPalette.sidebarColor].
    return ColoredBox(
      color: palette.sidebarColor,
      // Colour runs to the window edges; content stays clear of the status
      // bar, home indicator and any display cutout.
      child: SafeArea(
        top: showHeader,
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader) const _Header(),
            if (_tabbed)
              _SidebarTabs(
                tab: tab,
                invitations: sharing!.invites.length,
                onChanged: onTabChanged!,
              ),
            _SearchField(
              query: query,
              onChanged: onQueryChanged,
              onCreate: onCreate,
              archiveMode: archiveMode,
              hiddenMode: hiddenMode,
              focusNode: searchFocusNode,
              shortcut: searchShortcut,
              belowTabs: _tabbed,
            ),
            if (archiveMode && (notes.isNotEmpty || selecting))
              _ArchiveActions(
                selecting: selecting,
                checkedCount: checkedIds.length,
                total: notes.length,
                onStartSelecting: onStartSelecting,
                onCancelSelecting: onCancelSelecting,
                onCheckAll: onCheckAll,
                onDeleteAll: onDeleteAll,
                onDeleteChecked: onDeleteChecked,
                onRestoreChecked: onRestoreChecked,
              ),
            Expanded(
              child: _BelowInvitations(
                invitations:
                    !_specialMode &&
                        sharing != null &&
                        sharing!.invites.isNotEmpty
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
                  onArchiveSelected: _archiveSelected,
                  onDeleteSelected: _deleteSelected,
                  archiveShortcut: archiveShortcut,
                  child: notes.isEmpty
                      ? _buildEmpty(context)
                      : _grouped
                      ? _buildGrouped(context)
                      : _buildUngrouped(context),
                ),
              ),
            ),
            if (onSettingsPressed != null ||
                onArchiveToggle != null ||
                _showDesktopHiddenEntry)
              _SidebarFooter(
                onSettingsPressed: onSettingsPressed,
                onArchivePressed: onArchiveToggle,
                onHiddenPressed: _showDesktopHiddenEntry
                    ? onHiddenToggle
                    : null,
                showingArchive: archiveMode,
                showingHidden: hiddenMode,
                archivedCount: archivedCount,
                hiddenCount: hiddenCount,
                hiddenShortcut: hiddenShortcut,
                settingsShortcut: settingsShortcut,
                updates: updates,
              ),
          ],
        ),
      ),
    );
  }
}

extension on Sidebar {
  bool get _specialMode => archiveMode || hiddenMode;

  /// The tabs split the ordinary list only. The archive and Hidden Notes
  /// are folders of their own, and a build without an account has nobody
  /// else's notes to show.
  bool get _tabbed => sharing != null && !_specialMode && onTabChanged != null;

  bool get _onSharedTab => _tabbed && tab == SidebarTab.shared;

  /// Hidden Notes are always the person's own, so the way into them sits
  /// over their own notes rather than over other people's.
  bool get _showMobileHiddenEntry =>
      AppPlatform.isMobile && onHiddenToggle != null && !_onSharedTab;

  bool get _showDesktopHiddenEntry =>
      AppPlatform.isDesktop &&
      onHiddenToggle != null &&
      (hiddenMode || (showHiddenFolder && hiddenCount > 0));

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
    final empty = _SidebarEmpty(
      message: query.trim().isEmpty
          ? archiveMode
                ? 'Archived Notes is empty'
                : hiddenMode
                ? 'Hidden Notes is empty'
                : _onSharedTab
                ? 'Nothing shared with you yet'
                : 'No notes yet'
          : 'No matching notes',
      detail: query.trim().isEmpty && _onSharedTab
          ? 'Notes other people share with you appear here'
          : null,
    );
    if (!_showMobileHiddenEntry) return empty;
    return CustomScrollView(
      center: hiddenMode ? null : _mobileNotesCenterKey,
      slivers: [
        _mobileHiddenSliver(),
        SliverFillRemaining(
          key: _mobileNotesCenterKey,
          hasScrollBody: false,
          child: empty,
        ),
      ],
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

    if (!_showMobileHiddenEntry) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        itemCount: notes.length,
        itemBuilder: rowBuilder,
      );
    }
    return CustomScrollView(
      center: hiddenMode ? null : _mobileNotesCenterKey,
      slivers: [
        _mobileHiddenSliver(),
        SliverPadding(
          key: _mobileNotesCenterKey,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              rowBuilder,
              childCount: notes.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _mobileHiddenSliver() => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: SizedBox(
        height: NoteFooter.height,
        child: _HiddenEntry(
          showingHidden: hiddenMode,
          count: hiddenCount,
          onPressed: onHiddenToggle!,
        ),
      ),
    ),
  );

  /// Whether the reader may change [note]: their own always, a shared one
  /// only where the space says so. The row's rule, and the keyboard's.
  bool _mayEdit(Note note) => sharing?.canEdit(note) ?? !note.isShared;

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
  /// list, mirroring the glyph the row itself offers. Null where there is
  /// nothing to file.
  VoidCallback? get _archiveSelected {
    if (_specialMode || selecting || onArchive == null) return null;
    final note = _highlighted;
    if (note == null || !_mayEdit(note)) return null;
    return () => onArchive!(note.id);
  }

  /// Throws it away for good, or throws away every ticked note while the
  /// archive is picking them. The archive only — the list has no permanent
  /// delete to lend a key — and every path through here asks first.
  VoidCallback? get _deleteSelected {
    if (!_specialMode) return null;
    if (selecting) {
      final deleteChecked = onDeleteChecked;
      return checkedIds.isEmpty ? null : deleteChecked;
    }
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
    if (selecting) return;
    final ordered = _grouped ? _noteGroups.displayOrder : notes;
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
  }) => NoteRow(
    key: ValueKey(note.id),
    note: note,
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
    onDelete: !_specialMode || onDelete == null || !_mayEdit(note)
        ? null
        : () => onDelete!(note.id),
    selecting: selecting,
    checked: checkedIds.contains(note.id),
    onToggleChecked: onToggleChecked == null
        ? null
        : () => onToggleChecked!(note.id),
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
            label: hasSharedSections && !_tabbed ? 'My notes' : 'Notes',
            count: summary ? ownCount : null,
            streak: summary ? streak : null,
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

    if (!_showMobileHiddenEntry) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        itemCount: entries.length,
        itemBuilder: entryBuilder,
      );
    }
    return CustomScrollView(
      center: hiddenMode ? null : _mobileNotesCenterKey,
      slivers: [
        _mobileHiddenSliver(),
        SliverPadding(
          key: _mobileNotesCenterKey,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              entryBuilder,
              childCount: entries.length,
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
    required this.onArchiveSelected,
    required this.onDeleteSelected,
    required this.archiveShortcut,
    required this.child,
  });

  /// Walks the highlight by one visible row. Negative is up, positive down.
  final ValueChanged<int> onMoveSelected;

  /// Moves focus from the selected row into its editor.
  final VoidCallback? onEnterSelected;

  /// Files the highlighted note away, exactly as its own glyph does. Null
  /// where nothing in the list can be archived.
  final VoidCallback? onArchiveSelected;

  /// Throws it away for good: the archive only, and behind the confirmation
  /// the button there already asks for.
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

  void _keepFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _node.requestFocus();
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_entersEditor(event)) {
      final enter = widget.onEnterSelected;
      if (enter == null) return KeyEventResult.ignored;
      enter();
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

    // The archive's delete puts a question on screen, and that dialog hands
    // the keyboard back to this list itself once it is answered.
    final delete = widget.onDeleteSelected;
    if (delete != null) {
      delete();
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
        // row it was aimed at.
        onPointerDown: (_) => _node.requestFocus(),
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
            borderRadius: BorderRadius.circular(99),
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

class _SidebarFooter extends StatefulWidget {
  const _SidebarFooter({
    this.onSettingsPressed,
    this.onArchivePressed,
    this.onHiddenPressed,
    required this.showingArchive,
    required this.showingHidden,
    required this.archivedCount,
    required this.hiddenCount,
    this.hiddenShortcut,
    this.settingsShortcut,
    this.updates,
  });

  final VoidCallback? onSettingsPressed;
  final VoidCallback? onArchivePressed;
  final VoidCallback? onHiddenPressed;
  final bool showingArchive;
  final bool showingHidden;
  final int archivedCount;
  final int hiddenCount;
  final ShortcutBinding? hiddenShortcut;
  final ShortcutBinding? settingsShortcut;
  final UpdateChecker? updates;

  @override
  State<_SidebarFooter> createState() => _SidebarFooterState();
}

class _SidebarFooterState extends State<_SidebarFooter> {
  String _standaloneVersion = '';

  @override
  void initState() {
    super.initState();
    widget.updates?.addListener(_changed);
    if (widget.updates == null && !AppPlatform.isFlutterTest) {
      unawaited(_readInstalledVersion());
    }
  }

  @override
  void didUpdateWidget(covariant _SidebarFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updates == widget.updates) return;
    oldWidget.updates?.removeListener(_changed);
    widget.updates?.addListener(_changed);
    if (widget.updates == null &&
        _standaloneVersion.isEmpty &&
        !AppPlatform.isFlutterTest) {
      unawaited(_readInstalledVersion());
    }
  }

  @override
  void dispose() {
    widget.updates?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _readInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _standaloneVersion = info.version);
    } catch (error) {
      debugPrint('KapyNotes: could not show the installed version: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final updates = widget.updates;
    final version = updates?.currentVersion ?? _standaloneVersion;
    // The badge asks the user to go and look. While a download is running,
    // or once it has finished and the title bar offers the restart, there is
    // nothing to go and look at.
    final updateNeedsAttention =
        (updates?.hasUpdate ?? false) &&
        !(updates?.isReadyToInstall ?? false) &&
        !(updates?.isDownloading ?? false);
    final rows =
        (widget.onHiddenPressed == null ? 0 : 1) +
        (widget.onArchivePressed == null ? 0 : 1) +
        (widget.onSettingsPressed == null ? 0 : 1);
    return Container(
      height: AppControlMetrics.scaleBar(context, NoteFooter.height * rows),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
      ),
      child: Column(
        children: [
          if (widget.onHiddenPressed != null)
            Expanded(
              child: _HiddenEntry(
                showingHidden: widget.showingHidden,
                count: widget.hiddenCount,
                onPressed: widget.onHiddenPressed!,
                shortcut: widget.hiddenShortcut,
              ),
            ),
          if (widget.onArchivePressed != null)
            Expanded(
              child: _ArchiveEntry(
                showingArchive: widget.showingArchive,
                count: widget.archivedCount,
                onPressed: widget.onArchivePressed!,
              ),
            ),
          if (widget.onSettingsPressed != null)
            Expanded(
              child: _SettingsEntry(
                key: const ValueKey('sidebar-settings'),
                onPressed: widget.onSettingsPressed!,
                version: version,
                hasUpdate: updateNeedsAttention,
                shortcut: widget.settingsShortcut,
              ),
            ),
        ],
      ),
    );
  }
}

class _HiddenEntry extends StatelessWidget {
  const _HiddenEntry({
    required this.showingHidden,
    required this.count,
    required this.onPressed,
    this.shortcut,
  });

  final bool showingHidden;
  final int count;
  final VoidCallback onPressed;
  final ShortcutBinding? shortcut;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = showingHidden ? 'All notes' : 'Hidden Notes';
    final shortcut = this.shortcut;
    return Tooltip(
      message: shortcut == null ? label : '$label · ${shortcut.displayLabel}',
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          key: ValueKey(
            showingHidden ? 'sidebar-all-notes' : 'sidebar-hidden-notes',
          ),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                KapyIcon(
                  showingHidden ? KapyIcons.notesRounded : hiddenIcon,
                  size: AppControlMetrics.footerIconControl,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
                if (!showingHidden && count > 0) ...[
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: AppTypeScale.small,
                      color: palette.textTertiary,
                    ),
                  ),
                  if (shortcut != null) const SizedBox(width: 8),
                ],
                if (shortcut != null) _FolderShortcutHint(shortcut: shortcut),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderShortcutHint extends StatelessWidget {
  const _FolderShortcutHint({required this.shortcut});

  final ShortcutBinding shortcut;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = shortcut.displayLabel;
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: palette.surfaceBackground.withMultipliedAlpha(0.42),
          border: Border.all(color: palette.controlBorder, width: 0.5),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppPlatform.isWindows ? AppTypeScale.micro : 9.5,
            height: AppPlatform.isWindows ? 1.1 : 1,
            color: palette.textTertiary,
          ),
        ),
      ),
    );
  }
}

/// The strip above the archive: pick some notes, or empty the whole thing.
///
/// Only ever in the archive. The main list has no delete at all — a note
/// leaves it by being archived — so there is nothing here to offer anywhere
/// else, and a bar that appeared over the ordinary notes would be a bar of
/// dangerous buttons over the ones people actually keep.
///
/// Icons rather than words on the right, because the sidebar can be dragged
/// down to 150pt and the count on the left is the part that must stay
/// readable when it is.
class _ArchiveActions extends StatelessWidget {
  const _ArchiveActions({
    required this.selecting,
    required this.checkedCount,
    required this.total,
    this.onStartSelecting,
    this.onCancelSelecting,
    this.onCheckAll,
    this.onDeleteAll,
    this.onDeleteChecked,
    this.onRestoreChecked,
  });

  final bool selecting;
  final int checkedCount;
  final int total;
  final VoidCallback? onStartSelecting;
  final VoidCallback? onCancelSelecting;
  final VoidCallback? onCheckAll;
  final VoidCallback? onDeleteAll;
  final VoidCallback? onDeleteChecked;
  final VoidCallback? onRestoreChecked;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = selecting
        ? checkedCount == 0
              ? 'Select notes'
              : '$checkedCount selected'
        : 'Archived Notes';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                fontWeight: FontWeight.w400,
                color: palette.textSecondary,
              ),
            ),
          ),
          if (selecting) ...[
            if (checkedCount < total)
              _IconButton(
                key: const ValueKey('archive-check-all'),
                icon: KapyIcons.selectAllRounded,
                tooltip: 'Select all',
                onPressed: onCheckAll,
              ),
            _IconButton(
              key: const ValueKey('archive-restore-checked'),
              icon: restoreIcon,
              tooltip: 'Restore selected',
              onPressed: checkedCount == 0 ? null : onRestoreChecked,
            ),
            _IconButton(
              key: const ValueKey('archive-delete-checked'),
              icon: deleteIcon,
              tooltip: 'Delete selected',
              onPressed: checkedCount == 0 ? null : onDeleteChecked,
            ),
            _IconButton(
              key: const ValueKey('archive-cancel-selecting'),
              icon: KapyIcons.closeRounded,
              tooltip: 'Done selecting',
              onPressed: onCancelSelecting,
            ),
          ] else ...[
            _IconButton(
              key: const ValueKey('archive-start-selecting'),
              icon: KapyIcons.checklistRounded,
              tooltip: 'Select notes',
              onPressed: total == 0 ? null : onStartSelecting,
            ),
            _IconButton(
              key: const ValueKey('archive-delete-all'),
              icon: KapyIcons.deleteSweepOutlined,
              tooltip: 'Delete all',
              onPressed: total == 0 ? null : onDeleteAll,
            ),
          ],
        ],
      ),
    );
  }
}

class _ArchiveEntry extends StatelessWidget {
  const _ArchiveEntry({
    required this.showingArchive,
    required this.count,
    required this.onPressed,
  });

  final bool showingArchive;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = showingArchive ? 'All notes' : 'Archived Notes';
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        key: ValueKey(showingArchive ? 'sidebar-all-notes' : 'sidebar-archive'),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              KapyIcon(
                showingArchive ? KapyIcons.notesRounded : archiveIcon,
                size: AppControlMetrics.footerIconControl,
                color: palette.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    color: palette.textSecondary,
                  ),
                ),
              ),
              if (!showingArchive && count > 0)
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: AppTypeScale.small,
                    color: palette.textTertiary,
                  ),
                ),
            ],
          ),
        ),
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
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color: palette.chipCurrency.withValues(alpha: 0.35),
                          width: 0.5,
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
          borderRadius: BorderRadius.circular(8),
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
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected
                      ? palette.controlBorder
                      : palette.controlBorder.withValues(alpha: 0),
                  width: 0.5,
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
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: palette.controlBorder, width: 0.5),
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

class _SearchField extends StatefulWidget {
  const _SearchField({
    required this.query,
    required this.onChanged,
    required this.onCreate,
    required this.archiveMode,
    required this.hiddenMode,
    this.focusNode,
    this.shortcut,
    this.belowTabs = false,
  });

  /// Sits under the tabs rather than the title bar, and needs less room
  /// above it to read as part of the same header.
  final bool belowTabs;

  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onCreate;
  final bool archiveMode;
  final bool hiddenMode;
  final FocusNode? focusNode;
  final ShortcutBinding? shortcut;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.query,
  );

  @override
  void didUpdateWidget(_SearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Creating a note clears the search; reflect that in the field.
    if (widget.query != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Padding(
      // On a desktop the field keeps the sidebar's 12pt gutter, the edge the
      // footer and archive actions hold, and the same room under the title
      // bar. The list's own top padding makes up the gap beneath it.
      padding: AppPlatform.hasPointer
          ? EdgeInsets.fromLTRB(12, widget.belowTabs ? 8 : 12, 12, 8)
          : EdgeInsets.fromLTRB(10, widget.belowTabs ? 8 : 9, 10, 9),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('sidebar-search-field'),
              controller: _controller,
              focusNode: widget.focusNode,
              onChanged: widget.onChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                fontSize: AppTypeScale.control,
                color: palette.textPrimary,
              ),
              cursorHeight: AppTypeScale.control + 2,
              decoration: kapyFieldDecoration(
                context,
                hintText: widget.archiveMode
                    ? 'Search Archived Notes'
                    : widget.hiddenMode
                    ? 'Search Hidden Notes'
                    : 'Search notes',
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
                suffixIcon: widget.query.isEmpty
                    ? AppPlatform.hasPointer && widget.shortcut != null
                          ? _SearchShortcutHint(shortcut: widget.shortcut!)
                          : null
                    : CompactIconButton(
                        tooltip: 'Clear search',
                        extent: AppControlMetrics.fieldAdornmentSlot,
                        foregroundColor: palette.textTertiary,
                        onPressed: () {
                          _controller.clear();
                          widget.onChanged('');
                        },
                        icon: KapyIcon(
                          KapyIcons.cancelRounded,
                          size: AppControlMetrics.iconAdornment,
                        ),
                      ),
                suffixIconConstraints: BoxConstraints(
                  minWidth: AppControlMetrics.fieldAdornmentSlot,
                  minHeight: AppControlMetrics.fieldAdornmentSlot,
                ),
                contentPadding: EdgeInsets.symmetric(
                  vertical: AppControlMetrics.fieldVerticalPadding,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _IconButton(
            key: const ValueKey('sidebar-new-note'),
            icon: KapyIcons.addRounded,
            tooltip: 'New note',
            onPressed: widget.onCreate,
          ),
        ],
      ),
    );
  }
}

class _SearchShortcutHint extends StatelessWidget {
  const _SearchShortcutHint({required this.shortcut});

  final ShortcutBinding shortcut;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = shortcut.displayLabel;
    return Center(
      child: Tooltip(
        message: 'Global search · $label',
        child: Semantics(
          label: 'Global search shortcut $label',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: palette.surfaceBackground.withMultipliedAlpha(0.42),
              border: Border.all(color: palette.controlBorder, width: 0.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: AppPlatform.isWindows ? AppTypeScale.micro : 9.5,
                height: AppPlatform.isWindows ? 1.1 : 1,
                color: palette.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteActionChoice {
  const _NoteActionChoice({
    required this.value,
    required this.label,
    required this.icon,
    this.hint,
    this.destructive = false,
  });

  final String value;
  final String label;
  final KapyIconData icon;
  final String? hint;
  final bool destructive;
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
    this.onShare,
    this.onArchive,
    this.onRestore,
    this.onHide,
    this.onUnhide,
    this.onDelete,
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
  });

  final Note note;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final bool selected;
  final VoidCallback onTap;

  /// Opens the note in a pane beside the focused one: from the menu, with
  /// Option- or Alt-click, and by dragging the row onto the panes.
  final VoidCallback? onOpenToSide;

  /// Whether the note is already open in a pane other than the focused one.
  final bool openElsewhere;
  final VoidCallback? onShare;
  final VoidCallback? onArchive;
  final VoidCallback? onRestore;
  final VoidCallback? onHide;
  final VoidCallback? onUnhide;

  /// Throws the note away for good. Only ever offered inside the archive:
  /// everywhere else the way out of the list is [onArchive], which keeps it.
  final VoidCallback? onDelete;
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
  final VoidCallback? onToggleChecked;

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

  /// A click opens the note where the focus is. Option- or Alt-click opens it
  /// beside that instead, the way a code editor's file list does.
  void _open() {
    if (_canOpenToSide && HardwareKeyboard.instance.isAltPressed) {
      widget.onOpenToSide!();
      return;
    }
    widget.onTap();
  }

  List<_NoteActionChoice> _availableActions() {
    // Named only where there is a keyboard to press it on: this same menu
    // opens on a long press on a phone, and a chord nobody there can type is
    // a line of noise beside the thing they came to tap.
    final archiveShortcut = AppPlatform.hasPointer
        ? widget.archiveShortcut
        : null;
    return [
      if (_canOpenToSide)
        _NoteActionChoice(
          value: 'open-side',
          label: 'Open to the side',
          icon: KapyIcons.viewColumnOutlined,
          hint: AppPlatform.isMacOS ? 'Option + Click' : 'Alt + Click',
        ),
      if (widget.onTogglePin != null)
        _NoteActionChoice(
          value: 'pin',
          label: widget.pinned ? 'Unpin note' : 'Pin note',
          icon: widget.pinned ? KapyIcons.pinRounded : KapyIcons.pinOutlined,
        ),
      if (widget.onShare != null)
        _NoteActionChoice(
          value: 'share',
          label: widget.shared ? 'Manage sharing' : 'Share note',
          icon: KapyIcons.peopleOutlined,
        ),
      if (widget.onHide != null)
        const _NoteActionChoice(
          value: 'hide',
          label: 'Move to Hidden Notes',
          icon: hiddenIcon,
        ),
      if (widget.onDelete != null)
        _NoteActionChoice(
          value: 'delete',
          label: 'Delete permanently',
          icon: deleteIcon,
          hint: archiveShortcut?.displayLabel,
          destructive: true,
        ),
      if (widget.onRestore != null)
        const _NoteActionChoice(
          value: 'restore',
          label: 'Restore note',
          icon: restoreIcon,
        ),
      if (widget.onUnhide != null)
        const _NoteActionChoice(
          value: 'unhide',
          label: 'Move to Notes',
          icon: unhideIcon,
        ),
      // Filing a note away is the destructive end of the ordinary note menu:
      // keep it last, after the protected-folder alternative, and use the
      // same warning colour as the permanent action in Archived Notes.
      if (widget.onArchive != null)
        _NoteActionChoice(
          value: 'archive',
          label: 'Archive note',
          icon: archiveIcon,
          hint: archiveShortcut?.displayLabel,
          destructive: true,
        ),
    ];
  }

  String _actionKey(String value) => '$value-note-${widget.note.id}';

  Widget _actionContents(
    BuildContext context,
    _NoteActionChoice action, {
    required bool touch,
  }) {
    final palette = context.palette;
    final foreground = action.destructive
        ? Theme.of(context).colorScheme.error
        : palette.textPrimary;
    return Row(
      children: [
        KapyIcon(
          action.icon,
          size: touch
              ? AppControlMetrics.iconAction
              : AppControlMetrics.iconControl,
          color: action.destructive ? foreground : palette.textSecondary,
        ),
        SizedBox(width: touch ? 14 : 10),
        Expanded(
          child: Text(
            action.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: touch ? AppTypeScale.body : AppTypeScale.control,
              color: foreground,
            ),
          ),
        ),
        if (action.hint case final hint?) ...[
          SizedBox(width: touch ? 18 : 10),
          Text(
            hint,
            maxLines: 1,
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: palette.textTertiary,
            ),
          ),
        ],
      ],
    );
  }

  Future<String?> _showTouchActions(
    BuildContext context,
    List<_NoteActionChoice> actions,
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
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
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
                        child: _actionContents(
                          sheetContext,
                          action,
                          touch: true,
                        ),
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
    final actions = _availableActions();
    if (actions.isEmpty) return;

    String? choice;
    if (AppPlatform.isMobile) {
      choice = await _showTouchActions(context, actions);
    } else {
      final row = this.context.findRenderObject() as RenderBox?;
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
              child: _actionContents(context, action, touch: false),
            ),
        ],
      );
    }
    if (!mounted) return;
    if (choice == 'archive') widget.onArchive?.call();
    if (choice == 'restore') widget.onRestore?.call();
    if (choice == 'hide') widget.onHide?.call();
    if (choice == 'unhide') widget.onUnhide?.call();
    if (choice == 'delete') widget.onDelete?.call();
    if (choice == 'share') widget.onShare?.call();
    if (choice == 'pin') widget.onTogglePin?.call();
    if (choice == 'open-side') widget.onOpenToSide?.call();
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
    final hasMenu =
        !widget.selecting &&
        (widget.onTogglePin != null ||
            _canOpenToSide ||
            widget.onArchive != null ||
            widget.onRestore != null ||
            widget.onHide != null ||
            widget.onUnhide != null ||
            widget.onDelete != null ||
            widget.onShare != null);

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        // The row is the main click target in the sidebar; matching the
        // settings rows, which are InkWells and already say so.
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Semantics(
          container: true,
          button: true,
          selected: widget.selected,
          child: GestureDetector(
            onTap: widget.selecting
                ? (widget.onToggleChecked ?? widget.onTap)
                : _open,
            onSecondaryTapDown: !hasMenu
                ? null
                : (details) =>
                      _showContextMenu(context, details.globalPosition),
            onLongPressStart: !hasMenu
                ? null
                : (details) =>
                      _showContextMenu(context, details.globalPosition),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: widget.selected || (widget.selecting && widget.checked)
                    ? palette.selectedBackground
                    : (_hovering ? palette.hover : Colors.transparent),
                borderRadius: BorderRadius.circular(7),
              ),
              // Open in another pane: ringed rather than filled, so it reads
              // as on screen without competing with the focused note's row.
              // Painted over the row rather than around it, so nothing moves.
              foregroundDecoration: widget.openElsewhere && !widget.selected
                  ? BoxDecoration(
                      border: Border.all(color: palette.selectedBorder),
                      borderRadius: BorderRadius.circular(7),
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
            borderRadius: BorderRadius.circular(7),
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

class _SidebarEmpty extends StatelessWidget {
  const _SidebarEmpty({required this.message, this.detail});

  final String message;

  /// A quieter line under [message], saying what will fill the space.
  final String? detail;

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
