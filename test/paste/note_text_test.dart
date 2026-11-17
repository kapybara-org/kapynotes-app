import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/paste/html_reader.dart';
import 'package:kapy_notes/paste/note_text.dart';
import 'package:kapy_notes/paste/paste_writers.dart';

const anchor = '\uFFFC';

/// What an editor that reads HTML makes of a markdown note's copy, written
/// back out as markdown.
String throughHtml(String markdown, {Map<int, String> embeds = const {}}) =>
    writeMarkdownPaste(
      HtmlPasteReader().read(
        noteHtml(markdown, markdown: true, embeds: embeds),
      ),
    ).text;

/// [formats] as the words each one covers.
List<String> styled(String text, List<NoteFormatRange> formats) => [
  for (final range in formats)
    '${range.format.name}:${text.substring(range.start, range.end)}',
];

void main() {
  group('a markdown note', () {
    test('copies out as HTML that reads back as the same markdown', () {
      const notes = [
        '# Title\n\n## Part',
        'Line **bold** *italic* ~~gone~~ <u>under</u> x<sup>ab</sup>\nnext line',
        '[the docs](https://example.com/docs) and <https://a.example>',
        '- a\n- b\n  - nested\n\n3. three\n4. four',
        '- a\n- b\n  - nested\n3. three\n4. four',
        '- [ ] open\n- [x] done',
        '> quoted\n> lines',
        '```dart\nvoid main() {}\n```',
        '| L | C | R |\n| --- | :-: | --: |\n| 1<br>2 | `x` | **b** |',
        r'Money $5 and $10, math $x^2$ here'
            '\n\n'
            r'$$\int_0^1 x\,dx$$',
      ];
      for (final note in notes) {
        expect(throughHtml(note), note, reason: note);
      }
    });

    test('copies a picture out where it was', () {
      const note = 'pic:\n$anchor\nend';
      const image = '<img src="data:image/png;base64,iVBORw0KGgo=">';
      final html = noteHtml(note, markdown: true, embeds: {5: image});
      expect(html, '<p>pic:<br>$image<br>end</p>');
      final back = writeMarkdownPaste(HtmlPasteReader().read(html));
      expect(back.text, note);
      expect(back.images, hasLength(1));
    });

    test('leaves out an attachment it is given no HTML for', () {
      expect(noteHtml('a $anchor b', markdown: true), '<p>a  b</p>');
    });

    test('reads a star between operands as times, as the editor does', () {
      expect(
        noteHtml('2*3*4 and *it*', markdown: true),
        '<p>2*3*4 and <i>it</i></p>',
      );
      expect(
        noteHtml(
          '[x](https://a.example/2*3) <https://b.example/4*5>',
          markdown: true,
        ),
        '<p><a href="https://a.example/2*3">x</a> '
        '<a href="https://b.example/4*5">https://b.example/4*5</a></p>',
      );
    });

    test('reads math only between dollars, as the editor does', () {
      final html = noteHtml(r'\(x\) costs $y$', markdown: true);
      expect(html, contains('data-latex="y"'));
      expect(html, isNot(contains('data-latex="x"')));
    });

    test('converts to a note without markdown, its styles beside the text', () {
      final converted = convertNote(
        '# Title\n\nsome **bold** and *it*\n\n- a\n  - b\n- [x] c',
        toMarkdown: false,
      );
      expect(converted.text, 'Title\n\nsome bold and it\n\n• a\n  ◦ b\n☑ c');
      expect(styled(converted.text, converted.formats), [
        'heading:Title',
        'bold:bold',
        'italic:it',
      ]);
    });
  });

  group('a note without markdown', () {
    const note =
        'Shopping\n• milk\n  ◦ skim\n☐ call mom\n☑ done\n1. first\n'
        '2. second\n\nrent 1200 *not em*\nfood 300';
    final formats = [
      const NoteFormatRange(start: 0, end: 8, format: NoteFormat.heading),
      NoteFormatRange(
        start: note.indexOf('rent'),
        end: note.indexOf('rent') + 4,
        format: NoteFormat.bold,
      ),
    ];

    test('copies out as HTML with its styles, lists and to-dos', () {
      expect(
        noteHtml(note, markdown: false, formats: formats),
        '<h1>Shopping</h1><ul><li>milk<ul><li>skim</li></ul></li>'
        '<li style="list-style-type:none">☐ call mom</li>'
        '<li style="list-style-type:none">☑ done</li></ul>'
        '<ol><li>first</li><li>second</li></ol>'
        '<p><b>rent</b> 1200 *not em*<br>food 300</p>',
      );
    });

    test('copies a subtitle out as a second-level heading', () {
      expect(
        noteHtml(
          'Trip\nDay one\nwalked',
          markdown: false,
          formats: const [
            NoteFormatRange(start: 0, end: 4, format: NoteFormat.heading),
            NoteFormatRange(start: 5, end: 12, format: NoteFormat.subtitle),
            NoteFormatRange(start: 13, end: 19, format: NoteFormat.italic),
          ],
        ),
        '<h1>Trip</h1><h2>Day one</h2><p><i>walked</i></p>',
      );
    });

    test('copies a table out as the grid it draws', () {
      expect(
        noteHtml('| a | b |\n| --- | --- |\n| 1 | 2 |', markdown: false),
        '<table border="1" cellpadding="4" style="border-collapse:collapse">'
        '<thead><tr><th>a</th><th>b</th></tr></thead>'
        '<tbody><tr><td>1</td><td>2</td></tr></tbody></table>',
      );
    });

    test('converts to markdown with its styles written out', () {
      final converted = convertNote(note, toMarkdown: true, formats: formats);
      expect(
        converted.text,
        '# Shopping\n\n- milk\n  - skim\n- [ ] call mom\n- [x] done\n1. first\n'
        '2. second\n\n**rent** 1200 \\*not em\\*\nfood 300',
      );
      expect(converted.formats, isEmpty);
    });

    test('keeps every attachment in its place through a conversion', () {
      const plain = 'Trip\n$anchor\n• bring $anchor';
      final converted = convertNote(plain, toMarkdown: true);
      expect(converted.text, 'Trip\n$anchor\n\n- bring $anchor');
      expect(converted.anchors.keys, [5, 15]);
      for (final at in converted.anchors.values) {
        expect(converted.text[at], anchor);
      }
    });
  });
}
