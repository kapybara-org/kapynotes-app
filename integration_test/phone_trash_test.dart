// Recently deleted on a phone (KAP-400), for KAPY-35's design check: the
// whole app over notes kept in memory, each state light and dark, and also
// read off the device's own screen.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_trash_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The Phones workflow runs it through tool/ci/phone_screenshots.sh: Delete's
// notice with Undo, Home's menu with Recently deleted and its count, the
// list, a row swiped to Put back and Delete now, a deleted note's page under
// its bar, and that page's more menu. No sheet or dialog opens under a held
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
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/sidebar.dart' show NoteRow;
import 'package:material_ui/material_ui.dart';

import 'rates_support.dart';
import 'screenshot.dart';
import 'sharing_support.dart' show pumpUntil, shown;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-trash-integration.json');

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

  testWidgets("Recently deleted on Home: Delete's notice, the menu's count, "
      'the list, its swipe, and a deleted page with Put back', (tester) async {
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
        'draft',
        'Draft for the team\nWeekly update, first pass',
        DateTime(2025, 11, 4, 18, 30),
      ),
      _note(
        'grocery',
        'Grocery list\nOats, lemons, coffee',
        DateTime(2025, 10, 28, 19),
      ),
    ];
    var clock = DateTime(2025, 10, 30, 8);
    final prefs = LayoutPrefs(store)..load();
    final notes = NotesStore(store, now: () => clock);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => _now,
    );
    await notes.load();
    notes.trashAll(['grocery']);
    clock = DateTime(2025, 11, 12, 17);
    notes.trashAll(['draft']);
    clock = _now;
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

    Future<void> shot(String name) async {
      for (final mode in [AppearanceMode.light, AppearanceMode.dark]) {
        prefs.appearance = mode;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: name);
        await screenshot('trash-$name-${mode.name}', device: true);
      }
    }

    Future<void> tap(Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Finder row(String title) => find.widgetWithText(NoteRow, title);

    // A phone opens on a note's page; Home is under it.
    final home = find.byKey(const ValueKey('page-home'));
    if (home.evaluate().isNotEmpty) await tap(home);
    expect(row('Call with Arjun'), findsOneWidget);
    expect(row('Grocery list'), findsNothing);

    // Delete moves the note to Recently deleted, with Undo on its notice. It
    // runs once in each look, so each notice is shot before it goes, and
    // Undo brings the note back between them.
    final moved = find.text('Moved to Recently deleted');
    for (final mode in [AppearanceMode.light, AppearanceMode.dark]) {
      prefs.appearance = mode;
      await tester.pumpAndSettle();
      await tester.drag(row('Call with Arjun'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tap(find.byKey(const ValueKey('swipe-delete-arjun')));
      expect(find.text('Delete note?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await pumpUntil(tester, () => shown(tester, moved));
      expect(row('Call with Arjun'), findsNothing);
      expect(notes.byId('arjun')!.isTrashed, isTrue);
      await screenshot('trash-moved-notice-${mode.name}', device: true);
      if (mode == AppearanceMode.light) {
        await tester.tap(find.text('Undo').last);
        await pumpUntil(
          tester,
          () => row('Call with Arjun').evaluate().isNotEmpty,
        );
        expect(notes.byId('arjun')!.isTrashed, isFalse);
      }
    }
    await pumpUntil(tester, () => moved.evaluate().isEmpty);
    await tester.pumpAndSettle();

    await tap(find.byKey(const ValueKey('phone-filters')));
    await tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    final trash = find.byKey(ValueKey('notes-filter-${NotesShow.trash.name}'));
    expect(
      find.descendant(of: trash, matching: find.text('3')),
      findsOneWidget,
    );
    await shot('home-menu');

    await tap(trash);
    expect(row('Grocery list'), findsOneWidget);
    expect(row('Draft for the team'), findsOneWidget);
    expect(row('Call with Arjun'), findsOneWidget);
    expect(row('Morning pages'), findsNothing);
    await shot('list');

    await tester.drag(row('Grocery list'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('swipe-delete-grocery')), findsOneWidget);
    await shot('swipe');
    await tester.drag(row('Grocery list'), const Offset(120, 0));
    await tester.pumpAndSettle();

    await tap(row('Draft for the team'));
    expect(find.byKey(const ValueKey('trashed-note-bar')), findsOneWidget);
    await shot('page');

    await tap(find.byKey(const ValueKey('page-more')));
    expect(find.byKey(const ValueKey('page-more-put-back')), findsOneWidget);
    expect(find.text('Delete now…'), findsOneWidget);
    await shot('page-menu');
    await tap(find.byKey(const ValueKey('page-more-put-back')));
    expect(notes.byId('draft')!.isTrashed, isFalse);
    expect(tester.takeException(), isNull);
  });
}
