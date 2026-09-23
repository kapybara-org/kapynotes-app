import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/export/archive.dart';
import 'package:kapy_notes/export/manifest.dart';
import 'package:kapy_notes/files/file_opener.dart';
import 'package:kapy_notes/files/file_ingest.dart';
import 'package:kapy_notes/ui/editor/file_insertion.dart';

const anchor = NoteAttachmentRef.placeholder;

NoteFileRef file({
  int offset = 0,
  String hash = 'ab12cd34ef56ab12cd34',
  String name = 'Invoice.pdf',
  int bytes = 2048,
}) => NoteFileRef(
  offset: offset,
  hash: hash,
  key: Uint8List(32),
  mime: 'application/pdf',
  bytes: bytes,
  name: name,
);

void main() {
  group('NoteFileRef', () {
    test('round-trips through JSON as its own kind', () {
      final ref = file().copyWith(attachmentId: 'att-1');
      final json = ref.toJson();
      expect(json['kind'], 'file');
      expect(NoteAttachmentRef.fromJson(json), ref);
    });

    test('a record without a name is kept whole, not dropped', () {
      // Dropped, the next write would have taken it out of the note for
      // everyone; kept as a kind this build cannot read, it goes back out
      // exactly as it came.
      final json = file().toJson()..remove('name');
      final ref = NoteAttachmentRef.fromJson(json);
      expect(ref, isA<NoteUnknownRef>());
      expect(ref!.toJson(), json);
    });

    test('a name cannot hide a program behind a direction override', () {
      final ref = file(name: sanitizeFileName('invoice\u202Efdp.exe'));
      expect(ref.name, 'invoicefdp.exe');
      expect(isExecutableFile(ref), isTrue);
    });

    test('programs and what runs them are never opened', () {
      for (final name in ['x.appref-ms', 'x.scpt', 'x.webloc', 'x.chm']) {
        expect(isExecutableFile(file(name: name)), isTrue, reason: name);
      }
      expect(isExecutableFile(file(name: 'Invoice.pdf')), isFalse);
    });

    test('a name from another device cannot become a path here', () {
      final json = file().toJson()..['name'] = '../../Library/evil.sh';
      final ref = NoteAttachmentRef.fromJson(json)! as NoteFileRef;
      expect(ref.name, 'evil.sh');
    });

    test('sanitises names without losing the extension', () {
      expect(sanitizeFileName(r'C:\Users\me\Q3 report.pdf'), 'Q3 report.pdf');
      expect(sanitizeFileName('a\u0000b<c>:d|e?.txt'), 'a_b_c__d_e_.txt');
      expect(sanitizeFileName('..hidden'), 'hidden');
      expect(sanitizeFileName('trailing. '), 'trailing');
      expect(sanitizeFileName('   '), 'File');
      final long = sanitizeFileName('${'x' * 400}.docx');
      expect(long.length, NoteFileRef.maxNameLength);
      expect(long, endsWith('.docx'));
    });

    test('only a plain extension reaches the disk', () {
      expect(fileExtensionOf('Report.PDF'), '.pdf');
      expect(fileExtensionOf('archive.tar.gz'), '.gz');
      expect(fileExtensionOf('noext'), '');
      expect(fileExtensionOf('.bashrc'), '');
      expect(fileExtensionOf('x.p d f'), '');
      expect(fileExtensionOf('x.${'a' * 30}'), '');
    });

    test('an older build keeps a file it cannot draw, byte for byte', () {
      // What a pre-files build does with it is covered by NoteUnknownRef; this
      // pins the record a newer build writes, so that promise holds for it.
      final json = file().toJson();
      json['kind'] = 'file-v2';
      final unknown = NoteAttachmentRef.fromJson(json)! as NoteUnknownRef;
      expect(unknown.toJson(), json);
    });
  });

  group('insertFilesIntoBody', () {
    test('puts each file on its own line and the caret after them', () {
      final result = insertFilesIntoBody(
        body: 'Receipts',
        existing: const [],
        caret: 8,
        incoming: [
          file(hash: 'a' * 20),
          file(hash: 'b' * 20),
        ],
      );
      expect(result.body, 'Receipts\n$anchor\n$anchor\n');
      expect(result.attachments.map((ref) => ref.offset), [9, 11]);
      expect(result.selection, result.body.length);
    });

    test('moves attachments after the caret along', () {
      final existing = [file(offset: 5, hash: 'c' * 20)];
      final result = insertFilesIntoBody(
        body: 'one\n\n$anchor\n',
        existing: existing,
        caret: 4,
        incoming: [file(hash: 'd' * 20)],
      );
      expect(result.body, 'one\n$anchor\n\n$anchor\n');
      expect(result.attachments.map((ref) => ref.hash), ['d' * 20, 'c' * 20]);
      expect(result.attachments.map((ref) => ref.offset), [4, 7]);
    });
  });

  group('ingestFileAttachments', () {
    late Directory root;
    late BlobStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kapy-file-ingest');
      store = BlobStore(directory: Directory('${root.path}/store'));
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<XFile> write(String name, List<int> bytes) async {
      final file = File('${root.path}/$name');
      await file.writeAsBytes(bytes);
      return XFile(file.path, name: name);
    }

    test('copies the file in, leaving the original where it was', () async {
      final bytes = List.generate(5000, (i) => i & 0xFF);
      final picked = await write('Budget 2026.xlsx', bytes);

      final batch = await ingestFileAttachments([picked], store: store);

      expect(batch.rejections, isEmpty);
      final ref = batch.files.single;
      expect(ref.name, 'Budget 2026.xlsx');
      expect(ref.bytes, 5000);
      expect(ref.mime, contains('spreadsheetml'));
      expect(ref.key, hasLength(32));
      expect(await store.read(ref.hash), bytes);
      expect((await store.fileFor(ref.hash))!.path, endsWith('.xlsx'));
      expect(await File(picked.path).readAsBytes(), bytes);
    });

    test('refuses what cannot be sent, by name, and keeps the rest', () async {
      final ok = await write('notes.txt', [1, 2, 3]);
      final empty = await write('empty.txt', const []);
      final big = await write('big.bin', List.filled(2048, 7));
      final folder = await Directory('${root.path}/Folder').create();

      final batch = await ingestFileAttachments(
        [ok, empty, big, XFile(folder.path, name: 'Folder')],
        store: store,
        attachmentMaxBytes: 1024 + fileSealingOverhead,
      );

      expect(batch.files.map((ref) => ref.name), ['notes.txt']);
      expect(
        {for (final r in batch.rejections) r.name: r.reason},
        {
          'empty.txt': FileRejection.empty,
          'big.bin': FileRejection.tooLarge,
          'Folder': FileRejection.directory,
        },
      );
      // A refused file was never copied in.
      expect(await store.totalBytes(), 3);
    });

    test('names the files beyond the selection limit', () async {
      final picked = [
        for (var i = 0; i < 3; i++) await write('f$i.txt', [i + 1]),
      ];
      final batch = await ingestFileAttachments(picked, store: store, limit: 2);
      expect(batch.files, hasLength(2));
      expect(batch.rejections.single, (
        name: 'f2.txt',
        reason: FileRejection.tooMany,
      ));
    });

    test('a file that vanished before it was read is refused', () async {
      final gone = await write('gone.pdf', [1]);
      await File(gone.path).delete();
      final batch = await ingestFileAttachments([gone], store: store);
      expect(batch.files, isEmpty);
      expect(batch.rejections.single.reason, FileRejection.unreadable);
    });
  });

  group('BlobStore', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kapy-blob-store');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('a copy that fails partway leaves nothing behind', () async {
      final store = BlobStore(directory: root);
      Stream<List<int>> broken() async* {
        yield [1, 2, 3];
        throw const FileSystemException('disk full');
      }

      await expectLater(
        store.importStream(broken(), extension: '.pdf'),
        throwsA(isA<FileSystemException>()),
      );
      final left = await root.list(recursive: true).toList();
      expect(left.whereType<File>(), isEmpty);
    });

    test('a sweep spares a blob still being attached', () async {
      var now = DateTime.now();
      final store = BlobStore(directory: root, now: () => now);
      final hash = await store.put(Uint8List.fromList([9, 9, 9]));

      expect(await store.sweep(const {}), 0);
      expect(await store.has(hash), isTrue);

      now = now.add(const Duration(hours: 1));
      expect(await store.sweep(const {}), 3);
      expect(await store.has(hash), isFalse);
    });
  });

  group('export', () {
    const hash = 'ee55ee55ee55ee55ee55';
    final bytes = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));

    Uint8List build(
      List<NoteAttachmentRef> refs,
      String body, {
      Map<String, Uint8List>? blobs,
    }) => buildExportArchive(
      notes: [
        Note(
          id: 'file-note',
          body: body,
          attachments: refs,
          createdAt: DateTime.utc(2026, 9, 1),
          updatedAt: DateTime.utc(2026, 9, 2),
        ),
      ],
      appVersion: '1.28.0',
      exportedAt: DateTime.utc(2026, 9, 2),
      imageBytes: blobs ?? {hash: bytes},
    );

    test('writes the file under its extension, linked by its name', () {
      final contents = readExportArchive(
        build([
          file(offset: 6, hash: hash, name: 'Tax [final].pdf'),
        ], 'Taxes\n$anchor\n'),
      );
      expect(contents.images['attachments/$hash.pdf'], bytes);
      expect(
        contents.markdown.values.single,
        contains('[Tax (final).pdf](../attachments/$hash.pdf)'),
      );
    });

    test('restores the file with its name and size', () {
      final contents = readExportArchive(
        build([file(offset: 6, hash: hash, bytes: 300)], 'Taxes\n$anchor\n'),
      );
      final read = noteFromArchive(
        contents.manifest!.notes.single,
        contents.markdown,
        availableImages: contents.images.keys.toSet(),
      )!;
      final restored = read.note.attachments.single as NoteFileRef;
      expect(read.note.body, 'Taxes\n$anchor\n');
      expect(restored.name, 'Invoice.pdf');
      expect(restored.bytes, 300);
      expect(restored.offset, 6);
    });

    test('only an archive with a file in it needs the files schema', () {
      final withFile = readExportArchive(
        build([file(offset: 6, hash: hash)], 'Taxes\n$anchor\n'),
      );
      expect(withFile.manifest!.schema, exportSchemaVersion);
      final without = readExportArchive(build(const [], 'Taxes\n'));
      expect(without.manifest!.schema, exportSchemaVersion - 1);
    });

    test('a file this device never downloaded does not shift later links', () {
      // Before, the missing file's placeholder took the next attachment's
      // link, and every link after it moved up one.
      const other = 'ff66ff66ff66ff66ff66';
      final contents = readExportArchive(
        build(
          [
            file(offset: 0, hash: 'missing0missing0miss'),
            file(offset: 2, hash: other, name: 'Kept.txt'),
          ],
          '$anchor\n$anchor\n',
          blobs: {other: bytes},
        ),
      );
      final markdown = contents.markdown.values.single;
      expect(markdown, '\n[Kept.txt](../attachments/$other.txt)\n');
    });
  });
}
