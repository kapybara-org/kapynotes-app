import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/note_link.dart';
import 'package:kapy_notes/ui/editor/markdown_syntax.dart';

// What typing keeps from one key to the next, against the same read from
// scratch: after every edit of a long run of random ones, the answers match.

const _note = '''
# Budget
rent = 1200
total = rent * 2 // monthly
see https://example.com/a and www.kapy.app/b.
price: 3 * 4.50
- groceries: 12 + 8
`code https://x.io/c` and [words](https://kapy.app/d)
x = 5
x * total
> quoted 7 * 6
```
fenced = 3
```
| a | b |
| --- | --- |
| 1 | https://t.co/e |
plain words about nothing''';

const _keys = 'abx= 12*+/:.#`-[]()\nhtps:/w';

/// [text] with one random edit: a key typed, a stretch deleted, or a line
/// pasted.
String _edit(String text, Random random) {
  final at = random.nextInt(text.length + 1);
  switch (random.nextInt(4)) {
    case 0:
      final end = min(text.length, at + random.nextInt(12));
      return text.replaceRange(at, end, '');
    case 1:
      final lines = _note.split('\n');
      return text.replaceRange(
        at,
        at,
        '${lines[random.nextInt(lines.length)]}\n',
      );
    default:
      return text.replaceRange(at, at, _keys[random.nextInt(_keys.length)]);
  }
}

List<(int, int, HighlightKind)> _spans(List<HighlightSpan> spans) => [
  for (final span in spans) (span.start, span.end, span.kind),
];

List<(int, int, String, String)> _links(List<NoteLink> links) => [
  for (final link in links) (link.start, link.end, link.text, '${link.uri}'),
];

void main() {
  test('highlighting kept line by line matches highlighting from scratch', () {
    final registry = CalcEngine().registry;
    final kept = Highlighter(registry);
    final finder = NoteLinkFinder();
    final random = Random(14);
    var text = _note * 3;
    for (var i = 0; i < 400; i++) {
      text = _edit(text, random);
      final links = finder.find(text);
      expect(_links(links), _links(findNoteLinks(text)), reason: 'edit $i');
      expect(
        _spans(kept.spans(text, links: links)),
        _spans(Highlighter(registry).spans(text)),
        reason: 'edit $i',
      );
    }
  });

  test('links over markdown match a check of every pair', () {
    final finder = NoteLinkFinder();
    final random = Random(15);
    var text = _note * 2;
    for (var i = 0; i < 300; i++) {
      text = _edit(text, random);
      final analysis = MarkdownAnalyzer.analyzeWhole(text);
      final found = finder.find(text);
      bool overlaps(NoteLink link, Iterable<TextRange> ranges) => ranges.any(
        (range) => link.start < range.end && link.end > range.start,
      );
      final expected = [
        for (final link in found)
          if (!overlaps(link, analysis.literals) &&
              !overlaps(link, analysis.addresses) &&
              !overlaps(link, [
                for (final written in analysis.links)
                  TextRange(start: written.start, end: written.end),
              ]))
            link,
      ];
      final web = analysis
          .linksWith(found)
          .where((link) => found.any((f) => identical(f, link)))
          .toList();
      expect(_links(web), _links(expected), reason: 'edit $i');
    }
  });
}
