import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/note.dart';
import '../data/update_checker.dart';
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
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                      itemCount: notes.length,
                      itemExtent: AppControlMetrics.sidebarNoteRowExtent,
                      itemBuilder: (context, index) {
                        final note = notes[index];
                        return NoteRow(
                          key: ValueKey(note.id),
                          note: note,
                          query: query,
                          displayTime: displayTime,
                          selected: note.id == selectedId,
                          onTap: () => onSelect(note.id),
                          onDelete: onDelete == null
                              ? null
                              : () => onDelete!(note.id),
                        );
                      },
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
    this.onDelete,
  });

  final Note note;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

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

    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
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
    final deleteVisible =
        widget.onDelete != null &&
        (_hovering || widget.selected || !AppPlatform.hasPointer);

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
          onSecondaryTapDown: widget.onDelete == null
              ? null
              : (details) => _showContextMenu(context, details.globalPosition),
          onLongPressStart: widget.onDelete == null
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
                        ),
                    ],
                  ),
                ),
                if (widget.onDelete != null) ...[
                  const SizedBox(width: 4),
                  _DeleteNoteButton(
                    noteId: widget.note.id,
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

class _DeleteNoteButton extends StatelessWidget {
  const _DeleteNoteButton({
    required this.noteId,
    required this.visible,
    required this.onPressed,
  });

  final String noteId;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: visible ? 1 : 0,
      child: CompactIconButton(
        key: ValueKey('delete-note-$noteId'),
        tooltip: 'Delete note',
        onPressed: onPressed,
        icon: Icon(
          Icons.delete_outline_rounded,
          size: AppControlMetrics.iconAdornment,
        ),
        foregroundColor: context.palette.textTertiary,
      ),
    ),
  );
}

class _UpdatedAtMetadata extends StatelessWidget {
  const _UpdatedAtMetadata({
    required this.updatedAt,
    required this.displayTime,
  });

  final DateTime updatedAt;
  final DateTime Function(DateTime) displayTime;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final timestamp = SidebarTimestamp.format(
      updatedAt,
      displayTime: displayTime,
    );
    return Semantics(
      label: 'Updated $timestamp',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Icon(
              Icons.schedule_rounded,
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
