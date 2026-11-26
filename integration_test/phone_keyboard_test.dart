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
// Ask Kapy AI sits 12 above the keyboard while it's up and 12 above the bar
// once it's down, typed in or not (KAP-343).
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
import 'keyboard_support.dart';
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
    double above(double top) =>
        top -
        tester
            .getRect(
              find.ancestor(of: field, matching: find.byType(Container)).first,
            )
            .bottom;
    double keyboard() =>
        (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
        tester.view.devicePixelRatio;
    double bar() => tester.getRect(find.byKey(const ValueKey('phone-bar'))).top;
    final chats = find.byKey(const ValueKey('kapy-ai-page-chats'));

    await tester.tap(field);
    await settleKeyboard(tester, up: true);
    expect(focused(), isTrue);
    await until(
      () => (above(keyboard()) - 12).abs() < 1,
      'Ask Kapy AI 12 above the keyboard',
    );
    await screenshot('kapy-ai-page-keyboard-up', device: true);

    await tester.tapAt(tester.getCenter(chats));
    await settleKeyboard(tester, up: false);
    expect(focused(), isFalse);
    expect(tester.takeException(), isNull);
    expect(above(bar()), moreOrLessEquals(12, epsilon: 1));
    await screenshot('kapy-ai-page-keyboard-closed', device: true);

    await tester.tap(field);
    await settleKeyboard(tester, up: true);
    tester.widget<TextField>(field).controller!.text = 'What is left';
    await until(
      () => (above(keyboard()) - 12).abs() < 1,
      'Ask Kapy AI 12 above the keyboard, typed in',
    );
    await tester.tapAt(tester.getCenter(chats));
    await settleKeyboard(tester, up: false);
    expect(
      above(bar()),
      moreOrLessEquals(12, epsilon: 1),
      reason: 'typed in, then put away',
    );

    await tester.tap(find.byKey(const ValueKey('bar-notes')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('kapy-ai-page')),
      findsNothing,
      reason: 'the bar takes a tap again',
    );
  });
}
