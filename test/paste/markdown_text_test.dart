import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/paste/markdown_text.dart';
import 'package:kapy_notes/paste/paste_writers.dart';

void main() {
  group('looksLikeMarkdown', () {
    test('one unmistakable sign is enough', () {
      expect(looksLikeMarkdown('```\ncode\n```'), isTrue);
      expect(looksLikeMarkdown('| a | b |\n|---|---|\n| 1 | 2 |'), isTrue);
      expect(looksLikeMarkdown('![chart](https://e.com/c.png)'), isTrue);
    });

    test('weaker signs have to add up', () {
      expect(looksLikeMarkdown('# Plan\n\n- one\n- two'), isTrue);
      expect(
        looksLikeMarkdown('Read **this** and [that](https://e.com)'),
        isTrue,
      );
      expect(looksLikeMarkdown('- 5'), isFalse);
      expect(looksLikeMarkdown('- a\n- b'), isFalse);
      expect(looksLikeMarkdown('a *word* here'), isFalse);
      expect(looksLikeMarkdown('costs \$5 and \$10'), isFalse);
    });
  });

  group('normalizeMarkdownPaste', () {
    test("ChatGPT's TeX delimiters become dollars, outside code", () {
      expect(
        normalizeMarkdownPaste(
          'Area \\(\\pi r^2\\) and\n\n\\[E=mc^2\\]\n\n'
          '```\nprint("\\(x\\)")\n```',
        ).text,
        'Area \$\\pi r^2\$ and\n\n\$\$E=mc^2\$\$\n\n'
        '```\nprint("\\(x\\)")\n```',
      );
    });

    test('a formula over several lines keeps its lines', () {
      expect(
        normalizeMarkdownPaste(
          r'\['
          '\n'
          r'a = b \\'
          '\nc = d\n'
          r'\]',
        ).text,
        r'$$'
        '\n'
        r'a = b \\'
        '\nc = d\n'
        r'$$',
      );
    });

    test("linked pictures become the note's own, each on its own line", () {
      final output = normalizeMarkdownPaste(
        'See ![chart](https://e.com/c.png) here',
      );
      expect(output.text, 'See\n\uFFFC\nhere');
      expect(output.images.single.image.src, 'https://e.com/c.png');
      expect(output.images.single.image.alt, 'chart');
    });

    test('everything else is kept as written', () {
      const source =
          '* a\n* b\n\n1) one\n\n> quote\n\n| a | b |\n|---|---|\n| 1 | 2 |';
      expect(normalizeMarkdownPaste(source).text, source);
    });
  });

  group('readMarkdownPaste, for a note without markdown', () {
    test("math stays TeX and the markup becomes the note's own", () {
      final output = writePlainPaste(
        readMarkdownPaste(
          'Area \\(\\pi r^2\\) and\n\\[E=mc^2\\]\n'
          'cost \$5 and \$10, **bold**.\n\n- one\n- two',
        ),
      );
      expect(
        output.text,
        'Area \\pi r^2 and\n\nE=mc^2\n\ncost \$5 and \$10, bold.\n\n• one\n• two',
      );
      expect(
        [
          for (final range in output.formats)
            output.text.substring(range.start, range.end),
        ],
        ['bold'],
      );
    });

    test('a line ends where it was ended', () {
      expect(writePlainPaste(readMarkdownPaste('one\ntwo')).text, 'one\ntwo');
    });
  });

  test('cleanPastedText drops what a note cannot hold', () {
    expect(cleanPastedText('a\r\nb\rc\uFFFCd'), 'a\nb\ncd');
  });
}
