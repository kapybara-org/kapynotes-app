import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/crdt.dart';
import 'package:kapy_notes/ui/editor/markdown_editing.dart';
import 'package:kapy_notes/ui/editor/markdown_syntax.dart';

import 'crdt/helpers.dart';

MarkdownTable tableIn(String note) =>
    MarkdownAnalyzer.analyzeWhole(note).tables.single;

TextEditingValue valueOf(String note) => TextEditingValue(
  text: note,
  selection: TextSelection.collapsed(offset: note.length),
);

String apply(
  String note,
  MarkdownEdit Function(TextEditingValue value, MarkdownTable table) edit,
) => edit(valueOf(note), tableIn(note)).value.text;

/// Every row of the one table in [note] has [columns] cells, and its delimiter
/// row is a delimiter row.
void expectValidTable(String note, int columns) {
  final table = tableIn(note);
  expect(markdownTableColumnCount(table), columns, reason: note);
  for (final row in table.rows) {
    expect(row.cells.length, columns, reason: note);
  }
  final delimiter = note.substring(table.delimiterStart, table.delimiterEnd);
  expect(
    RegExp(r'^\|( *:?-{3,}:? *\|)+$').hasMatch(delimiter),
    isTrue,
    reason: delimiter,
  );
}

const table =
    'Trip\n\n'
    '| Item | Who | Cost |\n'
    '| --- | :---: | ---: |\n'
    '| Tickets | Ana | 412 |\n'
    '| Hotel | **Sanjay** | 896 |\n'
    '| Taxi \\| cab | [Ana](https://a.example) | 38 |\n'
    '\nafter';

void main() {
  group('moving a row', () {
    test('down and up, every character of it kept', () {
      final down = apply(
        table,
        (v, t) => moveMarkdownTableRow(v, t, from: 1, to: 3),
      );
      expect(
        down,
        'Trip\n\n'
        '| Item | Who | Cost |\n'
        '| --- | :---: | ---: |\n'
        '| Hotel | **Sanjay** | 896 |\n'
        '| Taxi \\| cab | [Ana](https://a.example) | 38 |\n'
        '| Tickets | Ana | 412 |\n'
        '\nafter',
      );
      expect(
        apply(down, (v, t) => moveMarkdownTableRow(v, t, from: 3, to: 1)),
        table,
      );
    });

    test('the header never moves, and nothing moves past the end', () {
      for (final (from, to) in [(0, 1), (1, 0), (1, 4), (2, 2)]) {
        expect(
          apply(
            table,
            (v, t) => moveMarkdownTableRow(v, t, from: from, to: to),
          ),
          table,
        );
      }
    });

    test('wide characters and empty cells move whole', () {
      const note = '| a | b |\n| --- | --- |\n| 東京 | 🍵 |\n|  | x |';
      expect(
        apply(note, (v, t) => moveMarkdownTableRow(v, t, from: 2, to: 1)),
        '| a | b |\n| --- | --- |\n|  | x |\n| 東京 | 🍵 |',
      );
    });
  });

  group('moving a column', () {
    test('takes its alignment, its width and its escaped pipes along', () {
      const note =
          '| a | b \\| c | d |\n| --- | :------: | ---: |\n| 1 | **2** | 3 |';
      final moved = apply(
        note,
        (v, t) => moveMarkdownTableColumn(v, t, from: 1, to: 2),
      );
      expect(
        moved,
        '| a | d | b \\| c |\n| --- | ---: | :------: |\n| 1 | 3 | **2** |',
      );
      expectValidTable(moved, 3);
    });

    test('a one-column table has nowhere to move it', () {
      const note = '| a |\n| --- |\n| 1 |';
      expect(
        apply(note, (v, t) => moveMarkdownTableColumn(v, t, from: 0, to: 1)),
        note,
      );
    });
  });

  group('column widths', () {
    test('are read from the dashes past the third', () {
      const note = '| a | b | c |\n| --- | :----------: | -: |\n| 1 | 2 | 3 |';
      expect(markdownTableDashes(note, tableIn(note)), [3, 10, 1]);
      expect(
        [
          for (final d in markdownTableDashes(note, tableIn(note)))
            markdownTableColumnWidth(d),
        ],
        [null, 10, null],
      );
    });

    test('setting one adds dashes after the third, colons kept', () {
      expect(
        apply(
          table,
          (v, t) => setMarkdownTableColumnWidth(v, t, column: 1, width: 8),
        ),
        table.replaceFirst('| :---: |', '| :--------: |'),
      );
    });

    test('narrowing takes dashes from the end and never the first three', () {
      final wide = table.replaceFirst('| ---: |', '| ----------: |');
      expect(
        apply(
          wide,
          (v, t) => setMarkdownTableColumnWidth(v, t, column: 2, width: 5),
        ),
        table.replaceFirst('| ---: |', '| -----: |'),
      );
      expect(
        apply(
          wide,
          (v, t) => setMarkdownTableColumnWidth(v, t, column: 2, width: 1),
        ),
        table.replaceFirst('| ---: |', '| ----: |'),
      );
    });

    test('resetting goes back to three dashes', () {
      final wide = table.replaceFirst('| --- |', '| --------- |');
      expect(
        apply(
          wide,
          (v, t) => setMarkdownTableColumnWidth(v, t, column: 0, width: null),
        ),
        table,
      );
      expect(
        apply(
          table,
          (v, t) => setMarkdownTableColumnWidth(v, t, column: 0, width: null),
        ),
        table,
      );
    });

    test('survive adding, removing and aligning other columns', () {
      final wide = table.replaceFirst('| ---: |', '| --------: |');
      final added = apply(
        wide,
        (v, t) => insertMarkdownTableColumn(v, t, after: 0),
      );
      expect(added, contains('| --- | --- | :---: | --------: |'));
      expectValidTable(added, 4);
      final removed = apply(
        added,
        (v, t) => removeMarkdownTableColumn(v, t, column: 1),
      );
      expect(removed, wide);
      final aligned = apply(
        wide,
        (v, t) => setMarkdownTableColumnAlign(
          v,
          t,
          column: 2,
          align: MarkdownCellAlign.center,
        ),
      );
      expect(aligned, contains('| --- | :---: | :--------: |'));
    });
  });

  group('the edges', () {
    test('deleting the last body row leaves a header-only table', () {
      const note = '| a | b |\n| --- | --- |\n| 1 | 2 |';
      final gone = apply(note, (v, t) => removeMarkdownTableRow(v, t, row: 1));
      expect(gone, '| a | b |\n| --- | --- |');
      expectValidTable(gone, 2);
    });

    test('the header row and the only column stay', () {
      expect(
        apply(table, (v, t) => removeMarkdownTableRow(v, t, row: 0)),
        table,
      );
      const one = '| a |\n| --- |\n| 1 |';
      expect(
        apply(one, (v, t) => removeMarkdownTableColumn(v, t, column: 0)),
        one,
      );
    });
  });

  group('two devices at once', () {
    /// [base] on two devices, [left] on one and [right] on the other, synced.
    String merged(String base, String left, String right) {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      b.apply(type(a, base));
      final fromA = type(a, left);
      final fromB = type(b, right);
      a.apply(fromB);
      b.apply(fromA);
      expect(a.view.body, b.view.body);
      return a.view.body;
    }

    String sized(String note, int column, int? width) => apply(
      note,
      (v, t) => setMarkdownTableColumnWidth(v, t, column: column, width: width),
    );

    test('resizing the same column on both keeps a delimiter row', () {
      final wide = sized(table, 0, 12);
      for (final (left, right) in [
        (6, 9),
        (5, 5),
        (4, 20),
        (null, 7),
        (null, null),
      ]) {
        final result = merged(
          wide,
          sized(wide, 0, left),
          sized(wide, 0, right),
        );
        expectValidTable(result, 3);
        expect(
          markdownTableDashes(result, tableIn(result))[0],
          greaterThanOrEqualTo(3),
        );
      }
    });

    test('resizing different columns keeps both widths', () {
      final result = merged(table, sized(table, 0, 8), sized(table, 2, 9));
      expect(markdownTableDashes(result, tableIn(result)), [8, 3, 9]);
    });

    test('moving a row while the other device edits a cell in it', () {
      final moved = apply(
        table,
        (v, t) => moveMarkdownTableRow(v, t, from: 1, to: 3),
      );
      final edited = apply(
        table,
        (v, t) => setMarkdownTableCell(v, t, row: 1, column: 0, text: 'Trains'),
      );
      expectValidTable(merged(table, moved, edited), 3);
    });

    test('editing different cells keeps both edits', () {
      final one = apply(
        table,
        (v, t) => setMarkdownTableCell(v, t, row: 1, column: 0, text: 'Trains'),
      );
      final other = apply(
        table,
        (v, t) => setMarkdownTableCell(v, t, row: 3, column: 2, text: '41'),
      );
      final result = merged(table, one, other);
      expect(result, contains('| Trains | Ana | 412 |'));
      expect(result, contains('| 41 |'));
      expectValidTable(result, 3);
    });
  });
}
