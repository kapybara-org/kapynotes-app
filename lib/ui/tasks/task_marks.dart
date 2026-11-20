import 'package:material_ui/material_ui.dart';

import '../../core/editor_font.dart';
import '../../core/theme.dart';
import '../../data/note.dart';
import '../../data/task_board.dart';
import '../../data/task_details.dart';
import '../../sync/spaces.dart';
import '../tag_colours.dart';

/// What the Tasks sidebar narrows the page to: every open task, the Done
/// view, or one note's tasks.
@immutable
class TaskFilter {
  const TaskFilter.all() : noteId = null, done = false;
  const TaskFilter.done() : noteId = null, done = true;
  const TaskFilter.note(String this.noteId) : done = false;

  final String? noteId;
  final bool done;

  @override
  bool operator ==(Object other) =>
      other is TaskFilter && other.noteId == noteId && other.done == done;

  @override
  int get hashCode => Object.hash(noteId, done);
}

/// A note's name on a task's mark, with its space's name after it when that
/// name exists.
///
/// A personal space has no name of its own, and a team space can arrive
/// without one. [Space.name] is null in both cases. Printing it anyway shows
/// "Title · null" beside the task, on the Tasks list, on phones, and in ⌘K.
String taskNoteLabel(Note note, Space? space) {
  final name = space?.name?.trim();
  if (name == null || name.isEmpty) return note.title;
  return '${note.title} · $name';
}

/// Shantell Sans, the hand the app titles things in.
TextStyle handStyle(double size, double line, FontWeight weight, Color color) {
  const hand = WritingFont.handwritten;
  return TextStyle(
    fontFamily: hand.fontFamily,
    fontFamilyFallback: hand.fontFamilyFallback,
    fontVariations: hand.fontVariations,
    fontSize: size,
    height: line / size,
    fontWeight: weight,
    color: color,
  );
}

/// A quiet mark that a task has details: lines for words, a picture mark for
/// a picture or a video. Never a dot, so it cannot be read as a tag.
class TaskDetailsIcon extends StatelessWidget {
  const TaskDetailsIcon({super.key, required this.item});

  final TaskItem item;

  @override
  Widget build(BuildContext context) {
    final details = taskBlockOf(item.note.body, item.line)?.details;
    if (details == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: details.hasVideo
            ? 'Has a picture or video'
            : details.hasPicture
            ? 'Has a picture'
            : 'Has details',
        child: KapyIcon(
          details.hasMedia ? KapyIcons.imageOutlined : KapyIcons.alignLeft,
          size: 14,
          color: context.palette.textTertiary,
        ),
      ),
    );
  }
}

/// Figtree, every label and every task's words.
TextStyle uiStyle(double size, double line, FontWeight weight, Color color) =>
    TextStyle(
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      fontSize: size,
      height: line / size,
      fontWeight: weight,
      color: color,
    );

/// A note's quiet mark: its first tag's dot colour, as a small square, or a
/// plain one when it has no coloured tag. A dashed one stands for no note.
class NoteSwatch extends StatelessWidget {
  const NoteSwatch({super.key, required this.note, this.size = 10});

  final Note? note;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final note = this.note;
    final radius = size >= 14
        ? 4.0
        : size <= 8
        ? 2.0
        : 3.0;
    if (note == null) {
      return CustomPaint(
        size: Size.square(size),
        painter: _DashedSquare(palette.checkboxBorder, radius),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color:
            TagMarks.of(context, note.id).firstOrNull?.colour?.dot(palette) ??
            (palette.brightness == Brightness.dark
                ? const Color(0xFF3A3530)
                : const Color(0xFFD9D2C1)),
        border: size <= 8
            ? null
            : Border.all(color: palette.textPrimary.withAlpha(0x24)),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class _DashedSquare extends CustomPainter {
  _DashedSquare(this.color, this.radius);

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          Radius.circular(radius),
        ),
      );
    for (final metric in outline.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 4) {
        canvas.drawPath(metric.extractPath(at, at + 2), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedSquare old) =>
      old.color != color || old.radius != radius;
}

/// The note a task lives in, at the end of its row: its swatch and its name.
class NoteMark extends StatelessWidget {
  const NoteMark({
    super.key,
    required this.note,
    required this.label,
    this.onPressed,
  });

  final Note note;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: 'Open $label',
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadii.compact),
        child: SizedBox(
          height: 24,
          child: Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                NoteSwatch(note: note, size: 8),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiStyle(
                      12,
                      16,
                      FontWeight.w400,
                      palette.textSecondary,
                    ),
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
