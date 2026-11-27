// The voice note window on a phone, as the sheet its chip opens: the
// Summary page with the clock-only Earlier and the starters in dark and
// light, the transcript, the More sheet, Earlier, a post opened from
// Earlier, the ask bar with the keyboard up, and the card a question waits
// at before the first answer. tool/ci/phone_screenshots.sh runs it on each
// phone and keeps every screenshot.
//
// Nothing is signed in and no request leaves the phone: Kapy AI runs on Pro
// with nothing agreed to, so the question stops at that card.
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
    await tester.tap(
      find.descendant(
        of: find.byType(NoteVoiceChip),
        matching: find.text(voiceTitle),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(
      find.descendant(of: _window, matching: find.text(voiceTitle)),
      findsOneWidget,
    );
    expect(find.text('Ask about this recording'), findsOneWidget);
    // On a sheet Earlier is the clock alone, a 44 pt target with its name
    // for a screen reader.
    expect(
      find.descendant(of: _starters, matching: find.text('Earlier')),
      findsNothing,
    );
    expect(tester.getSize(_earlier), const Size(44, 44));
    expect(
      find.descendant(of: _starters, matching: find.byTooltip('Earlier')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    return seed;
  }

  testWidgets('the sheet, light', (tester) async {
    await open(tester, AppearanceMode.light);
    await screenshot('phone-voice-window-summary-light', device: true);
  });

  testWidgets('the sheet, dark', (tester) async {
    final seed = await open(tester, AppearanceMode.dark);
    await screenshot('phone-voice-window-summary-dark', device: true);
    for (final label in voiceStarters) {
      await tester.dragUntilVisible(
        find.descendant(of: _starters, matching: find.text(label)),
        _starters,
        const Offset(-120, 0),
      );
    }
    await tester.dragUntilVisible(_earlier, _starters, const Offset(120, 0));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _window, matching: find.text('Transcript')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Finance said the first one'), findsOneWidget);
    await screenshot('phone-voice-window-transcript-dark');
    await tester.tap(
      find.descendant(of: _window, matching: find.text('Summary')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _window, matching: find.byTooltip('More')),
    );
    await tester.pumpAndSettle();
    final rename = find.byKey(const ValueKey('voice-more-rename'));
    expect(rename, findsOneWidget);
    await screenshot('phone-voice-window-more-dark', device: true);
    Navigator.of(tester.element(rename)).pop();
    await tester.pumpAndSettle();
    expect(_window, findsOneWidget);

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
    await screenshot('phone-voice-window-earlier-dark');

    await tester.tap(xPost);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _drawer, matching: find.text(xPostHeading)),
      findsOneWidget,
    );
    expect(find.text(xPostText), findsOneWidget);
    // In the drawer's header Earlier keeps its name.
    expect(
      find.descendant(
        of: find.descendant(of: _drawer, matching: _earlier),
        matching: find.text('Earlier'),
      ),
      findsOneWidget,
    );
    for (final key in [
      'voice-ask-insert',
      'voice-ask-copy',
      'voice-ask-again',
      'voice-ask-remove',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    await screenshot('phone-voice-window-x-post-dark');
    await tester.tap(find.byKey(const ValueKey('voice-ask-fold')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('voice-ask-field')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await screenshot('phone-voice-window-keyboard-dark', device: true);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle(const Duration(seconds: 1));

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
    await screenshot('phone-voice-window-consent-dark', device: true);
  });
}
