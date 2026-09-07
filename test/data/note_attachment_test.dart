import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';

const anchor = NoteAttachmentRef.placeholder;

NoteImageRef ref(int offset, {String hash = 'a'}) => NoteImageRef(
  offset: offset,
  hash: hash,
  key: Uint8List(32),
  mime: 'image/png',
  width: 800,
  height: 600,
  bytes: 1024,
);

/// An edit with no caret to guide it — a sync, an import, a formatter.
List<NoteAttachmentRef> edit(
  String before,
  String after,
  List<NoteAttachmentRef> refs,
) => rebaseNoteAttachments(
  oldText: before,
  newText: after,
  attachments: refs,
);

/// Backspace at [caret]: the character *before* it goes.
List<NoteAttachmentRef> backspaceAt(
  String before,
  int caret,
  List<NoteAttachmentRef> refs,
) => rebaseNoteAttachments(
  oldText: before,
  newText: before.substring(0, caret - 1) + before.substring(caret),
  attachments: refs,
  selectionStart: caret,
  selectionEnd: caret,
);

void main() {
  group('normalizeNoteAttachments', () {
    test('keeps only refs that sit on a placeholder', () {
      final body = 'a$anchor b$anchor';
      final kept = normalizeNoteAttachments([
        ref(1, hash: 'one'),
        ref(4, hash: 'two'),
        ref(2, hash: 'nowhere'),
      ], body);
      expect(kept.map((r) => r.hash), ['one', 'two']);
    });

    test('sorts by offset regardless of input order', () {
      final body = '$anchor$anchor';
      final kept = normalizeNoteAttachments([
        ref(1, hash: 'second'),
        ref(0, hash: 'first'),
      ], body);
      expect(kept.map((r) => r.hash), ['first', 'second']);
    });

    test('two refs on one anchor keep the first deterministically', () {
      final kept = normalizeNoteAttachments([
        ref(0, hash: 'winner'),
        ref(0, hash: 'loser'),
      ], anchor);
      expect(kept.map((r) => r.hash), ['winner']);
    });

    test('a body with no placeholders keeps nothing', () {
      expect(normalizeNoteAttachments([ref(0)], 'plain text'), isEmpty);
    });
  });

  group('orphanedAttachmentAnchors', () {
    test('finds a placeholder no ref claims', () {
      expect(orphanedAttachmentAnchors('a$anchor', const []), [1]);
    });

    test('finds nothing when every placeholder is claimed', () {
      expect(orphanedAttachmentAnchors('a$anchor', [ref(1)]), isEmpty);
    });
  });

  group('rebaseNoteAttachments', () {
    test('typing before an image pushes it along', () {
      final refs = edit('x$anchor', 'xyz$anchor', [ref(1)]);
      expect(refs.single.offset, 3);
    });

    test('typing after an image leaves it alone', () {
      final refs = edit('$anchor x', '$anchor xyz', [ref(0)]);
      expect(refs.single.offset, 0);
    });

    test('deleting the placeholder deletes the image', () {
      expect(edit('a${anchor}b', 'ab', [ref(1)]), isEmpty);
    });

    test('backspacing the FIRST of three deletes the first', () {
      // The case a prefix/suffix diff gets wrong: three identical characters
      // produce the same string whichever one is removed, so only the caret
      // says which image the user actually deleted.
      final refs = backspaceAt('$anchor$anchor$anchor', 1, [
        ref(0, hash: 'one'),
        ref(1, hash: 'two'),
        ref(2, hash: 'three'),
      ]);
      expect(refs.map((r) => r.hash), ['two', 'three']);
      expect(refs.map((r) => r.offset), [0, 1]);
    });

    test('backspacing the MIDDLE of three deletes the middle', () {
      final refs = backspaceAt('$anchor$anchor$anchor', 2, [
        ref(0, hash: 'one'),
        ref(1, hash: 'two'),
        ref(2, hash: 'three'),
      ]);
      expect(refs.map((r) => r.hash), ['one', 'three']);
      expect(refs.map((r) => r.offset), [0, 1]);
    });

    test('backspacing the LAST of three deletes the last', () {
      final refs = backspaceAt('$anchor$anchor$anchor', 3, [
        ref(0, hash: 'one'),
        ref(1, hash: 'two'),
        ref(2, hash: 'three'),
      ]);
      expect(refs.map((r) => r.hash), ['one', 'two']);
    });

    test('forward-delete at a caret takes the character after it', () {
      final refs = rebaseNoteAttachments(
        oldText: '$anchor$anchor',
        newText: anchor,
        attachments: [ref(0, hash: 'one'), ref(1, hash: 'two')],
        selectionStart: 0,
        selectionEnd: 0,
      );
      expect(refs.map((r) => r.hash), ['two']);
    });

    test('a selection replaced across two images drops both', () {
      final refs = rebaseNoteAttachments(
        oldText: 'a$anchor$anchor' 'b',
        newText: 'aXb',
        attachments: [ref(1, hash: 'one'), ref(2, hash: 'two')],
        selectionStart: 1,
        selectionEnd: 3,
      );
      expect(refs, isEmpty);
    });

    test('a selection that does not reproduce the text is not trusted', () {
      // A stale caret must fall through to the diff rather than delete
      // whatever it happens to be pointing at.
      final refs = rebaseNoteAttachments(
        oldText: 'a${anchor}b',
        newText: 'a${anchor}bc',
        attachments: [ref(1, hash: 'kept')],
        selectionStart: 0,
        selectionEnd: 0,
      );
      expect(refs.map((r) => r.hash), ['kept']);
      expect(refs.single.offset, 1);
    });

    test('with no caret, the diff resolves ambiguity towards the end', () {
      // Documents the fallback rather than endorsing it: a sync or an import
      // arrives with no caret, and something has to be chosen.
      final refs = edit('$anchor$anchor$anchor', '$anchor$anchor', [
        ref(0, hash: 'one'),
        ref(1, hash: 'two'),
        ref(2, hash: 'three'),
      ]);
      expect(refs.map((r) => r.hash), ['one', 'two']);
    });

    test('replacing a selection that spans an image drops it', () {
      final refs = edit('a${anchor}b', 'aZb', [ref(1)]);
      expect(refs, isEmpty);
    });

    test('clearing the whole note drops everything', () {
      expect(edit('$anchor$anchor', '', [ref(0), ref(1)]), isEmpty);
    });

    test('an unchanged body is returned untouched', () {
      final input = [ref(0)];
      expect(identical(edit(anchor, anchor, input), input), isTrue);
    });

    test('a multi-line note keeps images across an edit two lines up', () {
      const before = 'one\ntwo\n$anchor\nlast';
      const after = 'one and more\ntwo\n$anchor\nlast';
      final refs = edit(before, after, [ref(before.indexOf(anchor))]);
      expect(refs.single.offset, after.indexOf(anchor));
    });
  });

  group('json', () {
    test('round-trips every field', () {
      final original = NoteImageRef(
        offset: 3,
        hash: 'abc123',
        key: Uint8List.fromList(List.generate(32, (i) => i)),
        mime: 'image/jpeg',
        width: 1200,
        height: 900,
        bytes: 45678,
        thumbHash: 'thumb1',
        attachmentId: 'server-id',
        thumbId: 'server-thumb',
      );
      final back = NoteAttachmentRef.fromJson(original.toJson())!;
      expect(back, original);
      expect(back.key, original.key);
    });

    test('a local image with no server id round-trips', () {
      final back = NoteAttachmentRef.fromJson(ref(0).toJson())!;
      expect(back.attachmentId, isNull);
      expect(back.isUploaded, isFalse);
    });

    test('rejects a record with a wrong-length key', () {
      final broken = ref(0).toJson()..['key'] = 'AAAA';
      expect(NoteAttachmentRef.fromJson(broken), isNull);
    });

    test('rejects a record with no hash', () {
      final broken = ref(0).toJson()..remove('hash');
      expect(NoteAttachmentRef.fromJson(broken), isNull);
    });

    test('a width is carried, and only written when it is not full', () {
      expect(ref(0).toJson().containsKey('widthFactor'), isFalse);
      final narrow = ref(0).copyWith(widthFactor: 0.4);
      expect(narrow.toJson()['widthFactor'], 0.4);
      final read = NoteAttachmentRef.fromJson(narrow.toJson());
      expect((read as NoteImageRef).widthFactor, 0.4);
    });

    test('a nonsense width reads back as full rather than failing', () {
      for (final broken in [0, -1, 5, double.nan]) {
        final json = ref(0).toJson()..['widthFactor'] = broken;
        final back = NoteAttachmentRef.fromJson(json)! as NoteImageRef;
        expect(back.widthFactor, inInclusiveRange(0.25, 1));
      }
    });

    test('noteAttachmentsFromJson reconciles against the body', () {
      final json = [ref(0).toJson(), ref(9).toJson()];
      expect(noteAttachmentsFromJson(json, anchor).length, 1);
    });
  });

  group('kinds', () {
    NoteVoiceRef voice(int offset, {VoiceTranscript? transcript}) => NoteVoiceRef(
      offset: offset,
      hash: 'v',
      key: Uint8List(32),
      bytes: 2048,
      durationMs: 5000,
      transcript: transcript,
    );

    test('a voice ref round-trips', () {
      final original = voice(0).copyWith(
        transcript: VoiceTranscript(
          lang: 'en',
          engine: 'cf/deepgram-nova-3',
          at: 17,
          segments: const [TranscriptSegment(s: 0, e: 900, t: 'hello')],
        ),
      );
      final back = NoteAttachmentRef.fromJson(original.toJson());
      expect(back, isA<NoteVoiceRef>());
      final read = back! as NoteVoiceRef;
      expect(read.durationMs, 5000);
      expect(read.mime, 'audio/mp4');
      expect(read.transcript!.segments.single.t, 'hello');
      expect(read, original);
    });

    test('a ref with no kind is still an image, as every stored note has', () {
      final json = ref(0).toJson();
      expect(json.containsKey('kind'), isFalse);
      expect(NoteAttachmentRef.fromJson(json), isA<NoteImageRef>());
    });

    test('a voice ref with no duration is refused', () {
      final json = voice(0).toJson()..remove('durationMs');
      expect(NoteAttachmentRef.fromJson(json), isNull);
    });

    test('a broken transcript is dropped; the recording is not', () {
      final json = voice(0).toJson()..['transcript'] = {'lang': 'en'};
      final back = NoteAttachmentRef.fromJson(json)! as NoteVoiceRef;
      expect(back.transcript, isNull);
      expect(back.durationMs, 5000);
    });

    test('peaks survive only at exactly 100 bytes', () {
      final json = voice(0).toJson();
      json['peaks'] = base64.encode(Uint8List(100));
      expect((NoteAttachmentRef.fromJson(json)! as NoteVoiceRef).peaks, hasLength(100));
      json['peaks'] = base64.encode(Uint8List(64));
      expect((NoteAttachmentRef.fromJson(json)! as NoteVoiceRef).peaks, isNull);
    });

    test('an unknown kind survives toJson byte for byte, rebased', () {
      // The whole promise of the sealed hierarchy: an older build must be able
      // to open, edit and push a note full of things it cannot draw.
      final raw = <String, Object?>{
        'kind': 'chart',
        'offset': 0,
        'hash': 'c',
        'key': base64.encode(Uint8List(32)),
        'mime': 'application/x-kapy-chart',
        'bytes': 12,
        'series': [1, 2, 3],
        'palette': {'from': '#fff', 'to': '#000'},
      };
      final parsed = NoteAttachmentRef.fromJson(raw);
      expect(parsed, isA<NoteUnknownRef>());

      final moved = parsed!.copyWith(offset: 4);
      final out = moved.toJson();
      expect(out['offset'], 4);
      expect(out['series'], [1, 2, 3]);
      expect(out['palette'], {'from': '#fff', 'to': '#000'});
      expect({...out}..remove('offset'), {...raw}..remove('offset'));
    });

    test('an unknown kind missing the shared fields is still refused', () {
      expect(
        NoteAttachmentRef.fromJson({'kind': 'chart', 'offset': 0, 'hash': 'c'}),
        isNull,
      );
    });

    test('a mixed list rebases across three adjacent placeholders', () {
      final refs = <NoteAttachmentRef>[
        ref(0, hash: 'i'),
        voice(1),
        NoteAttachmentRef.fromJson({
          'kind': 'chart',
          'offset': 2,
          'hash': 'c',
          'key': base64.encode(Uint8List(32)),
          'mime': 'x/y',
        })!,
      ];
      // Delete the middle one with the caret saying so.
      final after = rebaseNoteAttachments(
        oldText: '$anchor$anchor$anchor',
        newText: '$anchor$anchor',
        attachments: refs,
        selectionStart: 1,
        selectionEnd: 2,
      );
      expect(after.map((r) => r.hash), ['i', 'c']);
      expect(after.map((r) => r.offset), [0, 1]);
    });

    test('comparing voice refs is constant in the size of the transcript', () {
      // Every keystroke rebases the attachment list and compares the result
      // against the old one to decide whether the note is dirty. If this
      // walked the segments, typing into a note holding a long recording would
      // stutter — so the guard is a real measurement, not a comment.
      //
      // Measured as a ratio between a tiny transcript and a huge one, both
      // timed in the same run: an absolute duration would only be measuring
      // how loaded the machine is when the whole suite runs in parallel.
      VoiceTranscript transcript(int segments) => VoiceTranscript(
        lang: 'en',
        engine: 'e',
        at: 1,
        segments: [
          for (var i = 0; i < segments; i++)
            TranscriptSegment(s: i, e: i + 1, t: 'word $i'),
        ],
      );

      Duration timeComparing(int segments) {
        final a = voice(0, transcript: transcript(segments));
        final b = voice(0, transcript: transcript(segments));
        for (var i = 0; i < 1000; i++) {
          a == b; // warm up, so the first run is not the one being measured
        }
        final watch = Stopwatch()..start();
        for (var i = 0; i < 20000; i++) {
          if (!(a == b)) fail('refs that are equal compared unequal');
        }
        return watch.elapsed;
      }

      final small = timeComparing(1).inMicroseconds;
      final large = timeComparing(100000).inMicroseconds;
      // Content comparison would be five orders of magnitude apart here, so a
      // generous bound still catches the only regression that matters.
      expect(large / (small == 0 ? 1 : small), lessThan(5),
          reason: 'small=${small}us large=${large}us');
    });
  });
}

