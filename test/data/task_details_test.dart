import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/task_details.dart';
import 'package:kapy_notes/data/task_lines.dart';

NoteImageRef _image(int offset) => NoteImageRef(
  offset: offset,
  hash: 'pic',
  key: Uint8List(32),
  mime: 'image/png',
  width: 10,
  height: 10,
  bytes: 8,
);

NoteVideoRef _video(int offset) => NoteVideoRef(
  offset: offset,
  hash: 'vid',
  key: Uint8List(32),
  mime: 'video/mp4',
  bytes: 8,
  width: 16,
  height: 9,
  durationMs: 1000,
);

void main() {
  test('a note with no indented details is read as tasks alone', () {
    const note = '☐ Send the weekly report\n☐ Call the garage\n';
    final blocks = taskBlocks(note);
    expect(blocks, hasLength(2));
    expect(blocks.every((block) => block.details == null), isTrue);
    expect(replaceTaskDetails(note, blocks.first.task, ''), note);
  });

  test('the indent is the boundary, and a blank line inside still belongs', () {
    const note = '''
☐ option to hide and turn it into a pill
  The menu stays up. After a few seconds it should shrink to a pill.

  The close button stays. Only the menu shrinks.
☐ Send the weekly report
''';
    final blocks = taskBlocks(note);
    expect(blocks, hasLength(2));
    final details = blocks.first.details!;
    expect(
      note.substring(details.start, details.end),
      '  The menu stays up. After a few seconds it should shrink to a pill.\n'
      '\n'
      '  The close button stays. Only the menu shrinks.',
    );
    expect(details.preview, startsWith('The menu stays up'));
    expect(blocks.last.details, isNull);
    expect(taskIsNested(note, blocks.last.task), isFalse);
  });

  test(
    'an indented blank line under a task is details, a margin blank is not',
    () {
      const opened = '☐ Buy milk\n  \n☐ Next\n';
      final details = taskBlocks(opened).first.details;
      expect(details, isNotNull);
      expect(taskBlocks(opened).last.details, isNull);

      const note = '☐ Buy milk\nThe shop closes at 8\n';
      expect(taskBlocks(note).single.details, isNull);
      expect(replaceTaskDetails(note, taskLines(note).single, ''), note);
    },
  );

  test('a line that is not indented is not details', () {
    const note = '☐ Buy milk\nThe shop closes at 8\n';
    final block = taskBlocks(note).single;
    expect(block.details, isNull);
    expect(replaceTaskDetails(note, block.task, ''), note);
  });

  test('markdown tasks keep the same indent boundary', () {
    const note = '''
- [ ] Write the note
      It has two paragraphs.

      The second one too.
- [ ] Next
''';
    final details = taskBlocks(note).first.details!;
    expect(details.preview, 'It has two paragraphs.');
    expect(note.substring(details.end), '\n- [ ] Next\n');
  });

  test('a smaller task inside the details counts on its parent', () {
    const note = '''
☐ Parent
  ☐ Child one
  ☐ Child two
☐ Sibling
''';
    final blocks = taskBlocks(note);
    expect(blocks, hasLength(4));
    expect(blocks.first.details!.children, hasLength(2));
    expect(taskIsNested(note, blocks[1].task), isTrue);
    expect(taskIsNested(note, blocks[2].task), isTrue);
    expect(taskIsNested(note, blocks.last.task), isFalse);
    final count = taskGroupCount(note, blocks.first.task);
    expect(count.total, 3);
    expect(count.done, 0);

    const done = '''
☑ Parent
  ☐ Child
  ☑ Finished
''';
    expect(taskGroupCount(done, taskLines(done).first), (done: 2, total: 3));
  });

  test('a task indented under a bullet is still its own task', () {
    const note = '• A list\n  ☐ Not details of a task\n';
    final tasks = taskLines(note);
    expect(tasks, hasLength(1));
    expect(taskIsNested(note, tasks.single), isFalse);
  });

  test('a picture and a video under a task are marks, not words', () {
    const note = '☐ Parent\n  The menu stays up.\n  ￼\n  ￼\n';
    final picture = _image(note.indexOf('￼'));
    final video = _video(note.lastIndexOf('￼'));
    final details = taskBlocks(
      note,
      attachments: [picture, video],
    ).single.details!;
    expect(details.hasPicture, isTrue);
    expect(details.hasVideo, isTrue);
    expect(details.preview, 'The menu stays up.');
    expect(foldedPreview(details.preview, limit: 8), 'The…');
    expect(
      foldedPreview(details.preview).length,
      lessThan(details.preview.length + 2),
    );
  });

  test('writing details does not touch the task line or what follows', () {
    const note = '☐ Buy milk\n☐ Call the garage\n';
    final task = taskLines(note).first;
    final written = replaceTaskDetails(note, task, 'Oat, if they have it.');
    expect(written, '☐ Buy milk\n  Oat, if they have it.\n☐ Call the garage\n');
    expect(written.substring(0, task.end), note.substring(0, task.end));
  });

  test('clearing details that were never there leaves the note identical', () {
    const note = 'Intro\n☐ Buy milk\nOutro\n';
    final task = taskLines(note).single;
    expect(replaceTaskDetails(note, task, ''), note);
    expect(replaceTaskDetails(note, task, '   \n'), note);
  });

  test(
    'a blank line inside survives a rewrite, and saving words keeps the pictures',
    () {
      const note = '☐ Parent\n  First\n  ￼\n  Second\n☐ Next\n';
      final task = taskLines(note).first;
      // What the sheet seeds its editor with: the placeholders stay.
      final seeded = taskDetailsWords(note, task);
      expect(seeded, 'First\n￼\nSecond');
      final written = replaceTaskDetails(note, task, seeded);
      expect(written, note);

      final edited = replaceTaskDetails(
        note,
        task,
        seeded.replaceAll('Second', 'Second, longer'),
      );
      expect(edited, '☐ Parent\n  First\n  ￼\n  Second, longer\n☐ Next\n');
      expect(taskBlocks(edited).first.details!.preview, 'First');
      expect(taskBlocks(edited).last.details, isNull);
    },
  );

  test(
    'what the assistant reads names a picture rather than a placeholder',
    () {
      const note = '☐ Parent\n  The menu stays up.\n  ￼\n';
      final task = taskLines(note).single;
      expect(taskDetailsText(note, task), 'The menu stays up.\npicture');
      expect(taskDetailsWords(note, task).contains('picture'), isFalse);
    },
  );

  test('a folded block keeps one preview row and hides the rest', () {
    const note = '☐ Parent\n  First\n\n  Second\n  ☐ Child\n☐ Next\n';
    final parent = taskBlocks(note).first.details!;
    final child = taskBlocks(note)[2].details;
    expect(child, isNull);
    final blocks = [(details: parent, folded: true)];

    expect(foldedLineFor(parent.start, blocks), FoldedLine.preview);
    expect(foldedLineFor(parent.start + 10, blocks), FoldedLine.hidden);
    expect(foldedLineFor(parent.end, blocks), FoldedLine.hidden);
    expect(foldedLineFor(parent.end + 1, blocks), FoldedLine.keep);
    expect(foldedLineFor(0, blocks), FoldedLine.keep);
  });

  test('an open block keeps every line', () {
    const note = '☐ Parent\n  First\n  Second\n';
    final details = taskBlocks(note).first.details!;
    final blocks = [(details: details, folded: false)];
    expect(foldedLineFor(details.start, blocks), FoldedLine.keep);
    expect(foldedLineFor(details.end, blocks), FoldedLine.keep);
  });

  test('emptying details takes the block away and leaves the next task', () {
    const note = '☐ Parent\n  Gone soon\n☐ Next\n';
    final written = replaceTaskDetails(note, taskLines(note).first, '');
    expect(written, '☐ Parent\n☐ Next\n');
  });
}
