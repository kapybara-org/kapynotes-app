import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:material_ui/material_ui.dart';

import '../../benchmark/markdown_rendering.dart' as rendering;
import '../../benchmark/spike_b_note_sliver.dart';
import '../test_fonts.dart';

/// Lines in every shape the benchmark note has, and the markdown the editor
/// styles that it lacks: bold, italic, inline code, links, lists, tasks,
/// headings of every level and a line long enough to wrap.
const _extra = [
  '# A title',
  '### A third-level heading with **bold** in it',
  '###### Small heading',
  'Some **bold**, some *italic*, some ***both*** and some `code`.',
  'A [link to the docs](https://example.com/docs) and https://kapy.example/x.',
  '- a bullet',
  '- [ ] a task to do',
  '- [x] a task that is done',
  '1. a numbered item',
  '12. a wider number',
  '> a quote with *emphasis*',
  'A line long enough to wrap onto a second row of the column and then a third '
      'row as well, because it simply keeps going with more and more words, '
      'and **bold** words too, until it is well past the width of the note.',
  '',
  'price = 12 usd',
  'price * 3 // a comment',
];

LineStyler _styler({bool forced = false}) {
  final theme = KapyTheme.dark();
  final palette = theme.extension<CalcPalette>()!;
  return LineStyler(
    base: EditorMetrics.textStyle(
      palette.textPrimary,
      WritingFont.handwritten,
    ).copyWith(fontWeight: FontWeight.w500),
    strut: EditorMetrics.strut(
      WritingFont.handwritten,
      allowTallRows: !forced,
    ),
    palette: palette,
    linkColor: theme.colorScheme.primary,
    highlighter: Highlighter(CalcEngine().registry),
  );
}

void main() {
  setUpAll(loadTestFonts);

  test('the repeated note is the benchmark note at 5,000 lines', () {
    expect(repeatedNote(5000), rendering.longNote());
    final long = repeatedNote(20000).split('\n');
    expect(long, hasLength(20000));
    expect(long.toSet().length, greaterThan(13000));
  });

  test('code fences and display formulas are found in one pass', () {
    final lines = ['a', '```python', 'x = 1', '```', r'$$', 'k^2', r'$$', 'b'];
    expect([for (final kind in classifyLines(lines)) kind.role], [
      LineRole.plain,
      LineRole.open,
      LineRole.body,
      LineRole.close,
      LineRole.open,
      LineRole.body,
      LineRole.close,
      LineRole.plain,
    ]);
  });

  for (final forced in [false, true]) {
    test('per-line paragraphs put every line where one paragraph of the whole '
        'note puts it, ${forced ? 'with' : 'without'} a forced strut', () {
      final styler = _styler(forced: forced);
      final lines = [
        ...rendering.longNote().split('\n'),
        ..._extra,
      ];
      final layout = NoteLayout(body: lines.join('\n'), styler: styler);
      for (var i = 0; i < lines.length; i++) {
        layout.measure(i);
      }

      final spans = <InlineSpan>[];
      for (var i = 0; i < lines.length; i++) {
        final span = styler.spanFor(lines[i], layout.kinds[i]);
        expect(span.toPlainText(), lines[i], reason: 'line $i');
        if (i > 0) spans.add(const TextSpan(text: '\n'));
        spans.add(span);
      }
      final whole = TextPainter(
        text: TextSpan(style: styler.base, children: spans),
        textDirection: TextDirection.ltr,
        strutStyle: styler.strut,
      )..layout(maxWidth: layout.columnWidth);
      final rows = whole.computeLineMetrics();

      // Every row of every line, read from the line's own paragraph placed at
      // its top in the height index, against the same row of the whole note:
      // the baseline its glyphs sit on, and where its writing starts and
      // stops. (A row's reported ascent is not compared: in one paragraph a
      // row also carries the newline's run, in the base face, so a row of
      // code or of hidden markers reports a different ascent over the same
      // baseline.)
      //
      // The whole paragraph is the less exact of the two across: it places
      // glyphs at float32 offsets along the note's unbroken run of text, so
      // past about 65,000px of it (some 120 lines) a row's width there is
      // only good to a step of 0.008px, and differences of 0.02px appear.
      var row = 0;
      var down = 0.0;
      var across = 0.0;
      final off = <String>[];
      for (var i = 0; i < lines.length; i++) {
        final own = layout.painterFor(i).computeLineMetrics();
        final top = layout.index.topOf(i);
        for (final mine in own) {
          final theirs = rows[row++];
          final vertical = (top + mine.baseline - theirs.baseline).abs();
          final horizontal = lines[i].isEmpty
              ? 0.0
              : math.max(
                  (mine.left - theirs.left).abs(),
                  (mine.width - theirs.width).abs(),
                );
          down = math.max(down, vertical);
          across = math.max(across, horizontal);
          if (vertical >= 0.01 || horizontal >= 0.05) {
            off.add('line $i row ${mine.lineNumber}: $vertical, $horizontal');
          }
        }
      }
      // ignore: avoid_print
      print('${forced ? 'forced' : 'relaxed'} strut: $row rows of '
          '${lines.length} lines; baselines within $down px, '
          'row ends within $across px');
      expect(off.take(8), isEmpty, reason: '${off.length} rows differ');
      expect(row, rows.length);
      expect(
        layout.index.total,
        moreOrLessEquals(whole.height, epsilon: 0.01),
      );
      whole.dispose();
    });
  }

  test('wrapped and heading lines are taller than one row, and the rest are '
      'one row', () {
    final layout = NoteLayout(body: _extra.join('\n'), styler: _styler());
    final heights = [
      for (var i = 0; i < _extra.length; i++) layout.measure(i),
    ];
    expect(heights[11], greaterThan(2 * 29 - 0.5));
    expect(heights[12], moreOrLessEquals(29, epsilon: 0.5));
  });
}
