import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/voice_consent_sheet.dart';
import 'package:material_ui/material_ui.dart';

void main() {
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

  testWidgets('names the model cloud summaries are sent to', (tester) async {
    await open(tester);
    expect(
      find.text(
        'Cloud summaries send the transcript text to MiniMax M3.1 Flash '
        'through OpenRouter.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('DeepSeek'), findsNothing);
  });

  testWidgets('fits a short window by scrolling, with both answers reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final result = await open(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

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
}
