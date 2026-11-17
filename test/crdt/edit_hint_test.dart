import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/crdt.dart';
import 'package:kapy_notes/data/task_lines.dart';

List<Object?> write(NoteDoc doc, String body, {TextEdit? near}) =>
    doc.reconcile(
      body: body,
      formats: const [],
      attachments: const [],
      createdAt: DateTime.utc(2026, 11, 1),
      near: near,
    );

/// Each checklist line's anchor, by the words on it.
Map<String, String> anchors(NoteDoc doc) => {
  for (final line in taskLines(doc.text))
    doc.text.substring(line.textStart, line.end): anchorKey(doc, line),
};

/// The words on the line [anchor] is on now, or null once it has gone.
String? wordsAt(NoteDoc doc, String anchor) {
  final lines = taskLines(doc.text);
  final index = taskLineIndex(doc, lines, anchor);
  return index < 0
      ? null
      : doc.text.substring(lines[index].textStart, lines[index].end);
}

void main() {
  const before = '☐ Buy oats\n☐ Buy milk\n☐ Buy eggs\n';
  const after = '☐ Buy oats\n☐ Buy eggs\n';
  // The middle line, as the editor saw it go: selected whole and deleted.
  const deleted = (start: 11, oldEnd: 22, newEnd: 11);

  test('a middle line deleted where the editor saw it keeps each task on '
      'its own line', () {
    final doc = NoteDoc(replica: 'a');
    write(doc, before);
    final was = anchors(doc);

    write(doc, after, near: deleted);

    expect(doc.text, after);
    expect(wordsAt(doc, was['Buy oats']!), 'Buy oats');
    expect(wordsAt(doc, was['Buy eggs']!), 'Buy eggs');
    expect(wordsAt(doc, was['Buy milk']!), isNull);
  });

  test('without the edit the same delete reads as the end of one line and '
      'the start of the next', () {
    final doc = NoteDoc(replica: 'a');
    write(doc, before);
    final was = anchors(doc);

    write(doc, after);

    expect(wordsAt(doc, was['Buy milk']!), 'Buy eggs');
  });

  test('an edit that does not fit the texts is ignored', () {
    final doc = NoteDoc(replica: 'a');
    write(doc, before);
    final was = anchors(doc);

    write(doc, after, near: (start: 0, oldEnd: 3, newEnd: 3));

    expect(doc.text, after);
    expect(wordsAt(doc, was['Buy milk']!), 'Buy eggs');
  });

  test('two edits compose into one stretch covering both', () {
    const text = 'abcdef';
    const typed = (start: 1, oldEnd: 1, newEnd: 3);
    const deletedLater = (start: 6, oldEnd: 8, newEnd: 6);
    final first = text.replaceRange(1, 1, 'XY');
    final second = first.replaceRange(6, 8, '');
    final both = composeEdits(typed, deletedLater);

    expect(both, (start: 1, oldEnd: 6, newEnd: 6));
    expect(diffTexts(text, second, near: both), diffTexts(text, second));
    expect(second, 'aXYbcd');
  });
}
