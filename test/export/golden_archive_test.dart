import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/export/archive.dart';
import 'package:kapy_notes/export/importer.dart';
import 'package:kapy_notes/export/manifest.dart';

/// An archive written by the build that first shipped export, checked in.
///
/// The point is not that the bytes never change — it is that a change to the
/// format which stops last release's export from opening has to be a decision
/// somebody made, not one this file lets through quietly. Regenerate it with
/// `dart run tool/make_golden_archive.dart`, and read the diff when you do.
Uint8List _golden() =>
    File('test/goldens/archives/schema-1.zip').readAsBytesSync();

void main() {
  test('a schema 1 archive still opens', () {
    final contents = readExportArchive(_golden());

    expect(contents.isReadable, isTrue);
    expect(contents.problems, isEmpty);
    expect(contents.manifest!.schema, 1);
    expect(contents.manifest!.appVersion, '1.6.0');
    expect(contents.manifest!.notes, hasLength(5));
  });

  test('its notes still come back with their formatting', () {
    final contents = readExportArchive(_golden());
    final entry = contents.manifest!.notes.firstWhere(
      (note) => note.path == 'notes/weekly-review.md',
    );

    final read = noteFromArchive(entry, contents.markdown)!;
    expect(read.handEdited, isFalse, reason: 'the hashes still agree');
    expect(
      read.note.body,
      'Weekly review\nsomething bold and something italic\n'
      'literals: *star* _score_ #hash `tick` [bracket]',
    );
    expect(read.note.formats, [
      const NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
      const NoteFormatRange(start: 24, end: 28, format: NoteFormat.bold),
      const NoteFormatRange(start: 43, end: 49, format: NoteFormat.italic),
    ]);
  });

  test('a line of arithmetic is still readable markdown', () {
    final contents = readExportArchive(_golden());
    expect(
      contents.markdown['notes/lisbon-trip-budget.md'],
      contains('daily * 7'),
    );
  });

  test('it still plans as a clean restore into an empty device', () {
    final plan = ImportPlan.from(
      archive: readExportArchive(_golden()),
      existing: const [],
      tombstones: const [],
      mode: ImportMode.restore,
      now: DateTime.utc(2026, 9, 10),
    );

    expect(plan.applyCount, 5);
    expect(plan.problems, isEmpty);
    expect(plan.handEditedCount, 0);
  });

  test('the names it chose are still the names it chooses', () {
    final contents = readExportArchive(_golden());
    expect(contents.markdown.keys, {
      'notes/lisbon-trip-budget.md',
      'notes/weekly-review.md',
      'notes/réunion-hebdo.md',
      'notes/weekly-review-2.md',
      'notes/note-55555555.md',
    });
    expect(exportSchemaVersion, 1, reason: 'bump the golden when this moves');
  });
}
