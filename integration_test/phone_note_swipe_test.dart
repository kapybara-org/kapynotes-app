// Home's swipe on a note row, for KAPY-35 to hold against the boards "Home,
// swiping a note" and "Home, a note archived": the whole app over notes kept
// in memory, dark, with each state also read off the device's own screen.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_note_swipe_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The Phones workflow runs it through tool/ci/phone_screenshots.sh, and the
// device shots land as build/screenshots/swipe-open-row-device.png and
// swipe-archived-notice-device.png. No sheet or dialog opens under a held
// press here, so the test's pointer events stay its own.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/sidebar.dart' show NoteRow;
import 'package:material_ui/material_ui.dart';

import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-note-swipe-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Wed 19 Nov 2025, 9:41, the morning the boards draw.
final _now = DateTime(2025, 11, 19, 9, 41);

Map<String, Object?> _note(String id, String body, DateTime edited) => {
  'id': id,
  'body': body,
  'createdAt': edited.millisecondsSinceEpoch,
  'updatedAt': edited.millisecondsSinceEpoch,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("Home's note rows: a short swipe shows Pin and Delete, and a "
      'full one archives with Undo', (tester) async {
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    store.data['notes.v1'] = [
      _note(
        'morning',
        'Morning pages\nThe desk, the room, a walk',
        DateTime(2025, 11, 19, 9, 12),
      ),
      _note(
        'arjun',
        'Call with Arjun\nPricing page by Friday\n☐ Send the deck',
        DateTime(2025, 11, 19, 8, 55),
      ),
      _note(
        'quote',
        'Quote for the deck\n40 seats × 12 = 480 a month',
        DateTime(2025, 11, 19, 8, 20),
      ),
      _note(
        'reading',
        'Reading list\nThe Overstory, Piranesi',
        DateTime(2025, 11, 9, 20),
      ),
    ];
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = AppearanceMode.dark;
    final notes = NotesStore(store, now: () => _now);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => _now,
    );
    await notes.load();
    notes.togglePinned('reading');
    await library.reconcileNow();

    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tasks: library,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // A phone opens on a note's page; Home is under it.
    final home = find.byKey(const ValueKey('page-home'));
    if (home.evaluate().isNotEmpty) {
      await tester.tap(home);
      await tester.pumpAndSettle();
    }
    final row = find.widgetWithText(NoteRow, 'Morning pages');
    expect(row, findsOneWidget);

    await tester.drag(row, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('swipe-pin-morning')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('swipe-delete-morning')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await screenshot('swipe-open-row', device: true);

    await tester.drag(row, const Offset(200, 0));
    await tester.pumpAndSettle();
    await tester.drag(row, const Offset(-340, 0));
    await tester.pumpAndSettle();
    expect(notes.byId('morning')!.isArchived, isTrue);
    expect(row, findsNothing);
    expect(find.text('Archived “Morning pages”'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await screenshot('swipe-archived-notice', device: true);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(notes.byId('morning')!.isArchived, isFalse);
    expect(row, findsOneWidget);
  });
}
