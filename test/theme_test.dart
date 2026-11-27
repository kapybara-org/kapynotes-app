import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';

void main() {
  test('dark theme is the design system neutral ladder', () {
    final palette = KapyTheme.darkPalette;

    expect(palette.editorBackground, const Color(0xFF0F0E0E));
    expect(palette.gutterBackground, palette.editorBackground);
    expect(palette.textPrimary, const Color(0xFFDBDBDB));
    expect(palette.paperFiber, Colors.transparent);

    // Names and figures stay in the note's ink; only the operators, the
    // units and comments step back.
    expect(
      {palette.number, palette.keyword, palette.function, palette.variable},
      {palette.textPrimary},
    );
    expect(palette.textTertiary, const Color(0xFF878787));
    expect(
      {palette.operator, palette.unit, palette.currency, palette.comment},
      {palette.textTertiary},
    );
    expect(palette.railBackground, palette.sidebarBackground);
    expect(palette.raisedBackground, isNull);
    expect(palette.raisedBorder, isNull);
    // A result is a grey chip: the note's ink on #1E1E1E.
    expect(
      {
        palette.chipNumber,
        palette.chipCurrency,
        palette.chipUnit,
        palette.chipBoolean,
        palette.chipOther,
      },
      {palette.textPrimary},
    );
    expect(palette.resultPillBackground, const Color(0xFF1E1E1E));
    final theme = KapyTheme.dark();
    expect(theme.colorScheme.primary, const Color(0xFFE8772E));
    expect(theme.colorScheme.onPrimary, const Color(0xFF1A0E06));
    expect(theme.colorScheme.error, const Color(0xFFEB534E));
    expect(theme.colorScheme.errorContainer, const Color(0xFF291919));
    expect(theme.textTheme.bodyMedium?.fontWeight, FontWeight.w400);
    expect(theme.textTheme.titleMedium?.fontWeight, FontWeight.w400);
    expect(theme.textTheme.displayLarge?.fontWeight, FontWeight.w400);
    expect(theme.dialogTheme.titleTextStyle?.fontWeight, FontWeight.w600);
    expect(theme.shadowColor, Colors.transparent);
    expect(theme.dialogTheme.elevation, 0);
    expect(theme.popupMenuTheme.elevation, 0);
    expect(
      (theme.tooltipTheme.decoration! as BoxDecoration).boxShadow,
      anyOf(isNull, isEmpty),
    );
  });

  test('the radii are the design system', () {
    expect(AppRadii.control, 7);
    expect(AppRadii.group, 10);
    expect(AppRadii.surface, 12);
    expect(AppRadii.card, 20);
    final dialog =
        KapyTheme.dark().dialogTheme.shape! as RoundedRectangleBorder;
    expect(dialog.borderRadius, BorderRadius.circular(AppRadii.surface));
  });

  test('controls are flat, borderless and orange where they are on', () {
    final theme = KapyTheme.dark();
    final palette = KapyTheme.darkPalette;
    final filled = theme.filledButtonTheme.style!;
    final outlined = theme.outlinedButtonTheme.style!;
    final segmented = theme.segmentedButtonTheme.style!;

    expect(filled.elevation!.resolve({}), 0);
    expect(filled.shadowColor!.resolve({}), Colors.transparent);
    expect(filled.minimumSize!.resolve({})!.height, 36);
    expect(filled.visualDensity, VisualDensity.standard);
    expect(filled.padding!.resolve({})!.vertical, greaterThanOrEqualTo(16));
    expect(filled.textStyle!.resolve({})!.fontWeight, FontWeight.w400);
    expect(filled.backgroundColor!.resolve({}), palette.accent);
    expect(filled.foregroundColor!.resolve({}), palette.onAccent);
    expect(
      (filled.shape!.resolve({})! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(AppRadii.control),
    );
    // A quiet button is a fill with no border, and focus rings it in orange.
    expect(outlined.side!.resolve({}), BorderSide.none);
    expect(outlined.backgroundColor!.resolve({}), palette.controlBackground);
    // Keyboard focus is the shared accent ring, not a second border.
    expect(outlined.side!.resolve({WidgetState.focused}), BorderSide.none);
    expect(outlined.minimumSize!.resolve({})!.height, 36);
    expect(
      theme.textButtonTheme.style!.foregroundColor!.resolve({}),
      palette.accentText,
    );
    expect(segmented.side!.resolve({}), BorderSide.none);
    expect(
      segmented.backgroundColor!.resolve({WidgetState.selected}),
      palette.segmentSelected,
    );
    expect(segmented.iconSize!.resolve({}), AppControlMetrics.iconControl);
    final field = theme.inputDecorationTheme;
    expect(field.filled, isTrue);
    expect(
      (field.border! as OutlineInputBorder).borderRadius,
      BorderRadius.circular(AppRadii.control),
    );
    expect(field.enabledBorder!.borderSide.color, Colors.transparent);
    expect(field.focusedBorder!.borderSide.color, palette.accent);

    final switches = theme.switchTheme;
    expect(switches.thumbColor!.resolve({}), const Color(0xFFFFFFFF));
    expect(
      switches.trackColor!.resolve({WidgetState.selected}),
      palette.accent,
    );
    expect(switches.trackColor!.resolve({}), palette.switchTrackOff);
    final checkbox = theme.checkboxTheme;
    expect(checkbox.shape, const CircleBorder());
    expect(checkbox.fillColor!.resolve({WidgetState.selected}), palette.accent);
    expect(
      (checkbox.side! as WidgetStateProperty<BorderSide?>).resolve({})!.color,
      palette.checkboxBorder,
    );
    expect(theme.chipTheme.shape, const StadiumBorder());
    expect(theme.chipTheme.side, BorderSide.none);
    expect(theme.dividerTheme.color, palette.pageBorder);
  });

  test('two weights: regular, and semibold for titles', () {
    expect(AppWeight.regular, 400);
    expect(AppWeight.semibold, 600);
    expect(AppWeight.axisOf(FontWeight.w500), AppWeight.regular);
    expect(AppWeight.axisOf(FontWeight.w700), AppWeight.semibold);
    expect(AppWeight.named(AppWeight.regular), FontWeight.w400);
    expect(AppWeight.named(AppWeight.semibold), FontWeight.w600);
    expect(AppWeight.named(700), FontWeight.w700);
  });

  test('the handwritten accent is one quiet line in Shantell Sans', () {
    final palette = KapyTheme.darkPalette;
    final style = handAccent(palette);
    expect(style.fontFamily, 'Shantell Sans');
    expect(style.fontSize, 17);
    expect(style.height, 24 / 17);
    expect(style.fontWeight, FontWeight.w400);
    expect(style.color, palette.textSecondary);
    expect(style.letterSpacing, 0);
  });

  test('Windows keeps readable sizes for small interface copy', () {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    final theme = KapyTheme.dark();

    // Inter, bundled, with Segoe UI drawing whatever it lacks.
    expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback?.first, 'Segoe UI');
    expect(theme.textTheme.bodyMedium?.fontWeight, FontWeight.w400);
    expect(theme.textTheme.bodySmall?.fontWeight, FontWeight.w400);
    expect(theme.textTheme.bodySmall?.fontSize, 13);
    expect(theme.textTheme.labelMedium?.fontSize, 13);
    expect(theme.textTheme.labelSmall?.fontSize, 12);
    expect(AppTypeScale.micro, 12);
    expect(AppTypeScale.caption, 13);
    expect(AppTypeScale.small, 13);
    expect(AppTypeScale.body, 14);
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
      KapyTheme.glassPalette(KapyTheme.darkPalette, 1).sidebarColor,
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
    final subtle = KapyTheme.glassPalette(KapyTheme.darkPalette, 0);
    final middle = KapyTheme.glassPalette(KapyTheme.darkPalette, 0.5);
    final clear = KapyTheme.glassPalette(KapyTheme.darkPalette, 1);
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
      KapyTheme.glassPalette(KapyTheme.darkPalette, 5).paperTranslucency,
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
    final dark = KapyTheme.darkPalette;
    final light = KapyTheme.lightPalette;
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
      'scrim': (p) => p.scrim,
      'resultPillBackground': (p) => p.resultPillBackground,
      'resultPillText': (p) => p.resultPillText,
      'totalPillBackground': (p) => p.totalPillBackground,
      'totalPillText': (p) => p.totalPillText,
      'clay': (p) => p.clay,
      'clayText': (p) => p.clayText,
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

  test('the interface is San Francisco on Apple and Inter elsewhere', () {
    addTearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      debugDefaultTargetPlatformOverride = null;
    });

    for (final (platform, face) in [
      (TargetPlatform.macOS, '.AppleSystemUIFont'),
      (TargetPlatform.iOS, '.AppleSystemUIFont'),
      (TargetPlatform.windows, 'Inter'),
      (TargetPlatform.android, 'Inter'),
      (TargetPlatform.linux, 'Inter'),
    ]) {
      AppPlatform.debugTargetPlatformOverride = platform;
      debugDefaultTargetPlatformOverride = platform;
      final text = KapyTheme.light().textTheme;
      for (final style in [text.bodyMedium, text.labelLarge, text.titleSmall]) {
        expect(style?.fontFamily, face, reason: '$platform');
        expect(
          style?.fontFamilyFallback?.first,
          AppPlatform.uiFontFamily,
          reason: 'the system face draws what the interface face lacks',
        );
      }
      expect(WritingFont.clean.fontFamily, face, reason: '$platform');
      expect(WritingFont.mixed.fontFamily, face, reason: '$platform');
    }
  });

  test(
    'the interface faces are bundled under the names the theme asks for',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(pubspec, contains('- family: ${AppFonts.inter}\n'));
      expect(pubspec, contains('- family: ${AppFonts.hand}\n'));
      // San Francisco's licence keeps it out of the bundle, and the faces
      // the design system replaced are gone with their files.
      for (final gone in ['Figtree', 'Newsreader', 'SF Pro']) {
        expect(pubspec, isNot(contains(gone)), reason: gone);
      }
      expect(pubspec, contains('- family: ${AppFonts.mono}\n'));
      for (final file in RegExp(r'(assets/fonts/\S+)').allMatches(pubspec)) {
        expect(File(file[1]!).existsSync(), isTrue, reason: file[1]);
      }
    },
  );

  test('handwritten editor face stays restrained', () {
    expect(WritingFont.handwritten.fontFamily, 'Shantell Sans');
    expect(WritingFont.handwritten.editorSize, 16);
    expect(WritingFont.handwritten.fontVariations, const [
      FontVariation('INFM', 16),
      FontVariation('BNCE', 0),
      FontVariation('SPAC', 0),
    ]);
  });

  test('mixed editor face writes in the interface face at 16', () {
    expect(WritingFont.mixed.label, 'Mixed');
    expect(WritingFont.mixed.fontFamily, AppFonts.ui);
    expect(WritingFont.mixed.fontFamilyFallback, AppFonts.uiFallback);
    expect(WritingFont.mixed.editorSize, 16);
  });

  test('muted text holds 4.5:1 on every surface it sits on', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
    }

    for (final palette in [KapyTheme.darkPalette, KapyTheme.lightPalette]) {
      for (final surface in [
        palette.editorBackground,
        palette.sidebarBackground,
        palette.railBackground,
        palette.controlBackground,
        palette.cardBackground,
        palette.wellBackground,
        palette.keycapBackground,
        palette.selectedBackground,
        palette.hover,
      ]) {
        expect(
          contrast(palette.textTertiary, surface),
          greaterThanOrEqualTo(4.5),
          reason: '${palette.textTertiary} on $surface',
        );
      }
    }
  });

  testWidgets('a hairline is one physical pixel at every display scale', (
    tester,
  ) async {
    for (final scale in [1.0, 1.25, 1.5, 2.0, 3.0]) {
      late double width;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(devicePixelRatio: scale),
          child: Builder(
            builder: (context) {
              width = AppHairline.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(width * scale, 1, reason: 'at ${scale}x');
    }
  });
}
