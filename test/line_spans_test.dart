import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/ui/editor/highlighting_controller.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

/// Every character [spans] draw, with what draws it: the run's style, or the
/// widget standing in its place.
List<Object?> _drawn(Iterable<InlineSpan> spans) => [
  for (final span in spans)
    if (span is TextSpan)
      for (final character in (span.text ?? '').split(''))
        (character, span.style)
    else if (span is WidgetSpan)
      (span.alignment, span.child.runtimeType, span.child.key),
];

const _note = '''Groceries and sums
## Monday
- [ ] milk \$2.50
- [x] bread
  1. nested *item* with **bold**
> quoted `code` and a [link](https://example.com)
price = 4 usd
price * 3
☐ a box with https://kapynotes.app/help in it
☑ done
```python
def score(page):
    return 1  # one
```
Inline \$x^2 + y\$ and then
\$\$
\\sum_{k=1}^{n} k
\$\$
| a | b |
| - | - |
| 1 | 2 |
total''';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('a line built on its own is drawn as the whole note draws it', (
    tester,
  ) async {
    final engine = CalcEngine();
    final controller = HighlightingController(
      highlighter: Highlighter(engine.registry),
      palette: KapyTheme.lightPalette,
      writingFont: WritingFont.mixed,
      markdown: true,
      formats: const [
        NoteFormatRange(start: 3, end: 9, format: NoteFormat.bold),
        NoteFormatRange(start: 40, end: 60, format: NoteFormat.italic),
      ],
      text: _note,
    )..spellingSuggestions = const [];
    addTearDown(controller.dispose);
    controller.setMathWidthDuringLayout(680);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    );
    const style = TextStyle(fontSize: 16, height: 1.75);

    for (final caret in [0, 30, 150, _note.length]) {
      controller.selection = TextSelection.collapsed(offset: caret);
      final whole = _drawn(
        controller
            .buildTextSpan(context: context, style: style, withComposing: false)
            .children!,
      );
      final spansIn = controller.spansIn(context, style);
      expect(whole, hasLength(_note.length));
      var start = 0;
      final texts = _note.split('\n');
      for (var line = 0; line < texts.length; line++) {
        final drawn = spansIn(start, start + texts[line].length).span;
        expect(
          _drawn((drawn as TextSpan).children!),
          whole.sublist(start, start + texts[line].length),
          reason: 'line $line with the caret at $caret',
        );
        start += texts[line].length + 1;
      }
    }
  });
  testWidgets('a new highlighter recolours the note before the next key', (
    tester,
  ) async {
    const text = 'fare = 1200 JPY\nfare * 2';
    HighlightingController controllerWith(Highlighter highlighter) =>
        HighlightingController(
          highlighter: highlighter,
          palette: KapyTheme.lightPalette,
          writingFont: WritingFont.mixed,
          markdown: true,
          text: text,
        )..spellingSuggestions = const [];
    Highlighter withRates(Map<String, double> rates) =>
        Highlighter(CalcEngine(ratesPerUsd: rates).registry);
    final controller = controllerWith(withRates(const {}));
    final rated = controllerWith(withRates(const {'JPY': 150}));
    addTearDown(controller.dispose);
    addTearDown(rated.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    );
    const style = TextStyle(fontSize: 16, height: 1.75);
    List<Object?> drawn(HighlightingController controller) => _drawn(
      (controller.spansIn(context, style)(0, text.length).span as TextSpan)
          .children!,
    );

    final before = drawn(controller);
    final expected = drawn(rated);
    expect(expected, isNot(before), reason: 'the rates have to show');
    // Exchange rates arriving swap the highlighter, with no edit to the note.
    controller.highlighter = withRates(const {'JPY': 150});
    expect(drawn(controller), expected);
  });
}
