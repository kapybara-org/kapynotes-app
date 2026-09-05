import 'dart:io';

import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/export/archive.dart';

/// Regenerates `test/goldens/archives/schema-1.zip`.
///
/// Only run this when the archive format is *meant* to change, and read the
/// diff when you do: the point of the golden is that a change which stops
/// last release's export from opening has to be a deliberate one.
///
///   dart run tool/make_golden_archive.dart
void main() {
  final notes = [
    Note(
      id: '11111111-1111-4111-8111-111111111111',
      body: 'Lisbon trip budget\nFlights for two\nflights = 412 eur\ndaily * 7',
      formats: const [
        NoteFormatRange(start: 0, end: 18, format: NoteFormat.heading),
        NoteFormatRange(start: 19, end: 34, format: NoteFormat.subtitle),
      ],
      createdAt: DateTime.utc(2026, 8, 1, 9),
      updatedAt: DateTime.utc(2026, 9, 4, 18, 2, 11),
    ),
    Note(
      id: '22222222-2222-4222-8222-222222222222',
      body: 'Weekly review\nsomething bold and something italic\nliterals: *star* '
          '_score_ #hash `tick` [bracket]',
      formats: const [
        NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
        NoteFormatRange(start: 24, end: 28, format: NoteFormat.bold),
        NoteFormatRange(start: 43, end: 49, format: NoteFormat.italic),
      ],
      createdAt: DateTime.utc(2026, 8, 2, 9),
      updatedAt: DateTime.utc(2026, 9, 3, 8, 30),
    ),
    Note(
      id: '33333333-3333-4333-8333-333333333333',
      body: 'Réunion hebdo\nnotes en français',
      createdAt: DateTime.utc(2026, 8, 3, 9),
      updatedAt: DateTime.utc(2026, 9, 2, 12),
    ),
    Note(
      id: '44444444-4444-4444-8444-444444444444',
      body: 'Weekly review\na second note that wants the same file name',
      createdAt: DateTime.utc(2026, 8, 4, 9),
      updatedAt: DateTime.utc(2026, 9, 1, 12),
    ),
    Note(
      id: '55555555-5555-4555-8555-555555555555',
      body: '   ',
      createdAt: DateTime.utc(2026, 8, 5, 9),
      updatedAt: DateTime.utc(2026, 8, 31, 12),
    ),
  ];

  final bytes = buildExportArchive(
    notes: notes,
    appVersion: '1.6.0',
    exportedAt: DateTime.utc(2026, 9, 5, 10, 14),
  );
  File('test/goldens/archives/schema-1.zip').writeAsBytesSync(bytes);
  stdout.writeln('wrote ${bytes.length} bytes');
}
