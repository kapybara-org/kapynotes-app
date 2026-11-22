import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/blob_store.dart';
import '../../data/note_attachment.dart';
import '../../data/task_board.dart';
import '../../data/task_details.dart';
import '../../images/note_image_provider.dart';
import '../page_toolbar.dart';
import '../sidebar_timestamp.dart';
import '../window_drag_area.dart';
import 'task_marks.dart';
import 'tasks_controller.dart';

/// The details of one task, beside the list on a desktop and edited live in
/// the note the task already lives in.
class TaskDetailsSheet extends StatefulWidget {
  const TaskDetailsSheet({
    super.key,
    required this.item,
    required this.tasks,
    required this.onClose,
    required this.onOpenNote,
    this.images,
    this.phone = false,
  });

  final TaskItem item;
  final TasksController tasks;
  final VoidCallback onClose;
  final VoidCallback onOpenNote;
  final BlobStore? images;

  /// On a phone's task page: the details alone, as M14 has them, larger and
  /// with each picture between the words where its mark sits. The page draws
  /// the task, its way back and Open in note.
  final bool phone;

  @override
  State<TaskDetailsSheet> createState() => _TaskDetailsSheetState();
}

class _TaskDetailsSheetState extends State<TaskDetailsSheet> {
  /// A run of picture marks, with the line breaks around it.
  static final _markRun = RegExp('\n?\uFFFC(?:\n?\uFFFC)*\n?');

  /// The words around each run of picture marks, a field each, and the runs
  /// between them exactly as the details hold them, so a write puts every
  /// mark back where it was. One field and no runs on a desktop.
  List<TextEditingController> _parts = const [];
  List<FocusNode> _focuses = const [];
  List<String> _marks = const [];

  /// Which fields were empty when the details were last read.
  List<bool> _wereEmpty = const [];
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _show(_plain(widget.item));
  }

  @override
  void didUpdateWidget(TaskDetailsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _adding = false;
      _show(_plain(widget.item));
      return;
    }
    final plain = _plain(widget.item);
    if (plain != _text && !_focuses.any((focus) => focus.hasFocus)) {
      _show(plain);
    }
  }

  @override
  void dispose() {
    for (final part in _parts) {
      part.dispose();
    }
    for (final focus in _focuses) {
      focus.dispose();
    }
    super.dispose();
  }

  String _plain(TaskItem item) => taskDetailsWords(item.note.body, item.line);

  void _show(String plain) {
    final runs = widget.phone
        ? _markRun.allMatches(plain).toList()
        : const <RegExpMatch>[];
    final parts = <String>[];
    var from = 0;
    for (final run in runs) {
      parts.add(plain.substring(from, run.start));
      from = run.end;
    }
    parts.add(plain.substring(from));
    final marks = [for (final run in runs) run[0]!];
    _wereEmpty = [for (final part in parts) part.isEmpty];
    if (listEquals(marks, _marks) && parts.length == _parts.length) {
      for (var i = 0; i < parts.length; i++) {
        if (_parts[i].text != parts[i]) _parts[i].text = parts[i];
      }
      return;
    }
    final old = <ChangeNotifier>[..._parts, ..._focuses];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final notifier in old) {
        notifier.dispose();
      }
    });
    _marks = marks;
    _parts = [for (final part in parts) TextEditingController(text: part)];
    _focuses = [for (final _ in parts) FocusNode()];
  }

  /// The details as the fields hold them, each run of marks back in its
  /// place. Words emptied take a line break with them, so no blank line is
  /// left in the note, and words written before the first run or after the
  /// last where there were none bring one, so they never share the
  /// picture's line. A field left as it was read puts back exactly what
  /// was there.
  String get _text {
    final parts = [for (final part in _parts) part.text];
    final marks = [..._marks];
    for (var i = 0; i < parts.length && marks.isNotEmpty; i++) {
      final emptied = parts[i].isEmpty && !_wereEmpty[i];
      final written = parts[i].isNotEmpty && _wereEmpty[i];
      if (i == 0) {
        final run = marks.first;
        if (emptied && run.startsWith('\n')) marks.first = run.substring(1);
        if (written && !run.startsWith('\n')) marks.first = '\n$run';
      } else if (i == parts.length - 1) {
        final run = marks.last;
        if (emptied && run.endsWith('\n')) {
          marks.last = run.substring(0, run.length - 1);
        }
        if (written && !run.endsWith('\n')) marks.last = '$run\n';
      } else if (emptied &&
          marks[i - 1].endsWith('\n') &&
          marks[i].startsWith('\n')) {
        marks[i] = marks[i].substring(1);
      }
    }
    return [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) marks[i - 1],
        parts[i],
      ],
    ].join();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final item = widget.item;
    final details = item.details;
    final empty = !_adding && _text.trim().isEmpty && details == null;
    // A note shared to view only: its details are shown, never taken, since
    // the controller would drop every write without a word.
    final editable = widget.tasks.canEdit(item.note);
    final phone = widget.phone;
    // Set flush with the words above, as Paper has them, and 44 pt on a phone.
    final link = TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: Size(0, phone ? 44 : 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      alignment: Alignment.centerLeft,
    );
    Widget field(int i) => TextField(
      controller: _parts[i],
      focusNode: _focuses[i],
      readOnly: !editable,
      minLines: 1,
      maxLines: null,
      style: uiStyle(
        phone ? 16 : 13,
        phone ? 22 : 20,
        FontWeight.w400,
        palette.textSecondary,
      ),
      decoration: InputDecoration(
        border: InputBorder.none,
        filled: false,
        isCollapsed: true,
        contentPadding: EdgeInsets.zero,
        hintText: editable && _marks.isEmpty ? 'Add details' : null,
      ),
      onChanged: (_) => widget.tasks.setDetails(widget.item, _text),
    );
    final words = empty && editable
        ? Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: link,
              onPressed: () {
                setState(() => _adding = true);
                unawaited(widget.tasks.openDetails(widget.item));
                _focuses.first.requestFocus();
              },
              child: Text(
                'Add details',
                style: uiStyle(
                  phone ? 16 : 13,
                  phone ? 22 : 20,
                  FontWeight.w500,
                  palette.accentText,
                ),
              ),
            ),
          )
        : empty
        ? null
        : field(0);
    final hint = empty || !editable
        ? Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              editable
                  ? 'Writes under the task, in its note.'
                  : 'You can view this note, not change it.',
              style: uiStyle(13, 18, FontWeight.w400, palette.textTertiary),
            ),
          )
        : null;
    final openNote = Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        style: link,
        onPressed: widget.onOpenNote,
        child: Text(
          'Open in note',
          style: uiStyle(13, 16, FontWeight.w500, palette.accentText),
        ),
      ),
    );
    if (phone) {
      // M14: each picture where its mark sits, 12 pt from the words around
      // it, and the words on either side in a field of their own.
      final body = item.note.body;
      final at = [
        if (details != null)
          for (var i = details.start; i < details.end; i++)
            if (body.codeUnitAt(i) == 0xFFFC) i,
      ];
      final column = <Widget>[
        if (words != null && (editable || _parts.first.text.isNotEmpty)) words,
      ];
      var mark = 0;
      for (var i = 1; i < _parts.length; i++) {
        for (final _ in '\uFFFC'.allMatches(_marks[i - 1])) {
          if (details != null && mark < at.length) {
            column.add(
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: TaskDetailPicture(
                  item: item,
                  details: details,
                  images: widget.images,
                  at: at[mark],
                  size: 96,
                  width: 200,
                ),
              ),
            );
          }
          mark++;
        }
        if (editable || _parts[i].text.isNotEmpty) column.add(field(i));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [...column, ?hint],
      );
    }
    final picture = details == null
        ? null
        : TaskDetailPicture(
            item: item,
            details: details,
            images: widget.images,
          );
    // D09: a column against the window's right edge, its header in the page
    // bar's row, and Open in note straight under the words.
    final edge = BorderSide(color: palette.railBorder);
    return DecoratedBox(
      key: const ValueKey('tasks-details'),
      decoration: BoxDecoration(border: Border(left: edge)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const ValueKey('tasks-details-header'),
            height: AppControlMetrics.scaleBar(context, PageToolbar.height),
            padding: const EdgeInsets.only(left: 20, right: 12),
            foregroundDecoration: BoxDecoration(border: Border(bottom: edge)),
            child: Row(
              children: [
                Text(
                  'Details',
                  style: uiStyle(13, 18, FontWeight.w500, palette.textPrimary),
                ),
                const Expanded(child: WindowDragArea(child: SizedBox.expand())),
                TextButton(
                  onPressed: widget.onClose,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    'Close',
                    style: uiStyle(
                      13,
                      18,
                      FontWeight.w500,
                      palette.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    item.words,
                    style: uiStyle(
                      15,
                      24,
                      FontWeight.w500,
                      palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ?picture,
                  ?words,
                  ?hint,
                  const SizedBox(height: 8),
                  openNote,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A picture under a task, small, or a play mark when it is a video.
class TaskDetailPicture extends StatelessWidget {
  const TaskDetailPicture({
    super.key,
    required this.item,
    required this.details,
    required this.images,
    this.at,
    this.size = 72,
    this.width,
  });

  final TaskItem item;
  final TaskDetails details;
  final BlobStore? images;

  /// The mark it draws, by where that sits in the note. Without it, the
  /// first picture under the task.
  final int? at;

  /// How tall it is, and how wide too unless [width] says otherwise.
  final double size;
  final double? width;

  @override
  Widget build(BuildContext context) {
    if (!details.hasMedia) return const SizedBox.shrink();
    NoteImageRef? picture;
    var video = false;
    for (final ref in item.note.attachments) {
      final here = at == null
          ? ref.offset >= details.start && ref.offset <= details.end
          : ref.offset == at;
      if (!here) continue;
      if (ref is NoteImageRef && picture == null) picture = ref;
      if (ref is NoteVideoRef) video = true;
    }
    final store = images;
    final child = picture != null && store != null
        ? Image(
            image: NoteImageProvider(hash: picture.hash, store: store),
            width: width ?? size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) => _mark(context, video),
          )
        : _mark(context, video);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.compact),
          child: SizedBox(width: width ?? size, height: size, child: child),
        ),
      ),
    );
  }

  Widget _mark(BuildContext context, bool video) => ColoredBox(
    color: context.palette.controlBackground,
    child: Center(
      child: KapyIcon(
        video ? KapyIcons.playRounded : KapyIcons.imageOutlined,
        size: 18,
        color: context.palette.textTertiary,
      ),
    ),
  );
}

/// A task opened from a phone's Tasks (M14): a page pushed over the list and
/// under the bar, with the way back at the left and Open in note at the
/// right, then the task, its note and day, and the details it holds, edited
/// live in that note as a window edits them beside the list.
class PhoneTaskPage extends StatelessWidget {
  const PhoneTaskPage({
    super.key,
    required this.item,
    required this.tasks,
    required this.label,
    required this.onBack,
    required this.onOpenNote,
    this.images,
  });

  final TaskItem item;
  final TasksController tasks;

  /// The note's name as the task's mark shows it.
  final String label;
  final VoidCallback onBack;
  final VoidCallback onOpenNote;
  final BlobStore? images;

  /// "Today, Wed 19", "Yesterday, Tue 18", then "Sat 14 Nov".
  String _added(DateTime now) {
    final at = DateTime.fromMillisecondsSinceEpoch(item.entry.addedAt);
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(at.year, at.month, at.day)).inDays;
    return switch (days) {
      <= 0 => 'Today, ${SidebarTimestamp.weekdayAndDay(at)}',
      1 => 'Yesterday, ${SidebarTimestamp.weekdayAndDay(at)}',
      _ => SidebarTimestamp.shortDay(at, now: now),
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final editable = tasks.canEdit(item.note);
    final done = item.line.done;
    return Material(
      color: palette.paperColor,
      // Holds a sideways swipe, so it never turns Home to Notes underneath;
      // iOS's edge swipe still takes the page back.
      child: GestureDetector(
        onHorizontalDragStart: (_) {},
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 21),
              child: Row(
                children: [
                  PageBackButton(to: 'Tasks', onPressed: onBack),
                  const Spacer(),
                  TextButton(
                    key: const ValueKey('phone-task-open-note'),
                    onPressed: onOpenNote,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(44, 44),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Open in note',
                      style: uiStyle(
                        AppTypeScale.body,
                        22,
                        FontWeight.w400,
                        palette.accentText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  9,
                  0,
                  21,
                  MediaQuery.viewInsetsOf(context).bottom +
                      MediaQuery.paddingOf(context).bottom +
                      24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _PhoneTaskBox(
                          item: item,
                          tasks: tasks,
                          editable: editable,
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 9),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(
                                    item.words,
                                    style:
                                        uiStyle(
                                          18,
                                          26,
                                          FontWeight.w500,
                                          done
                                              ? palette.textTertiary
                                              : palette.textPrimary,
                                        ).copyWith(
                                          decoration: done
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                  ),
                                ),
                                Text(
                                  '$label · ${_added(tasks.now())}',
                                  style: uiStyle(
                                    14,
                                    20,
                                    FontWeight.w400,
                                    palette.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 44, top: 14),
                      child: TaskDetailsSheet(
                        item: item,
                        tasks: tasks,
                        onClose: onBack,
                        onOpenNote: onOpenNote,
                        images: images,
                        phone: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The task's box at the top of its page, 44 pt to tap: done or not done,
/// in its note.
class _PhoneTaskBox extends StatelessWidget {
  const _PhoneTaskBox({
    required this.item,
    required this.tasks,
    required this.editable,
  });

  final TaskItem item;
  final TasksController tasks;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final sage = Theme.of(context).colorScheme.primary;
    final done = item.line.done;
    final tick = editable
        ? () => unawaited(tasks.setDone(item, done: !done))
        : null;
    return Semantics(
      checked: done,
      label: item.words,
      excludeSemantics: true,
      onTap: tick,
      child: GestureDetector(
        key: const ValueKey('phone-details-box'),
        behavior: HitTestBehavior.opaque,
        onTap: tick,
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: Opacity(
              opacity: editable ? 1 : lockedBoxOpacity,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: done ? sage : null,
                  border: Border.all(
                    color: done ? sage : palette.checkboxBorder,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: done
                    ? KapyIcon(
                        KapyIcons.checkRounded,
                        size: 14,
                        color: palette.paperColor,
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
