// Recently deleted on a real Mac (KAP-400): the whole app over notes kept in
// memory, in a 1100 × 640 window, which fits the CI runner's screen.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/trash_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
//
// It takes, light and dark, as screenshots in build/screenshots, for the
// design check: Delete's notice with Undo, the Show menu with Recently
// deleted under Archive, the list with a deleted note open under its bar, a
// row's menu, and the question Empty asks.
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryButton, kSecondaryButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'rates_support.dart';
import 'screenshot.dart';
import 'sharing_support.dart' show pumpUntil, shown;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'trash-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const mouse = PointerDeviceKind.mouse;

  testWidgets('Recently deleted: Delete with Undo, the Show menu, the list '
      'with its page bar, a row menu and Empty', (tester) async {
    if (AppPlatform.isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.setBounds(Offset.zero & const Size(1100, 640));
    }
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    var clock = DateTime.now().subtract(const Duration(days: 20));
    final notes = NotesStore(store, now: () => clock);
    final prefs = LayoutPrefs(store)..load();
    await notes.load();
    String make(String body) {
      clock = clock.add(const Duration(minutes: 1));
      return notes.create(body: body).id;
    }

    final grocery = make('Grocery list\nOats, lemons, coffee');
    final draft = make('Draft for the team\nWeekly update, first pass');
    make('Reading list\nThe Overstory, Piranesi');
    final trip = make('Trip budget\nFlights for two, 640');
    make('Call with Arjun\nPricing page by Friday');
    notes.trashAll([grocery]);
    clock = clock.add(const Duration(days: 12));
    notes.trashAll([draft]);
    clock = DateTime.now();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();

    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    Future<void> shot(String name) async {
      for (final mode in [AppearanceMode.light, AppearanceMode.dark]) {
        prefs.appearance = mode;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: name);
        await screenshot('trash-$name-${mode.name}');
      }
    }

    Future<void> click(Finder finder, {int buttons = kPrimaryButton}) async {
      await tester.tap(finder, kind: mouse, buttons: buttons);
      await tester.pumpAndSettle();
    }

    Finder row(String title) => find.widgetWithText(NoteRow, title);
    Finder filter(NotesShow show) =>
        find.byKey(ValueKey('notes-filter-${show.name}'));

    // Delete moves the note to Recently deleted, with Undo on its notice. It
    // runs once in each look, so each notice is shot before it goes, and
    // Undo brings the note back between them.
    final moved = find.text('Moved to Recently deleted');
    for (final mode in [AppearanceMode.light, AppearanceMode.dark]) {
      prefs.appearance = mode;
      await tester.pumpAndSettle();
      await click(row('Trip budget'), buttons: kSecondaryButton);
      await click(find.byKey(ValueKey('delete-note-$trip')));
      expect(find.text('Delete note?'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('confirm-delete')),
        kind: mouse,
      );
      await pumpUntil(tester, () => shown(tester, moved));
      expect(row('Trip budget'), findsNothing);
      expect(notes.byId(trip)!.isTrashed, isTrue);
      await screenshot('trash-moved-notice-${mode.name}');
      if (mode == AppearanceMode.light) {
        await tester.tap(find.text('Undo').last, kind: mouse);
        await pumpUntil(tester, () => row('Trip budget').evaluate().isNotEmpty);
        expect(notes.byId(trip)!.isTrashed, isFalse);
      }
    }
    await pumpUntil(tester, () => moved.evaluate().isEmpty);
    await tester.pumpAndSettle();

    await click(find.byKey(const ValueKey('sidebar-notes-filter')));
    expect(
      tester.getCenter(filter(NotesShow.trash)).dy,
      greaterThan(tester.getCenter(filter(NotesShow.archive)).dy),
    );
    await shot('show-menu');

    await click(filter(NotesShow.trash));
    expect(row('Trip budget'), findsOneWidget);
    expect(row('Draft for the team'), findsOneWidget);
    expect(row('Grocery list'), findsOneWidget);
    expect(find.byKey(const ValueKey('trash-empty')), findsOneWidget);
    await click(row('Draft for the team'));
    expect(find.byKey(const ValueKey('trashed-note-bar')), findsOneWidget);
    await shot('list');

    await click(row('Grocery list'), buttons: kSecondaryButton);
    expect(find.byKey(ValueKey('put-back-note-$grocery')), findsOneWidget);
    expect(find.text('Delete now…'), findsOneWidget);
    await shot('row-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await click(find.byKey(const ValueKey('trash-empty')));
    expect(find.text('Delete 3 notes for good?'), findsOneWidget);
    await shot('empty-question');
    await click(find.text('Cancel'));
    expect(notes.trashedNotes, hasLength(3));
  });
}
