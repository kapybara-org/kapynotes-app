import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';

void main() {
  test('dark theme keeps a restrained Numi-style palette', () {
    const palette = KapyTheme.darkPalette;

    expect(palette.editorBackground, const Color(0xFF202125));
    expect(palette.gutterBackground, palette.editorBackground);
    expect(palette.textPrimary, const Color(0xFFE7E9EC));
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
    expect(KapyTheme.dark().shadowColor, Colors.transparent);
    expect(KapyTheme.dark().dialogTheme.elevation, 0);
    expect(KapyTheme.dark().popupMenuTheme.elevation, 0);
    expect(
      (KapyTheme.dark().tooltipTheme.decoration! as BoxDecoration).boxShadow,
      anyOf(isNull, isEmpty),
    );
  });

  test('transparency thins the surfaces and never the type', () {
    final palette = KapyTheme.translucentDarkPalette;

    expect(palette.isGlass, isTrue);
    expect(palette.translucency, lessThan(1));
    expect(palette.paperTranslucency, lessThan(1));
    expect(KapyTheme.darkPalette.isGlass, isFalse);
    expect(KapyTheme.darkPalette.translucency, 1);
    expect(KapyTheme.darkPalette.paperTranslucency, 1);

    // The colours are untouched; the paint derived from them is what thins.
    // Dialogs, menus and tooltips read the colours and so stay exactly as
    // legible as they are with transparency off.
    expect(palette.editorBackground, KapyTheme.darkPalette.editorBackground);
    expect(palette.gutterBackground, KapyTheme.darkPalette.gutterBackground);
    expect(palette.surfaceBackground, KapyTheme.darkPalette.surfaceBackground);
    expect(palette.paperColor.a, lessThan(1));
    expect(palette.gutterColor.a, palette.paperColor.a);
    // The notes list is not one of the thinned surfaces: it is a panel over
    // the glass, and a column of titles has no body of its own to hold them
    // off a wallpaper.
    expect(palette.sidebarColor.a, 1);
    expect(KapyTheme.darkPalette.sidebarColor.a, 1);
    expect(
      KapyTheme.glassPalette(Brightness.dark, 1).sidebarColor,
      palette.sidebarColor,
      reason: 'and the slider does not reach it at either end',
    );
    expect(KapyTheme.darkPalette.paperColor.a, 1);
    expect(palette.textPrimary.a, 1);
    expect(palette.textSecondary.a, 1);
    expect(palette.number.a, 1);

    // The paper keeps more body than the chrome: a paragraph needs it.
    expect(palette.paperTranslucency, greaterThan(palette.translucency));
    expect(
      KapyTheme.translucentLightPalette.paperTranslucency,
      greaterThan(palette.paperTranslucency),
      reason: 'dark text over a bright wallpaper loses contrast sooner',
    );

    // The rim only exists on glass, so opaque chrome grows no edge.
    expect(palette.glassHighlight.a, greaterThan(0));
    expect(KapyTheme.darkPalette.glassHighlight.a, 0);
    expect(palette.opaque.isGlass, isFalse);
    expect(palette.opaque.glassHighlight.a, 0);
    expect(KapyTheme.darkPalette.opaque, same(KapyTheme.darkPalette));

    // The slider: more amount, thinner paint, never none.
    final subtle = KapyTheme.glassPalette(Brightness.dark, 0);
    final middle = KapyTheme.glassPalette(Brightness.dark, 0.5);
    final clear = KapyTheme.glassPalette(Brightness.dark, 1);
    expect(subtle.isGlass, isTrue);
    expect(subtle.paperTranslucency, greaterThan(middle.paperTranslucency));
    expect(clear.paperTranslucency, lessThan(middle.paperTranslucency));
    // And it starts at the subtle end: switching the mode on says nothing
    // about how far it should be taken, so every drag takes more away.
    expect(palette.paperTranslucency, subtle.paperTranslucency);
    expect(LayoutPrefs.defaultTransparencyAmount, 0);
    // The far end is a film, not a fill — but never nothing, since the type
    // needs something to stand on even over a blur.
    expect(clear.paperTranslucency, lessThan(0.1));
    expect(clear.paperTranslucency, greaterThan(0));
    expect(clear.translucency, greaterThan(0));
    expect(clear.translucency, lessThan(clear.paperTranslucency));
    // The subtle end is where the old scale ended: properly see-through.
    expect(subtle.paperTranslucency, lessThan(0.5));
    expect(
      KapyTheme.glassPalette(Brightness.dark, 5).paperTranslucency,
      clear.paperTranslucency,
      reason: 'out-of-range amounts clamp',
    );
    expect(
      KapyTheme.dark(
        transparency: true,
      ).extension<CalcPalette>()!.paperTranslucency,
      palette.paperTranslucency,
    );
    expect(KapyTheme.translucentLightPalette.isGlass, isTrue);
    expect(
      KapyTheme.translucentLightPalette.paperFiber.a,
      0,
      reason: 'fibres read as noise on glass',
    );
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

  test('mixed editor face uses monospace for its writing surface', () {
    expect(WritingFont.mixed.label, 'Mixed');
    expect(WritingFont.mixed.fontFamily, WritingFont.monospace.fontFamily);
    expect(
      WritingFont.mixed.fontFamilyFallback,
      WritingFont.monospace.fontFamilyFallback,
    );
    expect(WritingFont.mixed.editorSize, WritingFont.monospace.editorSize);
  });
}
