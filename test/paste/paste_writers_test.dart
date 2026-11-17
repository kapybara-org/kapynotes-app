import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/paste/paste_tree.dart';
import 'package:kapy_notes/paste/paste_writers.dart';

String markdown(List<PasteBlock> blocks) => writeMarkdownPaste(blocks).text;

PasteParagraph words(
  String text, {
  Set<PasteStyle> styles = const {},
  String? href,
}) => PasteParagraph([PasteText(text, styles: styles, href: href)]);

PasteListItem item(
  String text, {
  bool? checked,
  List<PasteBlock> more = const [],
}) => PasteListItem([words(text), ...more], checked: checked);

/// [output]'s formats, each as the words it covers.
List<String> formatted(PasteOutput output) => [
  for (final range in output.formats)
    '${range.format.name}: ${output.text.substring(range.start, range.end)}',
];

void main() {
  group('markdown', () {
    test('words that would read as markdown are escaped, and only those', () {
      expect(
        markdown([
          words('2024. A year'),
          words('* not a bullet'),
          words('# not a heading'),
          words('a *star* and snake_case and 1*2 and [x]'),
        ]),
        '2024\\. A year\n\n'
        '\\* not a bullet\n\n'
        '\\# not a heading\n\n'
        'a \\*star\\* and snake_case and 1*2 and \\[x]',
      );
    });

    test('dollars stay money unless they would read as math', () {
      expect(markdown([words('costs \$5 and \$10')]), 'costs \$5 and \$10');
      expect(markdown([words('the \$x\$ variable')]), 'the \\\$x\\\$ variable');
    });

    test('math is written between dollars', () {
      expect(
        markdown([
          const PasteParagraph([PasteText('area '), PasteMath(r'\pi r^2')]),
          const PasteMathBlock('E=mc^2'),
        ]),
        'area \$\\pi r^2\$\n\n\$\$E=mc^2\$\$',
      );
    });

    test('a link is written so that it reads back the same', () {
      expect(
        markdown([
          const PasteParagraph([
            PasteText('a link', href: 'https://e.com/a_(b)'),
            PasteText(' and '),
            PasteText('https://e.com', href: 'https://e.com'),
          ]),
        ]),
        '[a link](<https://e.com/a_(b)>) and <https://e.com>',
      );
    });

    test('nested and numbered lists indent under their item', () {
      expect(
        markdown([
          PasteList(
            ordered: true,
            start: 9,
            items: [
              item(
                'nine',
                more: [
                  PasteList(ordered: false, items: [item('sub')]),
                ],
              ),
              item('ten'),
            ],
          ),
          PasteList(
            ordered: false,
            items: [item('done', checked: true), item('open', checked: false)],
          ),
        ]),
        '9. nine\n'
        '   - sub\n'
        '10. ten\n'
        '- [x] done\n'
        '- [ ] open',
      );
    });

    test('lists one after another stay tight', () {
      expect(
        markdown([
          PasteList(ordered: false, items: [item('one'), item('two')]),
          PasteList(ordered: true, items: [item('three')]),
          PasteList(ordered: false, items: [item('four', checked: false)]),
          words('after'),
        ]),
        '- one\n- two\n1. three\n- [ ] four\n\nafter',
      );
    });

    test('an empty line the source had between two lists stays', () {
      expect(
        markdown([
          PasteList(ordered: false, items: [item('one')]),
          PasteList(ordered: true, items: [item('two')], afterEmptyLine: true),
        ]),
        '- one\n\n1. two',
      );
    });

    test('a picture stands on a line of its own', () {
      const image = PasteImage(src: 'https://e.com/p.png', alt: 'p');
      final output = writeMarkdownPaste([
        const PasteParagraph([
          PasteText('see'),
          PasteImageInline(image),
          PasteText('here'),
        ]),
      ]);
      expect(output.text, 'see\n\uFFFC\nhere');
      expect(output.images.single.offset, output.text.indexOf('\uFFFC'));
      expect(output.images.single.image.src, image.src);
      expect(output.formats, isEmpty);
    });
  });

  group('plain', () {
    test("lists use the editor's bullets, numbers and to-do boxes", () {
      final output = writePlainPaste([
        const PasteHeading(1, [PasteText('Title')]),
        PasteList(
          ordered: false,
          items: [
            item(
              'one',
              more: [
                const PasteList(
                  ordered: false,
                  items: [
                    PasteListItem([
                      PasteParagraph([
                        PasteText('nested '),
                        PasteText('link', href: 'https://e.com'),
                      ]),
                    ]),
                  ],
                ),
              ],
            ),
          ],
        ),
        PasteList(
          ordered: true,
          start: 3,
          items: [
            PasteListItem([
              words('three', styles: {PasteStyle.bold}),
            ]),
          ],
        ),
        PasteList(ordered: false, items: [item('done', checked: true)]),
      ]);
      expect(
        output.text,
        'Title\n\n'
        '• one\n'
        '  ◦ nested link (https://e.com)\n\n'
        '3. three\n\n'
        '☑ done',
      );
      expect(formatted(output), ['heading: Title', 'bold: three']);
    });

    test("headings and styles become the note's own formats", () {
      final output = writePlainPaste([
        const PasteCode('print(1)\nprint(2)', language: 'py'),
        const PasteQuote([
          PasteParagraph([
            PasteText('quoted '),
            PasteText('bold', styles: {PasteStyle.bold}),
          ]),
        ]),
        const PasteHeading(3, [PasteText('Small')]),
        const PasteParagraph([
          PasteText('it', styles: {PasteStyle.italic}),
          PasteText(' and '),
          PasteCodeSpan('c'),
        ]),
      ]);
      expect(
        output.text,
        'print(1)\nprint(2)\n\nquoted bold\n\nSmall\n\nit and c',
      );
      expect(formatted(output), [
        'bold: bold',
        'subtitle: Small',
        'italic: it',
      ]);
    });

    test('math stays TeX and tables stay GFM', () {
      final output = writePlainPaste([
        const PasteParagraph([PasteText('so '), PasteMath('x^2')]),
        const PasteMathBlock('E=mc^2'),
        const PasteTable(
          [
            [
              [PasteText('Name')],
              [PasteText('Qty')],
            ],
            [
              [PasteText('Tea')],
              [PasteText('4')],
            ],
          ],
          [PasteAlign.none, PasteAlign.none],
        ),
      ]);
      expect(
        output.text,
        'so x^2\n\nE=mc^2\n\n| Name | Qty |\n| --- | --- |\n| Tea | 4 |',
      );
    });

    test('without pictures, every format moves with its words', () {
      final output = PasteOutput(
        text: 'a\n\uFFFC\nbold',
        formats: const [
          NoteFormatRange(start: 4, end: 8, format: NoteFormat.bold),
        ],
        images: const [PastedImage(2, PasteImage(src: 'https://e.com/p.png'))],
      ).withoutPictures();
      expect(output.text, 'a\n\nbold');
      expect(formatted(output), ['bold: bold']);
      expect(output.images, isEmpty);
    });
  });
}
