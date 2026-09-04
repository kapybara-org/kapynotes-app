import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';

void main() {
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
}
