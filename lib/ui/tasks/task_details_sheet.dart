import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/blob_store.dart';
import '../../data/note_attachment.dart';
import '../../data/task_board.dart';
import '../../data/task_details.dart';
import '../../images/note_image_provider.dart';
import '../page_toolbar.dart';
import '../sidebar_timestamp.dart';
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
  /// with the picture under the words. The page draws the task, its way
  /// back and Open in note.
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
    final picture = details == null
        ? null
        : TaskDetailPicture(
            item: item,
            details: details,
            images: widget.images,
            size: phone ? 96 : 72,
            width: phone ? 200 : null,
          );
    final words = empty && editable
        ? Align(
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
                style: uiStyle(
                  phone ? 16 : 14,
                  22,
                  FontWeight.w500,
                  palette.accentText,
                ),
              ),
            ),
          )
        : empty
        ? null
        : TextField(
            controller: _words,
            focusNode: _focus,
            readOnly: !editable,
            minLines: phone ? 1 : 3,
            maxLines: phone ? null : 8,
            style: phone
                ? uiStyle(16, 22, FontWeight.w400, palette.textSecondary)
                : uiStyle(14, 22, FontWeight.w400, palette.textPrimary),
            decoration: InputDecoration(
              border: InputBorder.none,
              filled: false,
              isCollapsed: true,
              contentPadding: EdgeInsets.zero,
              hintText: editable ? 'Add details' : null,
            ),
            onChanged: (value) => widget.tasks.setDetails(widget.item, value),
          );
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
    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?words,
          if (picture != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: picture),
          ?hint,
        ],
      );
    }
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Details',
                  style: uiStyle(12, 16, FontWeight.w600, palette.textTertiary),
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
            const SizedBox(height: 8),
            ?picture,
            ?words,
            ?hint,
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
    this.width,
  });

  final TaskItem item;
  final TaskDetails details;
  final BlobStore? images;

  /// How tall it is, and how wide too unless [width] says otherwise.
  final double size;
  final double? width;

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
                        FontWeight.w500,
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
