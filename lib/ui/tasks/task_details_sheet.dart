import 'dart:async';

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
  });

  final TaskItem item;
  final TasksController tasks;
  final VoidCallback onClose;
  final VoidCallback onOpenNote;
  final BlobStore? images;

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
    final details = taskBlockOf(item.note.body, item.line)?.details;
    final empty = !_adding && _words.text.trim().isEmpty && details == null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(color: palette.separator),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
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
            if (details != null)
              TaskDetailPicture(
                item: item,
                details: details,
                images: widget.images,
              ),
            if (empty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
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
            else
              TextField(
                controller: _words,
                focusNode: _focus,
                minLines: 3,
                maxLines: 8,
                style: uiStyle(14, 22, FontWeight.w400, palette.textPrimary),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: 'Add details',
                ),
                onChanged: (value) =>
                    widget.tasks.setDetails(widget.item, value),
              ),
            if (empty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Writes under the task, in its note.',
                  style: uiStyle(13, 18, FontWeight.w400, palette.textTertiary),
                ),
              ),
            const Spacer(),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
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
