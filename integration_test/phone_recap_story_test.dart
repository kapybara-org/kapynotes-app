// A day's recap on a real phone or simulator: it opens over a page, moves on
// by itself, steps on and back with taps, pauses while held and closes with a
// swipe down. Each card is a shot, dark and light.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_recap_story_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The viewer is opened from a bare page with the app's theme, over the
// board's sample day, so its cards are drawn without a recap being made.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/recaps/recap_story_view.dart';
import 'package:material_ui/material_ui.dart';

import '../test/recaps/recap_story_samples.dart';
import 'screenshot.dart';

const _eyebrows = [
  'Thursday, 19 November',
  'Your day in numbers',
  'Highlights',
  'Tasks',
  'From a voice note',
  'What’s next',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final brightness in Brightness.values) {
    testWidgets('a day recap steps through its cards, ${brightness.name}', (
      tester,
    ) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.dark
              ? KapyTheme.dark()
              : KapyTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showRecapStory(
                    context,
                    story: sampleDay(),
                    actions: RecapStoryActions(
                      openNote: opened.add,
                      play: (_) {},
                      saveAsNote: (_) {},
                      shareImage: (_, _) async {},
                      onRemake: () {},
                      remakeCredits: 0,
                    ),
                  ),
                  child: const Text('Open recap'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      bool showing(String text) => find.text(text).evaluate().isNotEmpty;
      Future<void> wait(int ms) async {
        await tester.pump();
        await tester.pump(Duration(milliseconds: ms));
      }

      Rect card() => tester.getRect(find.byType(RecapStoryView));
      Future<void> tapAt(double x) async {
        final rect = card();
        await tester.tapAt(
          Offset(rect.left + rect.width * x, rect.top + rect.height * 0.19),
        );
        await wait(600);
      }

      await tester.tap(find.text('Open recap'));
      await wait(600);
      expect(showing(_eyebrows.first), isTrue, reason: 'it opens on the cover');

      await tester.pump(const Duration(seconds: 8));
      await wait(600);
      expect(
        showing(_eyebrows[1]),
        isTrue,
        reason: 'the cover moves on by itself',
      );

      final hold = await tester.startGesture(card().center);
      await tester.pump(const Duration(seconds: 8));
      await wait(600);
      await hold.up();
      await wait(100);
      expect(showing(_eyebrows[1]), isTrue, reason: 'holding pauses it');

      await tapAt(0.1);
      expect(showing(_eyebrows.first), isTrue, reason: 'a tap on the left');

      for (final (index, eyebrow) in _eyebrows.indexed) {
        expect(showing(eyebrow), isTrue, reason: 'card ${index + 1}');
        await screenshot('recap-day-${index + 1}-${brightness.name}');
        if (index < _eyebrows.length - 1) await tapAt(0.8);
      }

      await tester.pump(const Duration(seconds: 8));
      await wait(600);
      expect(
        showing(_eyebrows.last),
        isTrue,
        reason: 'the last card stays until it is closed',
      );

      await tester.fling(
        find.byType(RecapStoryView),
        const Offset(0, 400),
        1500,
      );
      await tester.pumpAndSettle();
      expect(find.byType(RecapStoryView), findsNothing, reason: 'swiped away');
      expect(showing('Open recap'), isTrue);
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
