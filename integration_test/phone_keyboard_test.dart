// A phone's keyboard on Kapy AI's page (KAP-337), on a real phone or
// simulator: the whole app over notes kept in memory, with a Kapy AI that
// never reaches a model or the network.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_keyboard_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Kapy AI is opened from the bar and Ask Kapy AI is tapped, so the keyboard
// comes up over the bar. A tap on the empty page above it puts the keyboard
// away, and the bar takes a tap again. Both states are device shots, the
// keyboard included, where tool/ci/phone_screenshots.sh names the device.
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
import 'package:material_ui/material_ui.dart';

import '../test/fake_kapy_ai.dart';
import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-keyboard-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a tap on Kapy AI’s empty page puts the keyboard away', (
    tester,
  ) async {
    kapyAiAvailable = true;
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final notes = NotesStore(store);
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = AppearanceMode.dark;
    await notes.load();
    notes.create(body: 'Call with Arjun\nSend the deck this morning');
    final ai = FakeKapyAi(pro: true)..set(model: KapyModel.cloud);

    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
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
    await tester.tap(find.byKey(const ValueKey('bar-kapyAi')));
    await tester.pumpAndSettle();
    expect(find.text('No chats yet'), findsOneWidget);

    final field = find.byKey(const ValueKey('kapy-ai-page-field'));
    bool focused() => tester
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .focusNode
        .hasFocus;
    await tester.tap(field);
    await until(() => tester.view.viewInsets.bottom > 0, 'the keyboard');
    expect(focused(), isTrue);
    await screenshot('kapy-ai-page-keyboard-up', device: true);

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('kapy-ai-page-chats'))),
    );
    await until(
      () => tester.view.viewInsets.bottom == 0,
      'the keyboard to go down',
    );
    expect(focused(), isFalse);
    expect(tester.takeException(), isNull);
    await screenshot('kapy-ai-page-keyboard-closed', device: true);

    await tester.tap(find.byKey(const ValueKey('bar-notes')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('kapy-ai-page')),
      findsNothing,
      reason: 'the bar takes a tap again',
    );
  });
}
