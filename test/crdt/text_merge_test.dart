import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/crdt.dart';

import 'helpers.dart';

const _alphabet = 'ab1 \n=xy';

String _word(Random rng, [int max = 4]) => String.fromCharCodes([
  for (var i = 0, n = 1 + rng.nextInt(max); i < n; i++)
    _alphabet.codeUnitAt(rng.nextInt(_alphabet.length)),
]);

String _text(Random rng, int length) => String.fromCharCodes([
  for (var i = 0; i < length; i++)
    _alphabet.codeUnitAt(rng.nextInt(_alphabet.length)),
]);

String _apply(String text, List<TextHunk> hunks) {
  final out = StringBuffer();
  var at = 0;
  for (final hunk in hunks) {
    out
      ..write(text.substring(at, hunk.start))
      ..write(hunk.insert);
    at = hunk.end;
  }
  out.write(text.substring(at));
  return out.toString();
}

/// One edit of [text] in its own offsets: `[start, end)` replaced by [insert].
typedef _Edit = ({int start, int end, String insert});

_Edit _randomEdit(Random rng, String text, {int? from, int? to}) {
  final low = from ?? 0;
  final high = to ?? text.length;
  final start = low + rng.nextInt(high - low + 1);
  final end = min(high, start + rng.nextInt(4));
  final insert = rng.nextInt(4) == 0 ? '' : _word(rng);
  return (start: start, end: end, insert: insert);
}

String _edited(String text, List<_Edit> edits) {
  final sorted = [...edits]..sort((a, b) => a.start.compareTo(b.start));
  return _apply(text, [
    for (final edit in sorted) TextHunk(edit.start, edit.end, edit.insert),
  ]);
}

void main() {
  group('diffHunks', () {
    test('equal texts have no hunks', () {
      expect(diffHunks('same', 'same'), isEmpty);
      expect(diffHunks('', ''), isEmpty);
    });

    test('one stretch is one hunk', () {
      expect(diffHunks('hello world', 'hello there world'), [
        const TextHunk(6, 6, 'there '),
      ]);
      expect(diffHunks('abcdef', 'abXYef'), [const TextHunk(2, 4, 'XY')]);
    });

    test('two stretches apart are two hunks, not one spanning both', () {
      final hunks = diffHunks(
        'first line\nmiddle\nlast line',
        'first line!\nmiddle\nlast line?',
      );
      expect(hunks, [const TextHunk(10, 10, '!'), const TextHunk(27, 27, '?')]);
    });

    test('rebuilds the new text from the old, whatever the edit', () {
      final rng = Random(7);
      for (var round = 0; round < 3000; round++) {
        final a = _text(rng, rng.nextInt(40));
        final edits = <_Edit>[];
        // Up to three edits in separate stretches of the text.
        final cuts = [0, a.length ~/ 3, 2 * a.length ~/ 3, a.length];
        for (var s = 0; s < 3; s++) {
          if (rng.nextBool()) {
            edits.add(_randomEdit(rng, a, from: cuts[s], to: cuts[s + 1]));
          }
        }
        final b = _edited(a, edits);
        final hunks = diffHunks(a, b);
        expect(_apply(a, hunks), b, reason: '"$a" -> "$b": $hunks');
        for (var i = 1; i < hunks.length; i++) {
          expect(hunks[i].start, greaterThan(hunks[i - 1].end));
        }
      }
    });

    test('past its budget it reports one stretch rather than searching', () {
      final rng = Random(3);
      final a = 'start ${_text(rng, 300)} end';
      final b = 'start ${_text(rng, 300)} end';
      final hunks = diffHunks(a, b, maxCost: 10);
      expect(hunks, hasLength(1));
      expect(_apply(a, hunks), b);
    });
  });

  group('mergeTexts', () {
    test('an untouched side takes the other whole', () {
      expect(
        mergeTexts(base: 'abc', local: 'abc', remote: 'aXbc').text,
        'aXbc',
      );
      expect(
        mergeTexts(base: 'abc', local: 'abYc', remote: 'abc').text,
        'abYc',
      );
    });

    test('edits in different places both land', () {
      final merge = mergeTexts(
        base: 'one\ntwo\nthree',
        local: 'one\ntwo!\nthree',
        remote: 'zero\none\ntwo\nthree\nfour',
      );
      expect(merge.text, 'zero\none\ntwo!\nthree\nfour');
      // The caret after the local "!" stays after it.
      expect(merge.mapLocal(8), 13);
      expect(merge.text.substring(0, merge.mapLocal(8)), 'zero\none\ntwo!');
    });

    test('at the same place the local words come first', () {
      final merge = mergeTexts(base: 'ab', local: 'aXXb', remote: 'aYYb');
      expect(merge.text, 'aXXYYb');
      // A caret after the local words is not pushed past the remote ones.
      expect(merge.mapLocal(3), 3);
    });

    test('a character goes if either side deleted it', () {
      expect(
        mergeTexts(base: 'abcdef', local: 'abef', remote: 'acdef').text,
        'aef',
      );
    });

    test('words typed inside a stretch the other side deleted survive', () {
      expect(
        mergeTexts(base: 'hello world', local: 'hello big world', remote: 'hd')
            .text,
        'hbig d',
      );
    });

    test('remote offsets map into the merged text', () {
      final merge = mergeTexts(
        base: 'abc',
        local: 'abc\n\n',
        remote: 'Xabc',
      );
      expect(merge.text, 'Xabc\n\n');
      // "abc" in the remote text, [1, 4), is still "abc" here.
      expect(
        merge.text.substring(merge.mapRemoteStart(1), merge.mapRemoteEnd(4)),
        'abc',
      );
    });

    test('equals applying both edits when they do not touch', () {
      final rng = Random(11);
      for (var round = 0; round < 3000; round++) {
        final base = _text(rng, 6 + rng.nextInt(40));
        final split = 2 + rng.nextInt(base.length - 3);
        // The local edit in the first part, the remote ones in the second,
        // with an untouched character between them.
        final local = _randomEdit(rng, base, from: 0, to: split - 1);
        final remote = _randomEdit(rng, base, from: split, to: base.length);
        final localText = _edited(base, [local]);
        final remoteText = _edited(base, [remote]);
        final merge = mergeTexts(
          base: base,
          local: localText,
          remote: remoteText,
        );
        expect(
          merge.text,
          _edited(base, [local, remote]),
          reason: 'base "$base", local $local, remote $remote',
        );
        // The caret after the local edit is after it in the merge too.
        final caret = local.start + local.insert.length;
        expect(
          merge.text.substring(0, merge.mapLocal(caret)),
          localText.substring(0, caret),
        );
      }
    });

    test('agrees with the note document when the edits do not touch', () {
      final rng = Random(23);
      for (var round = 0; round < 500; round++) {
        final base = _text(rng, 6 + rng.nextInt(30));
        final split = 2 + rng.nextInt(base.length - 3);
        final local = _randomEdit(rng, base, from: 0, to: split - 1);
        final remote = _randomEdit(rng, base, from: split, to: base.length);

        final here = NoteDoc(replica: 'here');
        type(here, base);
        final there = NoteDoc(replica: 'there')..mergeSnapshot(here.toSnapshot());
        final mine = type(here, _edited(base, [local]));
        final theirs = type(there, _edited(base, [remote]));
        here.apply(theirs);
        there.apply(mine);

        final merge = mergeTexts(
          base: base,
          local: _edited(base, [local]),
          remote: _edited(base, [remote]),
        );
        expect(here.text, there.text);
        expect(merge.text, here.text, reason: 'base "$base"');
      }
    });

    test('maps every local offset forward and into the text', () {
      final rng = Random(31);
      for (var round = 0; round < 1000; round++) {
        final base = _text(rng, rng.nextInt(30));
        final local = _edited(base, [_randomEdit(rng, base)]);
        final remote = _edited(base, [_randomEdit(rng, base)]);
        final merge = mergeTexts(base: base, local: local, remote: remote);
        var last = 0;
        for (var offset = 0; offset <= local.length; offset++) {
          final mapped = merge.mapLocal(offset);
          expect(mapped, greaterThanOrEqualTo(last));
          expect(mapped, lessThanOrEqualTo(merge.text.length));
          last = mapped;
        }
      }
    });
  });

  group('stateOps', () {
    test('rebuilds the whole document anywhere, tombstones and all', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, 'Hello world');
      type(doc, 'Hello there world');
      type(doc, 'Hello world, again');
      final other = NoteDoc(replica: 'b');
      for (final batch in doc.stateOps()) {
        other.apply(batch);
      }
      expect(other.text, doc.text);
      expect(other.pendingCount, 0);

      // And unions into a copy that has moved on meanwhile.
      final behind = NoteDoc(replica: 'c');
      type(behind, 'Something else');
      for (final batch in doc.stateOps()) {
        behind.apply(batch);
      }
      expect(behind.text, contains('Hello world, again'));
      expect(behind.text, contains('Something else'));
    });

    test('a long run is cut to fit, and still rebuilds', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, List.filled(4000, 'word ').join());
      final batches = doc.stateOps(maxBytes: 4096);
      expect(batches.length, greaterThan(4));
      final other = NoteDoc(replica: 'b');
      for (final batch in batches.reversed) {
        other.apply(batch);
      }
      expect(other.text, doc.text);
    });
  });
}
