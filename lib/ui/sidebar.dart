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
    this.onShare,
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

  /// Null where sharing is unavailable — no account, or a build without sync.
  /// The row then shows no share affordance at all rather than a dead one.
  final ValueChanged<String>? onShare;
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
                          onShare: onShare == null
                              ? null
                              : () => onShare!(note.id),
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
      padding: const EdgeInsets.only(left: 8),
      alignment: Alignment.centerLeft,
      child: updates == null
          ? FooterSettingsButton(onPressed: onSettingsPressed)
          : ListenableBuilder(
              listenable: updates,
              builder: (context, _) => _UpdateDot(
                visible: updates.hasUpdate,
                child: FooterSettingsButton(
                  onPressed: onSettingsPressed,
                  tooltip: updates.hasUpdate
                      ? 'Settings — update available'
                      : 'Settings',
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
  });

  final Note note;
  final String query;
  final DateTime Function(DateTime) displayTime;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onShare;
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
    final actionsVisible =
        _hovering || widget.selected || !AppPlatform.hasPointer;
    final deleteVisible = widget.onDelete != null && actionsVisible;
    final shareVisible = widget.onShare != null && actionsVisible;

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
                if (widget.onShare != null) ...[
                  const SizedBox(width: 4),
                  _RowAction(
                    key: ValueKey('share-note-${widget.note.id}'),
                    icon: Icons.ios_share_rounded,
                    tooltip: 'Share note',
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
