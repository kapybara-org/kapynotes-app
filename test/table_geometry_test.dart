import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/markdown_syntax.dart';
import 'package:kapy_notes/ui/editor/table_geometry.dart';

const _base = TextStyle(fontSize: 14);

/// The geometry of the one table in [note].
///
/// Exact pixel widths belong to whichever font the test runner has, so what is
/// asserted below is the arithmetic — padding, capping, fitting, the sum of the
/// columns — rather than numbers that would only be true here.
TableGeometry geometryFor(
  String note, {
  double? fitToWidth,
  double minRowHeight = 0,
}) {
  final analysis = MarkdownAnalyzer.analyzeWhole(note);
  final geometry = TableGeometry(
    table: analysis.tables.single,
    analysis: analysis,
    base: _base,
    scaler: TextScaler.noScaling,
    runStyle: (base, styles) => base,
    fitToWidth: fitToWidth,
    minRowHeight: minRowHeight,
  );
  addTearDown(geometry.dispose);
  return geometry;
}

const simple = '| Item | Cost |\n| --- | --- |\n| Tea | 4 |';

/// A table whose first column wants far more room than its second.
const lopsided =
    '| Notes | N |\n'
    '| --- | --- |\n'
    '| a sentence long enough to want a great deal of room | 4 |';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('columns, at their natural size', () {
    test('one per column of the table', () {
      expect(geometryFor(simple).columns.length, 2);
      expect(
        geometryFor(
          '| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |',
        ).columns.length,
        3,
      );
    });

    test('each is its widest cell plus padding on both sides', () {
      final geometry = geometryFor(simple);
      for (var c = 0; c < geometry.columns.length; c++) {
        expect(
          geometry.columns[c],
          greaterThan(TableGeometry.padding * 2),
          reason: 'column $c has words in it',
        );
        expect(
          geometry.innerWidth(c),
          closeTo(geometry.columns[c] - TableGeometry.padding * 2, 0.001),
        );
      }
    });

    test('a column holding longer words is wider', () {
      final narrow = geometryFor('| a |\n| --- |\n| b |');
      final wide = geometryFor(
        '| a |\n| --- |\n| a much longer cell than that |',
      );
      expect(wide.columns.single, greaterThan(narrow.columns.single));
    });

    test('an empty cell still leaves a column to click in', () {
      final geometry = geometryFor('| a | b |\n| --- | --- |\n|  |  |');
      expect(geometry.columns.length, 2);
      for (final column in geometry.columns) {
        expect(column, greaterThanOrEqualTo(TableGeometry.padding * 2));
      }
    });

    test('a very long cell is cut short rather than crowding the rest out', () {
      final geometry = geometryFor('| a |\n| --- |\n| ${'word ' * 300} |');
      expect(
        geometry.columns.single,
        lessThanOrEqualTo(
          TableGeometry.maxCellWidth + TableGeometry.padding * 2 + 0.001,
        ),
      );
    });

    test('the width is the sum of every column', () {
      final geometry = geometryFor(simple);
      expect(
        geometry.width,
        closeTo(geometry.columns.reduce((a, b) => a + b), 0.001),
      );
    });
  });

  group('fitted into a width', () {
    test('a table that already fits is left exactly as it was', () {
      final natural = geometryFor(simple);
      final fitted = geometryFor(simple, fitToWidth: natural.width + 200);
      expect(fitted.width, closeTo(natural.width, 0.001));
      for (var c = 0; c < fitted.columns.length; c++) {
        expect(fitted.columns[c], closeTo(natural.columns[c], 0.001));
      }
    });

    test('a table too wide is brought inside the width given', () {
      final fitted = geometryFor(lopsided, fitToWidth: 200);
      expect(fitted.width, lessThanOrEqualTo(200.001));
    });

    test('the widest column gives up the room, not the narrow one', () {
      final natural = geometryFor(lopsided);
      final fitted = geometryFor(lopsided, fitToWidth: 200);
      final wideLoss = natural.columns[0] - fitted.columns[0];
      final narrowLoss = natural.columns[1] - fitted.columns[1];
      expect(wideLoss, greaterThan(narrowLoss));
      expect(
        narrowLoss,
        closeTo(0, 0.001),
        reason: 'a column of one digit had nothing to give',
      );
    });

    test('an impossibly narrow width is shared equally', () {
      final fitted = geometryFor(lopsided, fitToWidth: 40);
      expect(fitted.width, lessThanOrEqualTo(40.001));
      expect(fitted.columns[0], closeTo(fitted.columns[1], 0.001));
    });

    test('words wrap instead of being cut short', () {
      final wide = geometryFor(lopsided);
      final narrow = geometryFor(lopsided, fitToWidth: 200);
      final row = narrow.table.rows.last;
      expect(
        narrow.cell(row, 0)!.height,
        greaterThan(wide.cell(wide.table.rows.last, 0)!.height),
        reason: 'the same sentence needs more lines in a narrower column',
      );
      expect(
        narrow.cell(row, 0)!.didExceedMaxLines,
        isFalse,
        reason: 'nothing is hidden behind an ellipsis when it can wrap',
      );
    });

    test('a cell is laid out inside its own column', () {
      final narrow = geometryFor(lopsided, fitToWidth: 200);
      final row = narrow.table.rows.last;
      expect(
        narrow.cell(row, 0)!.width,
        lessThanOrEqualTo(narrow.innerWidth(0) + 0.001),
      );
    });
  });

  group('row heights', () {
    test('a row is at least as tall as one line of the note', () {
      final geometry = geometryFor(simple, minRowHeight: 29);
      for (final row in geometry.table.rows) {
        expect(geometry.rowHeight(row), greaterThanOrEqualTo(29));
      }
    });

    test('a wrapped row is taller than a row of one line', () {
      final narrow = geometryFor(lopsided, fitToWidth: 200, minRowHeight: 29);
      expect(
        narrow.rowHeight(narrow.table.rows.last),
        greaterThan(narrow.rowHeight(narrow.table.rows.first)),
      );
    });

    test('a row is its tallest cell plus padding above and below', () {
      final geometry = geometryFor(simple);
      final row = geometry.table.rows.first;
      final tallest = [
        for (var c = 0; c < geometry.columns.length; c++)
          geometry.cell(row, c)!.height,
      ].reduce((a, b) => a > b ? a : b);
      expect(
        geometry.rowHeight(row),
        closeTo(tallest + TableGeometry.padding * 2, 0.001),
      );
    });

    test('the height is every row added up', () {
      final geometry = geometryFor(simple, minRowHeight: 29);
      expect(
        geometry.height,
        closeTo(
          geometry.table.rows.map(geometry.rowHeight).reduce((a, b) => a + b),
          0.001,
        ),
      );
    });
  });

  group('cells', () {
    test('carry the words, with the markdown taken off', () {
      final geometry = geometryFor('| a |\n| --- |\n| **bold** |');
      expect(
        geometry.cell(geometry.table.rows.last, 0)?.plainText,
        'bold',
        reason: 'the asterisks are syntax, not words',
      );
    });

    test('a column the row does not have has no words', () {
      final geometry = geometryFor(simple);
      expect(geometry.cell(geometry.table.rows.first, 5), isNull);
    });

    test('a short row has an empty cell where it stops', () {
      final geometry = geometryFor('| a | b | c |\n|---|---|---|\n| 1 |');
      final row = geometry.table.rows.last;
      expect(geometry.cell(row, 0)?.plainText, '1');
      expect(geometry.cell(row, 2)?.plainText, isEmpty);
    });
  });

  group('finding a column by where it is', () {
    test('left edges add up', () {
      final geometry = geometryFor(simple);
      expect(geometry.columnLeft(0), 0);
      expect(geometry.columnLeft(1), closeTo(geometry.columns[0], 0.001));
      expect(geometry.columnLeft(2), closeTo(geometry.width, 0.001));
    });

    test('an offset names the column it is in', () {
      final geometry = geometryFor(simple);
      expect(geometry.columnAt(0), 0);
      expect(geometry.columnAt(geometry.columns[0] - 0.1), 0);
      expect(geometry.columnAt(geometry.columns[0]), 1);
      expect(geometry.columnAt(geometry.width - 0.1), 1);
    });

    test('and nothing outside the grid', () {
      final geometry = geometryFor(simple);
      expect(geometry.columnAt(-1), isNull);
      expect(geometry.columnAt(geometry.width), isNull);
      expect(geometry.columnAt(geometry.width + 50), isNull);
    });
  });

  group('collaborator carets', () {
    test('stay inside the visible cell and advance through its words', () {
      final geometry = geometryFor(simple, minRowHeight: 29);
      final row = geometry.table.rows.last;
      final source = row.cells.first;
      final start = geometry.caretRectInCell(row, 0, source.start)!;
      final end = geometry.caretRectInCell(row, 0, source.end)!;

      expect(start.left, greaterThanOrEqualTo(TableGeometry.padding));
      expect(end.left, greaterThan(start.left));
      expect(start.top, greaterThanOrEqualTo(0));
      expect(end.bottom, lessThanOrEqualTo(geometry.rowHeight(row) + 0.001));
    });

    test('follow wrapped words onto their visible line', () {
      final geometry = geometryFor(lopsided, fitToWidth: 120, minRowHeight: 29);
      final row = geometry.table.rows.last;
      final source = row.cells.first;
      final start = geometry.caretRectInCell(row, 0, source.start)!;
      final end = geometry.caretRectInCell(row, 0, source.end)!;

      expect(end.top, greaterThan(start.top));
    });

    test('honour the column alignment', () {
      final startAligned = geometryFor('| a long heading |\n| :--- |\n| x |');
      final endAligned = geometryFor('| a long heading |\n| ---: |\n| x |');
      final startRow = startAligned.table.rows.last;
      final endRow = endAligned.table.rows.last;

      expect(
        endAligned.caretRectInCell(endRow, 0, endRow.cells.first.start)!.left,
        greaterThan(
          startAligned
              .caretRectInCell(startRow, 0, startRow.cells.first.start)!
              .left,
        ),
      );
    });
  });

  group('the cache', () {
    TableGeometry ask(
      TableGeometryCache cache,
      MarkdownAnalysis analysis, {
      double? fitToWidth,
      TextStyle base = _base,
    }) => cache.of(
      table: analysis.tables.single,
      analysis: analysis,
      base: base,
      scaler: TextScaler.noScaling,
      runStyle: (base, styles) => base,
      fitToWidth: fitToWidth,
    );

    test('measures one table once', () {
      final cache = TableGeometryCache();
      addTearDown(cache.dispose);
      final analysis = MarkdownAnalyzer.analyzeWhole(simple);
      expect(identical(ask(cache, analysis), ask(cache, analysis)), isTrue);
    });

    test('measures again when the width it is fitted into changes', () {
      final cache = TableGeometryCache();
      addTearDown(cache.dispose);
      final analysis = MarkdownAnalyzer.analyzeWhole(simple);
      expect(
        identical(
          ask(cache, analysis, fitToWidth: 600),
          ask(cache, analysis, fitToWidth: 300),
        ),
        isFalse,
        reason: 'a narrower column cannot reuse a wider answer',
      );
    });

    test('measures again when the style changes', () {
      final cache = TableGeometryCache();
      addTearDown(cache.dispose);
      final analysis = MarkdownAnalyzer.analyzeWhole(simple);
      expect(
        identical(
          ask(cache, analysis),
          ask(cache, analysis, base: const TextStyle(fontSize: 22)),
        ),
        isFalse,
      );
    });

    test('forgets everything when the note is read again', () {
      final cache = TableGeometryCache();
      addTearDown(cache.dispose);
      final first = MarkdownAnalyzer.analyzeWhole(simple);
      final second = MarkdownAnalyzer.analyzeWhole(simple);
      expect(
        identical(ask(cache, first), ask(cache, second)),
        isFalse,
        reason: 'every offset held came from the analysis that was replaced',
      );
    });
  });
}
