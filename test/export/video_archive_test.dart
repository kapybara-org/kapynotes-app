import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/export/archive.dart';

const anchor = NoteAttachmentRef.placeholder;
const hash = 'cc33';

final videoBytes = Uint8List.fromList(
  List.generate(512, (index) => (index * 7) & 0xFF),
);

NoteVideoRef video({int offset = 7}) => NoteVideoRef(
  offset: offset,
  hash: hash,
  key: Uint8List(32),
  mime: 'video/mp4',
  bytes: videoBytes.length,
  width: 1920,
  height: 1080,
  durationMs: 95000,
  widthFactor: 0.6,
);

Uint8List buildVideoArchive() => buildExportArchive(
  notes: [
    Note(
      id: 'video-note',
      body: 'Monday\n$anchor\nand then lunch',
      attachments: [video()],
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
    ),
  ],
  appVersion: '1.15.0',
  exportedAt: DateTime.utc(2026, 9, 2),
  imageBytes: {hash: videoBytes},
);

void main() {
  test('writes a playable video file and a human-readable markdown link', () {
    final contents = readExportArchive(buildVideoArchive());

    expect(contents.isReadable, isTrue);
    expect(contents.images['attachments/$hash.mp4'], videoBytes);
    final markdown = contents.markdown.values.single;
    expect(markdown, contains('[Video 1:35](../attachments/$hash.mp4)'));
    expect(markdown, isNot(contains('![](../attachments/')));
    expect(markdown, isNot(contains(anchor)));
  });

  test(
    'restores video layout and playback metadata at its original anchor',
    () {
      final contents = readExportArchive(buildVideoArchive());
      final read = noteFromArchive(
        contents.manifest!.notes.single,
        contents.markdown,
        availableImages: contents.images.keys.toSet(),
      )!;

      expect(read.note.body, 'Monday\n$anchor\nand then lunch');
      final restored = read.note.attachments.single as NoteVideoRef;
      expect(restored.offset, 7);
      expect(restored.hash, hash);
      expect(restored.mime, 'video/mp4');
      expect(restored.width, 1920);
      expect(restored.height, 1080);
      expect(restored.durationMs, 95000);
      expect(restored.widthFactor, 0.6);
      expect(restored.key, hasLength(32));
    },
  );

  test('records video as schema 3 rather than letting old readers guess', () {
    final manifest = readExportArchive(buildVideoArchive()).manifest!;
    expect(manifest.schema, 3);
    expect(manifest.notes.single.images.single.kind, 'video');
  });
}
