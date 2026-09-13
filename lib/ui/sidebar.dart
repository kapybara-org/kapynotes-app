import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/note.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import '../data/writing_streak.dart';
import '../sync/presence.dart';
import '../sync/sharing.dart';
import '../sync/spaces.dart';
import 'app_logo.dart';
import 'collaborator_colors.dart';
import 'compact_icon_button.dart';
import 'context_menu.dart';
import 'editor/note_footer.dart';
import 'editor_panes.dart';
import 'member_avatars.dart';
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
  });

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
            _SearchField(
              query: query,
              onChanged: onQueryChanged,
              onCreate: onCreate,
              archiveMode: archiveMode,
              hiddenMode: hiddenMode,
              focusNode: searchFocusNode,
              shortcut: searchShortcut,
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
              child: _NoteListKeys(
                onArchiveSelected: _archiveSelected,
                onDeleteSelected: _deleteSelected,
                child: notes.isEmpty
                    ? _buildEmpty(context)
                    : _grouped
                    ? _buildGrouped(context)
                    : _buildUngrouped(context),
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

  bool get _showMobileHiddenEntry =>
      AppPlatform.isMobile && onHiddenToggle != null;

  bool get _showDesktopHiddenEntry =>
      AppPlatform.isDesktop &&
      onHiddenToggle != null &&
      (showHiddenFolder || hiddenMode);

  bool get _hasPinned =>
      !_specialMode && notes.any((note) => pinnedNoteIds.contains(note.id));

  /// Sections appear once there is something meaningful to group, and over the
  /// whole list, whose heading is where the count of notes and the streak
  /// live. A search or the archive with no pins or shared notes in it stays
  /// exactly as quiet as the list was before any of these existed.
  bool get _grouped =>
      _hasPinned ||
      _summarised ||
      (sharing != null && notes.any((note) => note.isShared));

  /// Whether the heading over the person's own notes counts them and carries
  /// the streak: over the whole list only. A search result is not the
  /// library, and the archive is where notes go once they are done with.
  bool get _summarised => !_specialMode && query.trim().isEmpty;

  Widget _buildEmpty(BuildContext context) {
    final empty = _SidebarEmpty(
      message: query.trim().isEmpty
          ? archiveMode
                ? 'Archived Notes is empty'
                : hiddenMode
                ? 'Hidden Notes is empty'
                : 'No notes yet'
          : 'No matching notes',
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
    Widget rowBuilder(BuildContext context, int index) => SizedBox(
      height: AppControlMetrics.sidebarNoteRowExtent,
      child: _row(notes[index], shared: false),
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

  /// Files the highlighted note away: what Delete does in the list, mirroring
  /// the glyph the row itself offers. Null where there is nothing to file.
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
  Widget _buildGrouped(BuildContext context) {
    final pinned = archiveMode
        ? const <Note>[]
        : notes.where((note) => pinnedNoteIds.contains(note.id)).toList();
    final pinnedIds = pinned.map((note) => note.id).toSet();
    final remaining = notes
        .where((note) => !pinnedIds.contains(note.id))
        .toList();
    final hasSharedSections =
        sharing != null && notes.any((note) => note.isShared);
    final mine = hasSharedSections
        ? remaining.where((note) => !note.isShared).toList()
        : remaining;
    final bySpace = <String?, List<Note>>{};
    if (hasSharedSections) {
      for (final note in remaining) {
        if (note.isShared) {
          bySpace.putIfAbsent(note.spaceId, () => []).add(note);
        }
      }
    }
    final order = <String?>[
      if (sharing != null)
        for (final space in sharing!.teams)
          if (bySpace.containsKey(space.id)) space.id,
      for (final id in bySpace.keys)
        if (sharing == null || !sharing!.teams.any((space) => space.id == id))
          id,
    ];
    final extent = AppControlMetrics.sidebarNoteRowExtent;
    // Pinned ones included: the number is how many notes are theirs, not how
    // many happen to sit under the heading.
    final ownCount = hasSharedSections
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
            shared: hasSharedSections && note.isShared,
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
            label: hasSharedSections ? 'My notes' : 'Notes',
            count: summary ? ownCount : null,
            streak: summary ? streak : null,
          ),
        ),
        for (final note in mine) _GroupedNote(note, shared: false),
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
/// the same Delete has to go on deleting a character while somebody is
/// typing: the only thing that tells the two apart is where the keyboard is
/// pointed. Pressing anywhere in the list points it here — which is what
/// makes "click a note, then press Delete" work — and the search field above
/// is outside this subtree, so it keeps its own Delete untouched.
///
/// Left out on touch, which has no Delete key and would only lose its
/// on-screen keyboard to this.
class _NoteListKeys extends StatefulWidget {
  const _NoteListKeys({
    required this.onArchiveSelected,
    required this.onDeleteSelected,
    required this.child,
  });

  /// Files the highlighted note away, exactly as its own glyph does. Null
  /// where nothing in the list can be archived.
  final VoidCallback? onArchiveSelected;

  /// Throws it away for good: the archive only, and behind the confirmation
  /// the button there already asks for.
  final VoidCallback? onDeleteSelected;

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

  /// Whether [event] is the press a list of things is expected to answer by
  /// removing the one it has picked.
  ///
  /// macOS takes a row out of a list with Cmd+Delete and Windows with Delete
  /// on its own; with the list holding the keyboard rather than a text field
  /// the bare key cannot mean anything else on either, so both arrive here.
  /// Shift comes through because Windows spells "and do not keep it" that
  /// way, and a row offers one destructive action at a time, so there is
  /// nothing for it to choose between. Option is left alone — it is nobody's
  /// delete, and may be somebody's shortcut.
  ///
  /// Only the press, never the repeat: a key held down must not empty the
  /// list.
  static bool _removes(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.delete &&
        event.logicalKey != LogicalKeyboardKey.backspace) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed) return false;
    return AppPlatform.isMacOS
        ? !keyboard.isControlPressed
        : !keyboard.isMetaPressed;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
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
    // wrong when the press came from here: the next Delete would edit that
    // note instead of archiving it. Asking for the keyboard back afterwards
    // is answered after that, post-frame callbacks running in the order they
    // were asked for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _node.requestFocus();
    });
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
                hasUpdate: updates?.hasUpdate ?? false,
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
            fontSize: 9.5,
            height: 1,
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
                          fontSize: 10,
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

class _SearchField extends StatefulWidget {
  const _SearchField({
    required this.query,
    required this.onChanged,
    required this.onCreate,
    required this.archiveMode,
    required this.hiddenMode,
    this.focusNode,
    this.shortcut,
  });

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
      padding: const EdgeInsets.fromLTRB(10, 1, 10, 9),
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
              decoration: InputDecoration(
                isDense: true,
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
                filled: true,
                fillColor: palette.controlBackground,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: palette.controlBorder,
                    width: 0.5,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: palette.controlBorder,
                    width: 0.5,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: palette.selectedBorder,
                    width: 0.75,
                  ),
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
                fontSize: 9.5,
                height: 1,
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
      if (widget.onArchive != null)
        _NoteActionChoice(
          value: 'archive',
          label: 'Archive note',
          icon: archiveIcon,
          hint: archiveShortcut?.displayLabel,
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
    this.locked = false,
  });

  final DateTime updatedAt;
  final DateTime Function(DateTime) displayTime;
  final bool shared;
  final List<Collaborator> collaborators;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (collaborators.isNotEmpty) return _presence(context);
    final timestamp = SidebarTimestamp.format(
      updatedAt,
      displayTime: displayTime,
    );
    final what = [if (locked) 'Read-only', if (shared) 'Shared'];
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
                  : shared
                  ? KapyIcons.peopleOutlined
                  : KapyIcons.scheduleRounded,
              size: AppControlMetrics.iconInline,
              color: palette.textTertiary,
            ),
            const SizedBox(width: 4),
            Expanded(
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
  const _SidebarEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: AppTypeScale.body,
          color: context.palette.textTertiary,
        ),
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
