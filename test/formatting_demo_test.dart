import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_format.dart';

void main() {
  test('the bundled demo store exercises every persisted formatting kind', () {
    final root =
        jsonDecode(
              File('demo/kapy-notes-formatting-demo.json').readAsStringSync(),
            )
            as Map<String, Object?>;
    final notes = root['notes.v1']! as List<Object?>;
    final note = Note.fromJson(notes.single);

    expect(note, isNotNull);
    expect(note!.body, contains('Heading, Subtitle, and Text'));
    expect(note.body, contains('// only this comment is lightened'));
    expect(note.body, contains('• A clean bulleted item'));
    expect(note.body, contains('☐ An open task'));
    expect(note.body, contains('☑ A completed task'));
    expect(
      note.formats.map((range) => range.format).toSet(),
      NoteFormat.values.toSet(),
    );
  });
}
