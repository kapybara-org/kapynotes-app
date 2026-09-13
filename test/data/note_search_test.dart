import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';

Note noteWith({
  required String body,
  List<NoteAttachmentRef> attachments = const [],
}) => Note(
  id: 'note-1',
  body: body,
  attachments: attachments,
  createdAt: DateTime.utc(2026, 9, 13),
  updatedAt: DateTime.utc(2026, 9, 13),
);

void main() {
  test('global terms can span a title and a deeply nested note line', () {
    final note = noteWith(
      body:
          '# Launch plan\n- Website\n  - Accessibility\n    - Check contrast tokens',
    );

    expect(note.matches('launch contrast'), isTrue);
    expect(note.matchSnippet('launch contrast'), '- Check contrast tokens');
    expect(note.matches('launch missing'), isFalse);
  });

  test('quotes keep an exact phrase together', () {
    final note = noteWith(
      body: 'Launch plan\n- Ask Priya about final contrast tokens',
    );

    expect(note.matches('"launch plan" contrast'), isTrue);
    expect(note.matches('"launch contrast"'), isFalse);
  });

  test('speaker names and generated voice content are searchable', () {
    final voice = NoteVoiceRef(
      offset: 0,
      hash: 'voice-1',
      key: Uint8List(32),
      bytes: 128,
      durationMs: 1000,
      transcript: VoiceTranscript(
        lang: 'en',
        engine: 'test',
        at: 1,
        segments: const [
          TranscriptSegment(s: 0, e: 1000, t: 'Review the release'),
        ],
        speakers: const {0: 'Priya Rao'},
      ),
      takes: const [
        VoiceTake(
          kind: VoiceTakeKind.linkedin,
          text: 'The launch announcement is ready.',
          engine: 'test',
          at: 2,
        ),
      ],
    );
    final note = noteWith(
      body: NoteAttachmentRef.placeholder,
      attachments: [voice],
    );

    expect(note.matches('Priya announcement'), isTrue);
    expect(
      note.matchSnippet('announcement'),
      'Post for LinkedIn: The launch announcement is ready.',
    );
  });
}
