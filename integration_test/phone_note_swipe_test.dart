// Home's swipe on a note row, for KAPY-35 to hold against the boards "Home,
// swiping a note" and "Home, a note archived", and its Delete with Undo: the
// whole app over notes kept in memory, dark, with each state also read off
// the device's own screen.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_note_swipe_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The Phones workflow runs it through tool/ci/phone_screenshots.sh, and the
// device shots land as build/screenshots/swipe-open-row-device.png,
// swipe-archived-notice-device.png and swipe-deleted-notice-device.png. No
// sheet or dialog opens under a held press here, so the test's pointer events
// stay its own.
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
    // On a device a toast's lifetime is an animation, so pumpAndSettle
    // would run the notice out; this pumps on the real clock instead, until
    // the notice has faded all the way in.
    final notice = find.text('Archived “Morning pages”');
    await tester.drag(row, const Offset(-340, 0));
    await pumpUntil(tester, () => shown(tester, notice));
    expect(notes.byId('morning')!.isArchived, isTrue);
    expect(row, findsNothing);
    expect(notice, findsOneWidget);
    expect(shown(tester, notice), isTrue);
    expect(tester.takeException(), isNull);
    await screenshot('swipe-archived-notice', device: true);

    // The device shot may outlast the notice, so Undo is checked on a
    // second archive, tapped as soon as its notice shows.
    final quote = find.widgetWithText(NoteRow, 'Quote for the deck');
    final undo = find.text('Undo');
    await tester.drag(quote, const Offset(-340, 0));
    await pumpUntil(
      tester,
      () => shown(tester, find.text('Archived “Quote for the deck”')),
    );
    expect(notes.byId('quote')!.isArchived, isTrue);
    await tester.tap(undo.last);
    await pumpUntil(tester, () => quote.evaluate().isNotEmpty);
    expect(notes.byId('quote')!.isArchived, isFalse);
    expect(quote, findsOneWidget);

    // Delete asks, then moves the note to Recently deleted with Undo on its
    // notice, and it stays there once the notice has gone.
    final deleted = find.text('Moved to Recently deleted');
    List<String> listed() => [
      for (final row in tester.widgetList<NoteRow>(find.byType(NoteRow)))
        row.note.id,
    ];
    Future<void> delete(Finder row, String id) async {
      await tester.drag(row, const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('swipe-delete-$id')));
      await tester.pumpAndSettle();
      expect(find.text('Delete note?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await pumpUntil(tester, () => shown(tester, deleted));
      expect(row, findsNothing);
      expect(deleted, findsOneWidget);
    }

    final arjun = find.widgetWithText(NoteRow, 'Call with Arjun');
    await delete(arjun, 'arjun');
    expect(tester.takeException(), isNull);
    await screenshot('swipe-deleted-notice', device: true);
    // The note stays in Recently deleted once its notice has gone, on the
    // device's own clock, and Undo is checked on a second delete.
    await pumpUntil(tester, () => deleted.evaluate().isEmpty);
    expect(deleted, findsNothing);
    expect(notes.byId('arjun')!.isTrashed, isTrue);

    final before = listed();
    await delete(quote, 'quote');
    await tester.tap(undo.last);
    await pumpUntil(tester, () => quote.evaluate().isNotEmpty);
    expect(listed(), before);
    expect(notes.byId('quote')!.isTrashed, isFalse);
    expect(notes.tombstones, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

/// Whether [text] is on screen with every fade above it run in.
bool shown(WidgetTester tester, Finder text) =>
    text.evaluate().isNotEmpty &&
    tester
        .widgetList<FadeTransition>(
          find.ancestor(of: text, matching: find.byType(FadeTransition)),
        )
        .every((fade) => fade.opacity.value == 1);

/// Pumps on the real clock until [done], for at most four seconds, leaving a
/// toast up where pumpAndSettle would run its lifetime out.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var pass = 0; pass < 40 && !done(); pass++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}
