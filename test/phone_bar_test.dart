import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required double scale,
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: PhoneSpaces(
          space: LibrarySpace.notes,
          onSelected: (_) {},
          onSettingsPressed: () {},
          createLabel: 'New note',
          onCreate: () {},
          createActions: const [],
          onCreateAction: (_) {},
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final (scale, size) in [
      (1.0, const Size(393, 852)),
      (1.3, const Size(393, 852)),
      (2.0, const Size(412, 915)),
      (3.1, const Size(375, 667)),
    ]) {
      testWidgets('the bar fits its labels at $scale× text on '
          '${platform.name}', (tester) async {
        AppPlatform.debugTargetPlatformOverride = platform;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        await pumpBar(tester, scale: scale, size: size);
        expect(tester.takeException(), isNull);
        // Android's bar is the platform's own and sizes its labels itself.
        if (platform != TargetPlatform.iOS) return;
        for (final label in ['Notes', 'Tasks', 'Drawings', 'Settings']) {
          final text = find.text(label);
          if (text.evaluate().isEmpty) continue;
          expect(
            tester.getSize(text).height,
            lessThanOrEqualTo(13 * 1.3 + 0.5),
            reason: label,
          );
        }
      });
    }
  }
}
