import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';

const anchor = NoteAttachmentRef.placeholder;

NoteVoiceRef recording({
  VoiceTranscript? transcript,
  VoiceSummary? summary,
  int offset = 0,
}) => NoteVoiceRef(
  offset: offset,
  hash: 'v1',
  key: Uint8List(32),
  bytes: 1024,
  durationMs: 5000,
  transcript: transcript,
  summary: summary,
);

VoiceTranscript spoken(List<String> lines) => VoiceTranscript(
  lang: 'en',
  engine: 'cf/deepgram-nova-3',
  at: 1,
  segments: [
    for (var i = 0; i < lines.length; i++)
      TranscriptSegment(s: i * 1000, e: (i + 1) * 1000, t: lines[i]),
  ],
);

Note noteWith(String body, List<NoteAttachmentRef> attachments) => Note(
  id: 'n1',
  body: body,
  attachments: attachments,
  createdAt: DateTime.utc(2026, 9, 7),
  updatedAt: DateTime.utc(2026, 9, 7),
);

void main() {
  group('search finds what was said', () {
    test('a word only in a transcript matches', () {
      final note = noteWith(anchor, [
        recording(transcript: spoken(['we should renew the lease in March'])),
      ]);
      expect(note.matches('lease'), isTrue);
      expect(note.matches('mortgage'), isFalse);
    });

    test('a word only in a summary matches', () {
      final note = noteWith(anchor, [
        recording(
          summary: VoiceSummary(
            engine: 'cf/llama',
            at: 1,
            title: 'Kitchen plans',
            points: ['Order the tiles before Friday.'],
          ),
        ),
      ]);
      expect(note.matches('tiles'), isTrue);
      expect(note.matches('Kitchen'), isTrue);
    });

    test('matching is case-insensitive across both', () {
      final note = noteWith(anchor, [
        recording(transcript: spoken(['Call Priya back'])),
      ]);
      expect(note.matches('PRIYA'), isTrue);
    });

    test('a note with no recording behaves exactly as before', () {
      final note = noteWith('milk and bread', const []);
      expect(note.matches('bread'), isTrue);
      expect(note.matches('cheese'), isFalse);
    });
  });

  group('the snippet says why a note matched', () {
    test('text in the note wins, and loses its placeholder', () {
      final note = noteWith('$anchor\nbuy the lease paperwork', [
        recording(transcript: spoken(['something else entirely'])),
      ]);
      expect(note.matchSnippet('lease'), 'buy the lease paperwork');
    });

    test('a spoken match is marked, so it is not mistaken for typed text', () {
      final note = noteWith(anchor, [
        recording(transcript: spoken(['we should renew the lease in March'])),
      ]);
      expect(note.matchSnippet('lease'), '🎙 we should renew the lease in March');
    });

    test('the matching segment is shown, not the whole transcript', () {
      final note = noteWith(anchor, [
        recording(transcript: spoken(['first thing', 'the lease again', 'last thing'])),
      ]);
      expect(note.matchSnippet('lease'), '🎙 the lease again');
    });

    test('a summary point is preferred over a transcript segment', () {
      // The summary is the tidier sentence, and it is what the chip shows.
      final note = noteWith(anchor, [
        recording(
          transcript: spoken(['um so the the lease thing']),
          summary: VoiceSummary(
            engine: 'cf/llama',
            at: 1,
            title: 'Flat',
            points: ['The lease is up in March.'],
          ),
        ),
      ]);
      expect(note.matchSnippet('lease'), '🎙 The lease is up in March.');
    });

    test('no match anywhere is null', () {
      final note = noteWith(anchor, [recording(transcript: spoken(['hello']))]);
      expect(note.matchSnippet('mortgage'), isNull);
    });
  });

  group('a note that is only a recording still has a name', () {
    test('the summary titles it', () {
      final note = noteWith(anchor, [
        recording(
          summary: VoiceSummary(
            engine: 'cf/llama',
            at: 1,
            title: 'Standup thoughts',
            points: ['Ship the thing.'],
          ),
        ),
      ]);
      expect(note.title, 'Standup thoughts');
    });

    test('before the summary arrives it is a voice note, not Untitled', () {
      expect(noteWith(anchor, [recording()]).title, 'Voice note');
    });

    test('typed text still wins over the summary', () {
      final note = noteWith('Monday\n$anchor', [
        recording(
          offset: 7,
          summary: VoiceSummary(
            engine: 'cf/llama',
            at: 1,
            title: 'Standup thoughts',
            points: ['Ship it.'],
          ),
        ),
      ]);
      expect(note.title, 'Monday');
    });

    test('an image-only note is still Untitled, as it was', () {
      final note = noteWith(anchor, [
        NoteImageRef(
          offset: 0,
          hash: 'i',
          key: Uint8List(32),
          mime: 'image/png',
          width: 2,
          height: 2,
          bytes: 4,
        ),
      ]);
      expect(note.title, Note.untitled);
    });
  });
}
