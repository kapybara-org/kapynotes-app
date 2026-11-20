import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/image_insertion.dart';
import 'package:kapy_notes/ui/editor/task_details_editing.dart';

NoteImageRef _image() => NoteImageRef(
  offset: 0,
  hash: 'pic',
  key: Uint8List(32),
  mime: 'image/png',
  width: 10,
  height: 10,
  bytes: 8,
);

/// [text] with the caret at `|`.
TextEditingValue at(String text) {
  final caret = text.indexOf('|');
  return TextEditingValue(
    text: text.replaceAll('|', ''),
    selection: TextSelection.collapsed(offset: caret),
  );
}

String shown(TextEditingValue value) {
  final caret = value.selection.extentOffset;
  return value.text.replaceRange(caret, caret, '|');
}

TextEditingValue enter(String marked) {
  final before = at(marked);
  final caret = before.selection.extentOffset;
  final typed = TextEditingValue(
    text: before.text.replaceRange(caret, caret, '\n'),
    selection: TextSelection.collapsed(offset: caret + 1),
  );
  return editTaskDetailsEnter(before, typed) ?? typed;
}

TextEditingValue backspace(String marked) {
  final before = at(marked);
  final caret = before.selection.extentOffset;
  final typed = TextEditingValue(
    text: before.text.replaceRange(caret - 1, caret, ''),
    selection: TextSelection.collapsed(offset: caret - 1),
  );
  return backspaceEmptyTaskToDetails(before, typed) ?? typed;
}

void main() {
  test('Enter at the end of a task is left to the note, which starts the next task', () {
    final before = at('☐ Send the weekly report|');
    final caret = before.selection.extentOffset;
    final typed = TextEditingValue(
      text: before.text.replaceRange(caret, caret, '\n'),
      selection: TextSelection.collapsed(offset: caret + 1),
    );
    expect(editTaskDetailsEnter(before, typed), isNull);
  });

  test('Enter at the end of a task with details starts the next task after them', () {
    expect(
      shown(enter('☐ Hide it|\n  The menu stays up.')),
      '☐ Hide it\n  The menu stays up.\n☐ |',
    );
  });

  test('Shift+Enter drops into the details and does not split the name', () {
    expect(
      shown(shiftEnterDetails(at('☐ Hide| it'))!),
      '☐ Hide it\n  |',
    );
    expect(
      shown(shiftEnterDetails(at('☐ Hide it|\n  Already there.'))!),
      '☐ Hide it\n  Already there.\n  |',
    );
  });

  test('Tab attaches the plain line directly under a task, and Shift+Tab lets it go', () {
    final attached = tabTaskDetails(
      at('☐ Hide it\n|A plain line.'),
      detach: false,
    );
    expect(shown(attached!), '☐ Hide it\n  |A plain line.');

    final detached = tabTaskDetails(
      at('☐ Hide it\n  A plain line.|'),
      detach: true,
    );
    expect(shown(detached!), '☐ Hide it\nA plain line.|');
  });

  test('Tab does not attach a line that is not directly under the task', () {
    expect(
      tabTaskDetails(at('☐ Hide it\n\n|Later'), detach: false),
      isNull,
    );
  });

  test('Backspace on a new empty task makes it details of the task above', () {
    expect(
      shown(backspace('☐ Send the weekly report\n☐ |')),
      '☐ Send the weekly report\n  |',
    );
  });

  test('Backspace on an empty task with no task above is left alone', () {
    final before = at('☐ |');
    final caret = before.selection.extentOffset;
    final typed = TextEditingValue(
      text: before.text.replaceRange(caret - 1, caret, ''),
      selection: TextSelection.collapsed(offset: caret - 1),
    );
    expect(backspaceEmptyTaskToDetails(before, typed), isNull);
  });

  test('Enter on an empty details line leaves and starts the next task', () {
    expect(
      shown(enter('☐ Hide it\n  The menu stays up.\n  |')),
      '☐ Hide it\n  The menu stays up.\n☐ |',
    );
  });

  test('Enter on a details line that has words stays inside', () {
    expect(
      shown(enter('☐ Hide it\n  The menu stays up.|')),
      '☐ Hide it\n  The menu stays up.\n  |',
    );
    expect(
      shown(enter('☐ Hide it\n  The menu| stays up.')),
      '☐ Hide it\n  The menu\n  | stays up.',
    );
  });

  test('a blank line between indented paragraphs still belongs after Enter', () {
    const note = '☐ Hide it\n  First.\n\n  Second.|';
    expect(shown(enter(note)), '☐ Hide it\n  First.\n\n  Second.\n  |');
  });

  test('a picture pasted under a task is indented so it belongs', () {
    const before = '☐ Hide it\n';
    final raw = insertImagesIntoBody(
      body: before,
      existing: const [],
      caret: before.length,
      incoming: [_image()],
    );
    final attached = attachMediaUnderTask(bodyBefore: before, inserted: raw);
    expect(attached.body, '☐ Hide it\n  ￼\n');
    expect(attached.attachments.single.offset, attached.body.indexOf('￼'));
  });

  test('a picture pasted somewhere else is not pulled under the task', () {
    const before = '☐ Hide it\n\nAfter.\n';
    final caret = before.indexOf('After');
    final raw = insertImagesIntoBody(
      body: before,
      existing: const [],
      caret: caret,
      incoming: [_image()],
    );
    final attached = attachMediaUnderTask(bodyBefore: before, inserted: raw);
    expect(attached.body, raw.body);
  });
}
