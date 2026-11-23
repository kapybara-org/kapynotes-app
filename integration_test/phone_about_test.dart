// About & updates on a real phone, on the store's two answers, faked so the
// shots never depend on what either store sells today: nothing newer than
// the 1.35.4 this phone runs, and 1.35.5 waiting (1E0B-0).
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_about_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The store's button is left alone: it leaves the app for the store.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/store_updates.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/store_updates.dart';
import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-about-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  for (final waiting in [false, true]) {
    final state = waiting ? 'update' : 'latest';
    testWidgets('About & updates, $state, dark', (tester) async {
      final store = _MemoryStore();
      store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
      final notes = NotesStore(store);
      final prefs = LayoutPrefs(store)..load();
      await notes.load();
      notes.create(body: 'Groceries\nOat milk, lemons');
      prefs.appearance = AppearanceMode.dark;
      final play = AppPlatform.isAndroid;

      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: offlineRates(store),
          prefs: prefs,
          shortcuts: ShortcutPrefs(store)..load(),
          storeUpdates: fakeStoreUpdates(
            _MemoryStore(),
            releases: aboutReleases(),
            answer: () async => play
                ? StoreOffer(build: waiting ? 47 : 46)
                : StoreOffer(version: waiting ? '1.35.5' : '1.35.4'),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      final home = find.byKey(const ValueKey('page-home'));
      if (home.evaluate().isNotEmpty) {
        await tester.tap(home);
        await tester.pumpAndSettle();
      }

      await tap(tester, 'phone-account');
      final marked = find.descendant(
        of: find.byKey(const ValueKey('settings-section-about')),
        matching: find.text('Update available'),
      );
      expect(marked, waiting ? findsOneWidget : findsNothing);
      await screenshot('phone-about-$state-list');

      await tap(tester, 'settings-section-about');
      expect(
        find.text(
          waiting
              ? 'Version 1.35.5 is out'
              : '23 Nov 2026 · You have the latest version',
        ),
        findsOneWidget,
      );
      expect(
        find.text(play ? 'Update on Google Play' : 'Update on the App Store'),
        waiting ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      await screenshot('phone-about-$state', device: true);

      await tap(tester, 'settings-sheet-back');
      expect(marked, findsNothing, reason: 'seen once it is opened');
    });
  }
}
