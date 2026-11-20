import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/voice_consent_sheet.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  Future<Future<bool>> open(WidgetTester tester) async {
    late Future<bool> result;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showSpeechConsentSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('says what leaves the device, without naming a provider', (
    tester,
  ) async {
    await open(tester);
    expect(
      find.textContaining(
        'sends the audio to Kapy cloud. The audio is not kept, and it is '
        'never used to train AI.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('never used to train AI.'), findsNWidgets(2));
    expect(find.textContaining('OpenRouter'), findsNothing);
    expect(find.textContaining('MiniMax'), findsNothing);
    expect(find.textContaining('NVIDIA'), findsNothing);
    expect(find.textContaining('Settings › Voice & AI'), findsOneWidget);
    expect(find.textContaining('Version'), findsNothing);
  });

  for (final (name, size) in [
    ('desktop', Size(1280, 800)),
    ('phone portrait', Size(390, 844)),
    ('phone landscape', Size(844, 390)),
  ]) {
    testWidgets('fits a $name window, with both answers reachable', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final result = await open(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Turn on'));
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
    });
  }

  testWidgets('turning on and declining are answered as such', (tester) async {
    var result = await open(tester);
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);

    result = await open(tester);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('the sheet, light', (tester) async {
    tester.view.physicalSize = const Size(640, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    await expectLater(
      find.byType(AlertDialog),
      matchesGoldenFile('goldens/speech_consent_light.png'),
    );
  });
}
