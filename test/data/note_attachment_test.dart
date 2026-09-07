import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';

const anchor = NoteAttachmentRef.placeholder;

NoteAttachmentRef ref(int offset, {String hash = 'a'}) => NoteAttachmentRef(
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
      final original = NoteAttachmentRef(
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
      expect(NoteAttachmentRef.fromJson(narrow.toJson())!.widthFactor, 0.4);
    });

    test('a nonsense width reads back as full rather than failing', () {
      for (final broken in [0, -1, 5, double.nan]) {
        final json = ref(0).toJson()..['widthFactor'] = broken;
        final back = NoteAttachmentRef.fromJson(json)!;
        expect(back.widthFactor, inInclusiveRange(0.25, 1));
      }
    });

    test('noteAttachmentsFromJson reconciles against the body', () {
      final json = [ref(0).toJson(), ref(9).toJson()];
      expect(noteAttachmentsFromJson(json, anchor).length, 1);
    });
  });
}
