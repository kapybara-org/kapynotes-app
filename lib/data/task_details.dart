import 'dart:math' as math;

import 'note_attachment.dart';
import 'task_lines.dart';

/// The lines indented under one task, the way a markdown list item holds the
/// lines indented under it.
///
/// The indent is the boundary, not a blank line: a blank line between two
/// indented lines still belongs, and a line that is not indented far enough
/// ends the block. Nothing here is stored beside the note. The words are the
/// note's own text, so an export and another markdown app keep them with the
/// task, and a note that has no indented lines is left exactly as it was.
class TaskDetails {
  const TaskDetails({
    required this.start,
    required this.end,
    required this.preview,
    required this.hasPicture,
    required this.hasVideo,
    required this.children,
  });

  /// Where the first detail line starts, and where the last one ends, in the
  /// same sense as [TaskLine]: before the newline that ends the line, or at
  /// the end of the note.
  final int start;
  final int end;

  /// The first words of the block, with the indent and any picture mark taken
  /// off. Empty when the block is only a picture or a video.
  final String preview;

  final bool hasPicture;
  final bool hasVideo;
  final List<TaskLine> children;

  bool get hasMedia => hasPicture || hasVideo;
}

/// One task and the details indented under it, if it has any.
class TaskBlock {
  const TaskBlock({required this.task, required this.details});

  final TaskLine task;
  final TaskDetails? details;

  bool get hasDetails => details != null;
}

/// Every task in [text], in order, with the details indented under it.
///
/// A smaller task indented inside those details is listed on its parent as
/// well as on its own, so a caller can count it there and leave it out of
/// Today. [attachments] tells a picture from a video; without them a
/// placeholder counts as a picture.
List<TaskBlock> taskBlocks(
  String text, {
  List<NoteAttachmentRef> attachments = const [],
}) {
  final tasks = taskLines(text);
  return [
    for (var i = 0; i < tasks.length; i++)
      TaskBlock(
        task: tasks[i],
        details: _detailsOf(text, tasks, i, attachments),
      ),
  ];
}

/// The block [task] is, read again from [text]. Null when the line has gone.
TaskBlock? taskBlockOf(String text, TaskLine task) {
  final tasks = taskLines(text);
  final index = tasks.indexWhere((line) => line.start == task.start);
  if (index < 0) return null;
  return TaskBlock(
    task: tasks[index],
    details: _detailsOf(text, tasks, index, const []),
  );
}

/// Writes [plain] as the words under [task], indented to where the task's own
/// words start, and returns the note.
///
/// [plain] must carry the details' picture placeholders as they are: whoever
/// edits the words keeps the pictures in place (see [taskDetailsWords]), and
/// the note's attachment records follow the placeholders when the note is
/// written. A placeholder left out of [plain] takes its picture with it, so
/// a caller that shows the words rather than the pictures reads them with
/// [taskDetailsWords]. The task's own line is never rewritten, and neither is anything
/// after the details. An empty [plain] with nothing under the task leaves the
/// note unchanged when there was nothing there, and takes an empty block away
/// when there was one, so a note with no indented details that is given
/// nothing comes back identical.
String replaceTaskDetails(String text, TaskLine task, String plain) {
  final details = taskBlockOf(text, task)?.details;
  final was = details == null
      ? const <String>[]
      : text.substring(details.start, details.end).split('\n');
  final column = _blockIndent(was, task.textStart - task.start);
  final rebuilt = _indentedWords(plain, column, was).join('\n');
  if (details == null) {
    if (rebuilt.isEmpty) return text;
    if (task.end >= text.length) return '$text\n$rebuilt';
    // [task.end] is the newline that ends the task, or the end of the note.
    if (text[task.end] == '\n') {
      return text.replaceRange(task.end + 1, task.end + 1, '$rebuilt\n');
    }
    return text.replaceRange(task.end, task.end, '\n$rebuilt');
  }
  if (rebuilt.isEmpty) {
    var from = details.start;
    var to = details.end;
    if (to < text.length && text[to] == '\n') to++;
    // At the end of the note the newline that opened the block goes too, so
    // an emptied task does not keep a blank line under it.
    if (from > 0 && text[from - 1] == '\n' && to >= text.length) from--;
    return text.replaceRange(from, to, '');
  }
  return text.replaceRange(details.start, details.end, rebuilt);
}

/// The details under [task] with the block's indent taken off, so they
/// start flush and a line indented further keeps the rest, for an editor that
/// draws the pictures itself.
///
/// A picture or video stays a placeholder, so writing these words back with
/// [replaceTaskDetails] after an edit keeps the note's pictures exactly where
/// they were.
String taskDetailsWords(String text, TaskLine task) {
  final details = taskBlockOf(text, task)?.details;
  if (details == null) return '';
  final lines = text.substring(details.start, details.end).split('\n');
  final column = _blockIndent(lines, task.textStart - task.start);
  return lines.map((line) => _unindented(line, column)).join('\n');
}

/// How far a block of details is indented: as far as its least indented
/// line, and never less than where the task's words start. So details
/// indented further than they need come out flush, and a line indented past
/// the rest keeps the difference.
int _blockIndent(List<String> lines, int column) {
  final indents = [
    for (final line in lines)
      if (line.trim().isNotEmpty) _indentOf(line),
  ];
  return indents.isEmpty ? column : math.max(column, indents.reduce(math.min));
}

/// What a line of a folded task's details draws.
enum FoldedLine {
  /// The block's first line stays, at a folded row's height, for the preview
  /// drawn over it.
  preview,

  /// Every other line of the block takes no room and draws nothing.
  hidden,

  /// The line is not in a folded block.
  keep,
}

/// Where [lineStart] sits in [blocks], each with whether it is folded.
FoldedLine foldedLineFor(
  int lineStart,
  List<({TaskDetails details, bool folded})> blocks,
) {
  for (final block in blocks) {
    if (!block.folded) continue;
    final details = block.details;
    if (lineStart == details.start) return FoldedLine.preview;
    if (lineStart > details.start && lineStart <= details.end) {
      return FoldedLine.hidden;
    }
  }
  return FoldedLine.keep;
}

/// The details under [task] as plain words, for an assistant to read.
///
/// The indent is taken off. A picture or a video is named, so it is not
/// silent, and nothing here can be written back: it is a reading.
String taskDetailsText(String text, TaskLine task) {
  final details = taskBlockOf(text, task)?.details;
  if (details == null) return '';
  final lines = <String>[];
  for (final raw in text.substring(details.start, details.end).split('\n')) {
    if (_isMediaLine(raw)) {
      lines.add(raw.trim().length > 1 ? 'pictures' : 'picture');
      continue;
    }
    var line = raw.trimLeft();
    if (line.isEmpty) {
      lines.add('');
      continue;
    }
    lines.add(line);
  }
  final words = lines.join('\n').trim();
  if (details.hasVideo && !words.contains('video')) {
    return words.isEmpty ? 'video' : '$words\nvideo';
  }
  return words;
}

/// The first words a folded task shows, cut to [limit] characters.
String foldedPreview(String preview, {int limit = 42}) {
  final words = preview.trim();
  if (words.length <= limit) return words;
  final cut = words.substring(0, limit);
  final space = cut.lastIndexOf(' ');
  final kept = space >= 3 ? cut.substring(0, space) : cut;
  return '$kept…';
}

TaskDetails? _detailsOf(
  String text,
  List<TaskLine> tasks,
  int index,
  List<NoteAttachmentRef> attachments,
) {
  final task = tasks[index];
  final column = task.textStart - task.start;
  if (column <= 0) return null;
  final lines = _linesAfter(text, task.end);
  final kept = <_Line>[];
  final pending = <_Line>[];
  for (final line in lines) {
    if (line.blank) {
      // An indented blank line is inside the block. A blank line at the
      // margin belongs only when more indented lines follow it.
      if (_indentOf(line.text) >= column) {
        kept.addAll(pending);
        pending.clear();
        kept.add(line);
      } else {
        pending.add(line);
      }
      continue;
    }
    if (_indentOf(line.text) >= column) {
      kept.addAll(pending);
      pending.clear();
      kept.add(line);
      continue;
    }
    break;
  }
  if (kept.isEmpty) return null;
  final start = kept.first.start;
  final end = kept.last.end;
  final body = text.substring(start, end);
  var picture = false;
  var video = false;
  for (final line in kept) {
    final mark = _mediaOf(text, line, attachments);
    picture = picture || mark.$1;
    video = video || mark.$2;
  }
  return TaskDetails(
    start: start,
    end: end,
    preview: _preview(body),
    hasPicture: picture,
    hasVideo: video,
    children: [
      for (var i = index + 1; i < tasks.length && tasks[i].start <= end; i++)
        tasks[i],
    ],
  );
}

class _Line {
  const _Line(this.start, this.end, this.text);

  final int start;
  final int end;
  final String text;

  bool get blank => text.trim().isEmpty;
}

/// Lines after [end], which is the end of a task line (before its newline).
Iterable<_Line> _linesAfter(String text, int end) sync* {
  var start = end < text.length && text[end] == '\n' ? end + 1 : text.length;
  while (start <= text.length) {
    var lineEnd = text.indexOf('\n', start);
    if (lineEnd < 0) lineEnd = text.length;
    yield _Line(start, lineEnd, text.substring(start, lineEnd));
    if (lineEnd >= text.length) break;
    start = lineEnd + 1;
  }
}

int _indentOf(String line) {
  var i = 0;
  while (i < line.length) {
    final unit = line.codeUnitAt(i);
    if (unit != 0x20 && unit != 0x09) break;
    i++;
  }
  return i;
}

(bool, bool) _mediaOf(
  String text,
  _Line line,
  List<NoteAttachmentRef> attachments,
) {
  var picture = false;
  var video = false;
  if (line.text.contains('![')) picture = true;
  for (var i = 0; i < line.text.length; i++) {
    if (line.text.codeUnitAt(i) != 0xFFFC) continue;
    final at = line.start + i;
    NoteAttachmentRef? ref;
    for (final candidate in attachments) {
      if (candidate.offset == at) {
        ref = candidate;
        break;
      }
    }
    if (ref is NoteVideoRef) {
      video = true;
    } else {
      picture = true;
    }
  }
  return (picture, video);
}

String _preview(String body) {
  for (final raw in body.split('\n')) {
    var line = raw.trimLeft();
    if (line.isEmpty) continue;
    line = line.replaceAll('￼', '').trim();
    if (line.startsWith('☐ ') || line.startsWith('☑ ')) {
      line = line.substring(2).trim();
    } else if (RegExp(r'^[-*+] \[[ xX]\] ').hasMatch(line)) {
      line = line.substring(6).trim();
    }
    line = line.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '').trim();
    if (line.isEmpty) continue;
    return line.replaceAll(RegExp(r'\s+'), ' ');
  }
  return '';
}

bool _isMediaLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return false;
  for (final unit in trimmed.codeUnits) {
    if (unit != 0xFFFC) return false;
  }
  return true;
}

String _unindented(String line, int column) =>
    line.substring(math.min(_indentOf(line), column));

List<String> _indentedWords(String plain, int column, List<String> was) {
  final normalized = plain.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.trim().isEmpty) return const [];
  final lines = normalized.split('\n');
  final most = math.min(lines.length, was.length);
  var head = 0;
  while (head < most && _unindented(was[head], column) == lines[head]) {
    head++;
  }
  var tail = 0;
  while (tail < most - head &&
      _unindented(was[was.length - 1 - tail], column) ==
          lines[lines.length - 1 - tail]) {
    tail++;
  }
  final indent = ' ' * column;
  return [
    ...was.take(head),
    for (final line in lines.sublist(head, lines.length - tail))
      line.trim().isEmpty ? '' : '$indent$line',
    ...was.sublist(was.length - tail),
  ];
}
