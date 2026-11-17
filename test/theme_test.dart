import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';

void main() {
  test('dark theme keeps a restrained warm-neutral palette', () {
    const palette = KapyTheme.darkPalette;

    expect(palette.editorBackground, const Color(0xFF23201C));
    expect(palette.gutterBackground, palette.editorBackground);
    expect(palette.textPrimary, const Color(0xFFE2DCCF));
    expect(palette.paperFiber, Colors.transparent);

    // Names and figures stay in the note's ink; only the operators and the
    // units step back.
    expect(
      {palette.number, palette.keyword, palette.function, palette.variable},
      {palette.textPrimary},
    );
    expect(
      {palette.operator, palette.unit, palette.currency},
      {palette.textTertiary},
    );
    expect(
      {
        palette.chipNumber,
        palette.chipCurrency,
        palette.chipUnit,
        palette.chipBoolean,
        palette.chipOther,
      },
      {const Color(0xFFB3C79C)},
    );
    expect(KapyTheme.dark().colorScheme.primary, const Color(0xFF7D9468));
    expect(KapyTheme.dark().textTheme.bodyMedium?.fontWeight, FontWeight.w400);
    expect(KapyTheme.dark().textTheme.titleMedium?.fontWeight, FontWeight.w400);
    expect(KapyTheme.dark().shadowColor, Colors.transparent);
    expect(KapyTheme.dark().dialogTheme.elevation, 0);
    expect(KapyTheme.dark().popupMenuTheme.elevation, 0);
    expect(
      (KapyTheme.dark().tooltipTheme.decoration! as BoxDecoration).boxShadow,
      anyOf(isNull, isEmpty),
    );
  });

  test('interactive primitives are rounded, emphatic, and flat', () {
    final theme = KapyTheme.dark();
    final filled = theme.filledButtonTheme.style!;
    final outlined = theme.outlinedButtonTheme.style!;
    final segmented = theme.segmentedButtonTheme.style!;

    expect(filled.elevation!.resolve({}), 0);
    expect(filled.shadowColor!.resolve({}), Colors.transparent);
    expect(filled.minimumSize!.resolve({})!.height, 36);
    expect(filled.visualDensity, VisualDensity.standard);
    expect(filled.padding!.resolve({})!.vertical, greaterThanOrEqualTo(16));
    expect(filled.textStyle!.resolve({})!.fontWeight, FontWeight.w600);
    expect(
      (filled.shape!.resolve({})! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(AppRadii.control),
    );
    expect(outlined.side!.resolve({})!.width, 1);
    expect(outlined.minimumSize!.resolve({})!.height, 36);
    expect(outlined.visualDensity, VisualDensity.standard);
    expect(outlined.padding!.resolve({})!.vertical, greaterThanOrEqualTo(16));
    expect(
      segmented.backgroundColor!.resolve({WidgetState.selected}),
      theme.colorScheme.primary,
    );
    expect(
      segmented.foregroundColor!.resolve({WidgetState.selected}),
      theme.colorScheme.onPrimary,
    );
    expect(segmented.iconSize!.resolve({}), AppControlMetrics.iconControl);
    expect(theme.inputDecorationTheme.filled, isTrue);
    expect(
      (theme.inputDecorationTheme.border! as OutlineInputBorder).borderRadius,
      BorderRadius.circular(AppRadii.control),
    );
  });

  test('Windows keeps readable sizes for small interface copy', () {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    final theme = KapyTheme.dark();

    // Figtree, as everywhere, with Segoe UI drawing whatever it lacks.
    expect(theme.textTheme.bodyMedium?.fontFamily, AppFonts.ui);
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback?.first, 'Segoe UI');
    expect(theme.textTheme.bodyMedium?.fontWeight, FontWeight.w400);
    expect(theme.textTheme.bodySmall?.fontWeight, FontWeight.w400);
    expect(theme.textTheme.bodySmall?.fontSize, 12.5);
    expect(theme.textTheme.labelMedium?.fontSize, 12.5);
    expect(theme.textTheme.labelSmall?.fontSize, 11.5);
    expect(AppTypeScale.micro, 11.5);
    expect(AppTypeScale.caption, 12.5);
    expect(AppTypeScale.small, 13);
    expect(AppTypeScale.body, 13.5);
    expect(AppTypeScale.control, 14);
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

    // The rim only exists on light glass: opaque chrome grows no edge, and a
    // lit edge on charcoal reads as an outline rather than a reflection.
    expect(KapyTheme.translucentLightPalette.glassHighlight.a, greaterThan(0));
    expect(palette.glassHighlight.a, 0);
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

  test('the Riverbank tokens copy and blend like every other colour', () {
    const dark = KapyTheme.darkPalette;
    const light = KapyTheme.lightPalette;
    final tokens = <String, Color Function(CalcPalette)>{
      'railBackground': (p) => p.railBackground,
      'railBorder': (p) => p.railBorder,
      'tonalBackground': (p) => p.tonalBackground,
      'tonalForeground': (p) => p.tonalForeground,
      'tonalKeyBackground': (p) => p.tonalKeyBackground,
      'tonalKeyText': (p) => p.tonalKeyText,
      'keycapBackground': (p) => p.keycapBackground,
      'keycapBorder': (p) => p.keycapBorder,
      'keycapText': (p) => p.keycapText,
      'stickyMustard': (p) => p.stickyMustard,
      'stickyTeal': (p) => p.stickyTeal,
      'stickyOlive': (p) => p.stickyOlive,
      'stickyRust': (p) => p.stickyRust,
      'stickySage': (p) => p.stickySage,
      'scrim': (p) => p.scrim,
      'resultPillBackground': (p) => p.resultPillBackground,
      'resultPillText': (p) => p.resultPillText,
      'totalPillBackground': (p) => p.totalPillBackground,
      'totalPillText': (p) => p.totalPillText,
      'clay': (p) => p.clay,
    };
    const marker = Color(0xFF123456);
    final copied = dark.copyWith();
    final scrimOnly = dark.copyWith(scrim: marker);
    final atDark = dark.lerp(light, 0);
    final atLight = dark.lerp(light, 1);

    for (final MapEntry(key: name, value: token) in tokens.entries) {
      expect(token(copied), token(dark), reason: name);
      expect(
        token(scrimOnly),
        name == 'scrim' ? marker : token(dark),
        reason: name,
      );
      expect(token(atDark), isSameColorAs(token(dark)), reason: name);
      expect(token(atLight), isSameColorAs(token(light)), reason: name);
    }
  });

  test('a modal dims the window with the palette scrim', () {
    expect(
      KapyTheme.dark().drawerTheme.scrimColor,
      KapyTheme.darkPalette.scrim,
    );
    expect(
      KapyTheme.light().drawerTheme.scrimColor,
      KapyTheme.lightPalette.scrim,
    );
  });

  test('the interface is set in Figtree on every platform', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      AppPlatform.debugTargetPlatformOverride = platform;
      final text = KapyTheme.light().textTheme;
      for (final style in [text.bodyMedium, text.labelLarge, text.titleSmall]) {
        expect(style?.fontFamily, AppFonts.ui, reason: '$platform');
        expect(
          style?.fontFamilyFallback?.first,
          AppPlatform.uiFontFamily,
          reason: 'the system face draws what Figtree lacks on $platform',
        );
      }
    }
  });

  test(
    'the interface faces are bundled under the names the theme asks for',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(pubspec, contains('- family: ${AppFonts.ui}\n'));
      expect(pubspec, contains('- family: ${AppFonts.mono}\n'));
      for (final file in RegExp(r'(assets/fonts/\S+)').allMatches(pubspec)) {
        expect(File(file[1]!).existsSync(), isTrue, reason: file[1]);
      }
    },
  );

  test('handwritten editor face stays restrained', () {
    expect(WritingFont.handwritten.fontFamily, 'Shantell Sans');
    expect(WritingFont.handwritten.editorSize, 16.5);
    expect(WritingFont.handwritten.fontVariations, const [
      FontVariation('INFM', 16),
      FontVariation('BNCE', 0),
      FontVariation('SPAC', 0),
    ]);
  });

  test('mixed editor face writes in Figtree at 16', () {
    expect(WritingFont.mixed.label, 'Mixed');
    expect(WritingFont.mixed.fontFamily, 'Figtree');
    expect(WritingFont.mixed.fontFamilyFallback, AppPlatform.uiFontFallback);
    expect(WritingFont.mixed.editorSize, 16);
  });
}
