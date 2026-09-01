import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/window_chrome.dart';
import '../data/note.dart';
import 'app_logo.dart';
import 'editor/note_footer.dart';
import 'glass_surface.dart';

/// The note list, with search.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.notes,
    required this.selectedId,
    required this.query,
    required this.onQueryChanged,
    required this.onSelect,
    required this.onCreate,
    this.onDelete,
    this.onSettingsPressed,
    this.searchFocusNode,
    this.showHeader = true,
  });

  final List<Note> notes;
  final String? selectedId;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onSettingsPressed;
  final FocusNode? searchFocusNode;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GlassSurface(
      color: palette.sidebarBackground,
      blur: 30,
      // Colour runs to the window edges; content stays clear of the status
      // bar, home indicator and any display cutout.
      child: SafeArea(
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
                      itemExtent: 60,
                      itemBuilder: (context, index) {
                        final note = notes[index];
                        return NoteRow(
                          note: note,
                          query: query,
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
              _SidebarFooter(onSettingsPressed: onSettingsPressed!),
          ],
        ),
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({required this.onSettingsPressed});

  final VoidCallback onSettingsPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: NoteFooter.height,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
      ),
      padding: const EdgeInsets.only(left: 8),
      alignment: Alignment.centerLeft,
      child: FooterSettingsButton(onPressed: onSettingsPressed),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    // The sidebar owns the window's top-left corner, where macOS draws the
    // traffic lights. It is tall enough to simply start below them.
    final topInset = 11 + WindowChrome.topInset(atWindowLeftEdge: true);

    return Padding(
      padding: EdgeInsets.fromLTRB(14, topInset, 10, 9),
      child: Row(
        children: [
          const Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: AppWordmark(markSize: 20, fontSize: 15.5, spacing: 7),
            ),
          ),
          _IconButton(
            icon: Icons.add_rounded,
            tooltip: 'New note',
            onPressed: onCreate,
          ),
        ],
      ),
    );
  }
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
        style: TextStyle(fontSize: 13, color: palette.textPrimary),
        cursorHeight: 15,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search notes',
          hintStyle: TextStyle(fontSize: 13, color: palette.textTertiary),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 15,
            color: palette.textTertiary,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 28,
          ),
          suffixIcon: widget.query.isEmpty
              ? null
              : GestureDetector(
                  onTap: () {
                    _controller.clear();
                    widget.onChanged('');
                  },
                  child: Icon(
                    Icons.cancel_rounded,
                    size: 14,
                    color: palette.textTertiary,
                  ),
                ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 28,
            minHeight: 28,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          filled: true,
          fillColor: palette.controlBackground,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
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
    required this.selected,
    required this.onTap,
    this.onDelete,
  });

  final Note note;
  final String query;
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
              Icon(Icons.delete_outline_rounded, size: 16, color: error),
              const SizedBox(width: 10),
              Text('Delete Note', style: TextStyle(fontSize: 13, color: error)),
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
    // usual preview, so the reason for the hit is visible.
    final snippet = widget.query.trim().isEmpty
        ? null
        : widget.note.matchSnippet(widget.query.trim());
    final subtitle = snippet ?? widget.note.preview;

    final foreground = palette.textPrimary;
    final secondary = palette.textSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: widget.selected
                  ? palette.selectedBackground
                  : (_hovering ? palette.hover : Colors.transparent),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: secondary),
                ),
              ],
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
        style: TextStyle(fontSize: 12.5, color: context.palette.textTertiary),
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
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        color: context.palette.textSecondary,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
