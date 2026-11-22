// Kapy AI as a sheet over a note (M10) on a real phone or simulator: the
// whole app over notes kept in memory, with a Kapy AI that answers from the
// test and never from a model or the network.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/kapy_ai_sheet_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Call with Arjun is opened from Notes, and its sparkle pulls Kapy AI up as
// a sheet resting over the note, with the note's header and title still in
// view. A question is typed and sent, the answer lands once the sheet says it
// is reading, and with the keyboard down the shot is taken dark, at 1× and 2×
// text, with the sheet back at its rest and the answer on screen. Each is a
// screenshot in build/screenshots, and a device shot where
// tool/ci/phone_screenshots.sh names the device.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_panel.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import '../test/fake_kapy_ai.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'kapy-ai-sheet-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const question = 'What is left on this note?';
  const answer =
      'One task: send the deck this morning. The pricing page is due Friday.';

  for (final scale in [1.0, 2.0]) {
    testWidgets('a note with the sheet up and an answer at ${scale}x text', (
      tester,
    ) async {
      kapyAiAvailable = true;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final today = DateTime.now();
      final asked = DateTime(today.year, today.month, today.day, 9, 41);
      var clock = DateTime(today.year, today.month, today.day, 8, 55);
      final store = _MemoryStore();
      store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
      final notes = NotesStore(store, now: () => clock);
      final tags = TagStore(store);
      final prefs = LayoutPrefs(store)..load();
      prefs.appearance = AppearanceMode.dark;
      await notes.load();
      await tags.load();
      final call = notes.create(
        body:
            'Call with Arjun\n'
            'Acme renewal, 40 seats from January\n'
            '☑ Share the new seat count\n'
            '☐ Send the deck this morning\n'
            'Pricing page due Friday',
      );
      for (final name in ['Work', 'Acme']) {
        tags.addTag(call.id, tags.create(name)!.id);
      }
      clock = asked;

      final ai = FakeKapyAi(pro: true)..set(model: KapyModel.cloud);
      KapyChat chat(List<KapyMessage> messages) => KapyChat(
        id: 'm10',
        title: question,
        createdAt: asked,
        updatedAt: asked,
        model: KapyModel.cloud,
        messages: messages,
      );
      final questionMessage = KapyMessage(
        id: 'q',
        role: KapyRole.user,
        text: question,
        at: asked,
      );

      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: RatesRepository(store),
          prefs: prefs,
          shortcuts: ShortcutPrefs(store)..load(),
          tags: tags,
          kapyAi: ai,
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      /// Pumps frames until [ready], and fails naming [what] if it never is.
      Future<void> until(bool Function() ready, String what) async {
        for (var i = 0; i < 100 && !ready(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: 'waited 10 s for $what');
        await tester.pumpAndSettle();
      }

      final back = find.byKey(const ValueKey('page-home'));
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.widgetWithText(NoteRow, 'Call with Arjun'));
      await tester.pumpAndSettle();
      final sparkle = find.byKey(const ValueKey('page-kapy-ai'));
      await until(() => sparkle.evaluate().isNotEmpty, 'the note’s Kapy AI');

      // The sheet's route cancels the press it opens under, and the live
      // binding hands that cancel to its finder printer unless device pointer
      // events reach the app.
      binding.shouldPropagateDevicePointerEvents = true;
      addTearDown(() => binding.shouldPropagateDevicePointerEvents = false);
      await tester.tap(sparkle);
      final panel = find.byKey(const ValueKey('kapy-ai-panel'));
      await until(() => panel.evaluate().isNotEmpty, 'the Kapy AI sheet');
      binding.shouldPropagateDevicePointerEvents = false;
      expect(
        find.text('About Call with Arjun'),
        findsOneWidget,
        reason: 'the sheet asks about the note it was opened from',
      );
      final sheet = find.byKey(const ValueKey('kapy-ai-sheet'));
      final rest =
          tester.view.physicalSize.height /
          tester.view.devicePixelRatio *
          (1 - kapyAiSheetRest);
      bool resting() => (tester.getRect(sheet).top - rest).abs() < 1;
      expect(resting(), isTrue, reason: 'the sheet rests over the note');

      final field = find.byKey(const ValueKey('kapy-ai-field'));
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, question);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('kapy-ai-send')));
      await tester.pumpAndSettle();
      expect(ai.calls.last, 'ask:$question:${call.id}');

      ai.set(current: chat([questionMessage]));
      final thinking = find.byKey(const ValueKey('kapy-ai-thinking'));
      await until(() => thinking.evaluate().isNotEmpty, 'Reading your notes…');

      ai.set(
        current: chat([
          questionMessage,
          KapyMessage(
            id: 'a',
            role: KapyRole.assistant,
            text: answer,
            at: asked,
            model: KapyModel.cloud,
          ),
        ]),
        answering: false,
      );
      final answerText = find.textContaining(answer, findRichText: true);
      await until(
        () => answerText.evaluate().isNotEmpty && thinking.evaluate().isEmpty,
        'the answer',
      );

      FocusManager.instance.primaryFocus?.unfocus();
      await until(
        () => tester.view.viewInsets.bottom == 0 && resting(),
        'the keyboard to go down and the sheet to rest over the note',
      );

      expect(answerText, findsOneWidget);
      final over = tester.getRect(sheet);
      final shown = tester.getRect(answerText);
      final composer = tester.getRect(field);
      expect(
        shown.top >= over.top && shown.bottom <= composer.top,
        isTrue,
        reason:
            'the answer $shown is on screen, inside $over and above $composer',
      );
      expect(
        tester.getRect(find.byType(NoteField)).top,
        lessThan(over.top),
        reason: 'the note stays in view above the sheet',
      );
      expect(find.textContaining(question), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot(
        'kapy-ai-sheet-${scale.toInt()}x-answer-dark',
        device: true,
      );
    });
  }
}
