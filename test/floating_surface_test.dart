import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/floating_surface.dart';
import 'package:material_ui/material_ui.dart';

/// Puts [child] where these panels actually live: an entry in the root
/// overlay, with no route — and so no `Material` — above it.
Future<void> _pumpInOverlay(WidgetTester tester, Widget child) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  Overlay.of(
    ctx,
    rootOverlay: true,
  ).insert(OverlayEntry(builder: (_) => Center(child: child)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a panel in the overlay does not inherit the fallback style', (
    tester,
  ) async {
    // The bug this exists for: with no Material above it, Flutter's fallback
    // applies — red type, underlined twice in yellow — and a Text naming only
    // its size and colour merges with that rather than replacing it, so the
    // underline came along. It is what put stray double lines under tooltips.
    await _pumpInOverlay(
      tester,
      const FloatingSurface(
        child: Text('total', style: TextStyle(fontSize: 12)),
      ),
    );

    final style = DefaultTextStyle.of(tester.element(find.text('total'))).style;
    expect(style.decoration, TextDecoration.none);
    expect(style.color, isNot(const Color(0xD0FF0000)));
  });

  testWidgets('without it, the fallback is exactly what arrives', (
    tester,
  ) async {
    // Proving the trap is real rather than asserting against a guess: this is
    // what every hand-built overlay entry here used to render as.
    await _pumpInOverlay(
      tester,
      const Text('total', style: TextStyle(fontSize: 12)),
    );

    final style = DefaultTextStyle.of(tester.element(find.text('total'))).style;
    expect(style.decoration, TextDecoration.underline);
    expect(style.decorationStyle, TextDecorationStyle.double);
  });

  testWidgets('it is flat, and the same shape as the app it floats over', (
    tester,
  ) async {
    await _pumpInOverlay(
      tester,
      const FloatingSurface(child: Text('total')),
    );

    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(FloatingSurface),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = box.decoration! as BoxDecoration;
    expect(
      decoration.boxShadow,
      anyOf(isNull, isEmpty),
      reason: 'the theme sets a transparent shadow colour throughout',
    );
    expect(
      decoration.borderRadius,
      BorderRadius.circular(FloatingSurface.radius),
    );
    expect(decoration.border, isNotNull);
  });
}
