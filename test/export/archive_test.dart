import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/export/archive.dart';
import 'package:kapy_notes/export/manifest.dart';

Note _note({
  required String id,
  required String body,
  List<NoteFormatRange> formats = const [],
  DateTime? updatedAt,
}) => Note(
  id: id,
  body: body,
  formats: formats,
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: updatedAt ?? DateTime.utc(2026, 9, 1),
);

Uint8List _archiveOf(List<Note> notes) => buildExportArchive(
  notes: notes,
  appVersion: '1.6.0',
  exportedAt: DateTime.utc(2026, 9, 5, 10, 14),
);

/// Rebuilds a zip from a map of path to contents, for the awkward archives a
/// test needs and the exporter would never write.
Uint8List _zipOf(Map<String, String> files) {
  final archive = Archive();
  files.forEach((path, content) {
    archive.add(ArchiveFile.string(path, content));
  });
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  group('writing', () {
    test('lays out a manifest beside one markdown file per note', () {
      final contents = readExportArchive(
        _archiveOf([
          _note(id: 'a1', body: 'Weekly review\nnotes here'),
          _note(id: 'b2', body: 'Grocery list\nmilk'),
        ]),
      );

      expect(contents.isReadable, isTrue);
      expect(contents.manifest!.schema, exportSchemaVersion);
      expect(contents.manifest!.appVersion, '1.6.0');
      expect(contents.markdown.keys, {
        'notes/weekly-review.md',
        'notes/grocery-list.md',
      });
      expect(
        contents.markdown['notes/weekly-review.md'],
        'Weekly review\nnotes here',
      );
    });

    test('names a note after its first line, and never twice the same', () {
      final contents = readExportArchive(
        _archiveOf([
          _note(id: 'a1', body: 'Ideas'),
          _note(id: 'b2', body: 'Ideas'),
          _note(id: 'c3', body: 'Ideas'),
        ]),
      );
      expect(contents.markdown.keys, {
        'notes/ideas.md',
        'notes/ideas-2.md',
        'notes/ideas-3.md',
      });
    });

    test('falls back to the id when there is no title to use', () {
      final contents = readExportArchive(
        _archiveOf([_note(id: '8f2c1a90-dead-beef', body: '   ')]),
      );
      expect(contents.markdown.keys.single, 'notes/note-8f2c1a90.md');
    });

    test('does not hand Windows a name it refuses to open', () {
      final taken = <String>{};
      expect(archiveFileName('CON', 'id', taken), 'note-con.md');
      expect(archiveFileName('aux', 'id', taken), 'note-aux.md');
      expect(archiveFileName('a/b:c', 'id', taken), 'a-b-c.md');
    });
  });

  group('reading', () {
    test('a note comes back exactly as it went in', () {
      final formats = [
        const NoteFormatRange(start: 0, end: 6, format: NoteFormat.heading),
        const NoteFormatRange(start: 14, end: 18, format: NoteFormat.bold),
      ];
      final original = _note(
        id: 'a1',
        body: 'Budget for two\nrent and food',
        formats: normalizeNoteFormats(formats, 28),
      );

      final contents = readExportArchive(_archiveOf([original]));
      final read = noteFromArchive(
        contents.manifest!.notes.single,
        contents.markdown,
      )!;

      expect(read.handEdited, isFalse);
      expect(read.note.id, original.id);
      expect(read.note.body, original.body);
      expect(read.note.formats, original.formats);
      expect(
        read.note.createdAt.millisecondsSinceEpoch,
        original.createdAt.millisecondsSinceEpoch,
      );
      expect(
        read.note.updatedAt.millisecondsSinceEpoch,
        original.updatedAt.millisecondsSinceEpoch,
      );
    });

    test('the manifest wins over what markdown could not say', () {
      // A heading over half a line widens to the whole line in the `.md`, and
      // the exact range survives only because the manifest carries it.
      final original = _note(
        id: 'a1',
        body: 'Half a heading here',
        formats: const [
          NoteFormatRange(start: 0, end: 4, format: NoteFormat.heading),
        ],
      );
      final contents = readExportArchive(_archiveOf([original]));

      expect(contents.markdown.values.single, '# Half a heading here');
      final read = noteFromArchive(
        contents.manifest!.notes.single,
        contents.markdown,
      )!;
      expect(read.note.formats, [
        const NoteFormatRange(start: 0, end: 4, format: NoteFormat.heading),
      ]);
    });

    test('a hand-edited file is read from its text instead', () {
      final contents = readExportArchive(
        _archiveOf([_note(id: 'a1', body: 'Original')]),
      );
      final entry = contents.manifest!.notes.single;
      final edited = {entry.path: '**Rewritten by hand**'};

      final read = noteFromArchive(entry, edited)!;
      expect(read.handEdited, isTrue);
      expect(read.note.body, 'Rewritten by hand');
      expect(read.note.formats, [
        const NoteFormatRange(start: 0, end: 17, format: NoteFormat.bold),
      ]);
    });

    test('an entry that escapes the extraction root is refused', () {
      final bytes = _zipOf({
        '../../../etc/passwd': 'nope',
        '/tmp/absolute.md': 'nope',
        exportManifestPath: jsonEncode({
          'schema': 1,
          'app': 'KapyNotes',
          'appVersion': '1.6.0',
          'exportedAt': '2026-09-05T10:14:00Z',
          'notes': const [],
        }),
      });

      final contents = readExportArchive(bytes);
      expect(contents.isReadable, isTrue);
      expect(contents.problems.join(), contains('unsafe path'));
      expect(contents.markdown, isEmpty);
    });

    test('a manifest path that escapes is dropped with the entry', () {
      expect(isSafeArchivePath('notes/fine.md'), isTrue);
      expect(isSafeArchivePath('../outside.md'), isFalse);
      expect(isSafeArchivePath(r'notes\..\..\outside.md'), isFalse);
      expect(isSafeArchivePath('/etc/passwd'), isFalse);
      expect(isSafeArchivePath(r'C:\notes\x.md'), isFalse);
    });

    test('a truncated archive fails as one thing gone wrong', () {
      // A file in a sync folder that stopped halfway. A zip is indexed from
      // its tail, so there is nothing partial to salvage and the honest answer
      // is that this file is not readable.
      final full = _archiveOf([_note(id: 'a1', body: 'Something')]);
      final cut = Uint8List.sublistView(full, 0, full.length ~/ 2);

      final contents = readExportArchive(cut);
      expect(contents.isReadable, isFalse);
      expect(contents.fault, ArchiveFault.unreadable);
    });

    test('a note whose file is missing costs only that note', () {
      final good = readExportArchive(
        _archiveOf([
          _note(id: 'a1', body: 'Kept'),
          _note(id: 'b2', body: 'Lost'),
        ]),
      );
      final kept = good.manifest!.notes.firstWhere((n) => n.id == 'a1');
      final lost = good.manifest!.notes.firstWhere((n) => n.id == 'b2');

      expect(noteFromArchive(kept, good.markdown), isNotNull);
      expect(noteFromArchive(lost, const {}), isNull);
    });

    test('bytes that are not a zip at all fail as one thing gone wrong', () {
      final rubbish = Uint8List.fromList(
        List<int>.generate(2048, (index) => (index * 37) & 0xff),
      );
      expect(readExportArchive(rubbish).fault, ArchiveFault.unreadable);
    });

    test('a zip that is not an export says so', () {
      final contents = readExportArchive(_zipOf({'readme.txt': 'hello'}));
      expect(contents.fault, ArchiveFault.noManifest);
    });

    test('an archive from a newer version is refused, not guessed at', () {
      final contents = readExportArchive(
        _zipOf({
          exportManifestPath: jsonEncode({'schema': 2, 'notes': const []}),
        }),
      );
      expect(contents.fault, ArchiveFault.futureSchema);
      expect(contents.schema, 2);
    });

    test('one unreadable entry does not cost the rest of the archive', () {
      final good = readExportArchive(
        _archiveOf([_note(id: 'a1', body: 'Kept')]),
      );
      final entry = good.manifest!.notes.single;

      final contents = readExportArchive(
        _zipOf({
          entry.path: 'Kept',
          exportManifestPath: jsonEncode({
            'schema': 1,
            'app': 'KapyNotes',
            'appVersion': '1.6.0',
            'exportedAt': '2026-09-05T10:14:00Z',
            'notes': [
              entry.toJson(),
              {'id': 'broken'},
            ],
          }),
        }),
      );

      expect(contents.isReadable, isTrue);
      expect(contents.manifest!.notes, hasLength(1));
      expect(contents.problems.join(), contains('could not read'));
    });

    test('nothing at all is not an archive', () {
      expect(readExportArchive(Uint8List(0)).fault, ArchiveFault.unreadable);
    });
  });

  group('off the main isolate', () {
    // Export and import both hop to an isolate so a large archive does not
    // stall the thread the user is typing on. What crosses that boundary has
    // to be sendable, and nothing but running it actually proves that.
    test('an archive builds and reads back across an isolate', () async {
      final json = [
        _note(id: 'a1', body: 'Weekly review\nnotes here').toJson(),
        _note(id: 'b2', body: 'Grocery list').toJson(),
      ];

      final bytes = await Isolate.run(
        () => buildExportArchiveFromJson(
          notes: json,
          appVersion: '1.6.0',
          exportedAt: DateTime.utc(2026, 9, 5, 10, 14),
        ),
      );
      final contents = await Isolate.run(
        () => readExportArchiveFromBytes(bytes),
      );

      expect(contents.isReadable, isTrue);
      expect(contents.manifest!.notes, hasLength(2));
      expect(
        contents.markdown['notes/weekly-review.md'],
        'Weekly review\nnotes here',
      );
    });
  });
}
