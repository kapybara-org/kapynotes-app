import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/app_logo.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

const _body = '''
Lisbon trip budget

Flights for two
flights = 412 eur
flights to usd

Hotel: 7 nights
nightly = 128 eur
nightly * 7

Food and getting around // rough guess
daily = 55 eur
daily * 7

total
total to usd''';

const _rates = <String, double>{'EUR': 0.861401, 'GBP': 0.738359};
final _goldenNow = DateTime(2026, 9, 1, 15, 38);

/// Renders the whole app at a fixed size for visual review.
///
/// Goldens depend on macOS system fonts (see [loadTestFonts]); regenerate
/// them on macOS with `flutter test --update-goldens`.
late LayoutPrefs goldenPrefs;

Future<void> pumpForGolden(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  bool withNote = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

  final store = MemoryStore();
  store.data['rates.v1'] = RateSnapshot(
    base: 'USD',
    date: '01 Sep 2026',
    fetchedAt: DateTime.now(),
    rates: _rates,
  ).toJson();

  final notes = NotesStore(store, now: () => _goldenNow);
  final prefs = LayoutPrefs(store);
  goldenPrefs = prefs;
  final rates = RatesRepository(store);
  final shortcuts = ShortcutPrefs(store)..load();

  await notes.load();
  prefs.load();
  if (withNote) {
    final note = notes.create();
    notes.updateBody(note.id, _body);
  }
  // Publish the cached rates without going near the network.
  await rates.initialize();

  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
    ),
  );
  await tester.runAsync(
    () => precacheImage(
      const AssetImage(AppLogo.assetPath),
      tester.element(find.byType(KapyNotesApp)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('desktop dark', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark.png'),
    );
  });

  testWidgets('desktop light', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.light,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_light.png'),
    );
  });

  testWidgets('desktop dark empty state', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withNote: false,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_empty.png'),
    );
  });

  testWidgets('desktop dark, sidebar collapsed', (tester) async {
    // The toolbar owns the window's left edge here, where macOS draws the
    // traffic lights over it.
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    goldenPrefs.toggleSidebar();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_collapsed.png'),
    );
  });

  testWidgets('desktop dark settings', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await tester.tap(find.byKey(const ValueKey('note-settings')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings.png'),
    );
  });

  testWidgets('phone editor', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_editor.png'),
    );
  });

  testWidgets('phone notes drawer', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
    );
    await tester.tap(find.byTooltip('Show notes'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_drawer.png'),
    );
  });
}
