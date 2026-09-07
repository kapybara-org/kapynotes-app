import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/export/archive.dart';
import 'package:kapy_notes/export/manifest.dart';

const anchor = NoteAttachmentRef.placeholder;

Uint8List picture(int seed) =>
    Uint8List.fromList(List.generate(512, (i) => (i * 7 + seed) & 0xFF));

NoteAttachmentRef ref(int offset, String hash) => NoteImageRef(
  offset: offset,
  hash: hash,
  key: Uint8List(32),
  mime: 'image/png',
  width: 640,
  height: 480,
  bytes: 512,
);

void main() {
  final bytes = picture(1);
  // The store names a file by the sha256 of its contents; the test uses a
  // stand-in name, since nothing here recomputes it.
  const hash = 'aa11';
  final note = Note(
    id: 'note-1',
    body: 'A trip\n$anchor\nand what it cost',
    attachments: [ref(7, hash)],
    createdAt: DateTime.utc(2026, 9, 1),
    updatedAt: DateTime.utc(2026, 9, 2),
  );

  Uint8List build([Map<String, Uint8List>? images]) => buildExportArchive(
    notes: [note],
    appVersion: '1.12.0',
    exportedAt: DateTime.utc(2026, 9, 2),
    imageBytes: images ?? {hash: bytes},
  );

  test('the picture is written beside the notes, and linked from one', () {
    final contents = readExportArchive(build());
    expect(contents.isReadable, isTrue);
    expect(contents.images, contains('$exportImagesDirectory/$hash.png'));
    expect(contents.images.values.single, bytes);

    final markdown = contents.markdown.values.single;
    expect(markdown, contains('![](../images/$hash.png)'));
    // The placeholder character itself never reaches the file: a reader
    // opening this in another editor sees an image, not an invisible glyph.
    expect(markdown.contains(anchor), isFalse);
  });

  test('reading it back restores the note exactly', () {
    final contents = readExportArchive(build());
    final entry = contents.manifest!.notes.single;
    final read = noteFromArchive(
      entry,
      contents.markdown,
      availableImages: contents.images.keys.toSet(),
    )!;

    expect(read.handEdited, isFalse);
    expect(read.note.body, note.body);
    final restored = read.note.attachments.single as NoteImageRef;
    expect(restored.hash, hash);
    expect(restored.offset, 7);
    expect(restored.width, 640);
    expect(restored.mime, 'image/png');
    // A fresh key, because the archive carried none.
    expect(restored.key, hasLength(32));
    expect(restored.attachmentId, isNull);
  });

  test('a note whose picture is missing still comes back, without it', () {
    final contents = readExportArchive(build(const {}));
    final entry = contents.manifest!.notes.single;
    final read = noteFromArchive(entry, contents.markdown)!;

    // The words survive; the image does not, because there were no bytes.
    expect(read.note.body, contains('A trip'));
    expect(read.note.attachments, isEmpty);
    // And no orphaned placeholder is left drawing an empty box.
    expect(read.note.body.contains(anchor), isFalse);
  });

  test('one picture in two notes is stored once', () {
    final second = Note(
      id: 'note-2',
      body: 'again\n$anchor',
      attachments: [ref(6, hash)],
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
    );
    final contents = readExportArchive(
      buildExportArchive(
        notes: [note, second],
        appVersion: '1.12.0',
        exportedAt: DateTime.utc(2026, 9, 2),
        imageBytes: {hash: bytes},
      ),
    );
    expect(contents.images, hasLength(1));
    expect(contents.manifest!.notes, hasLength(2));
  });
}
