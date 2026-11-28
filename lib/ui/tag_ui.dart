import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
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
    required this.untagged,
    required this.isShared,
    required this.onFilter,
    required super.child,
  });

  final TagStore store;

  /// The tags the lists offer, in the person's order, each with its count.
  /// While Hidden is locked no Hidden note counts, and a tag found only on
  /// Hidden notes is left out, so neither gives Hidden away.
  final List<TagEntry> Function() listed;

  /// How many of the notes those counts count carry no tag.
  final int Function() untagged;
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
  fontWeight: AppWeight.font(AppWeight.axisOf(weight)),
  fontVariations: AppWeight.wght(AppWeight.axisOf(weight)),
  color: color,
);

/// Every refusal of a name says the same, so a tag the lists leave out
/// while Hidden is locked reads as an ordinary clash.
const chooseAnotherName = 'Choose another name';

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
  const TagPopover({super.key, required this.child, this.width = defaultWidth});

  static const double defaultWidth = 248;

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
          borderRadius: BorderRadius.circular(AppRadii.surface),
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
/// every note in [noteIds]. ↵ adds or takes off, ↑↓ move, esc closes.
class TagPicker extends StatefulWidget {
  const TagPicker({
    super.key,
    required this.shelf,
    required this.noteIds,
    required this.onClose,
  });

  final TagShelf shelf;
  final List<String> noteIds;
  final VoidCallback onClose;

  @override
  State<TagPicker> createState() => _TagPickerState();
}

/// What a tag list for some notes does: the field's words find tags or name
/// a new one, a row ticks or unticks, and a refused name or a full note says
/// why. A tag is ticked when every one of the notes has it and dashed when
/// only some do. Ticking puts it on the rest, and unticking takes it off them
/// all, as does a dashed tag that the notes without it have no room for. The
/// popover and ⌘K's Tag note... both draw it.
class TagPickerController extends ChangeNotifier {
  TagPickerController({required this.shelf, required this.noteIds});

  final TagShelf shelf;
  final List<String> noteIds;
  final query = TextEditingController();
  int _at = 0;
  String? _problem;

  TagStore get _store => shelf.store;

  /// The row ↵ acts on.
  int get at => _at;
  String? get problem => _problem;

  static const _tooMany = 'A note takes at most $noteTagsMax tags.';

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  /// Rows are reached with the pointer or the arrows, and the field's words
  /// start the list over.
  set at(int index) {
    _at = index;
    notifyListeners();
  }

  void typed() {
    _at = 0;
    _problem = null;
    notifyListeners();
  }

  List<TagEntry> matches() {
    final text = query.text.trim().toLowerCase();
    return [
      for (final entry in shelf.listed())
        if (entry.tag.name.v.toLowerCase().contains(text)) entry,
    ];
  }

  /// True when every one of the notes has [tagId], null when only some of
  /// them do, and false when none does.
  bool? isOn(String tagId) {
    final holding = noteIds.where((noteId) => _has(noteId, tagId)).length;
    return holding == noteIds.length ? true : (holding == 0 ? false : null);
  }

  bool _has(String noteId, String tagId) =>
      _store.tagsOf(noteId).any((tag) => tag.id == tagId);

  void toggle(String tagId) {
    final without = [
      for (final noteId in noteIds)
        if (!_has(noteId, tagId)) noteId,
    ];
    final room = without.any(
      (noteId) => _store.tagsOf(noteId).length < noteTagsMax,
    );
    if (without.length < noteIds.length && !room) {
      for (final noteId in noteIds) {
        _store.removeTag(noteId, tagId);
      }
      _problem = null;
    } else {
      _problem = _add(tagId, without);
    }
    notifyListeners();
  }

  /// Puts [tagId] on [ids], and says how far it went where some of them had
  /// no room for it.
  String? _add(String tagId, List<String> ids) {
    var full = 0;
    for (final noteId in ids) {
      if (!_store.addTag(noteId, tagId)) full++;
    }
    if (full == 0) return null;
    final holding = noteIds.where((noteId) => _has(noteId, tagId)).length;
    if (holding == 0) return _tooMany;
    return 'Added to $holding of ${noteIds.length} notes. '
        '${full == 1 ? 'One already has' : '$full already have'} '
        '$noteTagsMax tags.';
  }

  /// A name another tag has, in any case, picks that tag. One the lists
  /// leave out, found only on Hidden notes while Hidden is locked, is
  /// neither picked nor shown by its name.
  void create() {
    final existing = _store.named(query.text);
    if (existing != null &&
        !shelf.listed().any((entry) => entry.tag.id == existing.id)) {
      _problem = chooseAnotherName;
    } else if (noteIds.every(
      (noteId) => _store.tagsOf(noteId).length >= noteTagsMax,
    )) {
      _problem = _tooMany;
    } else if (_store.create(query.text) case final tag?) {
      query.clear();
      _problem = _add(tag.id, noteIds);
      _at = 0;
    } else {
      _problem = 'A tag name is 1 to $tagNameMax characters.';
    }
    notifyListeners();
  }

  void activate() {
    final matches = this.matches();
    if (matches.isNotEmpty) {
      return toggle(matches[_at.clamp(0, matches.length - 1)].tag.id);
    }
    if (query.text.trim().isNotEmpty) create();
  }

  void move(int by) {
    final count = matches().length;
    if (count == 0) return;
    _at = (_at + by).clamp(0, count - 1);
    notifyListeners();
  }
}

class _TagPickerState extends State<TagPicker> {
  late final _picker = TagPickerController(
    shelf: widget.shelf,
    noteIds: widget.noteIds,
  );

  @override
  void dispose() {
    _picker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_picker.shelf.store, _picker]),
    builder: (context, _) {
      final palette = context.palette;
      final matches = _picker.matches();
      final query = _picker.query.text.trim();
      Widget row({
        required Key key,
        required int index,
        required Widget leading,
        required String label,
        String? count,
        bool? ticked = false,
        required VoidCallback onTap,
      }) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _picker.at = index,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: index == _picker.at ? palette.hover : null,
              borderRadius: BorderRadius.circular(AppRadii.compact),
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
                    style: _text(13, FontWeight.w400, palette.textPrimary),
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
                  child: ticked == false
                      ? null
                      : KapyIcon(
                          ticked == null
                              ? KapyIcons.removeRounded
                              : KapyIcons.checkRounded,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
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
            ticked: _picker.isOn(entry.tag.id),
            onTap: () => _picker.toggle(entry.tag.id),
          ),
        if (matches.isEmpty && query.isNotEmpty)
          row(
            key: const ValueKey('tag-create'),
            index: 0,
            leading: KapyIcon(
              KapyIcons.addRounded,
              size: 12,
              color: palette.textTertiary,
            ),
            label: 'Create “$query”',
            onTap: _picker.create,
          ),
      ];
      final problem = _picker.problem;
      return TagPopover(
        key: const ValueKey('tag-picker'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.noteIds.any(widget.shelf.isShared))
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Text(
                  widget.noteIds.length == 1
                      ? 'Shared note: your tags and their colours show only '
                            'to you.'
                      : 'Your tags and their colours show only to you, on '
                            'shared notes too.',
                  style: _text(12, FontWeight.w400, palette.textTertiary),
                ),
              ),
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _picker.move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _picker.move(-1),
                const SingleActivator(LogicalKeyboardKey.enter):
                    _picker.activate,
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
                        key: const ValueKey('tag-picker-field'),
                        controller: _picker.query,
                        autofocus: true,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(tagNameMax),
                        ],
                        onChanged: (_) => _picker.typed(),
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
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 30.0 * 8),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: rows,
                ),
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

/// The tag list for [noteIds], opened from [spot]: where a note's menu or
/// the picked notes' sat, so it takes the menu's place.
Future<void> showTagPickerAt(
  BuildContext context,
  MenuSpot spot,
  List<String> noteIds,
) async {
  final shelf = TagShelf.maybeOf(context);
  if (shelf == null) return;
  await showKapyPopover<void>(
    context: context,
    barrierLabel: 'Close tags',
    pageBuilder: (context, _, _) => CustomSingleChildLayout(
      delegate: PopoverAtSpot(
        spot,
        mediaPadding: MediaQuery.paddingOf(context),
      ),
      child: TagPicker(
        shelf: shelf,
        noteIds: noteIds,
        onClose: () => Navigator.of(context).pop(),
      ),
    ),
  );
}

/// Lays a popover out with its corner at [point], kept inside the window.
class PopoverAtPoint extends SingleChildLayoutDelegate {
  PopoverAtPoint(this.point);

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
  bool shouldRelayout(PopoverAtPoint oldDelegate) => oldDelegate.point != point;
}

/// The chips at the end of a note's meta line. A chip's × takes its tag off,
/// a tap narrows the list to it, and a drag moves it: the first colours the
/// note.
class NoteTagChips extends StatelessWidget {
  const NoteTagChips({super.key, required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context) {
    final shelf = TagShelf.maybeOf(context);
    if (shelf == null) return const SizedBox.shrink();
    final tags = shelf.store.tagsOf(noteId);
    if (tags.isEmpty) return const SizedBox.shrink();
    void move(String dragged, String onto) {
      final ids = [for (final tag in tags) tag.id];
      final to = ids.indexOf(onto);
      ids
        ..remove(dragged)
        ..insert(to, dragged);
      shelf.store.setTags(noteId, ids);
    }

    // Past 360, or the width there is, the chips scroll, so nothing runs off
    // the line.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tag in tags) ...[
              _TagChip(
                tag: tag,
                onFilter: () => shelf.onFilter(tag.id),
                onRemove: () => shelf.store.removeTag(noteId, tag.id),
                onDropped: (dragged) => move(dragged, tag.id),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

/// + Tag after a note's chips, which opens the list of tags under it. A
/// phone's note adds tags from More instead.
class NoteAddTag extends StatefulWidget {
  const NoteAddTag({super.key, required this.noteId});

  final String noteId;

  @override
  State<NoteAddTag> createState() => _NoteAddTagState();
}

class _NoteAddTagState extends State<NoteAddTag> {
  final _picker = OverlayPortalController();

  /// Where the list opened: under + Tag, inside the window. It stays there
  /// while it's open, even when + Tag steps aside from the line.
  Offset _opened = Offset.zero;

  void _close() {
    if (_picker.isShowing) setState(_picker.hide);
  }

  void _toggle() {
    if (_picker.isShowing) return _close();
    final box = context.findRenderObject()! as RenderBox;
    setState(() {
      _opened = box.localToGlobal(box.size.bottomLeft(const Offset(0, 6)));
      _picker.show();
    });
  }

  @override
  Widget build(BuildContext context) {
    final shelf = TagShelf.maybeOf(context);
    if (shelf == null) return const SizedBox.shrink();
    final palette = context.palette;
    return TapRegion(
      groupId: _picker,
      onTapOutside: (_) => _close(),
      child: OverlayPortal(
        controller: _picker,
        overlayChildBuilder: (context) => CustomSingleChildLayout(
          delegate: PopoverAtPoint(_opened),
          child: TapRegion(
            groupId: _picker,
            child: TagPicker(
              shelf: shelf,
              noteIds: [widget.noteId],
              onClose: _close,
            ),
          ),
        ),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('note-add-tag'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: Container(
              // A phone's target is 44 pt tall; the pill stays small.
              height: AppPlatform.hasPointer ? 22 : 44,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 4, right: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  KapyIcon(
                    KapyIcons.addRounded,
                    size: 12,
                    color: palette.textTertiary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Tag',
                    style: _text(13, FontWeight.w400, palette.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
    final style = _text(12, FontWeight.w400, palette.textSecondary);
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TagDot(colour, size: 6),
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
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('tag-name-field'),
                  controller: _name,
                  autofocus: true,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(tagNameMax),
                  ],
                  onChanged: (_) {
                    if (_refused) setState(() => _refused = false);
                  },
                  onEditingComplete: () {},
                  onSubmitted: (name) {
                    if (!widget.onSubmit(name)) setState(() => _refused = true);
                  },
                  style: _text(
                    13,
                    FontWeight.w400,
                    _refused
                        ? Theme.of(context).colorScheme.error
                        : palette.textPrimary,
                  ),
                  decoration: const InputDecoration.collapsed(
                    hintText: 'Tag name',
                  ),
                ),
              ),
              if (_refused)
                Text(
                  chooseAnotherName,
                  key: const ValueKey('tag-name-refused'),
                  style: _text(
                    12,
                    FontWeight.w400,
                    Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ⋯ on a tag's row: Rename, Colour… and Delete. Rename is the row's own,
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
          label: 'Colour…',
          icon: KapyIcons.tagRounded,
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
                      style: _text(13, FontWeight.w400, palette.textPrimary),
                    ),
                  ),
                  if (key == current)
                    KapyIcon(
                      KapyIcons.checkRounded,
                      size: 14,
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
Future<void> deleteTag(BuildContext context, TagStore store, TagEntry entry) {
  final name = entry.tag.name.v;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete “$name”?'),
      content: Text(
        "It's on ${notesCount(entry.count)}. The notes stay as they are; only "
        "the tag goes, and notes it coloured take their next tag's colour.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('tag-delete-confirm'),
          // The toast goes up from the dialog, whose overlay outlives the
          // menu that asked: that menu may close while the dialog is open.
          onPressed: () {
            store.delete(entry.tag.id);
            Toast.show(
              context,
              'Deleted “$name”',
              action: 'Undo',
              onAction: () => store.restore(entry.tag.id),
            );
            Navigator.of(context).pop();
          },
          child: const Text('Delete'),
        ),
      ],
    ),
  );
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
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: children),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsRow(
            title: 'Your tags',
            subtitle:
                "A note takes its first tag's colour. Drag to change the "
                'order everywhere. Only you see your tags.',
            trailing: SettingsRowButton(
              key: const ValueKey('settings-new-tag'),
              label: 'New tag',
              onPressed: () => setState(() => _creating = true),
            ),
          ),
          if (entries.isNotEmpty || _creating)
            Divider(height: 1, thickness: 1, color: palette.separator),
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
                    TagDot(tagColourOf(entry.tag.colour.v), size: 10),
                    const SizedBox(width: 10),
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _text(
                                13,
                                FontWeight.w400,
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
                            KapyIcons.moreVerticalRounded,
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
                const TagDot(null, size: 10),
                const SizedBox(width: 10),
                Expanded(
                  child: TagNameField(
                    onSubmit: (name) {
                      if (_store.named(name) != null) return false;
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
