import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/markdown_editing.dart';
import 'package:kapy_notes/ui/editor/markdown_syntax.dart';

/// The table in [note]. Every test reads its offsets from the real parser
/// rather than counting characters, which is the only way the splices below
/// mean anything.
MarkdownTable tableIn(String note) =>
    MarkdownAnalyzer.analyzeWhole(note).tables.single;

TextEditingValue valueOf(String note) => TextEditingValue(
  text: note,
  selection: TextSelection.collapsed(offset: note.length),
);

/// The note after an operation, with the caret marked by `‸`.
///
/// Not `|`, which [markdown_editing_test.dart] uses: every row of a table is
/// full of pipes, so that marker cannot be read back here.
String shownAt(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid) return value.text;
  if (selection.isCollapsed) {
    return value.text.replaceRange(selection.start, selection.start, '‸');
  }
  return value.text
      .replaceRange(selection.end, selection.end, '‸')
      .replaceRange(selection.start, selection.start, '‸');
}

const simple = '| Item | Cost |\n| --- | --- |\n| Tea | 4 |';

void main() {
  group('reading a table', () {
    test('counts columns from the widest row and the delimiter', () {
      expect(markdownTableColumnCount(tableIn(simple)), 2);
      expect(
        markdownTableColumnCount(
          tableIn('| a | b | c |\n|---|---|---|\n| 1 |'),
        ),
        3,
      );
    });

    test('finds the table an offset is in, and none outside one', () {
      const note = 'intro\n\n$simple\n\nafter';
      final analysis = MarkdownAnalyzer.analyzeWhole(note);
      expect(markdownTableAt(analysis, 0), isNull);
      expect(markdownTableAt(analysis, note.length - 1), isNull);
      expect(markdownTableAt(analysis, note.indexOf('Tea')), isNotNull);
    });

    test('names the cell an offset is in', () {
      final table = tableIn(simple);
      expect(markdownTableCellAt(table, simple.indexOf('Item')), (
        row: 0,
        column: 0,
      ));
      expect(markdownTableCellAt(table, simple.indexOf('Cost')), (
        row: 0,
        column: 1,
      ));
      expect(markdownTableCellAt(table, simple.indexOf('4')), (
        row: 1,
        column: 1,
      ));
    });

    test('a divider or a cell\'s padding belongs to the cell left of it', () {
      final table = tableIn(simple);
      // The `|` between the two body cells, and the space after it.
      final divider = simple.indexOf('| 4');
      expect(markdownTableCellAt(table, divider)?.column, 0);
      expect(markdownTableCellAt(table, divider + 1)?.column, 0);
    });

    test('the delimiter row has no cell to edit', () {
      final table = tableIn(simple);
      expect(markdownTableCellAt(table, table.delimiterStart + 2), isNull);
    });

    test(
      'a short row still answers by column, though its cells share an offset',
      () {
        const note = '| a | b | c |\n|---|---|---|\n| 1 |';
        final table = tableIn(note);
        final row = table.rows.last;
        expect(row.cells.length, 3, reason: 'the parser pads the missing ones');
        expect(
          row.cells[1].start,
          row.cells[2].start,
          reason: 'and puts them at one offset, which is why indexes are used',
        );
      },
    );
  });

  group('moving between cells', () {
    test('goes along the row, then on to the next', () {
      final table = tableIn(simple);
      expect(nextMarkdownTableCell(table, row: 0, column: 0), (
        row: 0,
        column: 1,
      ));
      expect(nextMarkdownTableCell(table, row: 0, column: 1), (
        row: 1,
        column: 0,
      ));
    });

    test('backwards, and off the front', () {
      final table = tableIn(simple);
      expect(nextMarkdownTableCell(table, row: 1, column: 0, backwards: true), (
        row: 0,
        column: 1,
      ));
      expect(
        nextMarkdownTableCell(table, row: 0, column: 0, backwards: true),
        isNull,
      );
    });

    test('past the last cell is nothing, so a row can be added there', () {
      final table = tableIn(simple);
      expect(nextMarkdownTableCell(table, row: 1, column: 1), isNull);
    });
  });

  group('writing a cell', () {
    test('keeps every other character of the row', () {
      final value = valueOf(simple);
      final edit = setMarkdownTableCell(
        value,
        tableIn(simple),
        row: 1,
        column: 0,
        text: 'Coffee',
      );
      expect(edit.value.text, '| Item | Cost |\n| --- | --- |\n| Coffee | 4 |');
    });

    test('writing the same words changes nothing', () {
      final edit = setMarkdownTableCell(
        valueOf(simple),
        tableIn(simple),
        row: 1,
        column: 0,
        text: 'Tea',
      );
      expect(edit.changesText, isFalse);
    });

    test('fills an empty cell', () {
      const note = '| a | b |\n| --- | --- |\n|  |  |';
      final edit = setMarkdownTableCell(
        valueOf(note),
        tableIn(note),
        row: 1,
        column: 1,
        text: 'x',
      );
      expect(tableIn(edit.value.text).rows.last.cells.last.text, 'x');
    });

    test('a typed pipe stays in the words instead of splitting the cell', () {
      final edit = setMarkdownTableCell(
        valueOf(simple),
        tableIn(simple),
        row: 1,
        column: 0,
        text: 'a | b',
      );
      final table = tableIn(edit.value.text);
      expect(markdownTableColumnCount(table), 2, reason: 'still two columns');
      expect(table.rows.last.cells.first.text, 'a | b');
    });

    test('a line break becomes a space: a row is one line', () {
      final edit = setMarkdownTableCell(
        valueOf(simple),
        tableIn(simple),
        row: 1,
        column: 0,
        text: 'a\nb',
      );
      expect(edit.value.text.split('\n').length, 3);
      expect(tableIn(edit.value.text).rows.last.cells.first.text, 'a b');
    });

    test('a trailing space survives, or a second word could not be typed', () {
      final edit = setMarkdownTableCell(
        valueOf(simple),
        tableIn(simple),
        row: 1,
        column: 0,
        text: 'Tea ',
      );
      expect(edit.value.text.contains('| Tea  |'), isTrue);
    });

    test('a short row is written out in full, so the right cell is filled', () {
      const note = '| a | b | c |\n|---|---|---|\n| 1 |';
      final edit = setMarkdownTableCell(
        valueOf(note),
        tableIn(note),
        row: 1,
        column: 2,
        text: 'z',
      );
      expect(edit.value.text.endsWith('| 1 |  | z |'), isTrue);
      expect(
        tableIn(edit.value.text).rows.last.cells.map((cell) => cell.text),
        ['1', '', 'z'],
      );
    });
  });

  group('rows', () {
    test('a new row goes under the one asked for', () {
      final edit = insertMarkdownTableRow(
        valueOf(simple),
        tableIn(simple),
        after: 1,
      );
      expect(
        edit.value.text,
        '| Item | Cost |\n| --- | --- |\n| Tea | 4 |\n|  |  |',
      );
    });

    test('a row after the header goes under the delimiter, not inside it', () {
      final edit = insertMarkdownTableRow(
        valueOf(simple),
        tableIn(simple),
        after: 0,
      );
      expect(
        edit.value.text,
        '| Item | Cost |\n| --- | --- |\n|  |  |\n| Tea | 4 |',
      );
      expect(tableIn(edit.value.text).rows.length, 3);
    });

    test('appending adds one at the bottom', () {
      final edit = appendMarkdownTableRow(valueOf(simple), tableIn(simple));
      expect(tableIn(edit.value.text).rows.length, 3);
      expect(edit.value.text.endsWith('|  |  |'), isTrue);
    });

    test('removing takes its newline with it', () {
      final edit = removeMarkdownTableRow(
        valueOf(simple),
        tableIn(simple),
        row: 1,
      );
      expect(edit.value.text, '| Item | Cost |\n| --- | --- |');
    });

    test('the header cannot be removed', () {
      final edit = removeMarkdownTableRow(
        valueOf(simple),
        tableIn(simple),
        row: 0,
      );
      expect(edit.changesText, isFalse);
    });
  });

  group('columns', () {
    test('a new column is added to every row and to the delimiter', () {
      final edit = insertMarkdownTableColumn(
        valueOf(simple),
        tableIn(simple),
        after: 0,
      );
      expect(
        edit.value.text,
        '| Item |  | Cost |\n| --- | --- | --- |\n| Tea |  | 4 |',
      );
      expect(markdownTableColumnCount(tableIn(edit.value.text)), 3);
    });

    test('a column at the front', () {
      final edit = insertMarkdownTableColumn(
        valueOf(simple),
        tableIn(simple),
        after: -1,
      );
      expect(
        edit.value.text,
        '|  | Item | Cost |\n| --- | --- | --- |\n|  | Tea | 4 |',
      );
    });

    test('removing one takes it out of every row', () {
      final edit = removeMarkdownTableColumn(
        valueOf(simple),
        tableIn(simple),
        column: 0,
      );
      expect(edit.value.text, '| Cost |\n| --- |\n| 4 |');
    });

    test('the last column stays', () {
      const note = '| a |\n| --- |\n| 1 |';
      final edit = removeMarkdownTableColumn(
        valueOf(note),
        tableIn(note),
        column: 0,
      );
      expect(edit.changesText, isFalse);
    });

    test('a column keeps its alignment when another is added beside it', () {
      const note = '| a | b |\n| ---: | --- |\n| 1 | 2 |';
      final edit = insertMarkdownTableColumn(
        valueOf(note),
        tableIn(note),
        after: 0,
      );
      expect(tableIn(edit.value.text).aligns, [
        MarkdownCellAlign.end,
        MarkdownCellAlign.start,
        MarkdownCellAlign.start,
      ]);
    });

    test('a short row is filled out rather than shifted', () {
      const note = '| a | b | c |\n|---|---|---|\n| 1 |';
      final edit = insertMarkdownTableColumn(
        valueOf(note),
        tableIn(note),
        after: 2,
      );
      expect(
        tableIn(edit.value.text).rows.last.cells.map((cell) => cell.text),
        ['1', '', '', ''],
      );
    });
  });

  group('alignment', () {
    test('is written into the delimiter row', () {
      var value = valueOf(simple);
      value = setMarkdownTableColumnAlign(
        value,
        tableIn(value.text),
        column: 1,
        align: MarkdownCellAlign.end,
      ).value;
      expect(value.text.contains('| --- | ---: |'), isTrue);
      expect(tableIn(value.text).aligns, [
        MarkdownCellAlign.start,
        MarkdownCellAlign.end,
      ]);

      value = setMarkdownTableColumnAlign(
        value,
        tableIn(value.text),
        column: 1,
        align: MarkdownCellAlign.center,
      ).value;
      expect(tableIn(value.text).aligns.last, MarkdownCellAlign.center);

      value = setMarkdownTableColumnAlign(
        value,
        tableIn(value.text),
        column: 1,
        align: MarkdownCellAlign.start,
      ).value;
      expect(value.text.contains('| --- | --- |'), isTrue);
    });

    test('setting the alignment it already has changes nothing', () {
      final edit = setMarkdownTableColumnAlign(
        valueOf(simple),
        tableIn(simple),
        column: 0,
        align: MarkdownCellAlign.start,
      );
      expect(edit.changesText, isFalse);
    });

    test('leaves the rows alone', () {
      final edit = setMarkdownTableColumnAlign(
        valueOf(simple),
        tableIn(simple),
        column: 0,
        align: MarkdownCellAlign.center,
      );
      final rows = tableIn(edit.value.text).rows;
      expect(rows.first.cells.map((cell) => cell.text), ['Item', 'Cost']);
      expect(rows.last.cells.map((cell) => cell.text), ['Tea', '4']);
    });
  });

  group('every operation leaves a table that still parses', () {
    test('and carries the caret across it', () {
      // The caret sits in the first body cell; each operation should keep it
      // somewhere sensible rather than dropping it outside the note.
      final value = TextEditingValue(
        text: simple,
        selection: TextSelection.collapsed(offset: simple.indexOf('Tea')),
      );
      final table = tableIn(simple);
      final edits = <String, MarkdownEdit>{
        'cell': setMarkdownTableCell(
          value,
          table,
          row: 1,
          column: 0,
          text: 'Coffee',
        ),
        'row in': insertMarkdownTableRow(value, table, after: 1),
        'row out': removeMarkdownTableRow(value, table, row: 1),
        'column in': insertMarkdownTableColumn(value, table, after: 0),
        'column out': removeMarkdownTableColumn(value, table, column: 1),
        'align': setMarkdownTableColumnAlign(
          value,
          table,
          column: 0,
          align: MarkdownCellAlign.center,
        ),
      };
      edits.forEach((name, edit) {
        final text = edit.value.text;
        expect(
          MarkdownAnalyzer.analyzeWhole(text).tables.length,
          1,
          reason: '$name left something that is not one table: $text',
        );
        expect(
          edit.value.selection.baseOffset,
          allOf(greaterThanOrEqualTo(0), lessThanOrEqualTo(text.length)),
          reason: '$name put the caret outside the note',
        );
      });
    });
  });
}
