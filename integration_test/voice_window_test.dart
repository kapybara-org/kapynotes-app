// The voice note window on the Mac, opened from its chip in a note: the
// Summary page with Earlier and the starters in dark and light, the
// transcript, the More menu, Earlier, a post opened from Earlier, and the
// card a question waits at before the first answer. Each is a screenshot in
// build/screenshots for a reviewer to look at:
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/voice_window_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Nothing is signed in and no request leaves the machine: Kapy AI runs on
// Pro with nothing agreed to, so the question stops at that card.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:kapy_notes/ui/voice_note_dialog.dart';
import 'package:material_ui/material_ui.dart';

import 'rates_support.dart';
import 'screenshot.dart';
import 'voice_window_support.dart';

final _window = find.byType(VoiceNoteView);
final _starters = find.byKey(const ValueKey('voice-ask-starters'));
final _drawer = find.byKey(const ValueKey('voice-ask-drawer'));
final _earlier = find.byKey(const ValueKey('voice-ask-earlier'));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  kapyAiAvailable = true;

  Future<VoiceWindowSeed> open(
    WidgetTester tester,
    AppearanceMode appearance,
  ) async {
    final seed = await VoiceWindowSeed.create(appearance);
    addTearDown(seed.kapyAi.dispose);
    await tester.pumpWidget(
      KapyNotesApp(
        store: seed.store,
        notes: seed.notes,
        rates: offlineRates(seed.store),
        prefs: seed.prefs,
        shortcuts: ShortcutPrefs(seed.store)..load(),
        kapyAi: seed.kapyAi,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.byType(NoteVoiceChip));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(
      find.descendant(of: _window, matching: find.text(voiceTitle)),
      findsOneWidget,
    );
    expect(find.text('Ask about this recording'), findsOneWidget);
    expect(
      find.descendant(of: _earlier, matching: find.text('Earlier')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    return seed;
  }

  /// Every starter, in order, scrolled to where needed and back to the start.
  Future<void> checkStarters(WidgetTester tester) async {
    for (final label in voiceStarters) {
      await tester.dragUntilVisible(
        find.descendant(of: _starters, matching: find.text(label)),
        _starters,
        const Offset(-120, 0),
      );
    }
    await tester.dragUntilVisible(_earlier, _starters, const Offset(120, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('the window, light', (tester) async {
    await open(tester, AppearanceMode.light);
    await screenshot('voice-window-summary-light');
  });

  testWidgets('the window, dark', (tester) async {
    final seed = await open(tester, AppearanceMode.dark);
    await screenshot('voice-window-summary-dark');
    await checkStarters(tester);

    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Finance said the first one'), findsOneWidget);
    await screenshot('voice-window-transcript-dark');
    await tester.tap(find.text('Summary'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _window, matching: find.byTooltip('More')),
    );
    await tester.pumpAndSettle();
    final rename = find.byKey(const ValueKey('voice-more-rename'));
    expect(rename, findsOneWidget);
    await screenshot('voice-window-more-dark');
    Navigator.of(tester.element(rename)).pop();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _window, matching: find.text(voiceTitle)),
      findsOneWidget,
    );

    await tester.tap(_earlier);
    await tester.pumpAndSettle();
    final ownWords = find.descendant(
      of: _drawer,
      matching: find.text(ownWordsInstruction),
    );
    final xPost = find.descendant(
      of: _drawer,
      matching: find.text(xPostHeading),
    );
    expect(ownWords, findsOneWidget);
    expect(xPost, findsOneWidget);
    expect(
      tester.getTopLeft(ownWords).dy,
      lessThan(tester.getTopLeft(xPost).dy),
      reason: 'newest first',
    );
    await screenshot('voice-window-earlier-dark');

    await tester.tap(xPost);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _drawer, matching: find.text(xPostHeading)),
      findsOneWidget,
    );
    expect(find.text(xPostText), findsOneWidget);
    for (final key in [
      'voice-ask-insert',
      'voice-ask-copy',
      'voice-ask-again',
      'voice-ask-remove',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    await screenshot('voice-window-x-post-dark');
    await tester.tap(find.byKey(const ValueKey('voice-ask-fold')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _starters, matching: find.text(voiceStarters.first)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('Before the first answer'), findsOneWidget);
    expect(find.text(recordingConsent), findsOneWidget);
    expect(find.text('Go ahead'), findsOneWidget);
    expect(seed.kapyAi.pending, isA<KapyCloudConsent>());
    expect(seed.answers, isEmpty, reason: 'nothing leaves before Go ahead');
    expect(tester.takeException(), isNull);
    await screenshot('voice-window-consent-dark');
  });
}
