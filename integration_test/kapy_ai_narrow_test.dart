// Kapy AI over a narrow page on the Mac: the whole app in a window 400 and
// 520 points wide, over notes kept in memory and a Kapy AI that answers from
// the test and never from a model or the network.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/kapy_ai_narrow_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The panel opens over the note from the page's sparkle. It checks that the
// panel sits inside the page with its margins, that nothing overflows, and
// that Esc closes it after a click on its header. Each width is a screenshot
// in build/screenshots, for a person to look at.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_panel.dart';
import 'package:material_ui/material_ui.dart';

import '../test/fake_kapy_ai.dart';
import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'kapy-ai-narrow-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const question = 'What is left on Call with Arjun?';
  const answer =
      'One task: send the deck this morning. The pricing page is due Friday.';

  for (final width in [400.0, 520.0]) {
    testWidgets('the panel over a page ${width.toInt()} wide', (tester) async {
      kapyAiAvailable = true;
      final ratio = tester.view.devicePixelRatio;
      tester.view.physicalSize = Size(width, 700) * ratio;
      addTearDown(tester.view.resetPhysicalSize);

      final asked = DateTime.now();
      final store = _MemoryStore();
      store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
      final notes = NotesStore(store);
      final tags = TagStore(store);
      final prefs = LayoutPrefs(store)..load();
      prefs.appearance = AppearanceMode.dark;
      await notes.load();
      await tags.load();
      notes.create(
        body:
            'Call with Arjun\n'
            'Acme renewal, 40 seats from January\n'
            '☐ Send the deck this morning\n'
            'Pricing page due Friday',
      );
      final ai = FakeKapyAi(pro: true)
        ..set(
          model: KapyModel.cloud,
          current: KapyChat(
            id: 'c',
            title: question,
            createdAt: asked,
            updatedAt: asked,
            model: KapyModel.cloud,
            messages: [
              KapyMessage(
                id: 'q',
                role: KapyRole.user,
                text: question,
                at: asked,
              ),
              KapyMessage(
                id: 'a',
                role: KapyRole.assistant,
                text: answer,
                at: asked,
                model: KapyModel.cloud,
              ),
            ],
          ),
        );

      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: offlineRates(store),
          prefs: prefs,
          shortcuts: ShortcutPrefs(store)..load(),
          tags: tags,
          kapyAi: ai,
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byKey(const ValueKey('page-kapy-ai')));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('kapy-ai-panel'));
      expect(panel, findsOneWidget);
      expect(tester.takeException(), isNull);
      final over = tester.getRect(panel);
      final page = tester.getRect(find.byType(KapyAiDock));
      expect(
        over.left >= page.left + 12 - 1 && over.right <= page.right - 12 + 1,
        isTrue,
        reason: 'the panel $over sits inside the page $page',
      );
      expect(find.textContaining(answer, findRichText: true), findsOneWidget);
      await screenshot('kapy-ai-narrow-${width.toInt()}-dark');

      await tester.tap(
        find.descendant(of: panel, matching: find.text('Kapy AI')).first,
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(panel, findsNothing, reason: 'Esc closes it');
    });
  }
}
