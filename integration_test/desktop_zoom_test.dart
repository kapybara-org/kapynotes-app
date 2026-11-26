// The whole-window zoom on a real Mac: the same window at 100% and at 150%,
// and the narrowest window at 150% with Settings open over it and scrolled
// to the Zoom row, as screenshots in build/screenshots.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/desktop_zoom_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The app draws a zoomed window as a screen of that much higher pixel
// density. The test binding stands in for the app's own, so the test sets
// the window's pixel ratio the way the zoom does, and the Mac renders the
// same pixels the zoom draws.
import 'dart:ui' show Offset, Size;

import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:window_manager/window_manager.dart';

import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'desktop-zoom-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the window at 100% and 150%, and the narrowest at 150%', (
    tester,
  ) async {
    await windowManager.ensureInitialized();
    await windowManager.setBounds(Offset.zero & const Size(1100, 640));
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final notes = NotesStore(store);
    final prefs = LayoutPrefs(store)..load();
    final shortcuts = ShortcutPrefs(store)..load();
    await notes.load();
    notes.create(body: 'Groceries\nMilk 2.40\nBread 3.10\nTotal');
    notes.create(body: 'Lisbon trip budget\nFlights 420 + hotel 380');
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: shortcuts,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final ratio = tester.view.devicePixelRatio;
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await screenshot('desktop-zoom-$name');
    }

    await shot('100');

    prefs.zoom = 1.5;
    tester.view.devicePixelRatio = ratio * 1.5;
    await shot('150');

    await windowManager.setBounds(
      Offset.zero & (LayoutPrefs.minimumWindowSize * 1.5),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await shot('150-narrow');

    await tester.tap(find.byKey(const ValueKey('rail-settings')));
    await shot('150-narrow-settings');
    expect(find.text('Appearance'), findsWidgets);

    await tester.ensureVisible(find.byKey(const ValueKey('zoom-setting')));
    await shot('150-narrow-settings-zoom-row');
    expect(find.text('150%'), findsOneWidget);
  });
}
