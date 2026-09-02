import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/core/theme.dart';

void main() {
  test('dark theme keeps a restrained Numi-style palette', () {
    const palette = KapyTheme.darkPalette;

    expect(palette.editorBackground, const Color(0xFF212226));
    expect(palette.gutterBackground, palette.editorBackground);
    expect(palette.textPrimary, const Color(0xFFE3E7E9));
    expect(palette.paperFiber, Colors.transparent);

    expect({
      palette.number,
      palette.keyword,
      palette.unit,
      palette.currency,
      palette.function,
      palette.variable,
      palette.operator,
    }, hasLength(3));
    expect(
      {
        palette.chipNumber,
        palette.chipCurrency,
        palette.chipUnit,
        palette.chipBoolean,
        palette.chipOther,
      },
      {const Color(0xFF8DD32D)},
    );
    expect(KapyTheme.dark().colorScheme.primary, const Color(0xFF6CC4EE));
  });

  test('handwritten editor face stays restrained', () {
    expect(WritingFont.handwritten.fontFamily, 'Shantell Sans');
    expect(WritingFont.handwritten.editorSize, 16.5);
    expect(WritingFont.handwritten.fontVariations, const [
      FontVariation('INFM', 16),
      FontVariation('BNCE', 0),
      FontVariation('SPAC', 0),
    ]);
  });
}
