// A day's notes as tabs on a real Mac, for KAPY-35 to hold beside the phone
// shots in kapynotes-app#348: Fri 17 Oct 2025, the crowded day
// integration_test/phone_note_page_test.dart seeds, picked in the page's
// week with #342's tabs, at the boards' 1440 × 900, dark and light.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/day_tabs_mac_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/day_tabs.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart' show NoteEditor;
import 'package:kapy_notes/ui/editor/note_field.dart' show NoteField;
import 'package:kapy_notes/ui/note_tabs.dart' show NoteTabRow;
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'day-tabs-mac-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Wed 19 Nov 2025, 9:41, as the phone shots have it.
final _now = DateTime(2025, 11, 19, 9, 41);

Map<String, Object?> _note(String id, String body, DateTime edited) => {
  'id': id,
  'body': body,
  'createdAt': edited.millisecondsSinceEpoch,
  'updatedAt': edited.millisecondsSinceEpoch,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("Fri 17 Oct's seven notes open as the page's tabs, the "
      'earliest written first', (tester) async {
    const size = Size(1440, 900);
    if (AppPlatform.isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.setBounds(Offset.zero & size);
    }
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    store.data['notes.v1'] = [
      _note(
        'arjun',
        'Call with Arjun\nPricing page by Friday.',
        DateTime(2025, 11, 19, 8, 55),
      ),
      for (final (id, body, hour, minute) in [
        ('run', 'Morning run\n5 km by the river', 6, 45),
        ('standup', 'Standup\nDemo on Monday', 9, 0),
        ('design', 'Design review\nThe tabs on a phone', 10, 30),
        ('lunch', 'Lunch with Maya\nThe new place on Rua Augusta', 12, 15),
        ('invoices', 'Invoices\nOctober for Acme', 14, 0),
        ('reading', 'Reading list\nThe Overstory', 16, 40),
        ('dinner', 'Dinner plan\nPasta and a salad', 19, 20),
      ])
        _note('oct-$id', body, DateTime(2025, 10, 17, hour, minute)),
    ];
    final prefs = LayoutPrefs(store)..load();
    final notes = NotesStore(store, now: () => _now);
    final tags = TagStore(store, now: () => _now);
    final folders = FolderStore(store, now: () => _now);
    final days = NoteDayStore(store, now: () => _now);
    final dayTabs = DayTabsStore(store, now: () => _now);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => _now,
    );
    await notes.load();
    await tags.load();
    await folders.load();
    await days.load();
    await dayTabs.load();
    await library.reconcileNow();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    prefs.appearance = AppearanceMode.dark;
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: tags,
        folders: folders,
        days: days,
        dayTabs: dayTabs,
        tasks: library,
      ),
    );
    // The runner's screen is smaller than the boards' window, so the view is
    // held at their size: the shot draws the app's layers, not the screen.
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // One mouse for every click, which then leaves the week, so the picked
    // day's tooltip covers no tab in the shots.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(900, 600));
    addTearDown(mouse.removePointer);
    Future<void> click(Finder target) async {
      final at = tester.getCenter(target);
      await mouse.moveTo(at);
      await mouse.down(at);
      await mouse.up();
      await tester.pumpAndSettle();
    }

    String openNote() => tester
        .widget<NoteField>(
          find.descendant(
            of: find.byType(NoteEditor),
            matching: find.byType(NoteField),
          ),
        )
        .controller
        .text;

    expect(openNote(), startsWith('Call with Arjun\n'));
    for (var week = 0; week < 5; week++) {
      await click(find.byKey(const ValueKey('day-strip-back')));
    }
    await click(find.byKey(const ValueKey('day-strip-2025-10-17')));
    final titles = [
      for (final tab in tester.widget<NoteTabRow>(find.byType(NoteTabRow)).tabs)
        tab.title,
    ];
    expect(titles, [
      'Morning run',
      'Standup',
      'Design review',
      'Lunch with Maya',
      'Invoices',
      'Reading list',
      'Dinner plan',
    ]);
    expect(openNote(), startsWith('Morning run\n'));
    await mouse.moveTo(const Offset(900, 600));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    for (final mode in [AppearanceMode.dark, AppearanceMode.light]) {
      prefs.appearance = mode;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: mode.name);
      await screenshot('day-tabs-oct-17-${mode.name}');
    }
  });
}
