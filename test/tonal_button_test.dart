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
  testWidgets('a keycap prints its key in Geist Mono on the keycap colours', (
    tester,
  ) async {
    await _pump(tester, const Keycap('⌘F'));
    const palette = KapyTheme.darkPalette;

    final style = tester.widget<Text>(find.text('⌘F')).style!;
    expect(style.fontFamily, AppFonts.mono);
    expect(style.fontFamilyFallback, AppFonts.monoFallback);
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
    const palette = KapyTheme.darkPalette;

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
    const palette = KapyTheme.darkPalette;
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

  testWidgets('a tonal button with nothing to do greys out', (tester) async {
    await _pump(tester, const TonalButton(label: 'Share', onPressed: null));
    const palette = KapyTheme.darkPalette;

    expect(_surface(tester).color, palette.controlBackground);
    expect(_ink(tester, 'Share'), palette.textTertiary);
  });
}
