import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/checklist_pie.dart';
import 'package:material_ui/material_ui.dart';

Widget _pie(
  int done,
  int total, {
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: brightness == Brightness.dark ? KapyTheme.dark() : KapyTheme.light(),
  home: Builder(
    builder: (context) {
      final palette = context.palette;
      return ColoredBox(
        color: palette.paperColor,
        child: Center(
          child: RepaintBoundary(
            key: const ValueKey('pies'),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  for (final (done, total) in [(0, 8), (3, 8), (done, total)])
                    ChecklistPie(
                      done: done,
                      total: total,
                      fill: Theme.of(context).colorScheme.primary,
                      check: palette.paperColor,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  ),
);

void main() {
  testWidgets('reads as how many boxes are done', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_pie(3, 8));
    expect(find.bySemanticsLabel('3 of 8 done'), findsNWidgets(2));
    expect(find.bySemanticsLabel('0 of 8 done'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a ticked box moves the wedge in about 200ms', (tester) async {
    await tester.pumpWidget(_pie(3, 8));
    expect(tester.hasRunningAnimations, isFalse, reason: 'no wind-up');

    await tester.pumpWidget(_pie(4, 8));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.hasRunningAnimations, isFalse);
  });

  for (final brightness in Brightness.values) {
    testWidgets('empty, three of eight and all done, ${brightness.name}', (
      tester,
    ) async {
      // Drawn four times over, so the ring and the wedge can be checked.
      tester.view.devicePixelRatio = 4;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_pie(8, 8, brightness: brightness));
      await expectLater(
        find.byKey(const ValueKey('pies')),
        matchesGoldenFile('goldens/checklist_pie_${brightness.name}.png'),
      );
    });
  }
}
