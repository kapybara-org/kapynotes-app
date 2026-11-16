import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/line_metrics.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

const _base = TextStyle(fontSize: 16, height: 1.5);
const _tall = PlaceholderDimensions(
  size: Size(40, 90),
  alignment: PlaceholderAlignment.top,
);

/// Where each line starts, read off the whole text laid out as one paragraph,
/// the way the field lays it out.
List<double> wholeParagraphTops(
  InlineSpan span,
  String text,
  double width,
  StrutStyle strut, {
  List<PlaceholderDimensions> placeholders = const [],
}) {
  final painter = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    strutStyle: strut,
  );
  if (placeholders.isNotEmpty) painter.setPlaceholderDimensions(placeholders);
  painter.layout(maxWidth: width);
  final tops = <double>[];
  var offset = 0;
  for (final line in text.split('\n')) {
    tops.add(
      painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy,
    );
    offset += line.length + 1;
  }
  tops.add(painter.height);
  painter.dispose();
  return tops;
}

/// A note in the shapes the editor draws: a heading, hidden markers, a line
/// long enough to wrap, empty lines and a picture.
TextSpan note(String middle) => TextSpan(
  style: _base,
  children: [
    const TextSpan(
      text: 'Title\n',
      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
    ),
    const TextSpan(text: '**', style: TextStyle(fontSize: 0.01)),
    const TextSpan(
      text: 'bold',
      style: TextStyle(fontWeight: FontWeight.w700),
    ),
    const TextSpan(text: '**', style: TextStyle(fontSize: 0.01)),
    TextSpan(text: ' words\n$middle\n\n'),
    const WidgetSpan(child: SizedBox.shrink()),
    const TextSpan(text: '\nlast'),
  ],
);

void main() {
  setUpAll(loadTestFonts);

  for (final forced in [true, false]) {
    test('lines start where the whole paragraph puts them, '
        '${forced ? 'with' : 'without'} a forced strut', () {
      final strut = StrutStyle(
        fontSize: 16,
        height: 1.5,
        forceStrutHeight: forced,
      );
      final measurer = LineMeasurer();
      for (final middle in [
        'short',
        'a line long enough to wrap onto a second row and then a third row '
            'of the narrow column it is laid out in',
        'short\nand one more line',
        '',
      ]) {
        final span = note(middle);
        final text = span.toPlainText();
        final measured = measurer.measure(
          span: span,
          maxWidth: 200,
          strut: strut,
          textScaler: TextScaler.noScaling,
          placeholders: const [_tall],
        );
        final expected = wholeParagraphTops(
          span,
          text,
          200,
          strut,
          placeholders: const [_tall],
        );
        expect(
          [...measured.tops, measured.totalHeight],
          [for (final top in expected) moreOrLessEquals(top, epsilon: 0.01)],
          reason: middle,
        );
      }
    });
  }

  test('lays out only the lines an edit changed', () {
    const strut = StrutStyle(fontSize: 16, height: 1.5, forceStrutHeight: true);
    final measurer = LineMeasurer();
    final lines = List.generate(2000, (i) => 'line $i with some words');
    TextSpan spanOf(List<String> lines) =>
        TextSpan(style: _base, text: lines.join('\n'));

    measurer.measure(
      span: spanOf(lines),
      maxWidth: 300,
      strut: strut,
      textScaler: TextScaler.noScaling,
    );
    lines[1000] = '${lines[1000]} and more';
    final measured = measurer.measure(
      span: spanOf(lines),
      maxWidth: 300,
      strut: strut,
      textScaler: TextScaler.noScaling,
    );
    expect(measured.tops, hasLength(2000));
    final expected = wholeParagraphTops(
      spanOf(lines),
      lines.join('\n'),
      300,
      strut,
    );
    expect(measured.tops.last, moreOrLessEquals(expected[1999]));
    expect(measured.totalHeight, moreOrLessEquals(expected.last));
  });
}
