import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/note_math.dart';

import 'test_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  late NoteMath math;
  setUp(() => math = NoteMath());
  tearDown(() => math.dispose());

  NoteFormula draw(
    String tex, {
    bool display = false,
    double maxWidth = 1000,
    int copy = 0,
  }) => math.formula(
    tex,
    display: display,
    fontSize: 16,
    color: const Color(0xFF000000),
    maxWidth: maxWidth,
    copy: copy,
  );

  test('draws the TeX it reads, and says which it cannot', () {
    expect(math.draws(r'\frac{a}{b}'), isTrue);
    expect(math.draws(r'\frac{a'), isFalse);
    expect(math.draws(r'\nosuchcommand'), isFalse);
  });

  test('reads a LaTeX document\'s environments as the ones it has', () {
    expect(math.draws(r'\begin{align} a &= b \\ c &= d \end{align}'), isTrue);
    expect(math.draws(r'\begin{align*} a &= b \end{align*}'), isTrue);
    expect(
      math.draws(r'\begin{alignat}{2} a &= b &&= c \end{alignat}'),
      isTrue,
    );
    expect(
      math.draws(
        r'\begin{equation}\begin{split} a &= b \\ &= c \end{split}\end{equation}',
      ),
      isTrue,
    );
  });

  test('measures a formula, with its baseline inside it', () {
    final inline = draw(r'\frac{a}{b}');
    expect(inline.width, greaterThan(0));
    expect(inline.baseline, inInclusiveRange(0, inline.height));
    expect(
      draw(r'\frac{a}{b}', display: true).height,
      greaterThan(inline.height),
      reason: 'set apart, a fraction is set larger',
    );
  });

  test('draws a formula too wide for the column smaller', () {
    const long = 'a + b + c + d + e + f + g + h + i + j + k + l + m + n + o';
    final natural = draw(long);
    final fitted = draw(long, maxWidth: natural.width / 2);
    expect(fitted.width, lessThanOrEqualTo(natural.width / 2));
    expect(fitted.width, greaterThan(natural.width / 3));
  });

  test('gives each copy of a formula a widget of its own, and keeps it', () {
    final first = draw('x^2');
    final second = draw('x^2', copy: 1);
    expect(identical(first.child, second.child), isFalse);
    expect(second.width, first.width);
    expect(identical(draw('x^2').child, first.child), isTrue);
  });

  test(
    'reads Wikipedia\'s \\sgn, and a phantom\'s delimiter without braces',
    () {
      expect(math.draws(r'x = -\sgn(b)\sqrt{\vert c\vert}'), isTrue);
      expect(
        math.draws(r'x = \dfrac{-b\pm\sqrt{b^2 - 4ac}}{2a}. \vphantom\bigg)'),
        isTrue,
      );
    },
  );

  testWidgets('leaves a formula\'s glyphs out of the semantics tree', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: draw(r'x^2 + y').child),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('[xy2+]')), findsNothing);
  });
}
