import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/recaps/recap_story.dart';
import 'package:kapy_notes/ui/recaps/recap_story_view.dart';
import 'package:material_ui/material_ui.dart';

import 'recaps/recap_story_samples.dart';
import 'test_fonts.dart';

/// Every card of each kind of recap, side by side on phones the size of the
/// boards (Paper p-2-0), and one card of each in the desktop's frame over
/// the dimmed app, in dark and light.
void main() {
  setUpAll(loadTestFonts);

  final stories = <String, RecapStory Function()>{
    'day': sampleDay,
    'week': sampleWeek,
    'month': sampleMonth,
    'year': sampleYear,
  };

  final actions = RecapStoryActions(
    openNote: (_) {},
    play: (_) {},
    saveAsNote: (_) {},
    shareImage: (_, _) async {},
    onRemake: () {},
    remakeCredits: 0,
  );

  ThemeData theme(Brightness brightness) =>
      brightness == Brightness.dark ? KapyTheme.dark() : KapyTheme.light();

  /// Loads the pictures on screen, then lets each card's progress run to
  /// 45%, as the boards draw it.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    await tester.pump(const Duration(milliseconds: 3150));
  }

  for (final MapEntry(key: kind, value: sample) in stories.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('$kind recap, phone, ${brightness.name}', (tester) async {
        final story = sample();
        final count = story.cards.length;
        tester.view
          ..physicalSize = Size(393.0 * count, 852)
          ..devicePixelRatio = 1
          ..padding = const FakeViewPadding(top: 54, bottom: 34);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme(brightness),
            home: RepaintBoundary(
              key: const ValueKey('cards'),
              child: Row(
                children: [
                  for (var i = 0; i < count; i++)
                    SizedBox(
                      width: 393,
                      child: RecapStoryView(
                        story: story,
                        actions: actions,
                        desktop: false,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        for (var i = 1; i < count; i++) {
          for (var step = 0; step < i; step++) {
            await tester.tapAt(Offset(393.0 * i + 250, 160));
            await tester.pump(const Duration(milliseconds: 200));
          }
        }
        await settle(tester);
        await expectLater(
          find.byKey(const ValueKey('cards')),
          matchesGoldenFile(
            'goldens/recap_story_${kind}_${brightness.name}.png',
          ),
        );
      });

      testWidgets('$kind recap, desktop, ${brightness.name}', (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
        tester.view
          ..physicalSize = const Size(1440, 900)
          ..devicePixelRatio = 1;
        addTearDown(() {
          tester.view.reset();
          AppPlatform.debugTargetPlatformOverride = null;
        });
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme(brightness),
            home: Builder(
              builder: (context) => ColoredBox(
                color: context.palette.editorBackground,
                child: Center(
                  child: GestureDetector(
                    onTap: () => showRecapStory(
                      context,
                      story: sample(),
                      actions: actions,
                    ),
                    child: Text(
                      'My notes',
                      style: TextStyle(color: context.palette.textPrimary),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('My notes'));
        await tester.pump(const Duration(milliseconds: 200));
        for (var step = 0; step < (kind == 'day' ? 2 : 1); step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump(const Duration(milliseconds: 200));
        }
        await settle(tester);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/recap_story_${kind}_desktop_${brightness.name}.png',
          ),
        );
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }
  }
}
