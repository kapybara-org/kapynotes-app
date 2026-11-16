import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/calc/keyword_help.dart';
import 'package:kapy_notes/calc/parser.dart';

void main() {
  test('every colored calculator keyword has an explanation', () {
    expect(calcKeywordHelp.keys.toSet(), calcKeywords);
  });

  test('highlights only the // suffix on prose and calculation lines', () {
    const body = '''Meeting notes // confirm date
2 + 2 // rough estimate
  // standalone comment''';
    final comments = Highlighter(CalcEngine().registry)
        .spans(body)
        .where((span) => span.kind == HighlightKind.comment)
        .map((span) => body.substring(span.start, span.end))
        .toList();

    expect(comments, [
      '// confirm date',
      '// rough estimate',
      '// standalone comment',
    ]);
  });

  test('does not treat URL slashes as a comment delimiter', () {
    const body =
        'Read https://example.com/path//part and keep writing // real comment';
    final comments = Highlighter(CalcEngine().registry)
        .spans(body)
        .where((span) => span.kind == HighlightKind.comment)
        .map((span) => body.substring(span.start, span.end))
        .toList();

    expect(comments, ['// real comment']);
  });

  test('keeps numbers in an explicit description plain', () {
    const body = '7KvA Solar System : 12000rs';
    final numberText =
        Highlighter(CalcEngine(ratesPerUsd: const {'INR': 80}).registry)
            .spans(body)
            .where((span) => span.kind == HighlightKind.number)
            .map((span) => body.substring(span.start, span.end))
            .toList();

    expect(numberText, ['12000']);
  });

  test('highlights bracketless functions and temporal names', () {
    const body = 'sqrt 16\ntoday + 2 weeks';
    final highlighted = Highlighter(CalcEngine().registry)
        .spans(body)
        .map((span) => (body.substring(span.start, span.end), span.kind))
        .toList();

    expect(highlighted, contains(('sqrt', HighlightKind.function)));
    expect(highlighted, contains(('today', HighlightKind.constant)));
  });

  test('colours ×, ÷ and − as operators and leaves dashes as text', () {
    final highlighter = Highlighter(
      CalcEngine(ratesPerUsd: const {'EUR': 0.5}).registry,
    );
    List<(String, HighlightKind)> spans(String body) => highlighter
        .spans(body)
        .map((span) => (body.substring(span.start, span.end), span.kind))
        .toList();

    expect(spans('3 × 49 usd'), contains(('×', HighlightKind.operator)));
    expect(spans('10 ÷ 4'), contains(('÷', HighlightKind.operator)));
    expect(spans('10 − 3'), contains(('−', HighlightKind.operator)));
    expect(spans('Lunch — 12 usd'), [
      ('12', HighlightKind.number),
      ('usd', HighlightKind.currency),
    ]);
    expect(spans('2020–2024'), [('2020', HighlightKind.number)]);
  });
}
