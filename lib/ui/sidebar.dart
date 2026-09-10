import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/note.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import '../sync/sharing.dart';
import 'app_logo.dart';
import 'compact_icon_button.dart';
import 'editor/note_footer.dart';
import 'sidebar_timestamp.dart';

/// The note list, with search.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.notes,
    this.pinnedNoteIds = const {},
    required this.selectedId,
    required this.query,
    required this.displayTime,
    required this.onQueryChanged,
    required this.onSelect,
    required this.onCreate,
    this.onArchive,
    this.onRestore,
    this.onTogglePin,
    this.onArchiveToggle,
    this.onShare,
    this.sharing,
    this.onSettingsPressed,
    this.settingsShortcut,
    this.updates,
    this.searchFocusNode,
    this.showHeader = true,
    this.archiveMode = false,
    this.archivedCount = 0,
  });

  final List<Note> notes;
  final Set<String> pinnedNoteIds;
  final String? selectedId;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<String>? onArchive;
  final ValueChanged<String>? onRestore;
  final ValueChanged<String>? onTogglePin;
  final VoidCallback? onArchiveToggle;

  /// Null where there is nothing to share to: a build without a server.
  /// The row then shows no share affordance rather than one that opens onto
  /// an error.
  final ValueChanged<String>? onShare;

  /// Names the spaces shared notes are in. Null until the account is
  /// unlocked; the list then reads exactly as it did before sharing existed.
  final Sharing? sharing;
  final VoidCallback? onSettingsPressed;
  final ShortcutBinding? settingsShortcut;

  /// Drives the Update badge beside the installed version. Null where the app
  /// store owns updates; the version still comes from the installed package.
  final UpdateChecker? updates;
  final FocusNode? searchFocusNode;
  final bool showHeader;
  final bool archiveMode;
  final int archivedCount;

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
              focusNode: searchFocusNode,
            ),
            Expanded(
              child: notes.isEmpty
                  ? _SidebarEmpty(
                      message: query.trim().isEmpty
                          ? archiveMode
                                ? 'Archive is empty'
                                : 'No notes yet'
                          : 'No matching notes',
                    )
                  : _grouped
                  ? _buildGrouped(context)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                      itemCount: notes.length,
                      itemExtent: AppControlMetrics.sidebarNoteRowExtent,
                      itemBuilder: (context, index) =>
                          _row(notes[index], shared: false),
                    ),
            ),
            if (onSettingsPressed != null || onArchiveToggle != null)
              _SidebarFooter(
                onSettingsPressed: onSettingsPressed,
                onArchivePressed: onArchiveToggle,
                showingArchive: archiveMode,
                archivedCount: archivedCount,
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
  bool get _hasPinned =>
      !archiveMode && notes.any((note) => pinnedNoteIds.contains(note.id));

  /// Sections appear once there is something meaningful to group. An
  /// ordinary list with no pins or shared notes stays exactly as quiet as it
  /// was before either feature existed.
  bool get _grouped =>
      _hasPinned || (sharing != null && notes.any((note) => note.isShared));

  Widget _row(Note note, {required bool shared, bool pinned = false}) =>
      NoteRow(
        key: ValueKey(note.id),
        note: note,
        query: query,
        displayTime: displayTime,
        selected: note.id == selectedId,
        shared: shared,
        pinned: pinned,
        onTap: () => onSelect(note.id),
        onTogglePin: onTogglePin == null ? null : () => onTogglePin!(note.id),
        onShare: archiveMode || onShare == null
            ? null
            : () => onShare!(note.id),
        onArchive:
            archiveMode ||
                onArchive == null ||
                !(sharing?.canEdit(note) ?? !note.isShared)
            ? null
            : () => onArchive!(note.id),
        onRestore:
            !archiveMode ||
                onRestore == null ||
                !(sharing?.canEdit(note) ?? !note.isShared)
            ? null
            : () => onRestore!(note.id),
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      children: [
        if (pinned.isNotEmpty) ...[
          const _SectionLabel(label: 'Pinned', icon: Icons.push_pin_outlined),
          for (final note in pinned)
            SizedBox(
              height: extent,
              child: _row(
                note,
                shared: hasSharedSections && note.isShared,
                pinned: true,
              ),
            ),
        ],
        for (final id in order) ...[
          _SectionLabel(
            label: sharing?.spaceById(id)?.displayName ?? 'Shared',
            shared: true,
            attention:
                id != null &&
                (sharing?.trust.warningsFor(id).isNotEmpty ?? false),
          ),
          for (final note in bySpace[id]!)
            SizedBox(height: extent, child: _row(note, shared: true)),
        ],
        if (mine.isNotEmpty) ...[
          _SectionLabel(label: hasSharedSections ? 'My notes' : 'Notes'),
          for (final note in mine)
            SizedBox(height: extent, child: _row(note, shared: false)),
        ],
      ],
    );
  }
}

/// A heading over a group of notes. Small and quiet: the notes are the
/// content, this only says whose they are.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.label,
    this.icon,
    this.shared = false,
    this.attention = false,
  });

  final String label;
  final IconData? icon;
  final bool shared;

  /// A member's key changed and nobody has looked yet.
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          if (icon != null || shared) ...[
            Icon(
              attention
                  ? Icons.warning_amber_rounded
                  : icon ?? Icons.people_outline_rounded,
              size: AppControlMetrics.iconInline,
              color: attention ? error : palette.textTertiary,
            ),
            const SizedBox(width: 5),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypeScale.caption,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
                color: palette.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarFooter extends StatefulWidget {
  const _SidebarFooter({
    this.onSettingsPressed,
    this.onArchivePressed,
    required this.showingArchive,
    required this.archivedCount,
    this.settingsShortcut,
    this.updates,
  });

  final VoidCallback? onSettingsPressed;
  final VoidCallback? onArchivePressed;
  final bool showingArchive;
  final int archivedCount;
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
        (widget.onArchivePressed == null ? 0 : 1) +
        (widget.onSettingsPressed == null ? 0 : 1);
    return Container(
      height: AppControlMetrics.scaleBar(context, NoteFooter.height * rows),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
      ),
      child: Column(
        children: [
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
    final label = showingArchive ? 'All notes' : 'Archive';
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
              Icon(
                showingArchive ? Icons.notes_rounded : Icons.archive_outlined,
                size: AppControlMetrics.footerIconControl,
                color: palette.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
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
                  Icon(
                    Icons.settings_outlined,
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
                        fontWeight: FontWeight.w500,
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
                          fontWeight: FontWeight.w500,
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
    this.focusNode,
  });

  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onCreate;
  final bool archiveMode;
  final FocusNode? focusNode;

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
              controller: _controller,
              focusNode: widget.focusNode,
              onChanged: widget.onChanged,
              style: TextStyle(
                fontSize: AppTypeScale.control,
                color: palette.textPrimary,
              ),
              cursorHeight: AppTypeScale.control + 2,
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.archiveMode
                    ? 'Search archive'
                    : 'Search notes',
                hintStyle: TextStyle(
                  fontSize: AppTypeScale.control,
                  color: palette.textTertiary,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: AppControlMetrics.iconAdornment,
                  color: palette.textTertiary,
                ),
                prefixIconConstraints: BoxConstraints(
                  minWidth: AppControlMetrics.fieldAdornmentSlot + 2,
                  minHeight: AppControlMetrics.fieldAdornmentSlot,
                ),
                suffixIcon: widget.query.isEmpty
                    ? null
                    : CompactIconButton(
                        tooltip: 'Clear search',
                        extent: AppControlMetrics.fieldAdornmentSlot,
                        foregroundColor: palette.textTertiary,
                        onPressed: () {
                          _controller.clear();
                          widget.onChanged('');
                        },
                        icon: Icon(
                          Icons.cancel_rounded,
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
            icon: Icons.add_rounded,
            tooltip: 'New note',
            onPressed: widget.onCreate,
          ),
        ],
      ),
    );
  }
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
    this.onShare,
    this.onArchive,
    this.onRestore,
    this.onTogglePin,
    this.pinned = false,
    this.shared = false,
  });

  final Note note;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onShare;
  final VoidCallback? onArchive;
  final VoidCallback? onRestore;
  final VoidCallback? onTogglePin;
  final bool pinned;

  /// Whether the note is in a shared space, which the row marks so a person
  /// typing knows somebody else can see it.
  final bool shared;

  @override
  State<NoteRow> createState() => _NoteRowState();
}

class _NoteRowState extends State<NoteRow> {
  bool _hovering = false;

  /// Right-click on desktop, long-press on touch.
  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final palette = context.palette;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (widget.onTogglePin != null)
          PopupMenuItem(
            value: 'pin',
            height: 36,
            child: Row(
              children: [
                Icon(
                  widget.pinned
                      ? Icons.push_pin_rounded
                      : Icons.push_pin_outlined,
                  size: AppControlMetrics.iconControl,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  widget.pinned ? 'Unpin Note' : 'Pin Note',
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    color: palette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        if (widget.onShare != null)
          PopupMenuItem(
            value: 'share',
            height: 36,
            child: Row(
              children: [
                Icon(
                  Icons.people_outline_rounded,
                  size: AppControlMetrics.iconControl,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  widget.shared ? 'Sharing…' : 'Share…',
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    color: palette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        if (widget.onArchive != null)
          PopupMenuItem(
            value: 'archive',
            height: 36,
            child: Row(
              children: [
                Icon(
                  Icons.archive_outlined,
                  size: AppControlMetrics.iconControl,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  'Archive Note',
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    color: palette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        if (widget.onRestore != null)
          PopupMenuItem(
            value: 'restore',
            height: 36,
            child: Row(
              children: [
                Icon(
                  Icons.unarchive_outlined,
                  size: AppControlMetrics.iconControl,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  'Restore Note',
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    color: palette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (choice == 'archive') widget.onArchive?.call();
    if (choice == 'restore') widget.onRestore?.call();
    if (choice == 'share') widget.onShare?.call();
    if (choice == 'pin') widget.onTogglePin?.call();
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
    final actionsVisible =
        _hovering || widget.selected || !AppPlatform.hasPointer;
    final lifecycleVisible =
        (widget.onArchive != null || widget.onRestore != null) &&
        actionsVisible;
    final pinVisible = widget.pinned || actionsVisible;
    final hasMenu =
        widget.onTogglePin != null ||
        widget.onArchive != null ||
        widget.onRestore != null ||
        widget.onShare != null;

    return Padding(
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
            onTap: widget.onTap,
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
                color: widget.selected
                    ? palette.selectedBackground
                    : (_hovering ? palette.hover : Colors.transparent),
                borderRadius: BorderRadius.circular(7),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // At the minimum resizable desktop width, keep the new primary
                  // organization action and leave share/archive in the context
                  // menu instead of reducing every title to a few characters.
                  final showSecondaryActions = constraints.maxWidth >= 190;
                  return Row(
                    children: [
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
                                fontWeight: FontWeight.w500,
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
                              ),
                          ],
                        ),
                      ),
                      if (widget.onTogglePin != null) ...[
                        const SizedBox(width: 4),
                        _RowAction(
                          key: ValueKey('pin-note-${widget.note.id}'),
                          icon: widget.pinned
                              ? Icons.push_pin_rounded
                              : Icons.push_pin_outlined,
                          tooltip: widget.pinned ? 'Unpin note' : 'Pin note',
                          visible: pinVisible,
                          onPressed: widget.onTogglePin!,
                        ),
                      ],
                      if (showSecondaryActions &&
                          (widget.onArchive != null ||
                              widget.onRestore != null)) ...[
                        const SizedBox(width: 4),
                        _RowAction(
                          key: ValueKey(
                            '${widget.onRestore != null ? 'restore' : 'archive'}-note-${widget.note.id}',
                          ),
                          icon: widget.onRestore != null
                              ? Icons.unarchive_outlined
                              : Icons.archive_outlined,
                          tooltip: widget.onRestore != null
                              ? 'Restore note'
                              : 'Archive note',
                          visible: lifecycleVisible,
                          onPressed: widget.onRestore ?? widget.onArchive!,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A trailing action on a note row.
///
/// Hidden by opacity rather than by being absent, so revealing it on hover
/// cannot shift the title beside it — a row that reflows under the pointer is
/// a row that is hard to click. [IgnorePointer] keeps the invisible state from
/// being clickable anyway.
class _RowAction extends StatelessWidget {
  const _RowAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.visible,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: visible ? 1 : 0,
      child: CompactIconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: AppControlMetrics.iconAdornment),
        foregroundColor: context.palette.textTertiary,
      ),
    ),
  );
}

class _UpdatedAtMetadata extends StatelessWidget {
  const _UpdatedAtMetadata({
    required this.updatedAt,
    required this.displayTime,
    this.shared = false,
  });

  final DateTime updatedAt;
  final DateTime Function(DateTime) displayTime;
  final bool shared;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final timestamp = SidebarTimestamp.format(
      updatedAt,
      displayTime: displayTime,
    );
    return Semantics(
      label: shared ? 'Shared, updated $timestamp' : 'Updated $timestamp',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Icon(
              shared ? Icons.people_outline_rounded : Icons.schedule_rounded,
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

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CompactIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: AppControlMetrics.iconAction),
      foregroundColor: context.palette.textSecondary,
    );
  }
}
