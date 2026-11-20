import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/folders.dart';
import '../data/note.dart';
import 'compact_icon_button.dart';
import 'context_menu.dart';
import 'notes_list.dart' show NotesGroupHeading;
import 'tag_ui.dart' show PopoverAtPoint, TagPopover, notesCount;

TextStyle _figtree(double size, double line, FontWeight weight, Color color) =>
    TextStyle(
      fontSize: size,
      height: line / size,
      leadingDistribution: TextLeadingDistribution.even,
      fontWeight: weight,
      color: color,
    );

/// Where a tree row at [depth] starts: 8 in, and 16 more a level.
double _indent(int depth) => 8 + (depth - 1) * 16.0;

/// What a refused folder action says.
String _refusalText(FolderRefusal refusal) => switch (refusal) {
  FolderRefusal.emptyName => 'Give the folder a name',
  FolderRefusal.longName => 'Use up to $folderNameMax characters',
  FolderRefusal.nameTaken => 'A folder here already has that name',
  FolderRefusal.tooDeep => 'Folders go at most $folderDepthMax levels deep',
  FolderRefusal.intoItself => 'A folder can’t go inside itself',
  FolderRefusal.gone => 'That folder was deleted',
  FolderRefusal.full =>
    'Folders are full. Take some notes out of folders to file more.',
};

/// One line of the folder tree.
sealed class FolderTreeLine {
  const FolderTreeLine();
}

/// A folder, with how many notes are inside it at any depth.
final class FolderLine extends FolderTreeLine {
  const FolderLine(
    this.folder, {
    required this.count,
    required this.open,
    required this.empty,
  });

  final Folder folder;
  final int count;
  final bool open;

  /// Whether it holds no folder and no note, so there is nothing to open.
  final bool empty;
}

/// A note inside an open folder, a level deeper than its folder.
final class NoteLine extends FolderTreeLine {
  const NoteLine(this.note, {required this.depth});

  final Note note;
  final int depth;
}

/// The Folders tab's lines in the order it shows them: the folders by name,
/// and inside each open one its own folders, then its notes in [notes]'
/// order. The notes in no folder come after the tree. A folder's count takes
/// in its folders' notes too, and drawings are never listed or counted.
({List<FolderTreeLine> tree, List<Note> loose}) folderLines(
  FolderTree tree,
  Iterable<Note> notes,
  Set<String> open,
) {
  final inside = <String?, List<Note>>{};
  final counts = <String, int>{};
  for (final note in notes) {
    if (note.isDrawing) continue;
    final folderId = tree.folderOf(note.id);
    (inside[folderId] ??= []).add(note);
    var at = folderId;
    while (at != null) {
      counts.update(at, (count) => count + 1, ifAbsent: () => 1);
      at = tree.byId(at)?.parentId;
    }
  }
  final lines = <FolderTreeLine>[];
  void add(Folder folder) {
    final folders = tree.childrenOf(folder.id);
    final notes = inside[folder.id] ?? const <Note>[];
    final shown = open.contains(folder.id);
    lines.add(
      FolderLine(
        folder,
        count: counts[folder.id] ?? 0,
        open: shown,
        empty: folders.isEmpty && notes.isEmpty,
      ),
    );
    if (!shown) return;
    folders.forEach(add);
    for (final note in notes) {
      lines.add(NoteLine(note, depth: folder.depth + 1));
    }
  }

  tree.top.forEach(add);
  return (tree: lines, loose: inside[null] ?? const []);
}

/// The Notes | Folders switch at the foot of the Notes list beside the rail.
class NotesFoldersSwitch extends StatelessWidget {
  const NotesFoldersSwitch({
    super.key,
    required this.folders,
    required this.onChanged,
  });

  final bool folders;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget segment(bool forFolders) {
      final on = forFolders == folders;
      final colour = on ? palette.tonalForeground : palette.textSecondary;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          child: MouseRegion(
            cursor: on ? MouseCursor.defer : SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey(
                forFolders ? 'notes-switch-folders' : 'notes-switch-notes',
              ),
              behavior: HitTestBehavior.opaque,
              onTap: on ? null : () => onChanged(forFolders),
              child: Container(
                decoration: on
                    ? BoxDecoration(
                        color: palette.tonalBackground,
                        borderRadius: BorderRadius.circular(8),
                      )
                    : null,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    KapyIcon(
                      forFolders
                          ? KapyIcons.folderOutlined
                          : KapyIcons.noteOutlined,
                      size: 16,
                      strokeWidth: 1.8,
                      color: colour,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      forFolders ? 'Folders' : 'Notes',
                      style: _figtree(13, 16, FontWeight.w500, colour),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColoredBox(
            color: palette.separator,
            child: SizedBox(height: AppHairline.of(context)),
          ),
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('notes-folders-switch'),
            height: AppControlMetrics.scaleBar(context, 40),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: palette.cardBackground,
              border: Border.all(color: palette.controlBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [segment(false), segment(true)],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Folders tab beside the rail: the folder tree with the notes of each
/// open folder, New folder, then Not in a folder.
class FoldersTab extends StatefulWidget {
  const FoldersTab({
    super.key,
    required this.store,
    required this.notes,
    required this.open,
    required this.onOpen,
    required this.noteRow,
  });

  final FolderStore store;

  /// The notes it files: the person's own, before any filter narrows them.
  final List<Note> notes;

  /// The folders shown open.
  final Set<String> open;
  final void Function(String folderId, bool open) onOpen;

  /// A note's row: in an open folder, indented to [depth], or under Not in
  /// a folder with a null [depth].
  final Widget Function(Note note, int? depth) noteRow;

  @override
  State<FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends State<FoldersTab> {
  /// The folder whose name is a field.
  String? _renaming;

  /// Whether a new folder is being named, in [_namingIn], null being the top.
  bool _naming = false;
  String? _namingIn;

  FolderStore get _store => widget.store;

  void _stopNaming() => setState(() {
    _renaming = null;
    _naming = false;
    _namingIn = null;
  });

  void _newFolder([String? parentId]) {
    if (parentId != null) widget.onOpen(parentId, true);
    setState(() {
      _renaming = null;
      _naming = true;
      _namingIn = parentId;
    });
  }

  FolderRefusal? _submit(String name) {
    final renaming = _renaming;
    final refusal = renaming != null
        ? _store.rename(renaming, name)
        : _store.checkCreate(name, parentId: _namingIn);
    if (refusal != null) return refusal;
    if (renaming == null) _store.create(name, parentId: _namingIn);
    _stopNaming();
    return null;
  }

  Future<void> _showMenu(Offset position, Folder folder) async {
    const actions = [
      KapyMenuAction(
        value: 'rename',
        label: 'Rename',
        icon: KapyIcons.editOutlined,
      ),
      KapyMenuAction(
        value: 'new',
        label: 'New folder inside',
        icon: KapyIcons.folderAddOutlined,
      ),
      KapyMenuAction(
        value: 'move',
        label: 'Move to…',
        icon: KapyIcons.folderMoveOutlined,
      ),
      KapyMenuAction(
        value: 'delete',
        label: 'Delete folder…',
        icon: KapyIcons.deleteOutlined,
        destructive: true,
      ),
    ];
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: position,
      items: [
        for (final action in actions)
          PopupMenuItem(
            key: ValueKey('${action.value}-folder-${folder.id}'),
            value: action.value,
            height: 36,
            child: KapyMenuActionRow(action, touch: false),
          ),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        setState(() {
          _naming = false;
          _renaming = folder.id;
        });
      case 'new':
        _newFolder(folder.id);
      case 'move':
        await _moveFolder(context, position, _store, folder);
      case 'delete':
        await _delete(folder);
    }
  }

  /// Asks once, deletes, and offers Undo, which puts the folder back with
  /// whatever is still in it. Nothing in it is deleted: it moves up a level.
  Future<void> _delete(Folder folder) {
    final tree = _store.tree;
    final notes = tree.notesIn(widget.notes, folder.id).length;
    final folders = tree.childrenOf(folder.id).length;
    final into = _placeName(tree, folder.parentId);
    final what = [
      if (notes > 0) notesCount(notes),
      if (folders > 0) folders == 1 ? '1 folder' : '$folders folders',
    ];
    final content = switch ((notes, folders)) {
      (0, 0) => 'It’s empty.',
      (1, 0) => 'Its note moves to $into.',
      (0, 1) => 'Its folder moves to $into.',
      _ => 'Its ${what.join(' and ')} move to $into.',
    };
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete “${folder.name}”?'),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('folder-delete-confirm'),
            onPressed: () {
              _store.delete(folder.id);
              Toast.show(
                context,
                'Deleted “${folder.name}”',
                action: 'Undo',
                onAction: () => _store.restore(folder.id),
              );
              Navigator.of(context).pop();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: _store, builder: (context, _) => _list());

  Widget _list() {
    final (:tree, :loose) = folderLines(_store.tree, widget.notes, widget.open);
    final rows = <WidgetBuilder>[];
    void add(WidgetBuilder build, {double gap = 2}) {
      if (rows.isNotEmpty) rows.add((_) => SizedBox(height: gap));
      rows.add(
        (context) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: build(context),
        ),
      );
    }

    Widget field(int depth, [String initial = '']) => _FolderNameField(
      depth: depth,
      initial: initial,
      onSubmit: _submit,
      onCancel: _stopNaming,
    );

    for (final line in tree) {
      switch (line) {
        case FolderLine(:final folder):
          add(
            (_) => folder.id == _renaming
                ? field(folder.depth, folder.name)
                : _FolderRow(
                    key: ValueKey('folder-${folder.id}'),
                    line: line,
                    onToggle: () => widget.onOpen(folder.id, !line.open),
                    onMenu: (position) =>
                        unawaited(_showMenu(position, folder)),
                  ),
          );
          if (_naming && _namingIn == folder.id) {
            add((_) => field(folder.depth + 1));
          }
        case NoteLine(:final note, :final depth):
          add((_) => widget.noteRow(note, depth));
      }
    }
    add(
      (_) => _naming && _namingIn == null
          ? field(1)
          : _NewFolderRow(onTap: _newFolder),
    );
    if (loose.isNotEmpty) {
      add(
        (_) => NotesGroupHeading(
          key: const ValueKey('folders-loose-heading'),
          label: 'Not in a folder',
          detail: '${loose.length}',
        ),
        gap: 24,
      );
      for (final (index, note) in loose.indexed) {
        add((_) => widget.noteRow(note, null), gap: index == 0 ? 8 : 2);
      }
    }
    return ListView.builder(
      key: const ValueKey('folders-tab'),
      padding: const EdgeInsets.only(top: 4, bottom: 40),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index](context),
    );
  }
}

/// A folder in the tree: the chevron that opens it, its icon and name, and
/// how many notes are inside, which gives way to its actions under the
/// pointer. Right-click opens the same actions.
class _FolderRow extends StatefulWidget {
  const _FolderRow({
    super.key,
    required this.line,
    required this.onToggle,
    required this.onMenu,
  });

  final FolderLine line;
  final VoidCallback onToggle;
  final ValueChanged<Offset> onMenu;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final line = widget.line;
    final folder = line.folder;
    return MouseRegion(
      cursor: line.empty ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Semantics(
        button: !line.empty,
        expanded: line.empty ? null : line.open,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: line.empty ? null : widget.onToggle,
          onSecondaryTapUp: (details) => widget.onMenu(details.globalPosition),
          child: Container(
            height: AppControlMetrics.scaleBar(context, 32),
            padding: EdgeInsets.only(
              left: _indent(folder.depth),
              right: _hovering ? 4 : 8,
            ),
            decoration: BoxDecoration(
              color: _hovering ? palette.hover : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 12,
                  child: line.empty
                      ? null
                      : KapyIcon(
                          line.open
                              ? KapyIcons.chevronDownRounded
                              : KapyIcons.chevronRightRounded,
                          size: 12,
                          strokeWidth: 2,
                          color: palette.textTertiary,
                        ),
                ),
                const SizedBox(width: 8),
                KapyIcon(
                  KapyIcons.folderOutlined,
                  size: 16,
                  strokeWidth: 1.8,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _figtree(
                      13,
                      16,
                      FontWeight.w400,
                      palette.textSecondary,
                    ),
                  ),
                ),
                if (_hovering)
                  Builder(
                    builder: (button) => CompactIconButton(
                      key: ValueKey('folder-actions-${folder.id}'),
                      tooltip: 'Folder actions',
                      foregroundColor: palette.textTertiary,
                      onPressed: () {
                        final box = button.findRenderObject() as RenderBox?;
                        widget.onMenu(
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
                  )
                else if (line.count > 0) ...[
                  const SizedBox(width: 8),
                  Semantics(
                    label: notesCount(line.count),
                    child: ExcludeSemantics(
                      child: Text(
                        '${line.count}',
                        style:
                            _figtree(
                              12,
                              16,
                              FontWeight.w500,
                              palette.textTertiary,
                            ).copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                      ),
                    ),
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

/// New folder, under the tree.
class _NewFolderRow extends StatefulWidget {
  const _NewFolderRow({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_NewFolderRow> createState() => _NewFolderRowState();
}

class _NewFolderRowState extends State<_NewFolderRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Semantics(
        button: true,
        child: GestureDetector(
          key: const ValueKey('folders-new'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: AppControlMetrics.scaleBar(context, 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovering ? palette.hover : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                KapyIcon(
                  KapyIcons.addRounded,
                  size: 16,
                  strokeWidth: 1.8,
                  color: palette.textTertiary,
                ),
                const SizedBox(width: 8),
                Text(
                  'New folder',
                  style: _figtree(
                    13,
                    16,
                    FontWeight.w400,
                    palette.textTertiary,
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

/// A folder's name as a field, in place of its row or of New folder: ↵
/// keeps it, esc or a click elsewhere leaves it, and a refused name says why
/// under it.
class _FolderNameField extends StatefulWidget {
  const _FolderNameField({
    required this.depth,
    this.initial = '',
    required this.onSubmit,
    required this.onCancel,
  });

  final int depth;
  final String initial;
  final FolderRefusal? Function(String name) onSubmit;
  final VoidCallback onCancel;

  @override
  State<_FolderNameField> createState() => _FolderNameFieldState();
}

class _FolderNameFieldState extends State<_FolderNameField> {
  late final _name = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  FolderRefusal? _refusal;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final error = Theme.of(context).colorScheme.error;
    final refusal = _refusal;
    final start = _indent(widget.depth) + 12 + 8;
    return TapRegion(
      onTapOutside: (_) => widget.onCancel(),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
        },
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: AppControlMetrics.scaleBar(context, 32),
                padding: EdgeInsets.only(left: start, right: 8),
                decoration: BoxDecoration(
                  color: palette.wellBackground,
                  border: Border.all(
                    color: refusal == null ? palette.selectedBorder : error,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    KapyIcon(
                      KapyIcons.folderOutlined,
                      size: 16,
                      strokeWidth: 1.8,
                      color: palette.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('folder-name-field'),
                        controller: _name,
                        autofocus: true,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(folderNameMax),
                        ],
                        onChanged: (_) {
                          if (_refusal != null) setState(() => _refusal = null);
                        },
                        onEditingComplete: () {},
                        onSubmitted: (name) {
                          final refusal = widget.onSubmit(name);
                          if (refusal != null) {
                            setState(() => _refusal = refusal);
                          }
                        },
                        style: _figtree(
                          13,
                          16,
                          FontWeight.w400,
                          palette.textPrimary,
                        ),
                        decoration: InputDecoration.collapsed(
                          hintText: 'Folder name',
                          hintStyle: _figtree(
                            13,
                            16,
                            FontWeight.w400,
                            palette.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (refusal != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(start, 4, 8, 2),
                  child: Text(
                    _refusalText(refusal),
                    key: const ValueKey('folder-name-refused'),
                    style: _figtree(12, 16, FontWeight.w400, error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A note inside an open folder: its icon and title on a 32 row, a level
/// deeper than its folder. The open note's row is raised, with a firmer
/// title.
class TreeNoteFace extends StatelessWidget {
  const TreeNoteFace({
    super.key,
    required this.note,
    required this.depth,
    required this.selected,
    required this.hovering,
    this.ringed = false,
  });

  final Note note;
  final int depth;
  final bool selected;
  final bool hovering;
  final bool ringed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colour = selected ? palette.textPrimary : palette.textSecondary;
    return Container(
      height: AppControlMetrics.scaleBar(context, 32),
      padding: EdgeInsets.only(left: _indent(depth) + 12 + 8, right: 8),
      decoration: BoxDecoration(
        color: selected
            ? palette.selectedBackground
            : hovering
            ? palette.hover
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      foregroundDecoration: ringed
          ? BoxDecoration(
              border: Border.all(color: palette.selectedBorder),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Row(
        children: [
          KapyIcon(
            KapyIcons.noteOutlined,
            size: 16,
            strokeWidth: 1.8,
            color: colour,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _figtree(
                13,
                16,
                selected ? FontWeight.w500 : FontWeight.w400,
                colour,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A note in no folder, under the tree: its title over when it was last
/// edited, on a 48 row.
class LooseNoteFace extends StatelessWidget {
  const LooseNoteFace({
    super.key,
    required this.note,
    required this.date,
    required this.selected,
    required this.hovering,
    this.ringed = false,
  });

  final Note note;
  final String date;
  final bool selected;
  final bool hovering;
  final bool ringed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: AppControlMetrics.scaleBar(context, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: selected
            ? palette.selectedBackground
            : hovering
            ? palette.hover
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      foregroundDecoration: ringed
          ? BoxDecoration(
              border: Border.all(color: palette.selectedBorder),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            note.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _figtree(13, 16, FontWeight.w500, palette.textPrimary),
          ),
          Text(
            date,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _figtree(12, 16, FontWeight.w400, palette.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// Move to folder… on a note's menu: files the note where the list picks,
/// and says where, with an Undo that puts it back.
Future<void> moveNoteToFolder(
  BuildContext context,
  Offset position,
  FolderStore store,
  String noteId,
) async {
  final from = store.tree.folderOf(noteId);
  final picked = await _pickFolderAt(
    context,
    position,
    store: store,
    current: from,
    check: (folderId) => store.checkFile([noteId], folderId),
  );
  if (picked == null || picked.folderId == from) return;
  final refusal = store.file([noteId], picked.folderId);
  if (!context.mounted) return;
  if (refusal != null) {
    Toast.show(context, _refusalText(refusal), isError: true);
    return;
  }
  Toast.show(
    context,
    'Moved to ${_placeName(store.tree, picked.folderId)}',
    action: 'Undo',
    onAction: () => store.file([noteId], from),
  );
}

/// Move to… on a folder's menu: moves it with everything in it, and says
/// where, with an Undo that puts it back.
Future<void> _moveFolder(
  BuildContext context,
  Offset position,
  FolderStore store,
  Folder folder,
) async {
  final from = folder.parentId;
  final picked = await _pickFolderAt(
    context,
    position,
    store: store,
    current: from,
    moving: folder.id,
    check: (parentId) => store.checkMove(folder.id, parentId: parentId),
  );
  if (picked == null || picked.folderId == from) return;
  final refusal = store.move(folder.id, parentId: picked.folderId);
  if (!context.mounted) return;
  if (refusal != null) {
    Toast.show(context, _refusalText(refusal), isError: true);
    return;
  }
  Toast.show(
    context,
    'Moved “${folder.name}” to ${_placeName(store.tree, picked.folderId)}',
    action: 'Undo',
    onAction: () => store.move(folder.id, parentId: from),
  );
}

/// A place as the toasts and the delete question name it: a folder's name
/// in quotes, or My notes.
String _placeName(FolderTree tree, String? folderId) =>
    switch (folderId == null ? null : tree.byId(folderId)) {
      final folder? => '“${folder.name}”',
      null => 'My notes',
    };

/// Opens the folder list at [position] and returns the place picked: a
/// folder's id, or null for My notes. Nothing comes back when it's closed.
Future<({String? folderId})?> _pickFolderAt(
  BuildContext context,
  Offset position, {
  required FolderStore store,
  required String? current,
  String? moving,
  required FolderRefusal? Function(String? folderId) check,
}) => showGeneralDialog<({String? folderId})>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close folders',
  barrierColor: Colors.transparent,
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) => CustomSingleChildLayout(
    delegate: PopoverAtPoint(position),
    child: _FolderPicker(
      store: store,
      current: current,
      moving: moving,
      check: check,
      onPicked: (folderId) => Navigator.of(context).pop((folderId: folderId)),
      onClose: () => Navigator.of(context).pop(),
    ),
  ),
);

/// A place in the folder list: a folder, or My notes for none.
class _Place {
  const _Place(this.folder, {this.enabled = true});

  final Folder? folder;
  final bool enabled;
}

/// One field that finds a folder, over My notes and every folder with the
/// place the note or folder is in now ticked. ↵ picks, ↑↓ move, esc closes.
/// A folder being moved can't go into itself or its own folders, which are
/// greyed out; a note can also go into a new folder named in the field.
class _FolderPicker extends StatefulWidget {
  const _FolderPicker({
    required this.store,
    required this.current,
    this.moving,
    required this.check,
    required this.onPicked,
    required this.onClose,
  });

  final FolderStore store;

  /// Where the note or folder is now, null being My notes.
  final String? current;

  /// The folder being moved, or null when a note is being filed.
  final String? moving;

  /// Why a place can't be picked, which the list says instead of closing.
  final FolderRefusal? Function(String? folderId) check;
  final ValueChanged<String?> onPicked;
  final VoidCallback onClose;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  final _query = TextEditingController();
  int _at = 0;
  FolderRefusal? _refusal;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// My notes and every folder in the tree's order, or those whose names
  /// hold what's typed.
  List<_Place> _places() {
    final tree = widget.store.tree;
    final moving = widget.moving;
    final query = _query.text.trim().toLowerCase();
    final places = <_Place>[
      if (query.isEmpty || 'my notes'.contains(query)) const _Place(null),
    ];
    void add(Folder folder) {
      if (query.isEmpty || folder.name.toLowerCase().contains(query)) {
        places.add(
          _Place(
            folder,
            enabled: moving == null || !tree.isWithin(folder.id, moving),
          ),
        );
      }
      tree.childrenOf(folder.id).forEach(add);
    }

    tree.top.forEach(add);
    return places;
  }

  /// The name typed, as a new folder at the top, while filing a note and
  /// while no folder there has that name.
  String? _newName() {
    final name = _query.text.trim();
    if (widget.moving != null || name.isEmpty) return null;
    return widget.store.checkCreate(name) == FolderRefusal.nameTaken
        ? null
        : name;
  }

  void _pick(String? folderId) {
    final refusal = folderId == widget.current ? null : widget.check(folderId);
    if (refusal != null) {
      setState(() => _refusal = refusal);
      return;
    }
    widget.onPicked(folderId);
  }

  void _create(String name) {
    final refusal = widget.store.checkCreate(name);
    if (refusal != null) {
      setState(() => _refusal = refusal);
      return;
    }
    if (widget.store.create(name) case final folder?) _pick(folder.id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final palette = context.palette;
      final tree = widget.store.tree;
      final searching = _query.text.trim().isNotEmpty;
      final places = _places();
      final created = _newName();
      final count = places.length + (created == null ? 0 : 1);
      final at = count == 0 ? -1 : _at.clamp(0, count - 1);
      bool enabled(int index) =>
          index >= places.length || places[index].enabled;
      void choose(int index) => index < places.length
          ? _pick(places[index].folder?.id)
          : _create(created!);
      void move(int delta) {
        for (var step = 1; step <= count; step++) {
          final index = (at + delta * step) % count;
          if (enabled(index)) {
            setState(() => _at = index);
            return;
          }
        }
      }

      Widget row(
        int index, {
        required Key key,
        required KapyIconData icon,
        required String label,
        String? detail,
        int depth = 1,
        bool ticked = false,
      }) {
        final on = enabled(index);
        return MouseRegion(
          cursor: on ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: on ? (_) => setState(() => _at = index) : null,
          child: GestureDetector(
            key: key,
            behavior: HitTestBehavior.opaque,
            onTap: on ? () => choose(index) : null,
            child: Container(
              height: 30,
              padding: EdgeInsets.only(left: 8 + (depth - 1) * 12.0, right: 8),
              decoration: BoxDecoration(
                color: index == at && on ? palette.hover : null,
                borderRadius: BorderRadius.circular(AppRadii.compact),
              ),
              child: Row(
                children: [
                  KapyIcon(
                    icon,
                    size: 16,
                    strokeWidth: 1.8,
                    color: on ? palette.textSecondary : palette.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: label,
                        children: [
                          if (detail != null)
                            TextSpan(
                              text: '  $detail',
                              style: TextStyle(color: palette.textTertiary),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _figtree(
                        13,
                        16,
                        FontWeight.w400,
                        on ? palette.textPrimary : palette.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 14,
                    child: ticked
                        ? KapyIcon(
                            KapyIcons.checkRounded,
                            size: 14,
                            strokeWidth: 1.8,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        );
      }

      final rows = <Widget>[
        for (final (index, place) in places.indexed)
          switch (place.folder) {
            null => row(
              index,
              key: const ValueKey('folder-pick-top'),
              icon: KapyIcons.noteOutlined,
              label: 'My notes',
              ticked: widget.current == null,
            ),
            final folder => row(
              index,
              key: ValueKey('folder-pick-${folder.id}'),
              icon: KapyIcons.folderOutlined,
              label: folder.name,
              depth: searching ? 1 : folder.depth + 1,
              detail: switch (folder.parentId) {
                final parentId? when searching => [
                  for (final each in tree.pathOf(parentId)) each.name,
                ].join(' › '),
                _ => null,
              },
              ticked: widget.current == folder.id,
            ),
          },
        if (created != null)
          row(
            places.length,
            key: const ValueKey('folder-pick-new'),
            icon: KapyIcons.folderAddOutlined,
            label: 'New folder “$created”',
          ),
      ];
      final refusal = _refusal;
      return TagPopover(
        key: const ValueKey('folder-picker'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    move(-1),
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  if (at >= 0 && enabled(at)) choose(at);
                },
                const SingleActivator(LogicalKeyboardKey.escape):
                    widget.onClose,
              },
              child: Container(
                height: 32,
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 9),
                decoration: BoxDecoration(
                  color: palette.wellBackground,
                  border: Border.all(color: palette.selectedBorder),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Row(
                  children: [
                    KapyIcon(
                      KapyIcons.searchRounded,
                      size: 14,
                      strokeWidth: 1.8,
                      color: palette.textTertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('folder-picker-field'),
                        controller: _query,
                        autofocus: true,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(folderNameMax),
                        ],
                        onChanged: (_) => setState(() {
                          _at = 0;
                          _refusal = null;
                        }),
                        style: _figtree(
                          13,
                          16,
                          FontWeight.w400,
                          palette.textPrimary,
                        ),
                        decoration: InputDecoration.collapsed(
                          hintText: widget.moving == null
                              ? 'Find or create a folder'
                              : 'Find a folder',
                          hintStyle: _figtree(
                            13,
                            16,
                            FontWeight.w400,
                            palette.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 30.0 * 9),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: rows,
              ),
            ),
            if (refusal != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Text(
                  _refusalText(refusal),
                  key: const ValueKey('folder-picker-problem'),
                  style: _figtree(
                    12,
                    16,
                    FontWeight.w400,
                    Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
