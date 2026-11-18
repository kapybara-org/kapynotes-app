import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../sync/presence.dart';
import '../checklist_pie.dart';
import '../collaborator_colors.dart';
import 'note_footer.dart' show typingStatusText;

/// The note title's hand-drawn underline, under its last word: Paper's clay
/// stroke, a little longer than the word and rising slightly into it.
class NoteTitleUnderline extends StatelessWidget {
  const NoteTitleUnderline({super.key, required this.word});

  /// The last word of the title, in the coordinates this is laid out in.
  final Rect word;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('note-title-underline'),
    painter: _UnderlinePainter(word, context.palette.clay),
  );
}

class _UnderlinePainter extends CustomPainter {
  _UnderlinePainter(this.word, this.color);

  final Rect word;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = word.height / EditorMetrics.titleRow;
    final path = Path()
      ..moveTo(word.left - 2.9 * scale, word.top + 47.1 * scale)
      ..quadraticBezierTo(
        word.center.dx,
        word.top + 46.8 * scale,
        word.right + 2.9 * scale,
        word.top + 49.5 * scale,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.6 * scale
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_UnderlinePainter old) =>
      old.word != word || old.color != color;
}

/// The row under a note's title: when it was edited, how far its checklist
/// has got, its running total, and who else is in it or why it cannot be
/// changed.
class NoteMetaRow extends StatelessWidget {
  const NoteMetaRow({
    super.key,
    required this.edited,
    this.done = 0,
    this.tasks = 0,
    this.total,
    this.totalDetail,
    this.typing = const [],
    this.readOnlyLabel,
    this.readOnlyIcon,
    this.onReadOnlyPressed,
    this.today = false,
    this.tags,
  });

  final String edited;

  /// Counts what was done today, as over Tasks' one list: "3 of 13 done
  /// today".
  final bool today;

  /// Ticked boxes out of every box in the note. No boxes, no progress.
  final int done;
  final int tasks;

  final String? total;

  /// What the total counted and how, for the hover on it.
  final String? totalDetail;
  final List<Collaborator> typing;

  /// Set only when the note cannot be changed: what that is called here.
  final String? readOnlyLabel;
  final IconData? readOnlyIcon;
  final VoidCallback? onReadOnlyPressed;

  /// The note's tag chips and + Tag, at the end of the line.
  final Widget? tags;

  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final quiet = TextStyle(
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      fontSize: 13,
      height: 16 / 13,
      fontWeight: FontWeight.w500,
      color: palette.textTertiary,
    );
    final strong = quiet.copyWith(
      fontWeight: FontWeight.w600,
      color: palette.textSecondary,
    );
    final dot = Text('·', style: quiet.copyWith(color: palette.textDivider));
    final typingText = typingStatusText([for (final p in typing) p.name]);
    final progress = '$done of $tasks done${today ? ' today' : ''}';
    final items = <Widget>[
      Text(edited, key: const ValueKey('note-edited'), style: quiet),
      if (tasks > 0)
        Semantics(
          label: progress,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChecklistPie(
                key: const ValueKey('note-progress'),
                done: done,
                total: tasks,
                fill: Theme.of(context).colorScheme.primary,
                check: palette.paperColor,
              ),
              const SizedBox(width: 6),
              Text(progress, style: strong),
            ],
          ),
        ),
      if (total case final total?)
        Tooltip(
          message: totalDetail ?? '',
          child: Text.rich(
            key: const ValueKey('note-total'),
            TextSpan(
              text: 'Total: ',
              children: [TextSpan(text: total, style: strong)],
            ),
            style: quiet,
          ),
        ),
      if (typingText != null)
        Semantics(
          liveRegion: true,
          label: typingText,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final person in typing.take(3)) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: collaboratorColor(
                      person.userId,
                      on: palette.brightness,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
              ],
              const SizedBox(width: 3),
              Text(
                typingText,
                key: const ValueKey('typing-presence'),
                style: quiet,
              ),
            ],
          ),
        ),
      if (readOnlyLabel case final label?)
        _ReadOnly(
          label: label,
          icon: readOnlyIcon,
          style: strong,
          onPressed: onReadOnlyPressed,
        ),
    ];
    return SizedBox(
      height: EditorMetrics.metaRow,
      child: Row(
        children: [
          for (final (index, item) in items.indexed) ...[
            if (index > 0) ...[
              const SizedBox(width: _gap),
              dot,
              const SizedBox(width: _gap),
            ],
            item,
          ],
          if (tags case final tags?) ...[
            const SizedBox(width: _gap),
            dot,
            const SizedBox(width: _gap),
            tags,
          ],
        ],
      ),
    );
  }
}

class _ReadOnly extends StatelessWidget {
  const _ReadOnly({
    required this.label,
    required this.icon,
    required this.style,
    required this.onPressed,
  });

  final String label;
  final IconData? icon;
  final TextStyle style;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon case final icon?) ...[
          Icon(icon, size: 13, color: style.color),
          const SizedBox(width: 4),
        ],
        Text(label, key: const ValueKey('view-only-status'), style: style),
      ],
    );
    return Semantics(
      button: onPressed != null,
      child: onPressed == null
          ? content
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(onTap: onPressed, child: content),
            ),
    );
  }
}
