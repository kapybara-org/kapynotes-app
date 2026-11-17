import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/note_lines.dart';

/// Checks every line, and every offset in it, against the plain string.
void expectLines(NoteLines lines, String text) {
  expect(lines.text, text);
  expect(lines.textLength, text.length);
  final split = text.split('\n');
  expect(lines.length, split.length);
  var start = 0;
  for (var line = 0; line < split.length; line++) {
    expect(lines[line], split[line]);
    expect(lines.startOf(line), start, reason: 'start of line $line');
    expect(lines.endOf(line), start + split[line].length);
    for (var offset = start; offset <= start + split[line].length; offset++) {
      expect(lines.lineAt(offset), line, reason: 'offset $offset');
    }
    start += split[line].length + 1;
  }
}

void main() {
  test('indexes every line of a note', () {
    for (final text in [
      '',
      '\n',
      'one',
      'one\ntwo',
      'one\n\nthree\n',
      '\n\n\n',
    ]) {
      expectLines(NoteLines(text), text);
    }
  });

  test('an edit inside a line replaces that line alone', () {
    final lines = NoteLines('alpha\nbeta\ngamma');

    expect(lines.replace(7, 9, 'ET'), (line: 1, removed: 1, inserted: 1));
    expectLines(lines, 'alpha\nbETa\ngamma');
  });

  test('splitting and joining lines report the lines they replace', () {
    final lines = NoteLines('alpha\nbeta\ngamma');

    expect(lines.replace(8, 8, '\n'), (line: 1, removed: 1, inserted: 2));
    expectLines(lines, 'alpha\nbe\nta\ngamma');
    expect(lines.replace(5, 9, ''), (line: 0, removed: 3, inserted: 1));
    expectLines(lines, 'alphata\ngamma');
  });

  test('an empty edit replaces nothing', () {
    final lines = NoteLines('alpha\nbeta');

    expect(lines.replace(8, 8, ''), (line: 1, removed: 0, inserted: 0));
    expectLines(lines, 'alpha\nbeta');
  });

  test('random edits keep the lines and their index in step with the text', () {
    final random = Random(14);
    const pieces = ['x', 'yz', '\n', '\n\n', 'a\nb', ''];
    var text = 'one\ntwo\n\nfour';
    final lines = NoteLines(text);
    for (var i = 0; i < 3000; i++) {
      final start = random.nextInt(text.length + 1);
      final end = start + random.nextInt(min(text.length - start, 6) + 1);
      final replacement = text.length > 120
          ? ''
          : pieces[random.nextInt(pieces.length)];
      final before = text.split('\n');

      final edit = lines.replace(start, end, replacement);
      text = text.replaceRange(start, end, replacement);

      final after = text.split('\n');
      expect(after.length - before.length, edit.inserted - edit.removed);
      expect(after.sublist(0, edit.line), before.sublist(0, edit.line));
      expect(
        after.sublist(edit.line + edit.inserted),
        before.sublist(edit.line + edit.removed),
      );
      expectLines(lines, text);
    }
  });
}
