// Kapy AI's tab in the whole app on a real phone or simulator, over notes
// kept in memory, with a Kapy AI that never reaches a model or the network:
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_keyboard_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Search chats is tapped, so the keyboard comes up over the bar, and a tap on
// the empty page puts it away so the bar takes a tap again (KAP-337). On this
// tab the + starts a new chat in Kapy AI's sheet, ready to type in, and held
// it still offers the rest of New (KAP-397). Each state is a shot, the
// keyboard included where tool/ci/phone_screenshots.sh names the device.
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
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The app in [mode] on Kapy AI's tab, with no chats yet.
  Future<FakeKapyAi> openKapyAi(
    WidgetTester tester,
    AppearanceMode mode,
  ) async {
    kapyAiAvailable = true;
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final notes = NotesStore(store);
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = mode;
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
    final back = find.byKey(const ValueKey('page-home'));
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('bar-kapyAi')));
    await tester.pumpAndSettle();
    expect(find.text('No chats yet'), findsOneWidget);
    return ai;
  }

  /// Pumps frames until [ready], and fails naming [what] if it never is.
  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String what,
  ) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready(), isTrue, reason: 'waited 10 s for $what');
    await tester.pumpAndSettle();
  }

  bool focused(WidgetTester tester, Finder field) => tester
      .widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .focusNode
      .hasFocus;

  testWidgets('a tap on Kapy AI’s empty page puts the keyboard away', (
    tester,
  ) async {
    await openKapyAi(tester, AppearanceMode.dark);
    final search = find.byKey(const ValueKey('kapy-ai-page-search'));
    final chats = find.byKey(const ValueKey('kapy-ai-page-chats'));

    await tester.tap(search);
    await until(
      tester,
      () => tester.view.viewInsets.bottom > 0,
      'the keyboard',
    );
    expect(focused(tester, search), isTrue);
    await screenshot('kapy-ai-page-keyboard-up', device: true);

    await tester.tapAt(tester.getTopLeft(chats) + const Offset(20, 20));
    await until(
      tester,
      () => tester.view.viewInsets.bottom == 0,
      'the keyboard to go down',
    );
    expect(focused(tester, search), isFalse);
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

  for (final mode in [AppearanceMode.dark, AppearanceMode.light]) {
    testWidgets('on Kapy AI, the + starts a chat ready to type in, and held '
        'it offers the rest, ${mode.name}', (tester) async {
      final ai = await openKapyAi(tester, mode);
      final plus = find.byKey(const ValueKey('phone-new'));

      // The menu's route cancels the press it opens under, and the live
      // binding hands that cancel to its finder printer unless device
      // pointer events reach the app.
      binding.shouldPropagateDevicePointerEvents = true;
      addTearDown(() => binding.shouldPropagateDevicePointerEvents = false);
      await tester.longPress(plus);
      await tester.pumpAndSettle();
      for (final made in ['note', 'drawing']) {
        expect(find.byKey(ValueKey('phone-new-$made')), findsOneWidget);
      }
      await screenshot('kapy-ai-plus-menu-${mode.name}');
      await tester.tap(find.byKey(const ValueKey('phone-new-close')));
      await tester.pumpAndSettle();
      binding.shouldPropagateDevicePointerEvents = false;

      ai.calls.clear();
      await tester.tap(plus);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(ai.calls, ['newChat']);
      expect(find.byKey(const ValueKey('kapy-ai-sheet')), findsOneWidget);
      // A device with a hardware keyboard attached raises no software one,
      // so this reads the field's focus rather than viewInsets.
      expect(
        focused(tester, find.byKey(const ValueKey('kapy-ai-field'))),
        isTrue,
        reason: 'a new chat opens ready to type in',
      );
      expect(tester.takeException(), isNull);
      await screenshot('kapy-ai-plus-sheet-${mode.name}', device: true);
    });
  }
}
