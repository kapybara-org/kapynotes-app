import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/unloaded_pictures_status.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(() async => loadTestFonts());

  Widget status(ThemeData theme, {int count = 1, VoidCallback? onPressed}) =>
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          body: Center(
            child: UnloadedPicturesStatus(
              count: count,
              onPressed: onPressed ?? () {},
            ),
          ),
        ),
      );

  testWidgets('it counts the pictures and shows the first when pressed', (
    tester,
  ) async {
    var shown = 0;
    await tester.pumpWidget(
      status(KapyTheme.light(), onPressed: () => shown++),
    );

    expect(find.text("1 picture didn't load"), findsOneWidget);
    await tester.tap(find.byType(UnloadedPicturesStatus));
    expect(shown, 1);

    await tester.pumpWidget(status(KapyTheme.light(), count: 3));
    expect(find.text("3 pictures didn't load"), findsOneWidget);
  });

  for (final (name, theme) in [
    ('light', KapyTheme.light),
    ('dark', KapyTheme.dark),
  ]) {
    testWidgets('pictures not loaded status, $name', (tester) async {
      await tester.binding.setSurfaceSize(const Size(220, 64));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(status(theme()));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/unloaded_pictures_status_$name.png'),
      );
    });
  }
}
