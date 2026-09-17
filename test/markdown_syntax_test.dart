import 'dart:math';

import 'package:flutter/services.dart' show TextRange, TextSelection;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/note_link.dart';
import 'package:kapy_notes/ui/editor/markdown_syntax.dart';

MarkdownAnalysis read(String text) => MarkdownAnalyzer().analyze(text);

/// Every style covering the character at [offset].
Set<MarkdownStyle> stylesAt(MarkdownAnalysis analysis, int offset) => {
  for (final span in analysis.spans)
    if (span.start <= offset && offset < span.end) span.style,
};

/// What of [marked] is on screen with the caret at its `|`: the note with
/// every hidden range taken out. [editing] is a focused note; [typing] is
/// one being typed in, rather than one the caret was moved in.
String visible(String marked, {bool editing = true, bool typing = false}) {
  final caret = marked.indexOf('|');
  final text = marked.replaceAll('|', '');
  final concealment = read(text).concealFor(
    caret < 0 ? null : TextSelection.collapsed(offset: caret),
    revealBlocks: editing,
    revealEdges: editing && !typing,
  );
  var shown = text;
  for (final range in concealment.hidden.reversed) {
    shown = shown.replaceRange(range.start, range.end, '');
  }
  return shown;
}

/// The styles over the first occurrence of [needle], character by character.
Set<MarkdownStyle> stylesOf(MarkdownAnalysis analysis, String needle) {
  final start = analysis.text.indexOf(needle);
  expect(start, isNot(-1), reason: '"$needle" is not in the note');
  Set<MarkdownStyle>? common;
  for (var i = start; i < start + needle.length; i++) {
    final here = stylesAt(analysis, i);
    common = common == null ? here : common.intersection(here);
  }
  return common!;
}

void main() {
  group('reads', () {
    test('ATX headings at every level, with quiet markers', () {
      final analysis = read('# One\n## Two\n###### Six\n#hashtag');
      expect(stylesOf(analysis, 'One'), {MarkdownStyle.heading1});
      expect(stylesOf(analysis, 'Two'), {MarkdownStyle.heading2});
      expect(stylesOf(analysis, 'Six'), {MarkdownStyle.heading6});
      expect(stylesAt(analysis, 0), contains(MarkdownStyle.syntax));
      // Not a heading without its space.
      expect(stylesOf(analysis, 'hashtag'), isEmpty);
    });

    test('a setext heading, underline and all', () {
      final analysis = read('Title\n===\n\nSub\n---');
      expect(stylesOf(analysis, 'Title'), {MarkdownStyle.heading1});
      expect(stylesOf(analysis, '==='), {MarkdownStyle.syntax});
      expect(stylesOf(analysis, 'Sub'), {MarkdownStyle.heading2});
    });

    test('emphasis, strong, strikethrough and code, with their markers', () {
      final analysis = read('*it* **bold** ~~gone~~ `code`');
      expect(stylesOf(analysis, 'it'), {MarkdownStyle.emphasis});
      expect(stylesOf(analysis, 'bold'), {MarkdownStyle.strong});
      expect(stylesOf(analysis, 'gone'), {MarkdownStyle.strikethrough});
      expect(stylesOf(analysis, 'code'), {MarkdownStyle.code});
      expect(stylesOf(analysis, '**'), {
        MarkdownStyle.strong,
        MarkdownStyle.syntax,
      });
      expect(stylesOf(analysis, '`'), {
        MarkdownStyle.code,
        MarkdownStyle.syntax,
      });
    });

    test('a * between two operands is multiplication, not emphasis', () {
      for (final line in ['2*3*4', 'a*b*c', '(2+3)*4*(5)', '2**3**2']) {
        final analysis = read(line);
        expect(
          analysis.spans.where(
            (span) =>
                span.style == MarkdownStyle.emphasis ||
                span.style == MarkdownStyle.strong,
          ),
          isEmpty,
          reason: line,
        );
      }
      // Emphasis next to punctuation that is not an operand still works.
      expect(stylesOf(read('(*see* this)'), 'see'), {MarkdownStyle.emphasis});
      expect(stylesOf(read('**bold**.'), 'bold'), {MarkdownStyle.strong});
      // And `_` keeps CommonMark's own rules.
      expect(stylesOf(read('snake_case_name'), 'case'), isEmpty);
      expect(stylesOf(read('__init__'), 'init'), {MarkdownStyle.strong});
    });

    test('lists: bullets and boxes, numbers, and a ticked one\'s words', () {
      const note = '- [x] done\n  - child\n- [ ] open\n1. first\n2) second';
      final analysis = read(note);
      expect(analysis.ornaments, [
        const MarkdownOrnament(
          MarkdownOrnamentKind.checkbox,
          2,
          5,
          checked: true,
        ),
        MarkdownOrnament(
          MarkdownOrnamentKind.bullet,
          note.indexOf('- child'),
          note.indexOf('- child') + 2,
          depth: 1,
        ),
        MarkdownOrnament(
          MarkdownOrnamentKind.checkbox,
          note.indexOf('[ ]'),
          note.indexOf('[ ]') + 3,
        ),
      ]);
      expect(stylesOf(analysis, '[x]'), {MarkdownStyle.taskBox});
      expect(stylesOf(analysis, 'done'), {MarkdownStyle.doneTask});
      // The nested item is not ticked just because its parent is.
      expect(stylesOf(analysis, 'child'), isEmpty);
      expect(stylesOf(analysis, 'open'), isEmpty);
      expect(stylesOf(analysis, '1.'), {MarkdownStyle.listMarker});
      expect(stylesOf(analysis, '2)'), {MarkdownStyle.listMarker});
      expect(analysis.tasks, [
        const MarkdownTask(2, checked: true),
        MarkdownTask(note.indexOf('[ ]'), checked: false),
      ]);
    });

    test('a quote, its markers, and the bar drawn beside it', () {
      final analysis = read('> said\n> > twice');
      expect(stylesOf(analysis, 'said'), {MarkdownStyle.quote});
      expect(stylesAt(analysis, 0), {
        MarkdownStyle.quote,
        MarkdownStyle.syntax,
      });
      expect(
        analysis.blocks.map((block) => (block.kind, block.depth)),
        containsAll([
          (MarkdownBlockKind.quote, 1),
          (MarkdownBlockKind.quote, 2),
        ]),
      );
    });

    test('fenced and indented code, not read as markdown inside', () {
      const note = '```\n**not bold**\n```\n\n    # not a heading';
      final analysis = read(note);
      expect(stylesOf(analysis, 'not bold'), {MarkdownStyle.codeBlock});
      expect(stylesOf(analysis, 'not a heading'), {MarkdownStyle.codeBlock});
      expect(
        analysis.blocks.where((block) => block.kind == MarkdownBlockKind.code),
        hasLength(2),
      );
    });

    test('an unclosed fence runs to the end of the note', () {
      final analysis = read('before\n\n```\nall\n\nof\n\nthis');
      expect(stylesOf(analysis, 'this'), {MarkdownStyle.codeBlock});
    });

    test('links: the words are the link, the rest is syntax', () {
      const note = 'See [the site](https://kapy.example "Title") now';
      final analysis = read(note);
      expect(stylesOf(analysis, 'the site'), {MarkdownStyle.link});
      expect(stylesOf(analysis, 'https://kapy.example'), {
        MarkdownStyle.syntax,
      });
      expect(analysis.links, [
        MarkdownLink(
          note.indexOf('the site'),
          note.indexOf('the site') + 'the site'.length,
          'https://kapy.example',
        ),
      ]);
    });

    test('a reference link goes where its definition says', () {
      const note = 'Read [the docs][docs].\n\n[docs]: https://docs.example';
      final analysis = read(note);
      expect(analysis.links.single.destination, 'https://docs.example');
      expect(stylesOf(analysis, 'https://docs.example'), {
        MarkdownStyle.syntax,
      });
    });

    test('an image\'s alt text is its words', () {
      final analysis = read('![a cat](https://img.example/cat.png)');
      expect(stylesOf(analysis, 'a cat'), {MarkdownStyle.link});
      expect(stylesOf(analysis, '!['), {MarkdownStyle.syntax});
    });

    test('tables: the header row, and quiet pipes', () {
      final analysis = read('| Item | Cost |\n|---|--:|\n| Tea | 4 |');
      expect(stylesOf(analysis, 'Item'), {MarkdownStyle.tableHeader});
      expect(stylesOf(analysis, 'Tea'), isEmpty);
      expect(stylesAt(analysis, 0), {MarkdownStyle.syntax});
      expect(stylesOf(analysis, '|---|--:|'), {MarkdownStyle.syntax});
    });

    test('a table\'s rows, cells and alignment', () {
      const note = '| Item | Cost |\n|:-----|-----:|\n| Tea | **4** usd |';
      final table = read(note).tables.single;
      expect(table.start, 0);
      expect(table.end, note.length);
      expect(
        note.substring(table.delimiterStart, table.delimiterEnd),
        ['|:-----|-----:|'].single,
      );
      expect(table.aligns, [MarkdownCellAlign.start, MarkdownCellAlign.end]);
      expect(table.rows.map((row) => row.header), [true, false]);
      expect(table.rows.last.cells.map((cell) => cell.text), ['Tea', '4 usd']);
    });

    test('a thematic break is a rule', () {
      final analysis = read('above\n\n---\n\nbelow');
      expect(
        analysis.blocks.single,
        const MarkdownBlock(MarkdownBlockKind.rule, 7, 10),
      );
    });

    test('offsets count UTF-16 units, as the editor does', () {
      const note = '😀 **bold** 👍🏽\n- [ ] 🐱 *cat*';
      final analysis = read(note);
      expect(stylesOf(analysis, 'bold'), {MarkdownStyle.strong});
      expect(stylesOf(analysis, 'cat'), {MarkdownStyle.emphasis});
      expect(analysis.tasks.single.box, note.indexOf('[ ]'));
    });
  });

  group('hides', () {
    test('a heading\'s marks for good, but not a hashtag\'s', () {
      expect(visible('# Tit|le'), 'Title');
      expect(visible('# |Title'), 'Title');
      expect(visible('### Three\n|'), 'Three\n');
      expect(visible('#hashtag|'), '#hashtag');
      expect(visible('#|'), '#', reason: 'a heading still being typed');
    });

    test('inline marks until the caret is against them', () {
      expect(visible('Say **bo|ld** now'), 'Say bold now');
      expect(visible('Say **bold|** now'), 'Say **bold** now');
      expect(visible('Say **bold**| now'), 'Say **bold** now');
      expect(visible('Say |**bold** now'), 'Say **bold** now');
      expect(visible('Say **bold** no|w'), 'Say bold now');
      expect(visible('a `co|de` b'), 'a code b');
      expect(visible('a `code|` b'), 'a `code` b');
      expect(visible('~~gone|~~'), '~~gone~~');
    });

    test('and never while typing, or with the note not being edited', () {
      expect(visible('Say **bold**| now', typing: true), 'Say bold now');
      expect(visible('Say **bold**| now', editing: false), 'Say bold now');
    });

    test('every mark of an element wrapped round the one shown', () {
      expect(visible('***both|***'), '***both***');
      expect(visible('**a *b|***'), '**a *b***');
      // Not an element whose marks are elsewhere.
      expect(visible('**a *b|* c**'), 'a *b* c');
    });

    test('a link\'s address, shown with the caret at either end', () {
      const link = '[site](https://a.example "Title")';
      expect(visible('Go [si|te](https://a.example) now'), 'Go site now');
      expect(
        visible('Go [site|](https://a.example) now'),
        'Go [site](https://a.example) now',
      );
      expect(visible('$link|'), link);
      expect(visible('<https://a.ex|ample>'), 'https://a.example');
      expect(visible('<|https://a.example>'), '<https://a.example>');
    });

    test('an escape\'s backslash', () {
      expect(visible('a\\*b c|'), 'a*b c');
      expect(visible('a\\|*b'), 'a\\*b');
    });

    test('quote marks and a task\'s bullet for good', () {
      expect(visible('> quo|te'), 'quote');
      expect(visible('> > dee|p'), 'deep');
      expect(visible('- [ ] ta|sk'), '[ ] task');
      expect(visible('1. on|e'), '1. one', reason: 'a number is shown');
      expect(visible('- it|em'), '- item', reason: 'drawn over, not hidden');
    });

    test('a block\'s own lines, until the caret is in the block', () {
      const code = '```dart\nlet x = 1\n```';
      expect(visible('$code\nafter|'), '\nlet x = 1\n\nafter');
      expect(visible('```dart\nlet| x = 1\n```'), code);
      expect(
        visible('```dart\nlet| x = 1\n```', editing: false),
        ['\nlet x = 1\n'].single,
      );
      expect(visible('above\n\n---\n\nbelow|'), 'above\n\n\n\nbelow');
      expect(visible('above\n\n-|--'), 'above\n\n---');
      expect(visible('Title\n===\n\nnext|'), 'Title\n\n\nnext');
      expect(visible('Title|\n==='), 'Title\n===');
      expect(visible('[ref]: https://a.example\n\nnext|'), '\n\nnext');
    });

    test('a table as a grid, wherever the caret is', () {
      const note = '| a | b |\n|---|---|\n| 1 | 2 |\n\nafter';
      final analysis = read(note);
      MarkdownConcealment at(int offset) => analysis.concealFor(
        TextSelection.collapsed(offset: offset),
        revealBlocks: true,
        revealEdges: true,
      );
      String hiddenIn(MarkdownConcealment concealment) => [
        for (final range in concealment.hidden)
          note.substring(range.start, range.end),
      ].join('·');

      final away = at(note.length);
      final inside = at(3);

      // Hidden, not merely undrawn, so a row takes one line of the note. The
      // newlines between the rows are not hidden, or they would not be rows.
      expect(hiddenIn(away), '| a | b |·|---|---|·| 1 | 2 |');
      expect(
        hiddenIn(inside),
        hiddenIn(away),
        reason: 'the caret being in a table used to show every pipe',
      );
      expect(inside.transparent, isEmpty);
      expect(
        inside.key,
        away.key,
        reason: 'nothing changes, so nothing needs laying out again',
      );
    });

    test('the room a bullet and a box take, for what is drawn there', () {
      const note = '- item\n- [x] done';
      final transparent = read(
        note,
      ).concealFor(null, revealBlocks: false, revealEdges: false).transparent;
      expect(
        [
          for (final range in transparent)
            note.substring(range.start, range.end),
        ],
        ['- ', '[x]'],
      );
    });
  });

  group('line structure', () {
    test('runs from the line\'s start to where its words begin', () {
      const note = '# Title\n> - [ ] task\n1. one\nplain\n  - nested\n> \n#tag';
      expect(
        [
          for (final range in read(note).atomicPrefixes)
            note.substring(range.start, range.end),
        ],
        ['# ', '> - [ ] ', '1. ', '  - ', '> '],
      );
    });

    test('is found from any offset in it, or at its end', () {
      final analysis = read('text\n## Two');
      expect(analysis.atomicPrefixAt(2), isNull);
      expect(analysis.atomicPrefixAt(5), const TextRange(start: 5, end: 8));
      expect(analysis.atomicPrefixAt(8), const TextRange(start: 5, end: 8));
      expect(analysis.atomicPrefixAt(9), isNull);
    });
  });

  group('the words of a cell', () {
    List<String> runs(String note, int row, int column) {
      final analysis = read(note);
      final cell = analysis.tables.single.rows[row].cells[column];
      return [
        for (final run in analysis.runsIn(cell.start, cell.end))
          '${run.text}:${(run.styles.map((style) => style.name).toList()..sort()).join('+')}',
      ];
    }

    test('lose their markers and keep their styles', () {
      const note =
          '| a | b |\n|---|---|\n| **12** usd | `x` and [go](https://a.b) |';
      expect(runs(note, 1, 0), ['12:strong', ' usd:']);
      expect(runs(note, 1, 1), ['x:code', ' and :', 'go:link']);
      expect(runs(note, 0, 0), ['a:']);
    });

    test('are empty when the cell is', () {
      expect(runs('| a | |\n|---|---|', 0, 1), isEmpty);
    });
  });

  group('the calculator', () {
    test('reads list and quote markers as the app\'s own bullet', () {
      final analysis = read('- 5 + 3\n+ 12\n1. 4 * 2\n> - [ ] 7');
      expect(analysis.calculatorText, '• 5 + 3\n• 12\n•  4 * 2\n• • •   7');
    });

    test('reads the words of emphasis, and nothing crossed out', () {
      expect(read('**5 + 3**').calculatorText, '  5 + 3  ');
      expect(read('Total ~~12~~ 14').calculatorText, 'Total        14');
      // A `*` between operands was never emphasis, so it stays.
      expect(read('(2+3)*4*(5)').calculatorText, '(2+3)*4*(5)');
    });

    test('does not read code blocks, line for line', () {
      const note = 'a = 1\n```\nb = 2\n```\nc = 3';
      final text = read(note).calculatorText;
      expect(text.length, note.length);
      expect(text.split('\n'), ['a = 1', '   ', '     ', '   ', 'c = 3']);
    });

    test('is the note itself when there is no markdown in it', () {
      const note = 'Rent 1200 usd\n2 * 3';
      expect(identical(read(note).calculatorText, note), isTrue);
    });

    test('does not read a table, line for line', () {
      // The blank line matters: a table cannot interrupt a paragraph, and
      // without it these would be three lines of prose rather than a grid.
      const note = 'a = 1\n\n| 2+2 | 4 |\n| --- | --- |\n| 3*3 | 9 |\n\nc = 3';
      expect(read(note).tables, hasLength(1), reason: 'it is a table');

      final text = read(note).calculatorText;
      expect(text.length, note.length, reason: 'results stay on their lines');
      expect(identical(text, note), isFalse);
      expect(text.contains('|'), isFalse, reason: 'a row is not a sum');
      expect(text.contains('2+2'), isFalse);
      final lines = text.split('\n');
      expect(lines.first, 'a = 1');
      expect(lines.last, 'c = 3');
    });
  });

  group('links', () {
    test('a markdown link replaces the address found inside it', () {
      const note = 'Go [here](https://a.example) or https://b.example';
      final analysis = read(note);
      final links = analysis.linksWith(findNoteLinks(note));
      expect(links.map((link) => link.text), [
        'https://a.example',
        'https://b.example',
      ]);
      expect(links.first.start, note.indexOf('here'));
      expect(links.first.uri, Uri.parse('https://a.example'));
      expect(links.last.start, note.indexOf('https://b.example'));
    });

    test('an address in code is not a link', () {
      const note = '`https://a.example`';
      expect(read(note).linksWith(findNoteLinks(note)), isEmpty);
    });

    test('only destinations this app would open are clickable', () {
      const note = '[mail](mailto:hi@kapy.example) [js](javascript:alert(1))';
      final links = read(note).linksWith(const []);
      expect(links.single.uri.scheme, 'mailto');
    });

    test('spelling stays off code and addresses, not off a link\'s words', () {
      const note = 'Teh [wrods](https://a.example) `cdoe` www.b.example';
      final analysis = read(note);
      bool literal(String word) {
        final start = note.indexOf(word);
        return analysis.isLiteral(start, start + word.length);
      }

      expect(literal('wrods'), isFalse);
      expect(literal('https://a.example'), isTrue);
      expect(literal('cdoe'), isTrue);
      expect(literal('www.b.example'), isTrue);
      expect(literal('Teh'), isFalse);
    });
  });

  group('reading in pieces', () {
    const vocabulary = [
      '', '', '', '   ', '\t', //
      '# h', '## h two', '#no', '###### six', '# closed #',
      'para *em* **st** `c` ~~s~~ [l](http://x.com) <http://a.b> www.x.com',
      'plain words', '12 + 4', 'rent = 1200 usd', '2*3*4', 'a*b*c',
      '- item', '* item', '+ item', '1. item', '2) item', '- [ ] task',
      '- [x] done', '-', '  - nested', '   continued', '    indented',
      '\tindented', '> quote', '> - q item', '>', '> ```',
      '```', '```dart', '~~~', '````', '  ```', '``` `',
      '---', '***', '===', '* * *', '| a | b |', '|---|---|', '| 1 | 2 |',
      '<div>', '</div>', '<!--', '-->', '<script>', '</script>',
      '[ref]: http://x.com', '[ref]', '[text][ref]',
      'text\\*escaped', 'a  ', 'line\\', '*open', 'close*', '_u_',
      '😀 *x*', '`unclosed', '![img](a.png)', '[](empty)',
    ];

    String randomNote(Random random) => List.generate(
      random.nextInt(30),
      (_) => vocabulary[random.nextInt(vocabulary.length)],
    ).join('\n');

    List<Object> everything(MarkdownAnalysis analysis) {
      List<String> ranges(List<TextRange> list) =>
          [for (final range in list) '${range.start}-${range.end}']..sort();
      return [
        [for (final span in analysis.spans) span.toString()]..sort(),
        [
          for (final link in analysis.links)
            '${link.start}-${link.end}-${link.destination}',
        ]..sort(),
        [for (final task in analysis.tasks) '${task.box}-${task.checked}'],
        [
          for (final block in analysis.blocks)
            '${block.kind}-${block.start}-${block.end}-${block.depth}',
        ]..sort(),
        ranges(analysis.codeBlocks),
        ranges(analysis.unread),
        ranges(analysis.literals),
        ranges(analysis.addresses),
        ranges(analysis.urls),
        ranges(analysis.containerMarkers),
        [for (final conceal in analysis.conceals) conceal.toString()]..sort(),
        [
          for (final ornament in analysis.ornaments)
            '${ornament.kind.name}-${ornament.start}-${ornament.end}-'
                '${ornament.depth}-${ornament.checked}',
        ]..sort(),
        [
          for (final table in analysis.tables)
            '${table.start}-${table.end}-${table.delimiterStart}-'
                '${table.delimiterEnd}-${table.aligns}-'
                '${[
                  for (final row in table.rows) '${row.start}-${row.end}-${row.header}-'
                        '${[for (final cell in row.cells) '${cell.start}-${cell.end}-${cell.text}']}',
                ]}',
        ],
        ranges(analysis.atomicPrefixes),
        analysis.calculatorText,
      ];
    }

    test('gives exactly what reading the whole note gives', () {
      final random = Random(20260911);
      for (var i = 0; i < 1500; i++) {
        final note = randomNote(random);
        expect(
          everything(MarkdownAnalyzer().analyze(note)),
          everything(MarkdownAnalyzer.analyzeWhole(note)),
          reason: note,
        );
      }
    });

    test('and keeps doing so edit after edit', () {
      final random = Random(11);
      const typed = ['*', '`', '\n', ' ', '#', '-', '>', 'x', '[', ']', '~'];
      for (var round = 0; round < 60; round++) {
        final analyzer = MarkdownAnalyzer();
        var note = randomNote(random);
        for (var step = 0; step < 25; step++) {
          final at = note.isEmpty ? 0 : random.nextInt(note.length + 1);
          switch (random.nextInt(3)) {
            case 0:
              note = note.replaceRange(
                at,
                at,
                '${vocabulary[random.nextInt(vocabulary.length)]}\n',
              );
            case 1:
              note = note.replaceRange(
                at,
                min(note.length, at + random.nextInt(8)),
                '',
              );
            default:
              note = note.replaceRange(
                at,
                at,
                typed[random.nextInt(typed.length)],
              );
          }
          expect(
            everything(analyzer.analyze(note)),
            everything(MarkdownAnalyzer.analyzeWhole(note)),
            reason: note,
          );
        }
      }
    });

    test('reads nothing twice that has not changed', () {
      final analyzer = MarkdownAnalyzer();
      const note = '# Title\n\nSome **text**.\n\n- a\n- b';
      final first = analyzer.analyze(note);
      expect(identical(analyzer.analyze(note), first), isTrue);
    });

    test('never throws, whatever it is given', () {
      final random = Random(3);
      const alphabet = '*_`~#>-+[]()!<>|:\\ \n\t\r1a.=x\u{FFFC}😀';
      for (var i = 0; i < 400; i++) {
        final note = String.fromCharCodes(
          List.generate(
            random.nextInt(80),
            (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
          ),
        );
        final analysis = MarkdownAnalyzer().analyze(note);
        for (final span in analysis.spans) {
          expect(span.start, inInclusiveRange(0, note.length));
          expect(span.end, inInclusiveRange(span.start, note.length));
        }
        expect(analysis.calculatorText.length, note.length);
      }
    });
  });
}
