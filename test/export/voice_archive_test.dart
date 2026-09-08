import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/export/archive.dart';
import 'package:kapy_notes/export/manifest.dart';

const anchor = NoteAttachmentRef.placeholder;
const hash = 'bb22';

final audio = Uint8List.fromList(List.generate(256, (i) => (i * 3) & 0xFF));

NoteVoiceRef recording({
  int offset = 7,
  VoiceTranscript? transcript,
  VoiceSummary? summary,
}) => NoteVoiceRef(
  offset: offset,
  hash: hash,
  key: Uint8List(32),
  bytes: 256,
  durationMs: 134000,
  transcript: transcript,
  summary: summary,
);

final transcript = VoiceTranscript(
  lang: 'en',
  engine: 'cf/deepgram-nova-3',
  at: 1757260000000,
  segments: const [
    TranscriptSegment(s: 0, e: 1500, t: 'renew the lease in March'),
    TranscriptSegment(s: 1500, e: 3000, t: 'and ring the landlord'),
  ],
);

final summary = VoiceSummary(
  engine: 'cf/llama-3.3-70b',
  at: 1757260001000,
  title: 'Flat admin',
  points: const ['The lease is up in March.', 'Ring the landlord.'],
);

Note noteWith(NoteVoiceRef ref) => Note(
  id: 'note-1',
  body: 'Monday\n$anchor\nand then lunch',
  attachments: [ref],
  createdAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 2),
);

Uint8List build(NoteVoiceRef ref, {Map<String, Uint8List>? bytes}) =>
    buildExportArchive(
      notes: [noteWith(ref)],
      appVersion: '1.14.0',
      exportedAt: DateTime.utc(2026, 9, 2),
      imageBytes: bytes ?? {hash: audio},
    );

void main() {
  test('the recording is written where a person can play it', () {
    final contents = readExportArchive(build(recording()));
    expect(contents.isReadable, isTrue);
    expect(
      contents.images,
      contains('$exportAttachmentsDirectory/$hash.m4a'),
    );
    expect(contents.images.values.single, audio);
  });

  test('it is linked as a link, not as a broken image', () {
    // `![]()` on an audio file renders as a broken picture everywhere.
    final markdown = readExportArchive(build(recording())).markdown.values.single;
    expect(markdown, contains('](../attachments/$hash.m4a)'));
    expect(markdown, isNot(contains('![](../attachments/')));
    // The placeholder never reaches the file: it is invisible in every editor.
    expect(markdown.contains(anchor), isFalse);
  });

  test('the link is titled by the summary when there is one', () {
    final markdown = readExportArchive(
      build(recording(summary: summary)),
    ).markdown.values.single;
    expect(markdown, contains('[Flat admin 2:14](../attachments/$hash.m4a)'));
  });

  test('and by its length when there is not', () {
    final markdown = readExportArchive(build(recording())).markdown.values.single;
    expect(markdown, contains('[Voice note 2:14](../attachments/$hash.m4a)'));
  });

  test('reading it back restores the recording where it was', () {
    final contents = readExportArchive(build(recording()));
    final read = noteFromArchive(
      contents.manifest!.notes.single,
      contents.markdown,
      availableImages: contents.images.keys.toSet(),
    )!;

    expect(read.handEdited, isFalse);
    expect(read.note.body, 'Monday\n$anchor\nand then lunch');
    final restored = read.note.attachments.single as NoteVoiceRef;
    expect(restored.hash, hash);
    expect(restored.offset, 7);
    expect(restored.durationMs, 134000);
    expect(restored.mime, 'audio/mp4');
    // A fresh key: the archive carried none, and this device is the only place
    // this copy has ever lived.
    expect(restored.key, hasLength(32));
  });

  test('the words survive the round trip, so nothing is transcribed twice', () {
    final contents = readExportArchive(
      build(recording(transcript: transcript, summary: summary)),
    );
    final read = noteFromArchive(
      contents.manifest!.notes.single,
      contents.markdown,
      availableImages: contents.images.keys.toSet(),
    )!;
    final restored = read.note.attachments.single as NoteVoiceRef;

    expect(restored.transcript!.lang, 'en');
    expect(restored.transcript!.engine, 'cf/deepgram-nova-3');
    expect(restored.transcript!.segments, hasLength(2));
    expect(restored.transcript!.segments.first.t, 'renew the lease in March');
    expect(restored.summary!.title, 'Flat admin');
    expect(restored.summary!.points, hasLength(2));
  });

  test('a recording this device never downloaded is left out entirely', () {
    // Writing a link to bytes that are not in the archive would produce an
    // export that looks complete and is not.
    final contents = readExportArchive(build(recording(), bytes: {}));
    expect(contents.images, isEmpty);
    final markdown = contents.markdown.values.single;
    expect(markdown, isNot(contains('attachments/')));
    expect(markdown.contains(anchor), isFalse);
  });

  test('a note holding both kinds keeps them in order', () {
    final note = Note(
      id: 'note-2',
      body: '$anchor\n$anchor',
      attachments: [
        NoteImageRef(
          offset: 0,
          hash: 'aa11',
          key: Uint8List(32),
          mime: 'image/png',
          width: 4,
          height: 3,
          bytes: 12,
        ),
        recording(offset: 2),
      ],
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
    );
    final archive = buildExportArchive(
      notes: [note],
      appVersion: '1.14.0',
      exportedAt: DateTime.utc(2026, 9, 2),
      imageBytes: {'aa11': audio, hash: audio},
    );

    final contents = readExportArchive(archive);
    final read = noteFromArchive(
      contents.manifest!.notes.single,
      contents.markdown,
      availableImages: contents.images.keys.toSet(),
    )!;
    expect(read.note.attachments.map((r) => r.runtimeType.toString()), [
      'NoteImageRef',
      'NoteVoiceRef',
    ]);
    expect(read.note.attachments.map((r) => r.offset), [0, 2]);
  });

  test('the archive says it is schema 2', () {
    expect(readExportArchive(build(recording())).manifest!.schema, 2);
  });
}
