import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/task_details.dart';
import '../../data/task_lines.dart';
import '../tasks/task_marks.dart';
import 'markdown_editing.dart';
import 'task_details_editing.dart';
import 'note_field.dart';

/// The fold arrow, the sage rule, the folded preview and the first hint.
///
/// Drawn over the field, and it only takes a tap on the arrow or, on a phone,
/// on the folded line. Everything else falls through to the writing.
class TaskDetailsChrome extends StatelessWidget {
  const TaskDetailsChrome({
    super.key,
    required this.field,
    required this.text,
    required this.caret,
    required this.folded,
    required this.onToggle,
    required this.showHint,
    this.origin = Offset.zero,
  });

  final NoteFieldState? field;
  final String text;
  final int caret;
  final bool Function(TaskLine task) folded;
  final void Function(TaskLine task) onToggle;
  final bool showHint;

  /// Where the field's top-left sits in this overlay, so the arrow can sit in
  /// the margin to the left of the writing.
  final Offset origin;

  @override
  Widget build(BuildContext context) {
    final laid = field;
    if (laid == null) return const SizedBox.shrink();
    final palette = context.palette;
    final phone = !EditorMetrics.page;
    final blocks = taskBlocks(text);
    final caretLine = caret >= 0 && caret <= text.length
        ? markdownLinePrefix(text, caret.clamp(0, text.length))
        : null;
    final inDetails = caretInTaskDetails(text, caret);
    final children = <Widget>[];
    for (final block in blocks) {
      final details = block.details;
      if (details == null) continue;
      final taskRect = laid.caretRectAt(
        TextPosition(offset: block.task.textStart),
      );
      if (taskRect == null) continue;
      final isFolded = folded(block.task);
      children.add(
        Positioned(
          left: origin.dx - 22,
          top: origin.dy + taskRect.top + (taskRect.height - 18) / 2,
          width: 22,
          height: 22,
          child: _FoldArrow(
            folded: isFolded,
            onTap: () => onToggle(block.task),
          ),
        ),
      );
      if (isFolded) {
        final preview = laid.caretRectAt(TextPosition(offset: details.start));
        if (preview != null) {
          children.add(
            Positioned(
              left: origin.dx + 8,
              top: origin.dy + preview.top,
              right: 12,
              height: phone ? 44 : 22,
              child: _PreviewLine(
                text: foldedPreview(details.preview),
                hasPicture: details.hasPicture,
                hasVideo: details.hasVideo,
                phone: phone,
                onTap: phone ? () => onToggle(block.task) : null,
              ),
            ),
          );
        }
      } else if (inDetails &&
          caretLine != null &&
          caretLine.lineStart > block.task.end &&
          (caretLine.lineStart <= details.end || _inside(details, caretLine))) {
        final top = laid.caretRectAt(TextPosition(offset: details.start));
        final bottom = laid.caretRectAt(
          TextPosition(
            offset: (details.end - 1).clamp(details.start, text.length),
          ),
        );
        if (top != null && bottom != null) {
          children.add(
            Positioned(
              left: origin.dx + 4,
              top: origin.dy + top.top,
              width: 2,
              height: (bottom.bottom - top.top).clamp(top.height, 4000),
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.accent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
          );
        }
      }
    }
    if (showHint &&
        caretLine != null &&
        caretLine.isTask &&
        _lineEmpty(text, caretLine)) {
      final hint = laid.caretRectAt(TextPosition(offset: caretLine.lineStart));
      if (hint != null) {
        children.add(
          Positioned(
            left: origin.dx + hint.right + 12,
            top: origin.dy + hint.top,
            height: hint.height,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Shift+Enter adds details',
                  style: uiStyle(13, 20, FontWeight.w400, palette.textTertiary),
                ),
              ),
            ),
          ),
        );
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Stack(clipBehavior: Clip.none, children: children);
  }
}

bool _lineEmpty(String text, MarkdownLinePrefix line) =>
    text.substring(line.lineStart, line.lineEnd).trim().isEmpty;

bool _inside(TaskDetails details, MarkdownLinePrefix line) =>
    line.lineStart >= details.start && line.lineStart <= details.end;

class _FoldArrow extends StatelessWidget {
  const _FoldArrow({required this.folded, required this.onTap});

  final bool folded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = context.palette.textTertiary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: KapyIcon(
        folded ? KapyIcons.chevronRightRounded : KapyIcons.chevronDownRounded,
        size: 18,
        color: color,
      ),
    );
  }
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine({
    required this.text,
    required this.hasPicture,
    required this.hasVideo,
    required this.phone,
    required this.onTap,
  });

  final String text;
  final bool hasPicture;
  final bool hasVideo;
  final bool phone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final line = Row(
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: uiStyle(13, 20, FontWeight.w400, palette.textTertiary),
          ),
        ),
        if (hasPicture || hasVideo) ...[
          const SizedBox(width: 8),
          KapyIcon(
            hasVideo ? KapyIcons.playRounded : KapyIcons.imageOutlined,
            size: 14,
            color: palette.textTertiary,
          ),
        ],
      ],
    );
    if (onTap == null) {
      return Align(alignment: Alignment.centerLeft, child: line);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Align(alignment: Alignment.centerLeft, child: line),
    );
  }
}
