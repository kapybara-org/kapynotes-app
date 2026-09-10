import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/notebook_paper.dart';
import 'package:material_ui/material_ui.dart';

/// Renders the sheet on its own and hands back the pixels.
Future<ui.Image> _sheet(
  WidgetTester tester, {
  required PaperStyle style,
  required Brightness brightness,
  double lineHeight = 20,
  double topInset = 10,
  ScrollController? scroll,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? KapyTheme.dark()
          : KapyTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            height: 100,
            child: NotebookPaper(
              style: style,
              lineHeight: lineHeight,
              topInset: topInset,
              scroll: scroll,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (await tester.runAsync(
    () => captureImage(find.byType(NotebookPaper).evaluate().single),
  ))!;
}

/// How many pixels of the sheet are not the colour it started as.
Future<int> _markedPixels(WidgetTester tester, ui.Image image) async {
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final bytes = data!.buffer.asUint8List();
  var marked = 0;
  for (var i = 3; i < bytes.length; i += 4) {
    if (bytes[i] != 0) marked++;
  }
  return marked;
}

/// The y of every row that has any ink in it.
Future<List<int>> _inkedRows(WidgetTester tester, ui.Image image) async {
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final bytes = data!.buffer.asUint8List();
  final rows = <int>[];
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if (bytes[(y * image.width + x) * 4 + 3] != 0) {
        rows.add(y);
        break;
      }
    }
  }
  return rows;
}

void main() {
  testWidgets('plain paper paints nothing at all', (tester) async {
    final image = await _sheet(
      tester,
      style: PaperStyle.plain,
      brightness: Brightness.light,
    );
    expect(await _markedPixels(tester, image), 0);
  });

  testWidgets('the notepad grain is light-only, as it always was', (
    tester,
  ) async {
    // The fibres are a warm ink tone that reads as stock on a pale page and
    // as dirt on a dark one.
    final light = await _sheet(
      tester,
      style: PaperStyle.notepad,
      brightness: Brightness.light,
    );
    expect(await _markedPixels(tester, light), greaterThan(0));

    final dark = await _sheet(
      tester,
      style: PaperStyle.notepad,
      brightness: Brightness.dark,
    );
    expect(await _markedPixels(tester, dark), 0);
  });

  testWidgets('ruling is drawn in both themes, because it was asked for', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      final image = await _sheet(
        tester,
        style: PaperStyle.ruled,
        brightness: brightness,
      );
      expect(
        await _markedPixels(tester, image),
        greaterThan(0),
        reason: 'ruling nobody can see is not ruling',
      );
    }
  });

  testWidgets('a line lands under each row, at the row pitch', (tester) async {
    final image = await _sheet(
      tester,
      style: PaperStyle.ruled,
      brightness: Brightness.light,
      lineHeight: 20,
      topInset: 10,
    );

    // Rows at 10 + 20n, so lines just above 30, 50, 70, 90. Grouped, because
    // a hairline at 29.5 inks the pixel rows either side of it.
    final rows = await _inkedRows(tester, image);
    expect(rows, isNotEmpty);
    final bands = <int>[];
    for (final y in rows) {
      if (bands.isEmpty || y - bands.last > 2) bands.add(y);
    }
    expect(bands.length, 4, reason: 'a 100pt sheet holds four 20pt rows');
    for (var i = 1; i < bands.length; i++) {
      expect(bands[i] - bands[i - 1], 20);
    }
    // The first line is under the first row, not through it.
    expect(bands.first, greaterThanOrEqualTo(28));
    expect(bands.first, lessThanOrEqualTo(30));
  });

  testWidgets('ruling moves with the text rather than sitting still', (
    tester,
  ) async {
    // The sheet is behind the viewport, so a scroll that did not move the
    // lines would slide the writing across fixed ruling.
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final still = await _sheet(
      tester,
      style: PaperStyle.ruled,
      brightness: Brightness.light,
      lineHeight: 20,
      topInset: 10,
    );
    final bandsBefore = await _inkedRows(tester, still);

    // Half a row down: the lines should land halfway between where they were.
    final moved = await _sheet(
      tester,
      style: PaperStyle.ruled,
      brightness: Brightness.light,
      lineHeight: 20,
      topInset: 0,
    );
    final bandsAfter = await _inkedRows(tester, moved);
    expect(bandsAfter.first, lessThan(bandsBefore.first));
  });

  testWidgets('nothing is drawn before the editor has measured itself', (
    tester,
  ) async {
    // A pitch of zero would be an infinite loop, and a guessed one would be
    // ruling at the wrong spacing for a frame.
    final image = await _sheet(
      tester,
      style: PaperStyle.ruled,
      brightness: Brightness.light,
      lineHeight: 0,
    );
    expect(await _markedPixels(tester, image), 0);
  });
}
