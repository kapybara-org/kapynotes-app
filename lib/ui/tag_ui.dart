import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/tags.dart';
import 'context_menu.dart';
import 'settings_rows.dart';
import 'tag_colours.dart';

/// A tag as the lists offer it, with how many notes carry it.
typedef TagEntry = ({Tag tag, int count});

TagColour? tagColourOf(String key) => TagColour.values.asNameMap()[key];

TagMark tagMarkOf(Tag tag) =>
    (name: tag.name.v, colour: tagColourOf(tag.colour.v));

/// Which tags the Notes filter narrows the list to. A note matches a ticked
/// tag it carries (any of them, or all with [all]), or No tag when it carries
/// none.
@immutable
class TagFilter {
  const TagFilter({this.ids = const {}, this.none = false, this.all = false});

  final Set<String> ids;
  final bool none;
  final bool all;

  bool get narrowed => ids.isNotEmpty || none;
  int get ticked => ids.length + (none ? 1 : 0);

  bool matches(Iterable<String> tagIds) {
    if (none && tagIds.isEmpty) return true;
    if (ids.isEmpty) return false;
    final carried = tagIds.toSet();
    return all ? carried.containsAll(ids) : ids.any(carried.contains);
  }

  /// Only the ticks on tags still listed, so a tag that leaves the lists,
  /// deleted or Hidden again, stops narrowing what it no longer names.
  TagFilter within(Iterable<String> listed) =>
      TagFilter(ids: ids.intersection(listed.toSet()), none: none, all: all);

  TagFilter copyWith({Set<String>? ids, bool? none, bool? all}) => TagFilter(
    ids: ids ?? this.ids,
    none: none ?? this.none,
    all: all ?? this.all,
  );
}

/// The person's tags for whatever below draws or changes them.
class TagShelf extends InheritedWidget {
  const TagShelf({
    super.key,
    required this.store,
    required this.listed,
    required this.isShared,
    required this.onFilter,
    required super.child,
  });

  final TagStore store;

  /// The tags the lists offer, in the person's order, each with its count.
  /// While Hidden is locked no Hidden note counts, and a tag found only on
  /// Hidden notes is left out, so neither gives Hidden away.
  final List<TagEntry> Function() listed;
  final bool Function(String noteId) isShared;

  /// Narrows the list to one tag, from a chip.
  final ValueChanged<String> onFilter;

  static TagShelf? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TagShelf>();

  @override
  bool updateShouldNotify(TagShelf oldWidget) => true;
}

TextStyle _text(double size, FontWeight weight, Color color) => TextStyle(
  fontFamily: AppFonts.ui,
  fontFamilyFallback: AppFonts.uiFallback,
  fontSize: size,
  height: 16 / size,
  fontWeight: weight,
  color: color,
);

String notesCount(int count) => count == 1 ? '1 note' : '$count notes';

/// A tag's colour as a dot, or a ring for No colour.
class TagDot extends StatelessWidget {
  const TagDot(this.colour, {super.key, this.size = 8});

  final TagColour? colour;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colour?.dot(palette),
        border: colour == null
            ? Border.all(color: palette.textMuted, width: 1.2)
            : null,
      ),
    );
  }
}

/// The popover surface the tag lists sit on.
class TagPopover extends StatelessWidget {
  const TagPopover({super.key, required this.child, this.width = 248});

  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: width,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: palette.controlBackground,
          border: Border.all(color: palette.separator),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: palette.shadowAt(0x80),
              offset: const Offset(0, 12),
              blurRadius: 28,
              spreadRadius: -14,
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

/// One field that finds or creates, over the tags with ticks for the ones on
/// [noteId]. ↵ adds or takes off, ↑↓ move, esc closes.
class TagPicker extends StatefulWidget {
  const TagPicker({
    super.key,
    required this.shelf,
    required this.noteId,
    required this.onClose,
  });

  final TagShelf shelf;
  final String noteId;
  final VoidCallback onClose;

  @override
  State<TagPicker> createState() => _TagPickerState();
}

class _TagPickerState extends State<TagPicker> {
  final _query = TextEditingController();
  int _at = 0;
  String? _problem;

  TagStore get _store => widget.shelf.store;

  static const _tooMany = 'A note takes at most $noteTagsMax tags.';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<TagEntry> _matches() {
    final query = _query.text.trim().toLowerCase();
    return [
      for (final entry in widget.shelf.listed())
        if (entry.tag.name.v.toLowerCase().contains(query)) entry,
    ];
  }

  bool _isOn(String tagId) =>
      _store.tagsOf(widget.noteId).any((tag) => tag.id == tagId);

  void _toggle(String tagId) {
    if (_isOn(tagId)) {
      _store.removeTag(widget.noteId, tagId);
      return setState(() => _problem = null);
    }
    final added = _store.addTag(widget.noteId, tagId);
    setState(() => _problem = added ? null : _tooMany);
  }

  /// A name another tag has, in any case, picks that tag, even one the
  /// lists leave out while Hidden is locked.
  void _create() {
    if (_store.tagsOf(widget.noteId).length >= noteTagsMax) {
      return setState(() => _problem = _tooMany);
    }
    final tag = _store.create(_query.text);
    if (tag == null) {
      return setState(
        () => _problem = 'A tag name is 1 to $tagNameMax characters.',
      );
    }
    _store.addTag(widget.noteId, tag.id);
    _query.clear();
    setState(() {
      _problem = null;
      _at = 0;
    });
  }

  void _activate() {
    final matches = _matches();
    if (matches.isNotEmpty) {
      return _toggle(matches[_at.clamp(0, matches.length - 1)].tag.id);
    }
    if (_query.text.trim().isNotEmpty) _create();
  }

  void _move(int by) {
    final count = _matches().length;
    if (count == 0) return;
    setState(() => _at = (_at + by).clamp(0, count - 1));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final palette = context.palette;
      final matches = _matches();
      final query = _query.text.trim();
      Widget row({
        required Key key,
        required int index,
        required Widget leading,
        required String label,
        String? count,
        bool ticked = false,
        required VoidCallback onTap,
      }) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _at = index),
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: index == _at ? palette.hover : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _text(13, FontWeight.w500, palette.textPrimary),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 9),
                  Text(
                    count,
                    style: _text(12, FontWeight.w400, palette.textTertiary),
                  ),
                ],
                const SizedBox(width: 9),
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

      final rows = <Widget>[
        for (final (index, entry) in matches.indexed)
          row(
            key: ValueKey('tag-row-${entry.tag.id}'),
            index: index,
            leading: TagDot(tagColourOf(entry.tag.colour.v)),
            label: entry.tag.name.v,
            count: '${entry.count}',
            ticked: _isOn(entry.tag.id),
            onTap: () => _toggle(entry.tag.id),
          ),
        if (matches.isEmpty && query.isNotEmpty)
          row(
            key: const ValueKey('tag-create'),
            index: 0,
            leading: KapyIcon(
              KapyIcons.addRounded,
              size: 12,
              strokeWidth: 2,
              color: palette.textTertiary,
            ),
            label: 'Create “$query”',
            onTap: _create,
          ),
      ];
      final problem = _problem;
      return TagPopover(
        key: const ValueKey('tag-picker'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.shelf.isShared(widget.noteId))
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Text(
                  'Shared note: your tags and their colours show only to you.',
                  style: _text(12, FontWeight.w400, palette.textTertiary),
                ),
              ),
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _move(-1),
                const SingleActivator(LogicalKeyboardKey.enter): _activate,
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
                  borderRadius: BorderRadius.circular(8),
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
                        key: const ValueKey('tag-picker-field'),
                        controller: _query,
                        autofocus: true,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(tagNameMax),
                        ],
                        onChanged: (_) => setState(() {
                          _at = 0;
                          _problem = null;
                        }),
                        style: _text(13, FontWeight.w400, palette.textPrimary),
                        decoration: InputDecoration.collapsed(
                          hintText: 'Find or create a tag',
                          hintStyle: _text(
                            13,
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
              constraints: const BoxConstraints(maxHeight: 30.0 * 8),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: rows,
              ),
            ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Text(
                  problem,
                  key: const ValueKey('tag-picker-problem'),
                  style: _text(
                    12,
                    FontWeight.w500,
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

/// The tag list for [noteId] at [position], from the note's menu.
Future<void> showTagPickerAt(
  BuildContext context,
  Offset position,
  String noteId,
) async {
  final shelf = TagShelf.maybeOf(context);
  if (shelf == null) return;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close tags',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => CustomSingleChildLayout(
      delegate: _AtPoint(position),
      child: TagPicker(
        shelf: shelf,
        noteId: noteId,
        onClose: () => Navigator.of(context).pop(),
      ),
    ),
  );
}

class _AtPoint extends SingleChildLayoutDelegate {
  _AtPoint(this.point);

  final Offset point;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    math.max(0, math.min(point.dx, size.width - childSize.width - 8)),
    math.max(0, math.min(point.dy, size.height - childSize.height - 8)),
  );

  @override
  bool shouldRelayout(_AtPoint oldDelegate) => oldDelegate.point != point;
}

/// The chips at the end of a note's meta line, then + Tag. A chip's × takes
/// its tag off, a tap narrows the list to it, and a drag moves it: the first
/// colours the note.
class NoteTagChips extends StatefulWidget {
  const NoteTagChips({super.key, required this.noteId});

  final String noteId;

  @override
  State<NoteTagChips> createState() => _NoteTagChipsState();
}

class _NoteTagChipsState extends State<NoteTagChips> {
  final _picker = OverlayPortalController();
  final _link = LayerLink();

  void _close() {
    if (_picker.isShowing) setState(_picker.hide);
  }

  @override
  Widget build(BuildContext context) {
    final shelf = TagShelf.maybeOf(context);
    if (shelf == null) return const SizedBox.shrink();
    final palette = context.palette;
    final tags = shelf.store.tagsOf(widget.noteId);
    void move(String dragged, String onto) {
      final ids = [for (final tag in tags) tag.id];
      final to = ids.indexOf(onto);
      ids
        ..remove(dragged)
        ..insert(to, dragged);
      shelf.store.setTags(widget.noteId, ids);
    }

    final add = TapRegion(
      groupId: _picker,
      onTapOutside: (_) => _close(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _picker,
          overlayChildBuilder: (context) => Align(
            alignment: Alignment.topLeft,
            child: CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomLeft,
              offset: const Offset(0, 6),
              child: TapRegion(
                groupId: _picker,
                child: TagPicker(
                  shelf: shelf,
                  noteId: widget.noteId,
                  onClose: _close,
                ),
              ),
            ),
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey('note-add-tag'),
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  setState(_picker.isShowing ? _picker.hide : _picker.show),
              child: Container(
                height: 22,
                padding: const EdgeInsets.only(left: 4, right: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KapyIcon(
                      KapyIcons.addRounded,
                      size: 12,
                      strokeWidth: 2,
                      color: palette.textTertiary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Tag',
                      style: _text(12.5, FontWeight.w500, palette.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final tag in tags) ...[
                  _TagChip(
                    tag: tag,
                    onFilter: () => shelf.onFilter(tag.id),
                    onRemove: () =>
                        shelf.store.removeTag(widget.noteId, tag.id),
                    onDropped: (dragged) => move(dragged, tag.id),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ),
        add,
      ],
    );
  }
}

class _TagChip extends StatefulWidget {
  const _TagChip({
    required this.tag,
    required this.onFilter,
    required this.onRemove,
    required this.onDropped,
  });

  final Tag tag;
  final VoidCallback onFilter;
  final VoidCallback onRemove;
  final ValueChanged<String> onDropped;

  @override
  State<_TagChip> createState() => _TagChipState();
}

class _TagChipState extends State<_TagChip> {
  bool _hovering = false;

  static const double _nameMax = 120;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tag = widget.tag;
    final colour = tagColourOf(tag.colour.v);
    final style = _text(12, FontWeight.w600, palette.textPrimary);
    final painter = TextPainter(
      text: TextSpan(text: tag.name.v, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout(maxWidth: _nameMax);
    final truncated = painter.didExceedMaxLines;
    painter.dispose();

    Widget chip({bool remove = false}) => Container(
      height: 22,
      padding: const EdgeInsets.only(left: 7, right: 8),
      decoration: BoxDecoration(
        color: colour?.card(palette) ?? palette.cardBackground,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TagDot(colour, size: 7),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _nameMax),
            child: Text(
              tag.name.v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (remove) ...[
            const SizedBox(width: 4),
            GestureDetector(
              key: ValueKey('tag-chip-remove-${tag.id}'),
              onTap: widget.onRemove,
              child: KapyIcon(
                KapyIcons.closeRounded,
                size: 11,
                strokeWidth: 2,
                color: palette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );

    final face = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        key: ValueKey('tag-chip-${tag.id}'),
        onTap: widget.onFilter,
        child: chip(remove: _hovering),
      ),
    );
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != tag.id,
      onAcceptWithDetails: (details) => widget.onDropped(details.data),
      builder: (context, _, _) => Draggable<String>(
        data: tag.id,
        feedback: Material(type: MaterialType.transparency, child: chip()),
        childWhenDragging: Opacity(opacity: 0.4, child: chip()),
        child: truncated ? Tooltip(message: tag.name.v, child: face) : face,
      ),
    );
  }
}

/// A tag's name as a field, in place of the row that shows it: ↵ keeps it,
/// esc or a click elsewhere leaves it. [onSubmit] says whether it was kept.
class TagNameField extends StatefulWidget {
  const TagNameField({
    super.key,
    this.initial = '',
    required this.onSubmit,
    required this.onCancel,
  });

  final String initial;
  final bool Function(String name) onSubmit;
  final VoidCallback onCancel;

  @override
  State<TagNameField> createState() => _TagNameFieldState();
}

class _TagNameFieldState extends State<TagNameField> {
  late final _name = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  bool _refused = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return TapRegion(
      onTapOutside: (_) => widget.onCancel(),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
        },
        child: Material(
          type: MaterialType.transparency,
          child: TextField(
            key: const ValueKey('tag-name-field'),
            controller: _name,
            autofocus: true,
            inputFormatters: [LengthLimitingTextInputFormatter(tagNameMax)],
            onChanged: (_) {
              if (_refused) setState(() => _refused = false);
            },
            onSubmitted: (name) {
              if (!widget.onSubmit(name)) setState(() => _refused = true);
            },
            style: _text(
              13,
              FontWeight.w500,
              _refused
                  ? Theme.of(context).colorScheme.error
                  : palette.textPrimary,
            ),
            decoration: const InputDecoration.collapsed(hintText: 'Tag name'),
          ),
        ),
      ),
    );
  }
}

/// ⋯ on a tag's row: Rename, Colour ▸ and Delete. Rename is the row's own,
/// which turns into a field.
Future<void> showTagActions(
  BuildContext context, {
  required TagStore store,
  required TagEntry entry,
  required Offset position,
  required VoidCallback onRename,
}) async {
  PopupMenuItem<String> item(KapyMenuAction action) => PopupMenuItem(
    key: ValueKey('tag-action-${action.value}'),
    value: action.value,
    height: 36,
    child: KapyMenuActionRow(action, touch: false),
  );
  final choice = await showKapyContextMenu<String>(
    context: context,
    globalPosition: position,
    items: [
      item(
        const KapyMenuAction(
          value: 'rename',
          label: 'Rename',
          icon: KapyIcons.editOutlined,
        ),
      ),
      item(
        const KapyMenuAction(
          value: 'colour',
          label: 'Colour',
          icon: KapyIcons.tagRounded,
          hint: '›',
        ),
      ),
      item(
        const KapyMenuAction(
          value: 'delete',
          label: 'Delete',
          icon: KapyIcons.deleteOutlined,
          destructive: true,
        ),
      ),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'rename':
      onRename();
    case 'colour':
      final palette = context.palette;
      final current = entry.tag.colour.v;
      final picked = await showKapyContextMenu<String>(
        context: context,
        globalPosition: position,
        items: [
          for (final key in [...tagColours, noTagColour])
            PopupMenuItem(
              key: ValueKey('tag-colour-$key'),
              value: key,
              height: 32,
              child: Row(
                children: [
                  TagDot(tagColourOf(key), size: 10),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      key == noTagColour
                          ? 'No colour'
                          : '${key[0].toUpperCase()}${key.substring(1)}',
                      style: _text(13, FontWeight.w500, palette.textPrimary),
                    ),
                  ),
                  if (key == current)
                    KapyIcon(
                      KapyIcons.checkRounded,
                      size: 14,
                      strokeWidth: 1.8,
                      color: palette.textSecondary,
                    ),
                ],
              ),
            ),
        ],
      );
      if (picked != null) store.recolour(entry.tag.id, picked);
    case 'delete':
      await deleteTag(context, store, entry);
  }
}

/// Asks once, deletes, and offers Undo, which puts the tag back on the same
/// notes in the same place.
Future<void> deleteTag(
  BuildContext context,
  TagStore store,
  TagEntry entry,
) async {
  final name = entry.tag.name.v;
  final overlay = Overlay.of(context, rootOverlay: true);
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete “$name”?'),
      content: Text(
        "It's on ${notesCount(entry.count)}. The notes stay as they are; only "
        "the tag goes, and notes it coloured take their next tag's colour.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('tag-delete-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (sure != true) return;
  store.delete(entry.tag.id);
  late final OverlayEntry toast;
  final timer = Timer(const Duration(seconds: 6), () => toast.remove());
  toast = OverlayEntry(
    builder: (context) {
      final palette = context.palette;
      return Positioned(
        left: 0,
        right: 0,
        bottom: 24,
        child: Center(
          child: Container(
            key: const ValueKey('tag-toast'),
            height: 36,
            padding: const EdgeInsets.only(left: 14, right: 4),
            decoration: BoxDecoration(
              color: palette.textPrimary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Deleted “$name”',
                  style: _text(13, FontWeight.w500, palette.paperColor),
                ),
                TextButton(
                  onPressed: () {
                    timer.cancel();
                    toast.remove();
                    store.restore(entry.tag.id);
                  },
                  child: Text(
                    'Undo',
                    style: _text(13, FontWeight.w600, palette.paperColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(toast);
}

/// Settings › Notes › Tags: Your tags with New tag, then a row per tag to
/// drag, rename, recolour or delete. The order here is the order everywhere.
class TagSettings extends StatefulWidget {
  const TagSettings({super.key, required this.store, required this.listed});

  final TagStore store;
  final List<TagEntry> Function() listed;

  @override
  State<TagSettings> createState() => _TagSettingsState();
}

class _TagSettingsState extends State<TagSettings> {
  bool _creating = false;
  String? _renaming;

  TagStore get _store => widget.store;

  /// [shown] in its new order, with any tag the list leaves out kept where
  /// it was among the rest.
  void _reorder(List<String> shown, int from, int to) {
    final moved = [...shown];
    final id = moved.removeAt(from);
    moved.insert(to, id);
    final listed = shown.toSet();
    var next = 0;
    _store.reorder([
      for (final tag in _store.tags)
        listed.contains(tag.id) ? moved[next++] : tag.id,
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final palette = context.palette;
      final entries = widget.listed();
      Widget line({Key? key, required List<Widget> children}) => Container(
        key: key,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.separator)),
        ),
        child: Row(children: children),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsRow(
            title: 'Your tags',
            trailing: SettingsRowButton(
              key: const ValueKey('settings-new-tag'),
              label: 'New tag',
              onPressed: () => setState(() => _creating = true),
            ),
          ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) =>
                _reorder([for (final entry in entries) entry.tag.id], from, to),
            children: [
              for (final (index, entry) in entries.indexed)
                line(
                  key: ValueKey('settings-tag-${entry.tag.id}'),
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: KapyIcon(
                          KapyIcons.dragRounded,
                          size: 14,
                          color: palette.textTertiary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    TagDot(tagColourOf(entry.tag.colour.v)),
                    const SizedBox(width: 9),
                    Expanded(
                      child: _renaming == entry.tag.id
                          ? TagNameField(
                              initial: entry.tag.name.v,
                              onSubmit: (name) {
                                final kept = _store.rename(entry.tag.id, name);
                                if (kept) setState(() => _renaming = null);
                                return kept;
                              },
                              onCancel: () => setState(() => _renaming = null),
                            )
                          : Text(
                              entry.tag.name.v,
                              style: _text(
                                13,
                                FontWeight.w500,
                                palette.textPrimary,
                              ),
                            ),
                    ),
                    Text(
                      notesCount(entry.count),
                      style: _text(12, FontWeight.w400, palette.textTertiary),
                    ),
                    const SizedBox(width: 6),
                    Builder(
                      builder: (context) => GestureDetector(
                        key: ValueKey('settings-tag-more-${entry.tag.id}'),
                        onTapUp: (details) => showTagActions(
                          context,
                          store: _store,
                          entry: entry,
                          position: details.globalPosition,
                          onRename: () =>
                              setState(() => _renaming = entry.tag.id),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: KapyIcon(
                            KapyIcons.moreRounded,
                            size: 16,
                            color: palette.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (_creating)
            line(
              children: [
                const SizedBox(width: 24),
                const TagDot(null),
                const SizedBox(width: 9),
                Expanded(
                  child: TagNameField(
                    onSubmit: (name) {
                      final made = _store.create(name) != null;
                      if (made) setState(() => _creating = false);
                      return made;
                    },
                    onCancel: () => setState(() => _creating = false),
                  ),
                ),
              ],
            ),
        ],
      );
    },
  );
}
