// Android's bar over three-button navigation, on a real Android phone: the
// pill and its + sit just clear of the system's buttons (M01).
//
//   adb shell cmd overlay enable-exclusive --category \
//     com.android.internal.systemui.navbar.threebutton
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_bar_android_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// tool/ci/phone_screenshots.sh switches an emulator to three buttons for this
// run alone and back afterwards. The shot is taken dark, and with the device's
// own screen, so the system's buttons are in it.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:material_ui/material_ui.dart';

import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-bar-android-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the pill clears three-button navigation, dark', (tester) async {
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final notes = NotesStore(store);
    final prefs = LayoutPrefs(store)..load();
    await notes.load();
    notes.create(body: 'Groceries\nOat milk, lemons');
    notes.create(body: 'Call with Arjun\nSend the deck');
    prefs.appearance = AppearanceMode.dark;

    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final back = find.byKey(const ValueKey('page-back'));
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
      await tester.pumpAndSettle();
    }

    final view = tester.view;
    final screen = view.physicalSize / view.devicePixelRatio;
    final inset = view.viewPadding.bottom / view.devicePixelRatio;
    final bar = tester.getRect(find.byKey(const ValueKey('phone-bar')));
    final plus = tester.getRect(find.byKey(const ValueKey('phone-new')));
    expect(screen.height - bar.bottom, greaterThanOrEqualTo(inset + 8));
    expect(screen.height - plus.bottom, greaterThanOrEqualTo(inset + 8));
    expect(tester.takeException(), isNull);
    await screenshot('phone-bar-android-3button-dark', device: true);
  });
}
