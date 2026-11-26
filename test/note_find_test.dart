import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/markdown_syntax.dart';
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
      // Some languages lower İ to an i and a dot above it, two code units.
      // Dart lowers it to one, which is what lets an offset into the lower
      // case stand for the same offset into the text.
      expect(findInText('İ Cat', 'cat'), const [TextRange(start: 2, end: 5)]);
    });
  });

  // A table is drawn as a grid over its hidden source, so the words in its
  // cells are found one cell at a time, as the grid shows them.
  group('findInTables', () {
    const text =
        'Gear\n\n| Item | Qty |\n| --- | --- |\n| **Tent** pegs | 8 |\n\n'
        'Spare pegs';
    final tables = MarkdownAnalyzer.analyzeWhole(text);

    test('finds the words in each cell, the header too', () {
      final pegs = text.indexOf('pegs');
      expect(findInTables(tables, 'PEGS'), [
        TextRange(start: pegs, end: pegs + 4),
      ]);
      final qty = text.indexOf('Qty');
      expect(findInTables(tables, 'qty'), [
        TextRange(start: qty, end: qty + 3),
      ]);
    });

    test('finds words a cell\'s markdown splits, from its source', () {
      expect(findInTables(tables, 'tent pegs'), [
        TextRange(start: text.indexOf('Tent'), end: text.indexOf('pegs') + 4),
      ]);
    });

    test('never runs from one cell into the next, nor finds the grid', () {
      for (final words in ['pegs8', 'pegs 8', 'pegs | 8', '|', '---', '*']) {
        expect(findInTables(tables, words), isEmpty, reason: words);
      }
      expect(findInTables(tables, ''), isEmpty);
    });
  });

  group('NoteFind', () {
    MarkdownAnalysis note(String text) => MarkdownAnalyzer.analyzeWhole(text);

    test('starts at the first match from where the reader is, and goes '
        'round', () {
      final find = NoteFind();
      addTearDown(find.dispose);
      find.query.text = 'tent';

      expect(find.refresh(note('tent tent tent'), const [], from: 3), isTrue);
      expect(find.current, 1);
      expect(find.currentMatch, const TextRange(start: 5, end: 9));
      find.step();
      expect(find.current, 2);
      find.step();
      expect(find.current, 0);
      find.step(back: true);
      expect(find.current, 2);

      // Nothing changed, so nothing moves.
      expect(find.refresh(note('tent tent tent'), const [], from: 0), isFalse);
      expect(find.current, 2);

      // A match taken away leaves the reader on the next one, or round on
      // the first.
      expect(find.refresh(note('tent tent'), const [], from: 0), isTrue);
      expect(find.current, 0);
    });

    test('has no match to be on when there are none', () {
      final find = NoteFind();
      addTearDown(find.dispose);
      find.query.text = 'stove';

      expect(find.refresh(note('tent'), const [], from: 0), isTrue);
      expect(find.matches, isEmpty);
      expect(find.current, -1);
      expect(find.currentMatch, isNull);
      find.step();
      expect(find.current, -1);
    });
  });
}
