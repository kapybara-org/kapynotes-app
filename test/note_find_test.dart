import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/note_find.dart';

void main() {
  group('findInText', () {
    test('finds every match whatever its case, each apart', () {
      expect(findInText('Tent, tent and TENT', 'tent'), const [
        TextRange(start: 0, end: 4),
        TextRange(start: 6, end: 10),
        TextRange(start: 15, end: 19),
      ]);
      expect(findInText('aaaa', 'aa'), const [
        TextRange(start: 0, end: 2),
        TextRange(start: 2, end: 4),
      ]);
    });

    test('finds nothing for no words, or in no text', () {
      expect(findInText('tent', ''), isEmpty);
      expect(findInText('', 'tent'), isEmpty);
    });

    // The note draws its markdown's stars as nothing, so they are never
    // found, and the word they split is.
    test('passes over what the note hides, and finds words it splits', () {
      const text = '**bold** and bo**ld**';
      const hidden = [
        TextRange(start: 19, end: 21),
        TextRange(start: 15, end: 17),
        TextRange(start: 6, end: 8),
        TextRange(start: 0, end: 2),
      ];
      expect(findInText(text, 'bold', hidden: hidden), const [
        TextRange(start: 2, end: 6),
        TextRange(start: 13, end: 19),
      ]);
      expect(findInText(text, '*', hidden: hidden), isEmpty);
      expect(findInText(text, 'd a', hidden: hidden), const [
        TextRange(start: 5, end: 10),
      ]);
    });

    test('keeps its place past a letter whose lower case is longer', () {
      // İ lowers to two code units, an i and a dot above it.
      expect(findInText('İ Cat', 'cat'), const [TextRange(start: 2, end: 5)]);
    });
  });

  group('NoteFind', () {
    test('starts at the first match from where the reader is, and goes '
        'round', () {
      final find = NoteFind();
      addTearDown(find.dispose);
      find.query.text = 'tent';

      expect(find.refresh('tent tent tent', const [], from: 3), isTrue);
      expect(find.current, 1);
      expect(find.currentMatch, const TextRange(start: 5, end: 9));
      find.step();
      expect(find.current, 2);
      find.step();
      expect(find.current, 0);
      find.step(back: true);
      expect(find.current, 2);

      // Nothing changed, so nothing moves.
      expect(find.refresh('tent tent tent', const [], from: 0), isFalse);
      expect(find.current, 2);

      // A match taken away leaves the reader on the next one, or round on
      // the first.
      expect(find.refresh('tent tent', const [], from: 0), isTrue);
      expect(find.current, 0);
    });

    test('has no match to be on when there are none', () {
      final find = NoteFind();
      addTearDown(find.dispose);
      find.query.text = 'stove';

      expect(find.refresh('tent', const [], from: 0), isTrue);
      expect(find.matches, isEmpty);
      expect(find.current, -1);
      expect(find.currentMatch, isNull);
      find.step();
      expect(find.current, -1);
    });
  });
}
