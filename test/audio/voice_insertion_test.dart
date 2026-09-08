import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/voice_insertion.dart';

const anchor = NoteAttachmentRef.placeholder;

NoteVoiceRef recording({String hash = 'v1'}) => NoteVoiceRef(
  offset: 0,
  hash: hash,
  key: Uint8List(32),
  bytes: 1024,
  durationMs: 5000,
);

NoteImageRef picture(int offset) => NoteImageRef(
  offset: offset,
  hash: 'pic',
  key: Uint8List(32),
  mime: 'image/png',
  width: 4,
  height: 3,
  bytes: 12,
);

void main() {
  test('an empty note gets the chip and a line to write on', () {
    final result = insertVoiceIntoBody(
      body: '',
      existing: const [],
      caret: 0,
      incoming: recording(),
    );
    expect(result.body, '$anchor\n');
    expect(result.attachments.single.offset, 0);
    expect(result.selection, 2);
  });

  test('a recording started mid-sentence does not split the sentence', () {
    final result = insertVoiceIntoBody(
      body: 'Milk and bread',
      existing: const [],
      caret: 4,
      incoming: recording(),
    );
    expect(result.body, 'Milk\n$anchor\n and bread');
    expect(result.attachments.single.offset, 5);
  });

  test('it always takes its own line, never the end of a full one', () {
    final result = insertVoiceIntoBody(
      body: 'Groceries',
      existing: const [],
      caret: 9,
      incoming: recording(),
    );
    expect(result.body, 'Groceries\n$anchor\n');
  });

  test('the caret lands after the chip, ready to type', () {
    final result = insertVoiceIntoBody(
      body: 'Notes\n',
      existing: const [],
      caret: 6,
      incoming: recording(),
    );
    expect(result.body, 'Notes\n$anchor\n');
    expect(result.selection, 8);
    expect(result.body.substring(result.selection), '');
  });

  test('an attachment already in the note slides along', () {
    final result = insertVoiceIntoBody(
      body: '$anchor\nlater',
      existing: [picture(0)],
      caret: 2,
      incoming: recording(),
    );
    expect(result.attachments.map((r) => r.offset), [0, 2]);
    expect(result.attachments.first, isA<NoteImageRef>());
    expect(result.attachments.last, isA<NoteVoiceRef>());
  });

  test('one before the caret does not move', () {
    final result = insertVoiceIntoBody(
      body: 'a$anchor b',
      existing: [picture(1)],
      caret: 3,
      incoming: recording(),
    );
    expect(result.attachments.first.offset, 1);
  });

  group('appending, when the note is not on screen', () {
    test('a recording that outlived its editor still lands', () {
      final result = appendVoiceToBody(
        body: 'Shopping list',
        existing: const [],
        incoming: recording(),
      );
      expect(result.body, 'Shopping list\n$anchor\n');
      expect(result.attachments.single.hash, 'v1');
    });

    test('appending to an empty note is not a blank first line', () {
      final result = appendVoiceToBody(
        body: '',
        existing: const [],
        incoming: recording(),
      );
      expect(result.body, '$anchor\n');
    });

    test('two recordings appended in turn each get their own line', () {
      final first = appendVoiceToBody(
        body: '',
        existing: const [],
        incoming: recording(),
      );
      final second = appendVoiceToBody(
        body: first.body,
        existing: first.attachments,
        incoming: recording(hash: 'v2'),
      );
      expect(second.body, '$anchor\n$anchor\n');
      expect(second.attachments.map((r) => r.hash), ['v1', 'v2']);
      expect(second.attachments.map((r) => r.offset), [0, 2]);
    });
  });
}
