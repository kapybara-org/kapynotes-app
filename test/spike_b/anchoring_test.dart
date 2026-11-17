import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:material_ui/material_ui.dart';

import '../../benchmark/spike_b_note_sliver.dart';
import '../test_fonts.dart';

/// Every fifth line wraps onto several rows of the column.
String _note(int count) => [
  for (var i = 0; i < count; i++)
    i % 5 == 0
        ? 'Line $i is long enough to wrap onto more rows. ' * 6
        : 'Line $i is short.',
].join('\n');

/// Every line one row, so every long line's estimate is short by rows.
double _oneRow(String line, LineKind kind, double width) => 29;

const _viewport = Size(1280, 900);

Future<(NoteLayout, ScrollController)> _show(
  WidgetTester tester,
  String body,
) async {
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late NoteLayout layout;
  late ScrollController scroll;
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: SpikeNoteView(
        body: body,
        highlighter: Highlighter(CalcEngine().registry),
        estimate: _oneRow,
        onReady: (l, s) {
          layout = l;
          scroll = s;
        },
      ),
    ),
  );
  return (layout, scroll);
}

void main() {
  setUpAll(loadTestFonts);
  final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

  testWidgets(
    'refining estimates above the viewport leaves the first visible line '
    'where it is',
    (tester) async {
      final (layout, scroll) = await _show(tester, _note(3000));
      scroll.jumpTo(40000);
      await tester.pump();
      final render = layout.renderSliver!;
      final first = render.firstVisibleLine!;
      final top = render.screenTopOf(first)!;
      final offset = scroll.offset;
      final before = layout.index.topOf(first);
      expect(layout.index.isMeasured(first - 100), isFalse);

      layout.refine(0, first - 20);
      await tester.pump();

      final grew = layout.index.topOf(first) - before;
      expect(grew, greaterThan(1000));
      expect(render.firstVisibleLine, first);
      expect(render.screenTopOf(first), moreOrLessEquals(top, epsilon: 0.01));
      expect(scroll.offset, moreOrLessEquals(offset + grew, epsilon: 0.01));
      expect(layout.stats.anchorDriftMax, lessThan(0.01));
    },
    variant: mac,
  );

  testWidgets(
    'scrolling up over unmeasured lines moves the page by the scroll and '
    'nothing more',
    (tester) async {
      final (layout, scroll) = await _show(tester, _note(3000));
      layout.jumpToEnd();
      await tester.pump();
      final render = layout.renderSliver!;
      final corrections = layout.stats.corrections;
      for (var step = 0; step < 300; step++) {
        final first = render.firstVisibleLine!;
        final top = render.screenTopOf(first)!;
        scroll.jumpTo(scroll.offset - 40);
        await tester.pump();
        expect(
          render.screenTopOf(first),
          moreOrLessEquals(top + 40, epsilon: 0.01),
          reason: 'step $step',
        );
      }
      expect(layout.stats.corrections - corrections, greaterThan(10));
      expect(layout.stats.anchorDriftMax, lessThan(0.01));
    },
    variant: mac,
  );

  testWidgets(
    'a jump to the end puts the last line exactly on the bottom edge',
    (tester) async {
      final (layout, scroll) = await _show(tester, _note(3000));
      layout.jumpToEnd();
      await tester.pump();
      final render = layout.renderSliver!;
      final last = layout.length - 1;
      double bottom() =>
          render.screenTopOf(last)! + layout.index.heightOf(last);
      expect(bottom(), moreOrLessEquals(_viewport.height, epsilon: 0.001));
      expect(
        scroll.offset,
        moreOrLessEquals(scroll.position.maxScrollExtent, epsilon: 0.001),
      );
      await tester.pumpAndSettle();
      expect(bottom(), moreOrLessEquals(_viewport.height, epsilon: 0.001));
    },
    variant: mac,
  );

  testWidgets(
    'a fling up from the end through the platform physics corrects as it '
    'goes without moving the anchored line',
    (tester) async {
      final (layout, scroll) = await _show(tester, _note(3000));
      layout.jumpToEnd();
      await tester.pumpAndSettle();
      final start = scroll.offset;
      final corrections = layout.stats.corrections;
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 600),
        4000,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(start));
      expect(layout.stats.corrections, greaterThan(corrections));
      expect(layout.stats.anchorDriftMax, lessThan(0.01));
    },
    variant: mac,
  );
}
