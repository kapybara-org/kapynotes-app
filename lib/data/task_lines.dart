import '../crdt/anchor.dart';
import '../crdt/node_id.dart';
import '../crdt/note_doc.dart';

/// One checklist line in a note: `☐`/`☑` or markdown `- [ ]`/`- [x]`.
class TaskLine {
  const TaskLine({
    required this.start,
    required this.end,
    required this.textStart,
    required this.done,
  });

  /// Offset of the line's first character, and of the newline that ends it
  /// (or the end of the note).
  final int start;
  final int end;

  /// Offset of the first character after the box: what a task is anchored
  /// to, because ticking replaces the box and leaves this alone.
  final int textStart;
  final bool done;
}

final RegExp _box = RegExp(r'^[ \t]*(?:([☐☑])|[-*+] \[([ xX])\])[ \t]+(?=\S)');

/// Every checklist line in [text] with words after its box, in order.
List<TaskLine> taskLines(String text) {
  final lines = <TaskLine>[];
  var start = 0;
  while (start <= text.length) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    final match = _box.firstMatch(text.substring(start, end));
    if (match != null) {
      final glyph = match.group(1);
      lines.add(
        TaskLine(
          start: start,
          end: end,
          textStart: start + match.end,
          done: glyph != null ? glyph == '☑' : match.group(2) != ' ',
        ),
      );
    }
    start = end + 1;
  }
  return lines;
}

/// A task's anchor as it is written into its record: `replica:counter`.
String anchorKey(NoteDoc doc, TaskLine line) =>
    doc.anchorAt(line.textStart + 1).id!.key;

/// The anchor a record names, or null for one this build cannot read.
Anchor? parseAnchor(String key) {
  final split = key.lastIndexOf(':');
  final counter = int.tryParse(key.substring(split + 1));
  if (split <= 0 || counter == null) return null;
  return Anchor(NodeId(key.substring(0, split), counter));
}
