import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/note.dart';
import '../data/update_checker.dart';
import '../sync/sharing.dart';
import 'app_logo.dart';
import 'compact_icon_button.dart';
import 'editor/note_footer.dart';
import 'glass_surface.dart';
import 'sidebar_timestamp.dart';

/// The note list, with search.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.notes,
    required this.selectedId,
    required this.query,
    required this.displayTime,
    required this.onQueryChanged,
    required this.onSelect,
    required this.onCreate,
    this.onDelete,
    this.onShare,
    this.sharing,
    this.onSettingsPressed,
    this.updates,
    this.searchFocusNode,
    this.showHeader = true,
  });

  final List<Note> notes;
  final String? selectedId;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<String>? onDelete;

  /// Null where there is nothing to share to: a build without a server.
  /// The row then shows no share affordance rather than one that opens onto
  /// an error.
  final ValueChanged<String>? onShare;

  /// Names the spaces shared notes are in. Null until the account is
  /// unlocked; the list then reads exactly as it did before sharing existed.
  final Sharing? sharing;
  final VoidCallback? onSettingsPressed;

  /// Drives the dot on the settings gear. Null where the app cannot update
  /// itself, which is also where the dot would never have anything to say.
  final UpdateChecker? updates;
  final FocusNode? searchFocusNode;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GlassSurface(
      color: palette.sidebarBackground.withValues(alpha: 0.96),
      blur: 10,
      // Colour runs to the window edges; content stays clear of the status
      // bar, home indicator and any display cutout.
      child: SafeArea(
        top: showHeader,
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader) _Header(onCreate: onCreate),
            _SearchField(
              query: query,
              onChanged: onQueryChanged,
              focusNode: searchFocusNode,
            ),
            Expanded(
              child: notes.isEmpty
                  ? _SidebarEmpty(
                      message: query.trim().isEmpty
                          ? 'No notes yet'
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
            if (onSettingsPressed != null)
              _SidebarFooter(
                onSettingsPressed: onSettingsPressed!,
                updates: updates,
              ),
          ],
        ),
      ),
    );
  }
}

extension on Sidebar {
  /// Sections appear only once a shared note exists, so a list of private
  /// notes looks exactly as it always has.
  bool get _grouped => sharing != null && notes.any((note) => note.isShared);

  Widget _row(Note note, {required bool shared}) => NoteRow(
    key: ValueKey(note.id),
    note: note,
    query: query,
    displayTime: displayTime,
    selected: note.id == selectedId,
    shared: shared,
    onTap: () => onSelect(note.id),
    onShare: onShare == null ? null : () => onShare!(note.id),
    onDelete: onDelete == null ? null : () => onDelete!(note.id),
  );

  /// Your own notes first, then one section per shared space, in the order
  /// the spaces were made. A note whose space this device has not heard of
  /// yet sits under "Shared", rather than nowhere.
  Widget _buildGrouped(BuildContext context) {
    final sharing = this.sharing!;
    final mine = notes.where((note) => !note.isShared).toList();
    final bySpace = <String?, List<Note>>{};
    for (final note in notes) {
      if (note.isShared) bySpace.putIfAbsent(note.spaceId, () => []).add(note);
    }
    final order = <String?>[
      for (final space in sharing.teams)
        if (bySpace.containsKey(space.id)) space.id,
      for (final id in bySpace.keys)
        if (!sharing.teams.any((space) => space.id == id)) id,
    ];
    final extent = AppControlMetrics.sidebarNoteRowExtent;

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      children: [
        if (mine.isNotEmpty) ...[
          const _SectionLabel(label: 'My notes'),
          for (final note in mine)
            SizedBox(height: extent, child: _row(note, shared: false)),
        ],
        for (final id in order) ...[
          _SectionLabel(
            label: sharing.spaceById(id)?.displayName ?? 'Shared',
            shared: true,
            attention: id != null && sharing.trust.warningsFor(id).isNotEmpty,
          ),
          for (final note in bySpace[id]!)
            SizedBox(height: extent, child: _row(note, shared: true)),
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
    this.shared = false,
    this.attention = false,
  });

  final String label;
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
          if (shared) ...[
            Icon(
              attention
                  ? Icons.warning_amber_rounded
                  : Icons.people_outline_rounded,
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
                fontWeight: FontWeight.w600,
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

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({required this.onSettingsPressed, this.updates});

  final VoidCallback onSettingsPressed;
  final UpdateChecker? updates;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final updates = this.updates;
    return Container(
      height: AppControlMetrics.scaleBar(context, NoteFooter.height),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
      ),
      child: updates == null
          ? _SettingsEntry(
              key: const ValueKey('sidebar-settings'),
              onPressed: onSettingsPressed,
            )
          : ListenableBuilder(
              listenable: updates,
              builder: (context, _) => _SettingsEntry(
                key: const ValueKey('sidebar-settings'),
                onPressed: onSettingsPressed,
                hasUpdate: updates.hasUpdate,
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
    this.hasUpdate = false,
  });

  final VoidCallback onPressed;
  final bool hasUpdate;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
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
                _UpdateDot(
                  visible: hasUpdate,
                  child: Icon(
                    Icons.settings_outlined,
                    size: AppControlMetrics.iconControl,
                    color: palette.textSecondary,
                  ),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The entire announcement outside the settings pane: a 6px dot on the gear.
///
/// It is painted over the button rather than beside it, so nothing in the
/// footer moves when an update appears, and it ignores pointers so the gear
/// keeps the whole hit target.
class _UpdateDot extends StatelessWidget {
  const _UpdateDot({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!visible) return child;
    final palette = context.palette;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: 3,
          right: 3,
          child: IgnorePointer(
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: palette.chipCurrency,
                shape: BoxShape.circle,
                // A hairline of the sidebar behind it keeps the dot legible
                // where it overlaps the gear's own strokes.
                border: Border.all(color: palette.sidebarBackground, width: 1),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: AppControlMetrics.scaleBar(
      context,
      AppControlMetrics.toolbarHeight,
    ),
    child: Stack(
      alignment: Alignment.center,
      children: [
        AppWordmark(
          markSize: AppControlMetrics.wordmarkMark,
          fontSize: AppTypeScale.wordmark,
          spacing: 6.5,
        ),
        Positioned(
          right: 10,
          child: _IconButton(
            icon: Icons.add_rounded,
            tooltip: 'New note',
            onPressed: onCreate,
          ),
        ),
      ],
    ),
  );
}

class _SearchField extends StatefulWidget {
  const _SearchField({
    required this.query,
    required this.onChanged,
    this.focusNode,
  });

  final String query;
  final ValueChanged<String> onChanged;
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
          hintText: 'Search notes',
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
              // Inside a text field, so without a cursor of its own it would
              // inherit the field's I-beam and read as more text.
              : MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      _controller.clear();
                      widget.onChanged('');
                    },
                    child: Icon(
                      Icons.cancel_rounded,
                      size: AppControlMetrics.iconAdornment,
                      color: palette.textTertiary,
                    ),
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
            borderSide: BorderSide(color: palette.controlBorder, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: palette.controlBorder, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: palette.selectedBorder, width: 0.75),
          ),
        ),
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
    this.onDelete,
    this.shared = false,
  });

  final Note note;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;

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
    final error = Theme.of(context).colorScheme.error;
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
        PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Row(
            children: [
              Icon(
                Icons.delete_outline_rounded,
                size: AppControlMetrics.iconControl,
                color: error,
              ),
              const SizedBox(width: 10),
              Text(
                'Delete Note',
                style: TextStyle(fontSize: AppTypeScale.control, color: error),
              ),
            ],
          ),
        ),
      ],
    );
    if (choice == 'delete') widget.onDelete?.call();
    if (choice == 'share') widget.onShare?.call();
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
    final deleteVisible = widget.onDelete != null && actionsVisible;
    final shareVisible = widget.onShare != null && actionsVisible;
    final hasMenu = widget.onDelete != null || widget.onShare != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        // The row is the main click target in the sidebar; matching the
        // settings rows, which are InkWells and already say so.
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapDown: !hasMenu
              ? null
              : (details) => _showContextMenu(context, details.globalPosition),
          onLongPressStart: !hasMenu
              ? null
              : (details) => _showContextMenu(context, details.globalPosition),
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
            child: Row(
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
                          fontWeight: widget.selected
                              ? FontWeight.w600
                              : FontWeight.w500,
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
                if (widget.onShare != null) ...[
                  const SizedBox(width: 4),
                  _RowAction(
                    key: ValueKey('share-note-${widget.note.id}'),
                    icon: Icons.people_outline_rounded,
                    tooltip: widget.shared ? 'Sharing' : 'Share',
                    visible: shareVisible,
                    onPressed: widget.onShare!,
                  ),
                ],
                if (widget.onDelete != null) ...[
                  const SizedBox(width: 4),
                  _RowAction(
                    key: ValueKey('delete-note-${widget.note.id}'),
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Delete note',
                    visible: deleteVisible,
                    onPressed: widget.onDelete!,
                  ),
                ],
              ],
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
