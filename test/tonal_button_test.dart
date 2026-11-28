import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:kapy_notes/ui/tonal_button.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pump(WidgetTester tester, Widget child, {bool dark = true}) {
  AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  return tester.pumpWidget(
    MaterialApp(
      theme: dark ? KapyTheme.dark() : KapyTheme.light(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Material _surface(WidgetTester tester) => tester.widget<Material>(
  find
      .descendant(of: find.byType(TonalButton), matching: find.byType(Material))
      .first,
);

Color? _ink(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text)).text.style?.color;

void main() {
  testWidgets('a keycap prints its key in Geist on the keycap colours', (
    tester,
  ) async {
    await _pump(tester, const Keycap('⌘F'));
    final palette = KapyTheme.darkPalette;

    final style = tester.widget<Text>(find.text('⌘F')).style!;
    expect(style.fontFamily, AppFonts.ui);
    expect(style.fontFamilyFallback, AppFonts.uiFallback);
    expect(style.fontSize, AppTypeScale.keycap);
    expect(style.color, palette.keycapText);

    final decoration =
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byType(Keycap),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.color, palette.keycapBackground);
    expect(decoration.border, Border.all(color: palette.keycapBorder));
    expect(tester.getSize(find.byType(Keycap)).height, 20);
  });

  testWidgets('a tonal button is a flat sage tint that names its shortcut', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var pressed = 0;
    await _pump(
      tester,
      TonalButton(
        icon: KapyIcons.addRounded,
        label: 'New note',
        shortcut: '⌘N',
        onPressed: () => pressed++,
      ),
    );
    final palette = KapyTheme.darkPalette;

    final surface = _surface(tester);
    expect(surface.color, palette.tonalBackground);
    expect(surface.elevation, 0);
    expect((surface.shape! as RoundedRectangleBorder).side, BorderSide.none);
    expect(_ink(tester, 'New note'), palette.tonalForeground);
    expect(_ink(tester, '⌘N'), palette.tonalKeyText);
    expect(
      tester.getSize(find.byType(TonalButton)).height,
      AppControlMetrics.tonalButtonHeight,
    );
    // The chip repeats what the menus already say; a screen reader hears the
    // button's name, not "place of interest sign N".
    expect(find.bySemanticsLabel('New note'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('⌘')), findsNothing);

    await tester.tap(find.byType(TonalButton));
    expect(pressed, 1);
    semantics.dispose();
  });

  testWidgets('under the pointer a tonal button lays its own ink on the sage', (
    tester,
  ) async {
    await _pump(tester, TonalButton(label: 'Share', onPressed: () {}));
    final palette = KapyTheme.darkPalette;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(find.byType(TonalButton)));
    await tester.pumpAndSettle();

    expect(
      _surface(tester).color,
      Color.alphaBlend(
        palette.tonalForeground.withValues(alpha: 0.07),
        palette.tonalBackground,
      ),
    );
  });

  testWidgets('an icon-only tonal button is square and named by its tooltip', (
    tester,
  ) async {
    await _pump(
      tester,
      TonalButton(
        icon: KapyIcons.addRounded,
        tooltip: 'New note',
        onPressed: () {},
      ),
      dark: false,
    );

    expect(
      tester.getSize(find.byType(TonalButton)),
      Size.square(AppControlMetrics.tonalButtonHeight),
    );
    expect(find.byTooltip('New note'), findsOneWidget);
    expect(_surface(tester).color, KapyTheme.lightPalette.tonalBackground);
  });

  testWidgets('a quiet button with a sage icon is the main action: the plus '
      'in sage and its words in T1, where plain quiet words are T2', (
    tester,
  ) async {
    final palette = KapyTheme.darkPalette;
    FilledButton button() => tester.widget<FilledButton>(
      find.descendant(
        of: find.byType(TonalButton),
        matching: find.byType(FilledButton),
      ),
    );
    KapyIcon icon() => tester.widget<KapyIcon>(
      find.descendant(
        of: find.byType(TonalButton),
        matching: find.byType(KapyIcon),
      ),
    );

    await _pump(
      tester,
      TonalButton(
        icon: KapyIcons.addRounded,
        label: 'New note',
        quiet: true,
        sageIcon: true,
        onPressed: () {},
      ),
    );
    expect(icon().color, palette.accentText);
    expect(button().style!.foregroundColor!.resolve({}), palette.textPrimary);
    expect(button().style!.backgroundColor!.resolve({}), Colors.transparent);

    await _pump(
      tester,
      TonalButton(
        icon: KapyIcons.addRounded,
        label: 'Share',
        quiet: true,
        onPressed: () {},
      ),
    );
    expect(icon().color, isNull);
    expect(button().style!.foregroundColor!.resolve({}), palette.textSecondary);
  });

  test(
    'the focus border stands out from the surface and the selected fill',
    () {
      final palette = KapyTheme.darkPalette;
      double contrast(Color a, Color b) {
        final (x, y) = (a.computeLuminance(), b.computeLuminance());
        return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
      }

      expect(
        contrast(palette.selectedBorder, palette.sidebarBackground),
        greaterThanOrEqualTo(3),
      );
      expect(
        contrast(palette.selectedBorder, palette.selectedBackground),
        greaterThanOrEqualTo(3),
      );
    },
  );

  testWidgets('a tonal button with nothing to do greys out', (tester) async {
    await _pump(tester, const TonalButton(label: 'Share', onPressed: null));
    final palette = KapyTheme.darkPalette;

    expect(_surface(tester).color, palette.controlBackground);
    expect(_ink(tester, 'Share'), palette.textTertiary);
  });
}
