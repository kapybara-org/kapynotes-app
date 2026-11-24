import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/folders.dart';
import '../data/note.dart';
import 'compact_icon_button.dart';
import 'context_menu.dart';
import 'editor_panes.dart' show NoteDragData, NoteDraggable;
import 'note_tabs.dart' show clickOpensTabBehind;
import 'notes_grouping.dart' show NoteGroup;
import 'notes_list.dart' show NoteCardFace, NotesGroupHeading, PickBox;
import 'sidebar.dart' show SidebarEmpty;
import 'tag_ui.dart' show PopoverAtPoint, TagPopover, notesCount;
import 'tonal_button.dart';

TextStyle _figtree(
  double size,
  double line,
  FontWeight weight,
  Color color, {
  double? axis,
}) => chromeStyle(
  size: size,
  line: line,
  weight: axis ?? AppWeight.axisOf(weight),
  color: color,
);

/// Where a tree row at [depth] starts: 8 in, and 16 more a level.
double _indent(int depth) => 8 + (depth - 1) * 16.0;

/// The room a tree row keeps before its icon for the chevron that opens a
/// folder, its gap included: a 44 pt target on a phone, 12 and 8 beside the
/// rail. A folder with nothing in it, a note and the naming field keep it
/// too, so every icon at one depth lines up.
double _chevronSlot(bool phone) => phone ? 44 : 12 + 8;

/// What a refused folder action says.
String folderRefusalText(FolderRefusal refusal) => switch (refusal) {
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
/// A note dragged from the notes and held over Folders turns the list to the
/// folders, to be dropped on one.
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
      final face = Semantics(
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
      );
      return Expanded(
        child: forFolders && !on
            ? _DragHold(onHeld: () => onChanged(true), child: face)
            : face,
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
              color: palette.raisedBackground ?? palette.cardBackground,
              border: Border.all(
                color: palette.raisedBorder ?? palette.controlBorder,
              ),
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
/// open folder, a new folder named at its top, and notes dropped on a folder
/// filed in it. A phone's (M02) lists the notes in no folder after the tree,
/// headed as Home heads a day.
class FoldersTab extends StatefulWidget {
  const FoldersTab({
    super.key,
    required this.store,
    required this.notes,
    required this.open,
    required this.onOpen,
    required this.noteRow,
    this.inFront,
    this.onTab,
    this.header,
    this.phone = false,
    this.newFolder,
    this.onMade,
    this.looseHeading,
  });

  final FolderStore store;

  /// What a phone's Folders puts over the tree: its Drawings and Shared
  /// tiles.
  final Widget? header;

  /// A phone's Folders (M02): rows a finger's height, and a long press for a
  /// folder's actions.
  final bool phone;

  /// Notifies when a new folder is wanted at the top of the tree, from New
  /// folder by the search field.
  final Listenable? newFolder;

  /// A folder just named in the tree, which the window shows in the tab in
  /// front with Add notes beside it.
  final ValueChanged<String>? onMade;

  /// Heads the notes in no folder, as a phone's Home heads a day; null for
  /// the small heading beside the rail.
  final Widget Function(String label)? looseHeading;

  /// The notes it files: the person's own, before any filter narrows them.
  final List<Note> notes;

  /// The folders shown open.
  final Set<String> open;
  final void Function(String folderId, bool open) onOpen;

  /// A note's row: in an open folder, its icon [inset] in, or on a phone in
  /// the list of notes in no folder with a null [inset].
  final Widget Function(Note note, double? inset) noteRow;

  /// The folder the tab in front shows, which the tree marks.
  final String? inFront;

  /// Shows a folder in the tab in front, or with [behind] in a new tab behind
  /// it. Null without tabs, where a click opens a folder in the tree.
  final void Function(String folderId, {required bool behind})? onTab;

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

  @override
  void initState() {
    super.initState();
    widget.newFolder?.addListener(_newFolder);
  }

  @override
  void didUpdateWidget(FoldersTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.newFolder == widget.newFolder) return;
    oldWidget.newFolder?.removeListener(_newFolder);
    widget.newFolder?.addListener(_newFolder);
  }

  @override
  void dispose() {
    widget.newFolder?.removeListener(_newFolder);
    super.dispose();
  }

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
    final made = renaming == null
        ? _store.create(name, parentId: _namingIn)
        : null;
    _stopNaming();
    if (made != null) widget.onMade?.call(made.id);
    return null;
  }

  Future<void> _showMenu(Offset position, Folder folder) async {
    final choice = await showFolderMenu(context, position, folder);
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        setState(() {
          _naming = false;
          _renaming = folder.id;
        });
      case 'new':
        _newFolder(folder.id);
      case final action?:
        await runFolderAction(
          context,
          action,
          position,
          store: _store,
          notes: widget.notes,
          folder: folder,
        );
    }
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

    double inset(int depth) => _indent(depth) + _chevronSlot(widget.phone);

    if (widget.header case final header?) rows.add((_) => header);
    Widget field(int depth, [String initial = '']) => _FolderNameField(
      inset: inset(depth),
      initial: initial,
      onSubmit: _submit,
      onCancel: _stopNaming,
    );

    // A new folder is named at the top, under the button that asked.
    final namingTop = _naming && _namingIn == null;
    if (!widget.phone && tree.isEmpty && !namingTop) {
      return const SidebarEmpty(
        message: 'No folders yet',
        detail: 'Make a folder, then pick the notes that go in it.',
      );
    }
    if (namingTop) add((_) => field(1));
    for (final line in tree) {
      switch (line) {
        case FolderLine(:final folder):
          Widget row({bool dropping = false}) => _FolderRow(
            key: ValueKey('folder-${folder.id}'),
            phone: widget.phone,
            line: line,
            selected: folder.id == widget.inFront,
            dropping: dropping,
            onToggle: () => widget.onOpen(folder.id, !line.open),
            onTab: switch (widget.onTab) {
              final onTab? => ({required behind}) {
                if (!behind && !line.open && !line.empty) {
                  widget.onOpen(folder.id, true);
                }
                onTab(folder.id, behind: behind);
              },
              null => null,
            },
            onMenu: (position) => unawaited(_showMenu(position, folder)),
          );
          add(
            (_) => folder.id == _renaming
                ? field(folder.depth, folder.name)
                : widget.phone
                ? row()
                : _FolderDrop(
                    tree: _store.tree,
                    folderId: folder.id,
                    onDrop: (noteIds) =>
                        fileNotes(context, _store, noteIds, folder.id),
                    builder: (_, over) => row(dropping: over),
                  ),
          );
          if (_naming && _namingIn == folder.id) {
            add((_) => field(folder.depth + 1));
          }
        case NoteLine(:final note, :final depth):
          add((_) => widget.noteRow(note, inset(depth)));
      }
    }
    if (widget.looseHeading case final heading? when loose.isNotEmpty) {
      rows.add((_) => const SizedBox(height: 22));
      rows.add(
        (_) => Padding(
          key: const ValueKey('folders-loose-heading'),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: heading('Not in a folder'),
        ),
      );
      rows.add((_) => const SizedBox(height: 12));
      for (final (index, note) in loose.indexed) {
        if (index > 0) {
          rows.add(
            (context) => Divider(
              height: AppHairline.of(context),
              thickness: AppHairline.of(context),
              indent: 20,
              endIndent: 20,
              color: context.palette.separator,
            ),
          );
        }
        rows.add((_) => widget.noteRow(note, null));
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
/// pointer. Right-click opens the same actions. With tabs, a click shows the
/// folder in the tab in front, and ⌘-click (Ctrl-click off a Mac) or a
/// middle click in a tab behind it; without them, a click opens it here.
class _FolderRow extends StatefulWidget {
  const _FolderRow({
    super.key,
    required this.phone,
    required this.line,
    required this.selected,
    required this.onToggle,
    required this.onTab,
    required this.onMenu,
    this.dropping = false,
  });

  final bool phone;
  final FolderLine line;

  /// Whether the tab in front shows it.
  final bool selected;

  /// Whether notes dragged over it would be filed in it if let go.
  final bool dropping;
  final VoidCallback onToggle;
  final void Function({required bool behind})? onTab;
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
    final onTab = widget.onTab;
    final selected = widget.selected;
    final dropping = widget.dropping;
    final phone = widget.phone;
    // While notes are carried, a row answers the drag rather than the pointer.
    final hovering = _hovering && NoteDraggable.carrying.value == null;
    final chevron = SizedBox(
      width: _chevronSlot(phone),
      height: double.infinity,
      child: line.empty
          ? null
          : Align(
              alignment: Alignment.centerLeft,
              child: KapyIcon(
                line.open
                    ? KapyIcons.chevronDownRounded
                    : KapyIcons.chevronRightRounded,
                size: 12,
                color: palette.textTertiary,
              ),
            ),
    );
    return MouseRegion(
      cursor: line.empty && onTab == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Semantics(
        button: onTab != null || !line.empty,
        selected: selected,
        expanded: line.empty ? null : line.open,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTab != null
              ? () => onTab(behind: clickOpensTabBehind())
              : line.empty
              ? null
              : widget.onToggle,
          onTertiaryTapUp: onTab == null ? null : (_) => onTab(behind: true),
          onSecondaryTapUp: (details) => widget.onMenu(details.globalPosition),
          onLongPressStart: phone
              ? (details) => widget.onMenu(details.globalPosition)
              : null,
          child: Container(
            height: AppControlMetrics.scaleBar(context, phone ? 48 : 32),
            padding: EdgeInsets.only(
              left: _indent(folder.depth),
              right: hovering ? 4 : 8,
            ),
            decoration: BoxDecoration(
              color: dropping
                  ? palette.tonalBackground
                  : selected
                  ? palette.selectedBackground
                  : hovering
                  ? palette.hover
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            foregroundDecoration: dropping
                ? BoxDecoration(
                    border: Border.all(color: palette.selectedBorder),
                    borderRadius: BorderRadius.circular(8),
                  )
                : null,
            child: Row(
              children: [
                if (onTab == null || line.empty)
                  chevron
                else
                  Semantics(
                    button: true,
                    label: line.open
                        ? 'Hide what is in ${folder.name}'
                        : 'Show what is in ${folder.name}',
                    child: GestureDetector(
                      key: ValueKey('folder-chevron-${folder.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onToggle,
                      child: chevron,
                    ),
                  ),
                KapyIcon(
                  KapyIcons.folderOutlined,
                  size: phone ? 20 : 16,
                  color: dropping
                      ? palette.tonalForeground
                      : palette.textSecondary,
                ),
                SizedBox(width: phone ? 10 : 8),
                Expanded(
                  child: Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _figtree(
                      phone ? 16 : 13,
                      phone ? 22 : 16,
                      FontWeight.w400,
                      dropping
                          ? palette.tonalForeground
                          : selected
                          ? palette.textPrimary
                          : palette.textSecondary,
                      axis: selected ? AppWeight.selected : AppWeight.body,
                    ),
                  ),
                ),
                if (hovering)
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

/// New folder, under the search field while the list shows the folders: as
/// wide as the list, and in the same place however many folders there are.
class NewFolderButton extends StatelessWidget {
  const NewFolderButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = BorderRadius.circular(AppRadii.control);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: palette.raisedBackground ?? palette.cardBackground,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: palette.raisedBorder ?? palette.controlBorder,
          ),
        ),
        child: InkWell(
          key: const ValueKey('folders-new'),
          borderRadius: radius,
          hoverColor: palette.hover,
          onTap: onPressed,
          child: SizedBox(
            height: AppControlMetrics.scaleBar(context, 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                KapyIcon(
                  KapyIcons.folderAddOutlined,
                  size: 16,
                  color: palette.accentText,
                ),
                const SizedBox(width: 8),
                Text(
                  'New folder',
                  style: _figtree(
                    13,
                    18,
                    FontWeight.w500,
                    palette.textSecondary,
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
    required this.inset,
    this.initial = '',
    required this.onSubmit,
    required this.onCancel,
  });

  /// How far in its folder icon sits: at the tree's indent for its depth
  /// there, or near the edge where it floats.
  final double inset;
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
    final start = widget.inset;
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
                    folderRefusalText(refusal),
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

/// A note inside an open folder: its icon [inset] in, as its folder's own
/// folders', and its title on a 32 row. The open note's row is raised, with
/// a firmer title.
class TreeNoteFace extends StatelessWidget {
  const TreeNoteFace({
    super.key,
    required this.note,
    required this.inset,
    required this.selected,
    required this.hovering,
    this.ringed = false,
  });

  final Note note;
  final double inset;
  final bool selected;
  final bool hovering;
  final bool ringed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colour = selected ? palette.textPrimary : palette.textSecondary;
    return Container(
      height: AppControlMetrics.scaleBar(context, 32),
      padding: EdgeInsets.only(left: inset, right: 8),
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
          KapyIcon(KapyIcons.noteOutlined, size: 16, color: colour),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _figtree(
                13,
                16,
                FontWeight.w400,
                colour,
                axis: selected ? AppWeight.selected : AppWeight.body,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Move to folder… on a note's menu, or on the picked notes': files them
/// where the list picks, as [fileNotes] does.
Future<void> moveNotesToFolder(
  BuildContext context,
  Offset position,
  FolderStore store,
  List<String> noteIds,
) async {
  final picked = await _pickFolderAt(
    context,
    position,
    store: store,
    current: {for (final id in noteIds) store.tree.folderOf(id)},
    check: (folderId) => store.checkFile(noteIds, folderId),
  );
  if (picked == null) return;
  // A row the picker came from can be gone by now, as a folder made in it
  // reshuffles the tree; the notes go where they were sent all the same.
  if (!context.mounted) {
    store.file(noteIds, picked.folderId);
    return;
  }
  fileNotes(context, store, noteIds, picked.folderId);
}

/// Files [noteIds] in [folderId], null being My notes, and says where, with
/// an Undo that puts each back where it was: added, when Add notes did it,
/// and moved otherwise.
void fileNotes(
  BuildContext context,
  FolderStore store,
  List<String> noteIds,
  String? folderId, {
  bool adding = false,
}) {
  final from = {for (final id in noteIds) id: store.tree.folderOf(id)};
  final moving = [
    for (final id in noteIds)
      if (from[id] != folderId) id,
  ];
  if (moving.isEmpty) return;
  final refusal = store.file(moving, folderId);
  if (refusal != null) {
    Toast.show(context, folderRefusalText(refusal), isError: true);
    return;
  }
  final place = _placeName(store.tree, folderId);
  final verb = adding ? 'Added' : 'Moved';
  Toast.show(
    context,
    moving.length == 1
        ? '$verb to $place'
        : '$verb ${moving.length} notes to $place',
    action: 'Undo',
    onAction: () {
      final refusals = [
        for (final folderId in {for (final id in moving) from[id]})
          ?store.file([
            for (final id in moving)
              if (from[id] == folderId) id,
          ], folderId),
      ];
      if (refusals.isNotEmpty && context.mounted) {
        Toast.show(context, folderRefusalText(refusals.first), isError: true);
      }
    },
  );
}

/// A folder's actions, Delete apart from the rest: on its row in the tree
/// and on the page's More while it is in front. Its card on a folder's page
/// leaves out New folder inside, as a folder made there wouldn't show.
List<List<KapyMenuAction>> folderActions({bool newInside = true}) => [
  [
    const KapyMenuAction(
      value: 'rename',
      label: 'Rename',
      icon: KapyIcons.editOutlined,
    ),
    if (newInside)
      const KapyMenuAction(
        value: 'new',
        label: 'New folder inside',
        icon: KapyIcons.folderAddOutlined,
      ),
    const KapyMenuAction(
      value: 'move',
      label: 'Move to…',
      icon: KapyIcons.folderMoveOutlined,
    ),
  ],
  [
    const KapyMenuAction(
      value: 'delete',
      label: 'Delete folder…',
      icon: KapyIcons.deleteOutlined,
      destructive: true,
    ),
  ],
];

/// [folder]'s menu at [position], and the action picked from it.
Future<String?> showFolderMenu(
  BuildContext context,
  Offset position,
  Folder folder, {
  bool newInside = true,
}) => showKapyContextMenu<String>(
  context: context,
  globalPosition: position,
  items: kapyMenuItems((
    heading: null,
    groups: folderActions(newInside: newInside),
  ), key: (value) => '$value-folder-${folder.id}'),
);

/// Does [action], one of [folderActions], to [folder] from a menu at
/// [position]. Rename and New folder inside take the name in a field there.
/// [notes] are the ones folders hold, which Delete counts.
Future<void> runFolderAction(
  BuildContext context,
  String action,
  Offset position, {
  required FolderStore store,
  required List<Note> notes,
  required Folder folder,
}) async {
  switch (action) {
    case 'rename':
      await _nameFolderAt(
        context,
        position,
        initial: folder.name,
        submit: (name) => store.rename(folder.id, name),
      );
    case 'new':
      await _nameFolderAt(
        context,
        position,
        submit: (name) {
          final refusal = store.checkCreate(name, parentId: folder.id);
          if (refusal == null) store.create(name, parentId: folder.id);
          return refusal;
        },
      );
    case 'move':
      await _moveFolder(context, position, store, folder);
    case 'delete':
      await _deleteFolder(context, store, notes, folder);
  }
}

/// A field at [position] that names a folder, starting from [initial]. ↵
/// hands the name to [submit] and closes, unless [submit] says why not; esc
/// or a click outside closes it.
Future<void> _nameFolderAt(
  BuildContext context,
  Offset position, {
  String initial = '',
  required FolderRefusal? Function(String name) submit,
}) => showGeneralDialog<void>(
  context: context,
  barrierLabel: 'Close',
  barrierColor: Colors.transparent,
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) => CustomSingleChildLayout(
    delegate: PopoverAtPoint(position),
    child: TagPopover(
      key: const ValueKey('folder-name-popover'),
      child: _FolderNameField(
        inset: 9,
        initial: initial,
        onSubmit: (name) {
          final refusal = submit(name);
          if (refusal == null) Navigator.of(context).pop();
          return refusal;
        },
        onCancel: () => Navigator.of(context).pop(),
      ),
    ),
  ),
);

/// Asks once, deletes, and offers Undo, which puts the folder back with
/// whatever is still in it. Nothing in it is deleted: it moves up a level.
Future<void> _deleteFolder(
  BuildContext context,
  FolderStore store,
  List<Note> notes,
  Folder folder,
) {
  final tree = store.tree;
  final held = tree.notesIn(notes, folder.id).length;
  final folders = tree.childrenOf(folder.id).length;
  final into = _placeName(tree, folder.parentId);
  final what = _contents(held, folders);
  final content = switch ((held, folders)) {
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
            store.delete(folder.id);
            Toast.show(
              context,
              'Deleted “${folder.name}”',
              action: 'Undo',
              onAction: () => store.restore(folder.id),
            );
            Navigator.of(context).pop();
          },
          child: const Text('Delete'),
        ),
      ],
    ),
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
    current: {from},
    moving: folder.id,
    check: (parentId) => store.checkMove(folder.id, parentId: parentId),
  );
  if (picked == null || picked.folderId == from) return;
  final refusal = store.move(folder.id, parentId: picked.folderId);
  if (!context.mounted) return;
  if (refusal != null) {
    Toast.show(context, folderRefusalText(refusal), isError: true);
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
  required Set<String?> current,
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

  /// Where the notes or the folder are now, null being My notes. Each is
  /// ticked, and picking the one place they all are closes the list.
  final Set<String?> current;

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
    final here =
        widget.current.length == 1 && widget.current.contains(folderId);
    final refusal = here ? null : widget.check(folderId);
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
              ticked: widget.current.contains(null),
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
              ticked: widget.current.contains(folder.id),
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
                  folderRefusalText(refusal),
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

/// What a folder holds, as "6 notes" and "1 folder", leaving out a kind it
/// has none of.
List<String> _contents(int notes, int folders) => [
  if (notes > 0) notesCount(notes),
  if (folders > 0) folders == 1 ? '1 folder' : '$folders folders',
];

/// What a folder's page holds and where the folder sits: "6 notes and 1
/// folder, in Work". An [empty] folder's says only where it sits, and at the
/// top nothing, as the page itself says it is empty.
String? _holds(int notes, int folders, String? place, {required bool empty}) {
  if (empty) return place == null ? null : 'In $place';
  final what = _contents(notes, folders);
  return '${what.isEmpty ? 'No notes' : what.join(' and ')}, '
      'in ${place ?? 'My notes'}';
}

/// A folder open in a tab: its name, what it holds and where it sits, the
/// notes list's filter and view switch, the folders in it as cards, then its
/// notes by day, those in its folders included. Notes dropped on the page
/// are filed in the folder, and on a card in that card's folder. Add notes
/// stands at its right, or over its right edge where the page is narrow,
/// until its × puts it away for the page's own Add notes to bring back.
class FolderPage extends StatelessWidget {
  const FolderPage({
    super.key,
    required this.tree,
    required this.folderId,
    required this.filed,
    required this.notes,
    required this.controls,
    required this.cards,
    required this.group,
    required this.noteTile,
    required this.onTab,
    required this.onMenu,
    required this.onFile,
    required this.addNotes,
    required this.onAddNotes,
    required this.dateOf,
  });

  final FolderTree tree;
  final String folderId;

  /// The notes folders hold, before any filter: whether this one holds any,
  /// and the ones in no folder, which Add notes offers.
  final List<Note> filed;

  /// The notes a folder may hold, as the notes list's filter narrows them.
  final List<Note> notes;

  /// The notes list's filter and view switch.
  final Widget controls;
  final bool cards;

  /// [notes] in the notes list's groups: by day, unless it is set otherwise.
  final List<NoteGroup> Function(List<Note> notes) group;

  /// A note's card, or its row in the list view, giving only its time under
  /// a heading that names its day ([clockOnly]).
  final Widget Function(Note note, {bool clockOnly}) noteTile;

  /// Shows a folder in this tab, or with [behind] in a new tab behind it.
  final void Function(String folderId, {required bool behind}) onTab;

  /// A folder card's menu, asked for at [position].
  final void Function(Folder folder, Offset position) onMenu;

  /// Files notes in a folder: this one, or a card's, [adding] when Add notes
  /// does it.
  final void Function(List<String> noteIds, String folderId, {bool adding})
  onFile;

  /// Whether Add notes is open: what its × and the page's Add notes set.
  final bool addNotes;
  final ValueChanged<bool> onAddNotes;

  /// When a note in Add notes was last changed, as the notes list says it.
  final String Function(Note note) dateOf;

  static const double _cardWidth = 224;
  static const double _gap = 12;
  static const double _edge = 40;

  /// The most of the title's line the filter and the switch take.
  static const double _controlsWidth = 320;

  /// Add notes' width, and the least the page keeps beside it before Add
  /// notes goes over the page's edge instead.
  static const double _panelWidth = 320;
  static const double _pageLeast = 360;

  @override
  Widget build(BuildContext context) {
    final folder = tree.byId(folderId);
    if (folder == null) return const SizedBox.shrink();
    final palette = context.palette;
    final loose = tree.notesIn(filed, null);
    final page = _FolderDrop(
      tree: tree,
      folderId: folderId,
      onDrop: (noteIds) => onFile(noteIds, folderId),
      builder: (context, over) => Stack(
        fit: StackFit.expand,
        children: [
          _page(context, folder, loose),
          if (over)
            IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: DecoratedBox(
                  key: const ValueKey('folder-page-drop'),
                  decoration: BoxDecoration(
                    color: palette.tonalBackground.withValues(alpha: 0.2),
                    border: Border.all(color: palette.selectedBorder, width: 2),
                    borderRadius: BorderRadius.circular(AppRadii.surface),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (!addNotes) return page;
    final panel = _AddNotesPanel(
      key: const ValueKey('add-notes'),
      folder: folder,
      notes: loose,
      dateOf: dateOf,
      onAdd: (noteIds) => onFile(noteIds, folderId, adding: true),
      onClose: () => onAddNotes(false),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _panelWidth + _pageLeast) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: page),
              Container(
                width: _panelWidth,
                decoration: BoxDecoration(
                  color: palette.surfaceBackground,
                  border: Border(left: BorderSide(color: palette.separator)),
                ),
                child: panel,
              ),
            ],
          );
        }
        final radius = BorderRadius.circular(AppRadii.surface);
        return Stack(
          fit: StackFit.expand,
          children: [
            page,
            Positioned(
              top: 12,
              right: 12,
              bottom: 12,
              width: _panelWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.wellBackground,
                  border: Border.all(color: palette.separator),
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: palette.shadowAt(0x99),
                      offset: const Offset(0, 24),
                      blurRadius: 48,
                      spreadRadius: -16,
                    ),
                    BoxShadow(
                      color: palette.shadowAt(0x59),
                      offset: const Offset(0, 2),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: ClipRRect(borderRadius: radius, child: panel),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _page(BuildContext context, Folder folder, List<Note> loose) {
    final palette = context.palette;
    final folders = tree.childrenOf(folderId);
    final held = tree.notesIn(notes, folderId, deep: true);
    final empty =
        folders.isEmpty && tree.notesIn(filed, folderId, deep: true).isEmpty;
    final inside = <String, int>{};
    for (final note in held) {
      for (
        String? at = tree.folderOf(note.id);
        at != null && at != folderId;
        at = tree.byId(at)?.parentId
      ) {
        inside.update(at, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final place = switch (folder.parentId) {
      final parentId? => tree.byId(parentId)?.name,
      null => null,
    };
    final holds = _holds(held.length, folders.length, place, empty: empty);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - 2 * _edge;
        final across = math.max(
          1,
          ((width + _gap) / (_cardWidth + _gap)).floor(),
        );
        final rows = <WidgetBuilder>[];
        void gap(double height) => rows.add((_) => SizedBox(height: height));

        void grid(int count, double height, Widget Function(int index) tile) {
          for (var start = 0; start < count; start += across) {
            if (start > 0) gap(_gap);
            final end = math.min(start + across, count);
            rows.add(
              (context) => SizedBox(
                height: AppControlMetrics.scaleBar(context, height),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = start; index < end; index++) ...[
                      if (index > start) const SizedBox(width: _gap),
                      SizedBox(width: _cardWidth, child: tile(index)),
                    ],
                  ],
                ),
              ),
            );
          }
        }

        rows.add(
          (_) => Row(
            children: [
              KapyIcon(
                KapyIcons.folderOutlined,
                size: 24,
                color: palette.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    folder.name,
                    key: const ValueKey('folder-page-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppFonts.title,
                      fontSize: 30,
                      height: 38 / 30,
                      leadingDistribution: TextLeadingDistribution.even,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: (width / 2).clamp(0, _controlsWidth),
                child: controls,
              ),
              if (!addNotes) ...[
                const SizedBox(width: 12),
                TonalButton(
                  key: const ValueKey('folder-page-add-notes'),
                  icon: KapyIcons.noteAddRounded,
                  label: 'Add notes',
                  onPressed: () => onAddNotes(true),
                ),
              ],
            ],
          ),
        );
        if (holds != null) {
          gap(6);
          rows.add(
            (_) => Text(
              holds,
              key: const ValueKey('folder-page-holds'),
              style: _figtree(13, 18, FontWeight.w400, palette.textTertiary),
            ),
          );
        }
        if (empty) {
          gap(36);
          rows.add(
            (_) => Text(
              'Nothing in this folder yet.',
              key: const ValueKey('folder-page-empty'),
              style: _figtree(14, 20, FontWeight.w400, palette.textSecondary),
            ),
          );
          gap(4);
          rows.add(
            (_) => Text(
              loose.isEmpty
                  ? 'Drag notes here from another folder.'
                  : addNotes
                  ? 'Tick notes on the right and add them, or drag notes here.'
                  : 'Use Add notes, or drag notes here.',
              style: _figtree(13, 18, FontWeight.w400, palette.textTertiary),
            ),
          );
        }
        if (folders.isNotEmpty) {
          gap(22);
          grid(folders.length, 52, (index) {
            final inner = folders[index];
            return _FolderDrop(
              tree: tree,
              folderId: inner.id,
              onDrop: (noteIds) => onFile(noteIds, inner.id),
              builder: (_, over) => _FolderCard(
                key: ValueKey('folder-card-${inner.id}'),
                folder: inner,
                count: inside[inner.id] ?? 0,
                dropping: over,
                onTab: ({required behind}) => onTab(inner.id, behind: behind),
                onMenu: (position) => onMenu(inner, position),
              ),
            );
          });
        }
        for (final each in group(held)) {
          gap(24);
          rows.add(
            (_) => NotesGroupHeading(
              key: ValueKey('folder-group-${each.label}'),
              label: each.label,
              detail: each.detail,
            ),
          );
          gap(8);
          if (cards) {
            grid(
              each.notes.length,
              NoteCardFace.height,
              (at) => noteTile(each.notes[at], clockOnly: each.day != null),
            );
            continue;
          }
          for (final (at, note) in each.notes.indexed) {
            if (at > 0) gap(2);
            rows.add(
              (_) => Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  // As wide as three cards.
                  constraints: const BoxConstraints(
                    maxWidth: 3 * _cardWidth + 2 * _gap,
                  ),
                  child: noteTile(note, clockOnly: each.day != null),
                ),
              ),
            );
          }
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(_edge, 26, _edge, 40),
          itemCount: rows.length,
          itemBuilder: (context, index) => rows[index](context),
        );
      },
    );
  }
}

/// Files the notes dropped on what [builder] builds in [folderId], and says
/// while a drag that would file any of them there is over it: one carrying
/// notes a folder takes, not all of them in [folderId] already.
class _FolderDrop extends StatelessWidget {
  const _FolderDrop({
    required this.tree,
    required this.folderId,
    required this.onDrop,
    required this.builder,
  });

  final FolderTree tree;
  final String folderId;
  final ValueChanged<List<String>> onDrop;
  final Widget Function(BuildContext context, bool over) builder;

  @override
  Widget build(BuildContext context) => DragTarget<NoteDragData>(
    onWillAcceptWithDetails: (details) =>
        details.data.fileable.any((id) => tree.folderOf(id) != folderId),
    onAcceptWithDetails: (details) => onDrop(details.data.fileable),
    builder: (context, over, _) => builder(context, over.isNotEmpty),
  );
}

/// Calls [onHeld] once a dragged note has been held over [child] a moment.
class _DragHold extends StatefulWidget {
  const _DragHold({required this.onHeld, required this.child});

  final VoidCallback onHeld;
  final Widget child;

  @override
  State<_DragHold> createState() => _DragHoldState();
}

class _DragHoldState extends State<_DragHold> {
  Timer? _hold;

  void _letGo() {
    _hold?.cancel();
    _hold = null;
  }

  @override
  void dispose() {
    _letGo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DragTarget<NoteDragData>(
    onWillAcceptWithDetails: (_) {
      _hold ??= Timer(const Duration(milliseconds: 500), () {
        _hold = null;
        widget.onHeld();
      });
      return false;
    },
    onLeave: (_) => _letGo(),
    builder: (context, _, _) => widget.child,
  );
}

/// Add notes beside a folder's page: the notes in no folder, newest first,
/// found by what is in them, ticked by a click, and added to the folder
/// together. A row drags as well, with the ticked ones when it is one.
class _AddNotesPanel extends StatefulWidget {
  const _AddNotesPanel({
    super.key,
    required this.folder,
    required this.notes,
    required this.dateOf,
    required this.onAdd,
    required this.onClose,
  });

  final Folder folder;

  /// The notes in no folder.
  final List<Note> notes;
  final String Function(Note note) dateOf;
  final ValueChanged<List<String>> onAdd;
  final VoidCallback onClose;

  @override
  State<_AddNotesPanel> createState() => _AddNotesPanelState();
}

class _AddNotesPanelState extends State<_AddNotesPanel> {
  final _query = TextEditingController();
  final _ticked = <String>{};

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final notes = widget.notes;
    final query = _query.text.trim();
    final shown = [
      for (final note in notes)
        if (note.matches(query)) note,
    ];
    // A ticked note filed meanwhile, by a drag or on another device, has
    // left the list.
    final ticked = [
      for (final note in notes)
        if (_ticked.contains(note.id)) note.id,
    ];
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Add notes to ${widget.folder.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _figtree(
                  14,
                  20,
                  FontWeight.w600,
                  palette.textPrimary,
                  axis: AppWeight.section,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          CompactIconButton(
            key: const ValueKey('add-notes-close'),
            tooltip: 'Close',
            extent: 28,
            foregroundColor: palette.textTertiary,
            onPressed: widget.onClose,
            icon: const KapyIcon(KapyIcons.closeRounded, size: 16),
          ),
        ],
      ),
    );
    if (notes.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Expanded(
            child: SidebarEmpty(
              message: 'Every note is in a folder',
              detail: 'Notes you write outside a folder show up here.',
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: _field(context),
        ),
        if (shown.isEmpty)
          Expanded(
            child: SidebarEmpty(
              message: 'No notes match “$query”',
              detail: 'Notes already in a folder aren’t listed here.',
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${notes.length} not in a folder',
                    style: _figtree(
                      12,
                      16,
                      FontWeight.w400,
                      palette.textTertiary,
                    ),
                  ),
                ),
                if (shown.any((note) => !_ticked.contains(note.id)))
                  InkWell(
                    key: const ValueKey('add-notes-select-all'),
                    borderRadius: BorderRadius.circular(AppRadii.small),
                    onTap: () => setState(
                      () => _ticked.addAll([for (final note in shown) note.id]),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        'Select all',
                        style: _figtree(
                          12,
                          16,
                          FontWeight.w500,
                          palette.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              key: const ValueKey('add-notes-list'),
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              itemCount: shown.length,
              separatorBuilder: (_, _) => const SizedBox(height: 2),
              itemBuilder: (context, index) =>
                  _row(context, shown[index], ticked),
            ),
          ),
        ],
        if (shown.isNotEmpty || ticked.isNotEmpty) _foot(context, ticked),
      ],
    );
  }

  Widget _field(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: AppControlMetrics.scaleBar(context, 32),
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: palette.controlBackground,
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
            child: TextField(
              key: const ValueKey('add-notes-field'),
              controller: _query,
              onChanged: (_) => setState(() {}),
              style: _figtree(13, 18, FontWeight.w400, palette.textPrimary),
              decoration: InputDecoration.collapsed(
                hintText: 'Find a note',
                hintStyle: _figtree(
                  13,
                  18,
                  FontWeight.w400,
                  palette.textTertiary,
                ),
              ),
            ),
          ),
          if (_query.text.isNotEmpty)
            CompactIconButton(
              key: const ValueKey('add-notes-field-clear'),
              tooltip: 'Clear',
              extent: 24,
              foregroundColor: palette.textTertiary,
              onPressed: () => setState(_query.clear),
              icon: const KapyIcon(KapyIcons.closeRounded, size: 14),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Note note, List<String> ticked) {
    final palette = context.palette;
    final on = _ticked.contains(note.id);
    final radius = BorderRadius.circular(8);
    return NoteDraggable(
      data: NoteDragData(
        noteId: note.id,
        title: note.title,
        together: on && ticked.length > 1 ? ticked : const [],
        fileable: on ? ticked : [note.id],
      ),
      child: MergeSemantics(
        child: Semantics(
          checked: on,
          child: Material(
            color: on ? palette.selectedBackground : Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              key: ValueKey('add-note-${note.id}'),
              borderRadius: radius,
              hoverColor: palette.hover,
              onTap: () => setState(() {
                if (!_ticked.remove(note.id)) _ticked.add(note.id);
              }),
              child: Container(
                height: AppControlMetrics.scaleBar(context, 48),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    PickBox(checked: on),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            note.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _figtree(
                              13,
                              16,
                              FontWeight.w500,
                              palette.textPrimary,
                            ),
                          ),
                          Text(
                            widget.dateOf(note),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                _figtree(
                                  12,
                                  16,
                                  FontWeight.w400,
                                  palette.textTertiary,
                                ).copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _foot(BuildContext context, List<String> ticked) {
    final palette = context.palette;
    final radius = BorderRadius.circular(AppRadii.control);
    final ready = ticked.isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.separator)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Material(
          color: ready ? palette.tonalBackground : palette.controlBackground,
          borderRadius: radius,
          child: InkWell(
            key: const ValueKey('add-notes-add'),
            borderRadius: radius,
            onTap: ready
                ? () {
                    setState(_ticked.clear);
                    widget.onAdd(ticked);
                  }
                : null,
            child: SizedBox(
              height: AppControlMetrics.scaleBar(context, 36),
              child: Center(
                child: Text(
                  ready ? 'Add ${notesCount(ticked.length)}' : 'Add notes',
                  style: _figtree(
                    13,
                    18,
                    FontWeight.w500,
                    ready ? palette.tonalForeground : palette.textTertiary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A folder inside the one on the page: its icon, its name and how many
/// notes are inside it at any depth. A click shows it in this tab, ⌘-click
/// (Ctrl-click off a Mac) or a middle click in a tab behind, and a right
/// click opens its menu. Notes dragged over it ring it, to be filed in it
/// if let go.
class _FolderCard extends StatefulWidget {
  const _FolderCard({
    super.key,
    required this.folder,
    required this.count,
    required this.dropping,
    required this.onTab,
    required this.onMenu,
  });

  final Folder folder;
  final int count;
  final bool dropping;
  final void Function({required bool behind}) onTab;
  final ValueChanged<Offset> onMenu;

  @override
  State<_FolderCard> createState() => _FolderCardState();
}

class _FolderCardState extends State<_FolderCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final count = widget.count;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onTab(behind: clickOpensTabBehind()),
          onTertiaryTapUp: (_) => widget.onTab(behind: true),
          onSecondaryTapUp: (details) => widget.onMenu(details.globalPosition),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: widget.dropping
                  ? palette.tonalBackground
                  : _hovering
                  ? Color.alphaBlend(palette.hover, palette.controlBackground)
                  : palette.controlBackground,
              border: Border.all(
                color: widget.dropping
                    ? palette.selectedBorder
                    : palette.controlBorder,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                KapyIcon(
                  KapyIcons.folderOutlined,
                  size: 18,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _figtree(
                      14,
                      19,
                      FontWeight.w600,
                      palette.textPrimary,
                    ),
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 10),
                  Text(
                    notesCount(count),
                    style: _figtree(
                      12,
                      16,
                      FontWeight.w400,
                      palette.textTertiary,
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
