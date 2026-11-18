import 'dart:math' as math;

import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/highlighting_controller.dart';
import 'package:kapy_notes/ui/editor/note_lines.dart';
import 'package:kapy_notes/ui/editor/note_sliver.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

TextStyle get _style =>
    EditorMetrics.textStyle(const Color(0xFF000000), WritingFont.handwritten);

/// Lines of every height a note has: blank, one row, wrapped onto several,
/// and headings in a larger face.
String _note(int count) {
  final random = math.Random(count);
  return [
    for (var i = 0; i < count; i++)
      switch (random.nextInt(6)) {
        0 => '',
        1 => '# Heading $i',
        2 =>
          'Line $i, which wraps onto a second row of the column and then a '
              'third, because it goes on and on with words until it is well past '
              'the width of the note ${'and on ' * random.nextInt(20)}',
        _ => 'Line $i',
      },
  ].join('\n');
}

NoteLayout _layout(NoteLines lines) => NoteLayout(
  lines: lines,
  spanOf: (line) {
    final text = lines[line];
    return (
      span: TextSpan(
        text: text,
        style: text.startsWith('#') ? _style.copyWith(fontSize: 30) : _style,
      ),
      placeholders: const [],
      folded: false,
      row: null,
      inset: 0,
    );
  },
  style: _style,
  strut: EditorMetrics.strut(WritingFont.handwritten),
);

Widget _view(
  NoteLayout layout,
  ScrollController scroll, {
  double height = 600,
  double cacheExtent = 250,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: EditorMetrics.columnWidth,
      height: height,
      child: CustomScrollView(
        controller: scroll,
        scrollCacheExtent: ScrollCacheExtent.pixels(cacheExtent),
        slivers: [NoteSliver(layout: layout)],
      ),
    ),
  ),
);

/// Every line laid out now, each once: a line's render object is also the
/// render object of the widgets above it in the sliver.
List<RenderNoteLine> _shown(WidgetTester tester) =>
    tester.allRenderObjects.whereType<RenderNoteLine>().toSet().toList();

RenderNoteLine _line(WidgetTester tester, int line) =>
    _shown(tester).singleWhere((shown) => shown.line == line);

double _top(WidgetTester tester, int line) =>
    _line(tester, line).localToGlobal(Offset.zero).dy;

/// The first line whose box reaches below the top of the viewport.
int _firstInView(WidgetTester tester) {
  final shown = _shown(tester)..sort((a, b) => a.line.compareTo(b.line));
  return shown
      .firstWhere(
        (line) => line.localToGlobal(Offset.zero).dy + line.size.height > 0,
      )
      .line;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('only the lines in view and in the cache extent are laid out', (
    tester,
  ) async {
    final lines = NoteLines(_note(5000));
    final layout = _layout(lines);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_view(layout, scroll));

    final shown = _shown(tester).map((line) => line.line).toList()..sort();
    expect(shown.first, 0);
    expect(shown.length, lessThan(60));
    expect(scroll.position.maxScrollExtent, greaterThan(5000 * 29 - 600));

    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pump();
    final middle = _shown(tester).map((line) => line.line).toList()..sort();
    expect(middle.length, lessThan(60));
    expect(middle.first, greaterThan(1000));
    for (final line in _shown(tester)) {
      expect(
        line.size.height,
        layout.paragraphOf(line.line).height,
        reason: 'line ${line.line}',
      );
    }
  });

  testWidgets('measuring the lines above the first in view keeps it where it '
      'is on screen', (tester) async {
    final lines = NoteLines(_note(2000));
    final layout = _layout(lines);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_view(layout, scroll));
    scroll.jumpTo(30000);
    await tester.pump();

    var corrected = false;
    for (var step = 0; step < 60; step++) {
      final first = _firstInView(tester);
      final top = _top(tester, first);
      final before = scroll.offset;
      scroll.jumpTo(before - 200);
      await tester.pump();
      if ((scroll.offset - (before - 200)).abs() > 0.001) corrected = true;
      expect(
        _top(tester, first),
        moreOrLessEquals(top + 200, epsilon: 0.01),
        reason: 'step $step',
      );
    }
    expect(corrected, isTrue, reason: 'no estimate was wrong');
  });

  testWidgets('an edit above the first line in view keeps it where it is on '
      'screen', (tester) async {
    final lines = NoteLines(_note(2000));
    final layout = _layout(lines);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_view(layout, scroll));
    scroll.jumpTo(20000);
    await tester.pump();

    final first = _firstInView(tester);
    final text = lines[first];
    final top = _top(tester, first);
    final start = lines.startOf(10);
    final edit = lines.replace(start, start, 'One\n# Two\n\nFour\n');
    expect(edit, (line: 10, removed: 1, inserted: 5));
    layout.edited(edit);
    await tester.pumpWidget(_view(layout, scroll));

    expect(lines[first + 4], text);
    expect(_top(tester, first + 4), moreOrLessEquals(top, epsilon: 0.01));

    final end = lines.endOf(12);
    final removal = lines.replace(lines.startOf(5), end, '');
    layout.edited(removal);
    await tester.pumpWidget(_view(layout, scroll));
    expect(lines[first - 3], text);
    expect(_top(tester, first - 3), moreOrLessEquals(top, epsilon: 0.01));
  });

  testWidgets('an edit to a line in view lays out that line again', (
    tester,
  ) async {
    final lines = NoteLines(_note(200));
    final layout = _layout(lines);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_view(layout, scroll));

    final edit = lines.replace(
      lines.endOf(3),
      lines.endOf(3),
      ' ${'and more words ' * 30}',
    );
    layout.edited(edit);
    await tester.pumpWidget(_view(layout, scroll));
    final edited = _line(tester, 3);
    expect(edited.paragraph.plainText, lines[3]);
    expect(edited.size.height, greaterThan(3 * 29));
    expect(_top(tester, 4), _top(tester, 3) + edited.size.height);
  });

  testWidgets('jumping to the end lands the last line on the bottom of the '
      'viewport', (tester) async {
    final lines = NoteLines(_note(3000));
    final layout = _layout(lines);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_view(layout, scroll));

    var notified = 0;
    scroll.addListener(() => notified++);
    layout.jumpToEnd(scroll.position);
    await tester.pump();
    expect(notified, greaterThan(0));
    final last = _line(tester, lines.length - 1);
    expect(
      last.localToGlobal(Offset(0, last.size.height)).dy,
      moreOrLessEquals(600, epsilon: 0.01),
    );
    expect(scroll.offset, moreOrLessEquals(scroll.position.maxScrollExtent));
  });

  for (final (name, platform) in [
    ('on a desktop', TargetPlatform.macOS),
    ('on a phone', TargetPlatform.iOS),
  ]) {
    testWidgets('lines laid out one at a time sit where one paragraph of the '
        'whole note puts them, $name', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      // The page sets a code block's rows itself, as no one paragraph can, so
      // the block is left to the tests of those rows there.
      final body = '''Groceries and sums
## Monday
- [ ] milk \$2.50
- [x] bread
  1. nested *item* with **bold**
12. a wider number
> quoted `code` and a [link](https://example.com)
### A third-level heading with **bold** in it
###### Small heading
Some **bold**, some *italic*, some ***both*** and some `code`.

price = 4 usd
price * 3 // a comment
☐ a box with https://kapynotes.app/help in it
☑ done
A line long enough to wrap onto a second row of the column and then a third row as well, because it simply keeps going with more and more words, and **bold** words too, until it is well past the width of the note.

total''';
      final engine = CalcEngine();
      final controller = HighlightingController(
        highlighter: Highlighter(engine.registry),
        palette: KapyTheme.lightPalette,
        writingFont: WritingFont.handwritten,
        markdown: true,
        text: body,
      )..spellingSuggestions = const [];
      addTearDown(controller.dispose);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.light(),
          home: Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox();
            },
          ),
        ),
      );
      final strut = EditorMetrics.strut(WritingFont.handwritten);
      final whole = TextPainter(
        text: controller.buildTextSpan(
          context: context,
          style: _style,
          withComposing: false,
        ),
        textDirection: TextDirection.ltr,
        strutStyle: strut,
      )..layout(maxWidth: EditorMetrics.columnWidth);
      addTearDown(whole.dispose);
      final spansIn = controller.spansIn(context, _style);

      final lines = NoteLines(body);
      final layout = NoteLayout(
        lines: lines,
        spanOf: (line) => spansIn(lines.startOf(line), lines.endOf(line)),
        style: _style,
        strut: strut,
      );
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(_view(layout, scroll, cacheExtent: 5000));
      expect(_shown(tester), hasLength(lines.length));

      final rows = whole.computeLineMetrics();
      final heights = layout.heights!;
      var row = 0;
      final off = <String>[];
      for (var line = 0; line < lines.length; line++) {
        final top = heights.topOf(line);
        for (final mine in layout.paragraphOf(line).computeLineMetrics()) {
          final theirs = rows[row++];
          final down = (top + mine.baseline - theirs.baseline).abs();
          final across = lines[line].isEmpty
              ? 0.0
              : math.max(
                  (mine.left - theirs.left).abs(),
                  (mine.width - theirs.width).abs(),
                );
          if (down >= 0.01 || across >= 0.05) {
            off.add(
              'line $line row ${mine.lineNumber}: $down down, $across across',
            );
          }
        }
      }
      expect(off, isEmpty);
      expect(row, rows.length);
      expect(heights.total, moreOrLessEquals(whole.height, epsilon: 0.01));
    });
  }
}
