import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/blob_store.dart';
import '../../data/note_attachment.dart';
import '../../data/task_board.dart';
import '../../data/task_details.dart';
import '../../images/note_image_provider.dart';
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

  /// Inside a phone's sheet: no frame and no Close, since the sheet itself
  /// is the frame and is pulled down to close, and the task has its box.
  final bool phone;

  @override
  State<TaskDetailsSheet> createState() => _TaskDetailsSheetState();
}

class _TaskDetailsSheetState extends State<TaskDetailsSheet> {
  late final TextEditingController _words = TextEditingController(
    text: _plain(widget.item),
  );
  late final FocusNode _focus = FocusNode();
  bool _adding = false;

  @override
  void didUpdateWidget(TaskDetailsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _adding = false;
      _words.text = _plain(widget.item);
      return;
    }
    final plain = _plain(widget.item);
    if (plain != _words.text && !_focus.hasFocus) _words.text = plain;
  }

  @override
  void dispose() {
    _words.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _plain(TaskItem item) => taskDetailsWords(item.note.body, item.line);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final item = widget.item;
    final details = item.details;
    final empty = !_adding && _words.text.trim().isEmpty && details == null;
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
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (phone)
              _PhoneTaskName(
                item: item,
                tasks: widget.tasks,
                editable: editable,
              )
            else ...[
              Row(
                children: [
                  Text(
                    'Details',
                    style: uiStyle(
                      12,
                      16,
                      FontWeight.w600,
                      palette.textTertiary,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: widget.onClose,
                    child: Text(
                      'Close',
                      style: uiStyle(
                        13,
                        16,
                        FontWeight.w500,
                        palette.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                item.words,
                style: uiStyle(15, 24, FontWeight.w500, palette.textPrimary),
              ),
            ],
            const SizedBox(height: 8),
            if (details != null)
              TaskDetailPicture(
                item: item,
                details: details,
                images: widget.images,
              ),
            if (empty && editable)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: link,
                  onPressed: () {
                    setState(() => _adding = true);
                    unawaited(widget.tasks.openDetails(widget.item));
                    _focus.requestFocus();
                  },
                  child: Text(
                    'Add details',
                    style: uiStyle(14, 22, FontWeight.w500, palette.accentText),
                  ),
                ),
              )
            else if (!empty)
              TextField(
                controller: _words,
                focusNode: _focus,
                readOnly: !editable,
                minLines: 3,
                maxLines: 8,
                style: uiStyle(14, 22, FontWeight.w400, palette.textPrimary),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  filled: false,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                  hintText: editable ? 'Add details' : null,
                ),
                onChanged: (value) =>
                    widget.tasks.setDetails(widget.item, value),
              ),
            if (empty || !editable)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  editable
                      ? 'Writes under the task, in its note.'
                      : 'You can view this note, not change it.',
                  style: uiStyle(13, 18, FontWeight.w400, palette.textTertiary),
                ),
              ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: link,
                onPressed: widget.onOpenNote,
                child: Text(
                  'Open in note',
                  style: uiStyle(13, 16, FontWeight.w500, palette.accentText),
                ),
              ),
            ),
            Text(
              item.note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: uiStyle(12, 16, FontWeight.w400, palette.textTertiary),
            ),
          ],
        ),
      ],
    );
    if (phone) return body;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(color: palette.separator),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 26),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// The first picture under a task, small, or a play mark when it is a video.
class TaskDetailPicture extends StatelessWidget {
  const TaskDetailPicture({
    super.key,
    required this.item,
    required this.details,
    required this.images,
    this.size = 72,
  });

  final TaskItem item;
  final TaskDetails details;
  final BlobStore? images;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!details.hasMedia) return const SizedBox.shrink();
    NoteImageRef? picture;
    var video = false;
    for (final ref in item.note.attachments) {
      if (ref.offset < details.start || ref.offset > details.end) continue;
      if (ref is NoteImageRef && picture == null) picture = ref;
      if (ref is NoteVideoRef) video = true;
    }
    final store = images;
    final child = picture != null && store != null
        ? Image(
            image: NoteImageProvider(hash: picture.hash, store: store),
            width: size,
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
          child: SizedBox(width: size, height: size, child: child),
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

/// A task's details on a phone: a sheet that opens at half the screen and can
/// be pulled up to nearly all of it. The same body the desktop shows beside the
/// list, so a phone and a window edit one thing.
class PhoneTaskDetailsSheet extends StatefulWidget {
  const PhoneTaskDetailsSheet({
    super.key,
    required this.item,
    required this.tasks,
    required this.onClose,
    required this.onOpenNote,
    this.images,
  });

  final TaskItem item;
  final TasksController tasks;
  final VoidCallback onClose;
  final VoidCallback onOpenNote;
  final BlobStore? images;

  @override
  State<PhoneTaskDetailsSheet> createState() => _PhoneTaskDetailsSheetState();
}

class _PhoneTaskDetailsSheetState extends State<PhoneTaskDetailsSheet> {
  /// Where the top edge sits, as a share of the space the sheet has.
  static const double _half = 0.5;
  static const double _full = 0.92;
  static const double _dismiss = 0.32;

  double _open = _half;
  double? _dragged;

  void _dragUpdate(DragUpdateDetails details, double height) {
    final from = _dragged ?? _open;
    _dragged = (from - details.delta.dy / height).clamp(0.1, _full);
    setState(() => _open = _dragged!);
  }

  void _dragEnd(DragEndDetails details) {
    final from = _dragged;
    _dragged = null;
    if (from == null) return;
    if (from < _dismiss) {
      widget.onClose();
      return;
    }
    setState(() => _open = from >= (_half + _full) / 2 ? _full : _half);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // Above the keyboard while the details are typed into, and clear of the
    // home indicator at rest.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          // The route is the whole screen tall, so the dimmed list above the
          // sheet is this, and a tap on it closes the sheet as the barrier
          // would. A pull anywhere on the sheet moves it.
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('phone-details-scrim'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) =>
                      _dragUpdate(details, height),
                  onVerticalDragEnd: _dragEnd,
                  child: AnimatedContainer(
                    key: const ValueKey('phone-details-body'),
                    duration: _dragged == null
                        ? const Duration(milliseconds: 180)
                        : Duration.zero,
                    curve: Curves.easeOutCubic,
                    height: height * _open,
                    decoration: BoxDecoration(
                      color: palette.editorBackground,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(AppRadii.surface),
                      ),
                      border: Border(top: BorderSide(color: palette.separator)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          key: const ValueKey('phone-details-grabber'),
                          height: 22,
                          child: Center(
                            child: Container(
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(
                                color: palette.textTertiary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          // Pulled below half, the body keeps its half-height layout
                          // and slides out of view rather than squeezing.
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.topCenter,
                              minHeight: 0,
                              maxHeight: math.max(
                                height * _open - 22,
                                height * _half - 22,
                              ),
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  12 + bottom,
                                ),
                                child: TaskDetailsSheet(
                                  item: widget.item,
                                  tasks: widget.tasks,
                                  onClose: widget.onClose,
                                  onOpenNote: widget.onOpenNote,
                                  images: widget.images,
                                  phone: true,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The task at the top of a phone's sheet: its box, 44 pt to tap, and its
/// name beside it.
class _PhoneTaskName extends StatelessWidget {
  const _PhoneTaskName({
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
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
              child: Align(
                alignment: Alignment.centerLeft,
                child: Opacity(
                  opacity: editable ? 1 : lockedBoxOpacity,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: done ? sage : null,
                      border: Border.all(
                        color: done ? sage : palette.checkboxBorder,
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: done
                        ? KapyIcon(
                            KapyIcons.checkRounded,
                            size: 15,
                            strokeWidth: 2.2,
                            color: palette.paperColor,
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              item.words,
              style: uiStyle(
                16,
                24,
                FontWeight.w500,
                done ? palette.textTertiary : palette.textPrimary,
              ).copyWith(decoration: done ? TextDecoration.lineThrough : null),
            ),
          ),
        ),
      ],
    );
  }
}
