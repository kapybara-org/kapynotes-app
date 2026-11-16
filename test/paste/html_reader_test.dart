import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/paste/html_reader.dart';
import 'package:kapy_notes/paste/paste_tree.dart';
import 'package:kapy_notes/paste/paste_writers.dart';

/// [html] as it goes into a markdown note.
String read(String html, {Uri? baseUrl, PasteResources resources = const {}}) =>
    writeMarkdownPaste(
      HtmlPasteReader(baseUrl: baseUrl, resources: resources).read(html),
    ).text;

/// The pictures [html] carries, in order.
List<PasteImage> pictures(String html, {PasteResources resources = const {}}) =>
    [
      for (final placed in writeMarkdownPaste(
        HtmlPasteReader(resources: resources).read(html),
      ).images)
        placed.image,
    ];

void main() {
  group('structure', () {
    test('headings, lists, quotes and rules keep their shape', () {
      expect(
        read(
          '<blockquote><p>Said <i>this</i></p><ol start="3"><li>three</li>'
          '<li>four<ul><li>sub</li></ul></li></ol></blockquote><hr>'
          '<h2>Next</h2>',
        ),
        '> Said *this*\n'
        '>\n'
        '> 3. three\n'
        '> 4. four\n'
        '>    - sub\n'
        '\n'
        '---\n'
        '\n'
        '## Next',
      );
    });

    test('underline, strike, superscript and subscript survive', () {
      expect(
        read(
          '<p><u>under</u> x<sup>2</sup> H<sub>2</sub>O 1<sup>st</sup> '
          '<s>gone</s></p>',
        ),
        '<u>under</u> x² H₂O 1<sup>st</sup> ~~gone~~',
      );
    });

    test('links resolve against the page they were copied from', () {
      expect(
        read(
          '<p><a href="/docs/start">Start</a> or <a href="mailto:a@b.co">mail</a></p>',
          baseUrl: Uri.parse('https://example.com/guide/intro'),
        ),
        '[Start](https://example.com/docs/start) or [mail](mailto:a@b.co)',
      );
    });

    test('a table keeps its header and alignment, not the header bold', () {
      expect(
        read(
          '<table><thead><tr>'
          '<th style="font-weight:700;text-align:left">Name</th>'
          '<th style="text-align:right">Qty</th></tr></thead><tbody><tr>'
          '<td><b>Tea</b></td><td style="text-align:right">4</td>'
          '</tr></tbody></table>',
        ),
        '| Name | Qty |\n'
        '| --- | --: |\n'
        '| **Tea** | 4 |',
      );
    });

    test('pipes and line breaks stay inside their cell', () {
      expect(
        read(
          '<table><tr><th>a|b</th><th>c</th></tr>'
          '<tr><td>one<br>two</td><td><code>x|y</code></td></tr></table>',
        ),
        '| a\\|b | c |\n'
        '| --- | --- |\n'
        '| one<br>two | `x\\|y` |',
      );
    });
  });

  group('code', () {
    test('a code block keeps its language and outlasts fences inside it', () {
      expect(
        read(
          '<pre><code class="language-md">text\n```\ninner\n```'
          '</code></pre>',
        ),
        '````md\ntext\n```\ninner\n```\n````',
      );
    });

    test("a word processor's monospace paragraphs become a code block", () {
      expect(
        read(
          '<b style="font-weight:normal" id="docs-internal-guid-1">'
          '<p><span>Run this:</span></p><p>'
          '<span style="font-family:\'Courier New\',monospace">if x:</span>'
          '<br><span style="font-family:\'Courier New\',monospace">'
          '    go()</span></p></b>',
        ),
        'Run this:\n\n```\nif x:\n    go()\n```',
      );
    });

    test('what a code editor copied reads as code, and nothing else', () {
      final reader = HtmlPasteReader();
      expect(
        reader.readsAsCode(
          '<div style="font-family:Menlo, monospace;color:#333">'
          '<span style="color:#a00">final</span> x = 1;<br>print(x);</div>',
        ),
        isTrue,
      );
      expect(reader.readsAsCode('<p>Some <b>words</b></p>'), isFalse);
      expect(
        reader.readsAsCode(
          '<div style="font-family:monospace"><h1>Title</h1></div>',
        ),
        isFalse,
      );
    });
  });

  group('math', () {
    test("KaTeX's own TeX is kept rather than what it drew", () {
      expect(
        read(
          '<p>Let <span class="katex"><span class="katex-mathml"><math>'
          '<semantics><mrow><msub><mi>α</mi><mn>1</mn></msub></mrow>'
          '<annotation encoding="application/x-tex">\\alpha_1</annotation>'
          '</semantics></math></span><span class="katex-html" '
          'aria-hidden="true"><span class="base">α1</span></span></span> '
          'be small.</p><span class="katex-display"><span class="katex">'
          '<span class="katex-mathml"><math display="block"><semantics>'
          '<mrow><mi>E</mi></mrow>'
          '<annotation encoding="application/x-tex">E=mc^2</annotation>'
          '</semantics></math></span><span class="katex-html">E</span>'
          '</span></span>',
        ),
        'Let \$\\alpha_1\$ be small.\n\n\$\$E=mc^2\$\$',
      );
    });

    test('MathML without its TeX is written as TeX', () {
      expect(
        read('<p>so <math><msup><mi>x</mi><mn>2</mn></msup></math> grows</p>'),
        'so \$x^{2}\$ grows',
      );
    });

    test("Wikipedia's formulas come from the TeX Parsoid keeps", () {
      expect(
        read(
          '<p>form <span class="mwe-math-mathml-a11y"><math display="inline" '
          'data-mw=\'{"name":"math","body":{"extsrc":'
          '"\\\\textstyle ax^2 + bx + c = 0"}}\'><mi>a</mi></math></span>'
          '<img class="mwe-math-fallback-image-inline" '
          'src="https://wikimedia.org/x.svg" alt="ax^2"> here</p>',
        ),
        'form \$ax^2 + bx + c = 0\$ here',
      );
    });

    test("Gemini's formulas come from their data-math", () {
      expect(
        read(
          '<p>so <span class="math-inline" data-math="-5">'
          '<span class="katex">−5</span></span> and</p>'
          '<div class="math-block" data-math="E=mc^2">'
          '<span class="katex-display">E</span></div>',
        ),
        'so \$-5\$ and\n\n\$\$E=mc^2\$\$',
      );
    });
  });

  group('what sources add around the words', () {
    test("ChatGPT's thinking label is dropped", () {
      expect(
        read(
          '<div><span data-cot-label="">Thought for 12s</span></div>'
          '<p>Answer.</p>',
        ),
        'Answer.',
      );
    });

    test("Wikipedia's citation marks go, other references stay", () {
      expect(
        read(
          '<p>Fact<sup class="reference"><a href="#cite">[1]</a></sup> and '
          '<span class="reference">'
          '<a href="https://github.com/a/b/issues/1">issue #1</a></span>.</p>',
        ),
        'Fact and [issue #1](https://github.com/a/b/issues/1).',
      );
    });

    test("Perplexity's citation chips become links to their source", () {
      expect(
        read(
          '<p>Ends here.<span class="citation inline" data-pplx-citation="" '
          'data-pplx-citation-url="https://example.com/a">'
          '<span>example</span><span>+2</span></span></p>',
        ),
        'Ends here. [example](https://example.com/a)',
      );
    });

    test('emoji drawn as pictures become emoji again', () {
      expect(
        read(
          '<p>Done <img class="c-emoji__img" alt=":tada:" '
          'src="https://a.slack-edge.com/x/apple-medium/1f389@2x.png"> '
          '<img alt=":kapy-party:" data-stringify-emoji=":kapy-party:" '
          'src="https://emoji.slack-edge.com/T0/kapy-party/5c.png"></p>',
        ),
        'Done 🎉 :kapy-party:',
      );
    });

    test('badges and other vector pictures become their words', () {
      const html =
          '<p><a href="https://npmjs.com/got"><img alt="Downloads" '
          'src="https://img.shields.io/npm/dm/got.svg"></a> '
          '<img alt="Logo" src="https://example.com/logo.svg"> '
          '<img alt="Photo" src="https://example.com/p.png" width="360"></p>';
      expect(read(html), '[Downloads](https://npmjs.com/got) Logo\n\uFFFC');
      final photo = pictures(html).single;
      expect(photo.src, 'https://example.com/p.png');
      expect(photo.alt, 'Photo');
      expect(photo.widthFactor, 0.5);
    });

    test("GitHub's task lists become to-dos", () {
      expect(
        read(
          '<ul class="contains-task-list"><li class="task-list-item">'
          '<input type="checkbox" checked> first</li>'
          '<li class="task-list-item"><input type="checkbox"> second</li></ul>',
        ),
        '- [x] first\n- [ ] second',
      );
    });

    test("Apple's rich text: headings by size, ballot boxes as to-dos", () {
      expect(
        read(
          '<html><head><meta name="Generator" content="Cocoa HTML Writer">'
          '<style>p.p1 {margin: 0.0px; font: 24.0px Helvetica} '
          'p.p2 {margin: 0.0px; font: 13.0px Helvetica}</style></head><body>'
          '<p class="p1"><b>Title</b></p>'
          '<p class="p2">Body words here and more of them.</p>'
          '<p class="p2">☐ Buy milk</p><p class="p2">☑ Send the invoice</p>'
          '</body></html>',
        ),
        '# Title\n\n'
        'Body words here and more of them.\n\n'
        '- [ ] Buy milk\n'
        '- [x] Send the invoice',
      );
    });

    test("Word's numbered and bulleted lists stay two lists", () {
      expect(
        read(
          '<html><head><meta name="Generator" content="Microsoft Word 15">'
          '</head><body>'
          '<p class="MsoListParagraphCxSpFirst" '
          'style="text-indent:-.25in;mso-list:l0 level1 lfo1">'
          '<![if !supportLists]><span style="mso-list:Ignore">1.'
          '<span>&nbsp;&nbsp;</span></span><![endif]>One</p>'
          '<p class="MsoListParagraphCxSpLast" '
          'style="text-indent:-.25in;mso-list:l0 level1 lfo1">'
          '<![if !supportLists]><span style="mso-list:Ignore">2.'
          '<span>&nbsp;&nbsp;</span></span><![endif]>Two</p>'
          '<p class="MsoListParagraphCxSpFirst" '
          'style="text-indent:-.25in;mso-list:l1 level1 lfo2">'
          '<![if !supportLists]><span style="font-family:Symbol;'
          'mso-list:Ignore">·<span>&nbsp;</span></span><![endif]>Bullet</p>'
          '</body></html>',
        ),
        '1. One\n2. Two\n\n- Bullet',
      );
    });
  });

  group('pictures', () {
    test('a picture in the markup keeps its bytes and its place', () {
      const html =
          '<p>Before</p><p><img src="data:image/png;base64,iVBORw0KGgo=" '
          'alt="dot"></p><p>After</p>';
      expect(read(html), 'Before\n\n\uFFFC\n\nAfter');
      final picture = pictures(html).single;
      expect(picture.mime, 'image/png');
      expect(picture.bytes, base64.decode('iVBORw0KGgo='));
    });

    test('a picture the clipboard carried beside the markup is used', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final picture = pictures(
        '<p><img src="file:///tmp/clip/image1.png" alt="chart"></p>',
        resources: {
          'file:///tmp/clip/image1.png': (bytes: bytes, mime: 'image/png'),
        },
      ).single;
      expect(picture.bytes, bytes);
      expect(picture.alt, 'chart');
    });

    test('a lazy-loaded picture is the real one, not its stand-in', () {
      final picture = pictures(
        '<p><img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" '
        'data-src="https://example.com/real.jpg" alt="real"></p>',
      ).single;
      expect(picture.src, 'https://example.com/real.jpg');
    });

    test("an answer's avatar is not a picture, a large photo is", () {
      expect(
        pictures(
          '<p>Answered by <img src="https://www.gravatar.com/avatar/f7b0?s=64" '
          'alt="Sam\'s user avatar" width="32" height="32"> Sam</p>'
          '<p><img src="https://example.com/avatar-party.jpg" '
          'alt="The avatar party" width="480" height="320"></p>',
        ).map((picture) => picture.src),
        ['https://example.com/avatar-party.jpg'],
      );
    });

    test('spacers and tracking pixels are not pictures', () {
      expect(
        read(
          '<p>Words<img src="https://example.com/t.gif" width="1" height="1">'
          '<img src="https://example.com/icon.png" width="16">'
          '<img src="https://example.com/chip.png" '
          'style="width: 1.25rem; height: 1.25rem"></p>',
        ),
        'Words',
      );
    });
  });
}
