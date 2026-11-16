import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/paste/html_writer.dart';
import 'package:kapy_notes/paste/paste_tree.dart';

void main() {
  test('writes headings and paragraphs, with a line break as <br>', () {
    expect(
      writeHtml([
        const PasteHeading(2, [PasteText('Plan')]),
        const PasteParagraph([
          PasteText('one'),
          PasteBreak(),
          PasteText('two'),
        ]),
      ]),
      '<h2>Plan</h2><p>one<br>two</p>',
    );
  });

  test('escapes the words and keeps a run of spaces as wide as it was', () {
    expect(
      writeHtml([
        const PasteParagraph([PasteText('a <b> & c   d')]),
      ]),
      '<p>a &lt;b&gt; &amp; c &nbsp;&nbsp;d</p>',
    );
  });

  test('nests the styles of a run inside one another', () {
    expect(
      writeHtml([
        const PasteParagraph([
          PasteText(
            'all',
            styles: {
              PasteStyle.bold,
              PasteStyle.italic,
              PasteStyle.strike,
              PasteStyle.underline,
            },
          ),
          PasteText(' x'),
          PasteText('2', styles: {PasteStyle.superscript}),
          PasteText(' H'),
          PasteText('2', styles: {PasteStyle.subscript}),
          PasteText(' '),
          PasteCodeSpan('a<b', styles: {PasteStyle.bold}),
        ]),
      ]),
      '<p><b><i><s><u>all</u></s></i></b> x<sup>2</sup> H<sub>2</sub> '
      '<b><code>a&lt;b</code></b></p>',
    );
  });

  test('keeps the words of one link in one anchor', () {
    const href = 'https://a.example/?q=1&r=2';
    expect(
      writeHtml([
        const PasteParagraph([
          PasteText('see '),
          PasteText('the ', href: href),
          PasteText('docs', styles: {PasteStyle.bold}, href: href),
          PasteText(' now'),
        ]),
      ]),
      '<p>see <a href="https://a.example/?q=1&amp;r=2">the <b>docs</b></a> '
      'now</p>',
    );
  });

  test('ends a link at a line break', () {
    expect(
      writeHtml([
        const PasteParagraph([
          PasteText('https://a.example', href: 'https://a.example'),
          PasteBreak(),
          PasteText('next'),
        ]),
      ]),
      '<p><a href="https://a.example">https://a.example</a><br>next</p>',
    );
  });

  test('writes lists with their start, their nesting and their to-dos', () {
    expect(
      writeHtml([
        const PasteList(
          ordered: true,
          start: 3,
          items: [
            PasteListItem([
              PasteParagraph([PasteText('three')]),
            ]),
            PasteListItem([
              PasteParagraph([PasteText('four')]),
              PasteList(
                ordered: false,
                items: [
                  PasteListItem([
                    PasteParagraph([PasteText('deeper')]),
                  ]),
                ],
              ),
            ]),
          ],
        ),
        const PasteList(
          ordered: false,
          items: [
            PasteListItem([
              PasteParagraph([PasteText('open')]),
            ], checked: false),
            PasteListItem([
              PasteParagraph([PasteText('shut')]),
            ], checked: true),
          ],
        ),
      ]),
      '<ol start="3"><li>three</li><li>four<ul><li>deeper</li></ul></li></ol>'
      '<ul><li style="list-style-type:none">☐ open</li>'
      '<li style="list-style-type:none">☑ shut</li></ul>',
    );
  });

  test('writes code with its language, quotes, and rules', () {
    expect(
      writeHtml([
        const PasteCode('if (a < b) {\n  go();\n}', language: 'dart'),
        const PasteCode('plain'),
        const PasteQuote([
          PasteParagraph([PasteText('said')]),
        ]),
        const PasteRule(),
      ]),
      '<pre><code class="language-dart">if (a &lt; b) {\n  go();\n}</code></pre>'
      '<pre><code>plain</code></pre><blockquote><p>said</p></blockquote><hr>',
    );
  });

  test('writes a table with its header row and its alignment', () {
    expect(
      writeHtml([
        const PasteTable(
          [
            [
              [PasteText('L')],
              [PasteText('C')],
              [PasteText('R')],
            ],
            [
              [PasteText('1'), PasteBreak(), PasteText('2')],
              [PasteCodeSpan('x')],
              [
                PasteText('b', styles: {PasteStyle.bold}),
              ],
            ],
          ],
          [PasteAlign.none, PasteAlign.center, PasteAlign.right],
        ),
      ]),
      '<table border="1" cellpadding="4" style="border-collapse:collapse">'
      '<thead><tr><th>L</th><th style="text-align:center">C</th>'
      '<th style="text-align:right">R</th></tr></thead>'
      '<tbody><tr><td>1<br>2</td><td style="text-align:center"><code>x</code>'
      '</td><td style="text-align:right"><b>b</b></td></tr></tbody></table>',
    );
  });

  test('writes math as its TeX between dollars, marked with the TeX', () {
    expect(
      writeHtml([
        const PasteParagraph([
          PasteText('so '),
          PasteMath('a<b'),
          PasteText(' holds'),
        ]),
        const PasteMathBlock(r' \frac{1}{2} '),
      ]),
      '<p>so <span class="math math-inline" data-latex="a&lt;b">\$a&lt;b\$</span> '
      'holds</p><div class="math math-display" data-latex="\\frac{1}{2}">'
      '\$\$\\frac{1}{2}\$\$</div>',
    );
  });

  test('writes pictures as data URIs at the size they were shown', () {
    expect(
      writeHtml([
        PasteParagraph([
          PasteImageInline(
            PasteImage(
              bytes: Uint8List.fromList([1, 2, 3]),
              mime: 'image/jpeg',
              alt: 'a "cat"',
              width: 360,
              height: 270,
            ),
          ),
          const PasteImageInline(PasteImage(src: 'https://a.example/p.png')),
          const PasteImageInline(PasteImage(alt: 'lost')),
        ]),
      ]),
      '<p><img src="data:image/jpeg;base64,AQID" alt="a &quot;cat&quot;" '
      'width="360" height="270"><img src="https://a.example/p.png" alt="">'
      'lost</p>',
    );
  });

  test('writes each embedded character as the HTML it stands for', () {
    expect(
      writeHtml(
        [
          const PasteParagraph([PasteText('a\uE100b')]),
          const PasteMathBlock('x\uE100'),
        ],
        embeds: {'\uE100': '<img src="x">'},
      ),
      '<p>a<img src="x">b</p>'
      '<div class="math math-display" data-latex="x">\$\$x\$\$</div>',
    );
  });
}
