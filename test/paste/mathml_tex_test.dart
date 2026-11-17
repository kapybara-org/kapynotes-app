import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:kapy_notes/paste/mathml_tex.dart';

String tex(String mathml) => mathmlToTex(
  html_parser.parse('<math>$mathml</math>').querySelector('math')!,
);

void main() {
  test('scripts, fractions and roots', () {
    expect(
      tex('<msup><mi>p</mi><mi>α</mi></msup><mo>∥</mo><mi>n</mi>'),
      r'p^{\alpha}\parallel n',
    );
    expect(
      tex('<msubsup><mi>x</mi><mi>i</mi><mn>2</mn></msubsup>'),
      'x_{i}^{2}',
    );
    expect(
      tex(
        '<mfrac><mi>a</mi><mrow><mi>b</mi><mo>+</mo><mn>1</mn></mrow></mfrac>'
        '<msqrt><mi>x</mi></msqrt><mroot><mi>y</mi><mn>3</mn></mroot>',
      ),
      r'\frac{a}{b+1}\sqrt{x}\sqrt[3]{y}',
    );
    expect(
      tex('<mfrac linethickness="0"><mi>n</mi><mi>k</mi></mfrac>'),
      r'\binom{n}{k}',
    );
  });

  test('function names, big operators and accents', () {
    expect(
      tex('<mi>log</mi><mo>\u2061</mo><mi>p</mi><mo>≥</mo><mn>0</mn>'),
      r'\log p\ge0',
    );
    expect(
      tex(
        '<munderover><mo>∑</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow>'
        '<mi>n</mi></munderover><msub><mi>x</mi><mi>i</mi></msub>',
      ),
      r'\sum_{i=1}^{n}x_{i}',
    );
    expect(
      tex(
        '<mover accent="true"><mi>x</mi><mo>^</mo></mover><mo>+</mo>'
        '<mover accent="true"><mrow><mi>a</mi><mi>b</mi></mrow><mo>‾</mo>'
        '</mover>',
      ),
      r'\hat{x}+\overline{ab}',
    );
  });

  test('text, letter styles and spaces', () {
    expect(
      tex(
        '<mtext>if </mtext><mi mathvariant="double-struck">P</mi><mo>(</mo>'
        '<mi mathvariant="normal">d</mi><mi>x</mi><mo>)</mo>'
        '<mspace width="1em"></mspace><mi>sin</mi><mi>θ</mi>',
      ),
      r'\text{if }\mathbb{P}(\mathrm{d}x)\quad\sin\theta',
    );
  });

  test('fenced tables are the matrices and cases they draw', () {
    expect(
      tex(
        '<mrow><mo fence="true">(</mo><mtable>'
        '<mtr><mtd><mn>1</mn></mtd><mtd><mn>0</mn></mtd></mtr>'
        '<mtr><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd></mtr>'
        '</mtable><mo fence="true">)</mo></mrow>',
      ),
      r'\begin{pmatrix}1 & 0 \\ 0 & 1\end{pmatrix}',
    );
    expect(
      tex(
        '<mrow><mo fence="true">{</mo><mtable>'
        '<mtr><mtd><mn>1</mn></mtd><mtd><mtext>if </mtext><mi>x</mi></mtd></mtr>'
        '<mtr><mtd><mn>0</mn></mtd><mtd><mtext>otherwise</mtext></mtd></mtr>'
        '</mtable><mo fence="true"></mo></mrow>',
      ),
      r'\begin{cases}1 & \text{if }x \\ 0 & \text{otherwise}\end{cases}',
    );
    expect(
      tex(
        '<mrow><mo fence="true">(</mo><mi>a</mi><mo>+</mo><mi>b</mi>'
        '<mo fence="true">)</mo></mrow>',
      ),
      r'\left(a+b\right)',
    );
  });

  test("KaTeX's non-breaking spaces in text are spaces again", () {
    expect(
      tex('<mn>6.5</mn><mtext>\u00A0s per\u00A0slot</mtext>'),
      r'6.5\text{ s per slot}',
    );
  });

  test('stacked conditions under a sum are a substack', () {
    expect(
      tex(
        '<munder><mo>∏</mo><mrow><mtable>'
        '<mtr><mtd><mi>q</mi><mo>∣</mo><mi>n</mi></mtd></mtr>'
        '<mtr><mtd><mi>q</mi><mo>≠</mo><mi>p</mi></mtd></mtr>'
        '</mtable></mrow></munder><mi>q</mi>',
      ),
      r'\prod_{\substack{q\mid n \\ q\ne p}}q',
    );
  });

  test('a symbol with no TeX name stays the character it is', () {
    expect(tex('<mi>☃</mi><mo>+</mo><mn>1</mn>'), '☃+1');
  });
}
