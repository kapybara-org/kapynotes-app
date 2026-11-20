import 'package:flutter/services.dart';

import '../../data/note_attachment.dart';
import '../../data/task_details.dart';
import '../../data/task_lines.dart';
import 'editor_formatting.dart';
import 'image_insertion.dart';
import 'markdown_editing.dart';

/// Runs the task-details keystrokes before the note's own list handling.
///
/// Shift+Enter drops into the details. Enter and Backspace are recognized
/// from the edit they make, so a soft keyboard does the same thing as a key.
class TaskDetailsFormatter extends TextInputFormatter {
  const TaskDetailsFormatter({this.onEnteredDetails});

  /// Called when a keystroke is a way into the details, so the first hint
  /// can go away. Not called for Enter, which still means the next task.
  final void Function()? onEnteredDetails;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final keyboard = HardwareKeyboard.instance;
    final shift =
        (keyboard.isShiftPressed) &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed;
    if (shift && _insertedNewline(oldValue, newValue)) {
      final dropped = shiftEnterDetails(oldValue);
      if (dropped != null) {
        onEnteredDetails?.call();
        return dropped;
      }
    }
    final entered = editTaskDetailsEnter(oldValue, newValue);
    if (entered != null) return entered;
    final backed = backspaceEmptyTaskToDetails(oldValue, newValue);
    if (backed != null) {
      onEnteredDetails?.call();
      return backed;
    }
    return newValue;
  }
}

bool _insertedNewline(TextEditingValue oldValue, TextEditingValue newValue) {
  final selection = oldValue.selection;
  if (!selection.isValid || !selection.isCollapsed) return false;
  final caret = selection.extentOffset;
  return newValue.text == oldValue.text.replaceRange(caret, caret, '\n');
}

/// Whether [caret] is in a task's details, including the empty line just
/// opened under it. The sage rule uses this.
bool caretInTaskDetails(String text, int caret) {
  if (text.isEmpty || caret < 0 || caret > text.length) return false;
  final line = markdownLinePrefix(text, caret.clamp(0, text.length));
  return _detailsOwner(text, line) != null;
}

/// What Enter does around a task's details. Null leaves the keypress to the
/// note's own list handling, which still starts the next task.
///
/// Enter at the end of a task that already has details starts the next task
/// after those details, so they stay with the task. Enter on a details line
/// that has words stays inside and keeps the indent. Enter on an empty
/// details line leaves, and starts the next task.
TextEditingValue? editTaskDetailsEnter(
  TextEditingValue oldValue,
  TextEditingValue newValue,
) {
  final selection = oldValue.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.extentOffset;
  final text = oldValue.text;
  if (newValue.text != text.replaceRange(caret, caret, '\n')) return null;

  final line = markdownLinePrefix(text, caret);
  if (_atEndOfTask(text, line, caret)) {
    final task = _indexedTask(text, line);
    final details = task == null ? null : taskBlockOf(text, task)?.details;
    if (details != null) {
      return _insertLineAfter(text, details.end, _nextTaskMarker(text, line));
    }
  }

  final owner = _detailsOwner(text, line);
  if (owner == null) return null;
  if (_lineIsEmpty(text, line)) {
    return _replaceLine(text, line, _nextTaskMarker(text, owner));
  }
  if (caret < line.lineStart) return null;
  final indent = ' ' * _contentColumn(owner);
  return newValue.copyWith(
    text: newValue.text.replaceRange(caret + 1, caret + 1, indent),
    selection: TextSelection.collapsed(offset: caret + 1 + indent.length),
    composing: TextRange.empty,
  );
}

/// Shift+Enter drops into a task's details, without splitting its name.
///
/// With nothing under the task, an indented line opens and the caret sits on
/// it. With details already there, the caret moves to the end of them, on a
/// fresh indented line when the last one has words.
TextEditingValue? shiftEnterDetails(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final text = value.text;
  final caret = selection.extentOffset;
  final line = markdownLinePrefix(text, caret);
  if (line.isTask && caret >= line.markerStart) {
    final task = _indexedTask(text, line);
    final details = task == null ? null : taskBlockOf(text, task)?.details;
    final indent = ' ' * _contentColumn(line);
    if (details == null) {
      return _insertLineAfter(text, line.lineEnd, indent, caretInLine: indent.length);
    }
    final last = markdownLinePrefix(
      text,
      details.end > details.start ? details.end - 1 : details.start,
    );
    if (_lineIsEmpty(text, last)) {
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: last.lineEnd),
      );
    }
    return _insertLineAfter(
      text,
      details.end,
      indent,
      caretInLine: indent.length,
    );
  }
  final owner = _detailsOwner(text, line);
  if (owner == null) return null;
  final indent = ' ' * _contentColumn(owner);
  return _insertLineAfter(text, line.lineEnd, indent, caretInLine: indent.length);
}

/// Tab on a plain line directly under a task indents it so it belongs. Shift+Tab
/// on a details line takes that indent off. A list item is left to the note's
/// own nesting.
TextEditingValue? tabTaskDetails(
  TextEditingValue value, {
  required bool detach,
}) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final text = value.text;
  final caret = selection.extentOffset;
  final line = markdownLinePrefix(text, caret);
  if (line.isListItem) return null;

  if (detach) {
    final owner = _detailsOwner(text, line);
    if (owner == null) return null;
    final current = _indentWidth(text, line);
    final target = owner.markerStart - owner.lineStart;
    if (current <= target) return null;
    final removed = current - target;
    return TextEditingValue(
      text: text.replaceRange(line.lineStart, line.lineStart + removed, ''),
      selection: TextSelection.collapsed(
        offset: (caret - removed).clamp(0, text.length - removed),
      ),
    );
  }

  if (line.lineStart == 0 || line.isBlank) return null;
  final newline = text.lastIndexOf('\n', line.lineStart - 1);
  if (newline < 0) return null;
  final prev = markdownLinePrefix(
    text,
    newline == 0 ? 0 : text.lastIndexOf('\n', newline - 1) + 1,
  );
  if (prev.lineEnd != newline || !prev.isTask || _lineIsEmpty(text, prev)) {
    return null;
  }
  final column = _contentColumn(prev);
  final current = _indentWidth(text, line);
  if (current >= column) return null;
  final pad = ' ' * (column - current);
  return TextEditingValue(
    text: text.replaceRange(line.lineStart, line.lineStart, pad),
    selection: TextSelection.collapsed(offset: caret + pad.length),
  );
}

/// Backspace on a new, empty task turns that line into a details line of the
/// task above. Null leaves Backspace to take the box off, as it does today
/// when there is no task above.
TextEditingValue? backspaceEmptyTaskToDetails(
  TextEditingValue oldValue,
  TextEditingValue newValue,
) {
  final selection = oldValue.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.extentOffset;
  final text = oldValue.text;
  if (caret == 0 || newValue.text != text.replaceRange(caret - 1, caret, '')) {
    return null;
  }
  final line = markdownLinePrefix(text, caret);
  if (!line.isTask || !_lineIsEmpty(text, line)) return null;
  if (caret < line.markerStart || caret > line.contentStart) return null;
  final above = _taskAbove(text, line);
  if (above == null) return null;
  final indent = ' ' * _contentColumn(above);
  return TextEditingValue(
    text: text.replaceRange(line.lineStart, line.contentStart, indent),
    selection: TextSelection.collapsed(offset: line.lineStart + indent.length),
  );
}

/// Indents a picture or video that just landed on the line directly under a
/// task, so it belongs to that task. A drop anywhere else is left alone, and
/// a note that already had the picture is not rewritten: only the line this
/// insert added can move.
ImageInsertion attachMediaUnderTask({
  required String bodyBefore,
  required ImageInsertion inserted,
}) {
  final mark = _firstNewPlaceholder(bodyBefore, inserted.body);
  if (mark == null) return inserted;
  final line = markdownLinePrefix(inserted.body, mark);
  if (line.lineStart == 0) return inserted;
  final previousStart = inserted.body.lastIndexOf('\n', line.lineStart - 1);
  final prev = markdownLinePrefix(
    inserted.body,
    previousStart <= 0
        ? 0
        : inserted.body.lastIndexOf('\n', previousStart - 1) + 1,
  );
  if (!prev.isTask || prev.lineEnd + 1 != line.lineStart) return inserted;
  final column = _contentColumn(prev);
  final current = _indentWidth(inserted.body, line);
  if (current >= column) return inserted;
  final pad = ' ' * (column - current);
  final body = inserted.body.replaceRange(line.lineStart, line.lineStart, pad);
  final shiftAt = line.lineStart;
  return ImageInsertion(
    body: body,
    attachments: [
      for (final ref in inserted.attachments)
        ref.offset >= shiftAt ? ref.copyWith(offset: ref.offset + pad.length) : ref,
    ],
    selection: inserted.selection + pad.length,
  );
}

bool _atEndOfTask(String text, MarkdownLinePrefix line, int caret) {
  if (!line.isTask || caret != line.lineEnd) return false;
  return text.substring(line.contentStart, line.lineEnd).trim().isNotEmpty;
}

TaskLine? _indexedTask(String text, MarkdownLinePrefix line) {
  for (final task in taskLines(text)) {
    if (task.start == line.lineStart) return task;
  }
  return null;
}

int _contentColumn(MarkdownLinePrefix line) => line.contentStart - line.lineStart;

int _indentWidth(String text, MarkdownLinePrefix line) {
  var i = line.lineStart;
  while (i < line.lineEnd) {
    final unit = text.codeUnitAt(i);
    if (unit != 0x20 && unit != 0x09) break;
    i++;
  }
  return i - line.lineStart;
}

bool _lineIsEmpty(String text, MarkdownLinePrefix line) {
  final from = line.isListItem ? line.contentStart : line.lineStart;
  return text.substring(from, line.lineEnd).trim().isEmpty;
}

/// The task whose details [line] is in, or whose details [line] is the empty
/// line at the end of. Null when the line is ordinary writing.
MarkdownLinePrefix? _detailsOwner(String text, MarkdownLinePrefix line) {
  if (line.isTask && !_lineIsEmpty(text, line)) return null;
  var start = line.lineStart;
  while (start > 0) {
    start = text.lastIndexOf('\n', start - 2) + 1;
    final above = markdownLinePrefix(text, start);
    if (!_lineIsEmpty(text, above) && above.isTask) {
      return _underTask(text, above, line) ? above : null;
    }
    if (above.isTask) continue;
  }
  return null;
}

bool _underTask(String text, MarkdownLinePrefix task, MarkdownLinePrefix line) {
  final column = _contentColumn(task);
  var start = task.lineEnd < text.length ? task.lineEnd + 1 : text.length;
  if (start > line.lineStart) return false;
  while (start < line.lineStart && start < text.length) {
    final between = markdownLinePrefix(text, start);
    if (!_lineIsEmpty(text, between) && _indentWidth(text, between) < column) {
      return false;
    }
    if (between.lineEnd + 1 <= start) break;
    start = between.lineEnd + 1;
  }
  return _lineIsEmpty(text, line) || _indentWidth(text, line) >= column;
}

MarkdownLinePrefix? _taskAbove(String text, MarkdownLinePrefix line) {
  var start = line.lineStart;
  while (start > 0) {
    start = text.lastIndexOf('\n', start - 2) + 1;
    final above = markdownLinePrefix(text, start);
    if (above.isTask && !_lineIsEmpty(text, above)) return above;
  }
  return null;
}

String _nextTaskMarker(String text, MarkdownLinePrefix task) {
  final indent = text.substring(task.lineStart, task.markerStart);
  if (task.glyph || task.taskBox == null) return '$indent$uncheckedPrefix';
  final marker = text.substring(task.markerStart, task.markerEnd);
  return '$indent$marker [ ] ';
}

TextEditingValue _replaceLine(
  String text,
  MarkdownLinePrefix line,
  String replacement,
) {
  return TextEditingValue(
    text: text.replaceRange(line.lineStart, line.lineEnd, replacement),
    selection: TextSelection.collapsed(
      offset: line.lineStart + replacement.length,
    ),
  );
}

/// Puts [line] on its own line after the line that ends at [afterEnd].
TextEditingValue _insertLineAfter(
  String text,
  int afterEnd,
  String line, {
  int? caretInLine,
}) {
  final caretOn = caretInLine ?? line.length;
  if (afterEnd >= text.length) {
    final next = '$text\n$line';
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: text.length + 1 + caretOn),
    );
  }
  if (text[afterEnd] == '\n') {
    final at = afterEnd + 1;
    return TextEditingValue(
      text: text.replaceRange(at, at, '$line\n'),
      selection: TextSelection.collapsed(offset: at + caretOn),
    );
  }
  return TextEditingValue(
    text: text.replaceRange(afterEnd, afterEnd, '\n$line'),
    selection: TextSelection.collapsed(offset: afterEnd + 1 + caretOn),
  );
}

int? _firstNewPlaceholder(String before, String after) {
  var b = 0;
  var a = 0;
  while (a < after.length && b < before.length && after[a] == before[b]) {
    a++;
    b++;
  }
  final mark = after.indexOf(NoteAttachmentRef.placeholder, a);
  if (mark < 0) return null;
  return mark;
}
