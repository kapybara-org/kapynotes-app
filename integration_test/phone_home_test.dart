// The phone's Notes home on a real phone: the whole app over notes kept in
// memory, written over three days, so the list and its cards are the same on
// every run.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_home_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The list comes a day at a time (#203): Today, Yesterday, then the older
// day, each row under its own day with its time, and a tagged row with its
// dot after the time. Pinned (KAP-302) is a row of cards over the days,
// with its count and View all, which opens every pinned note two to a row;
// Back returns to Notes: the page's arrow and a swipe in from the left edge
// on both phones, and Android's system back. Folders lists only folders, and
// a folder's Add notes is a sheet of the notes in no folder (KAP-342). Each
// state is taken light and dark, and the list again at 2× text, as
// screenshots in build/screenshots.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:material_ui/material_ui.dart';

import 'rates_support.dart';
import 'screenshot.dart';
import 'sharing_support.dart' show pumpUntil, shown;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-home-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final today = DateTime.now();
  final older = DateTime(today.year, today.month, today.day - 3);
  late LayoutPrefs prefs;

  Future<void> launch(
    WidgetTester tester, {
    bool folders = false,
    List<String> unfiled = const [],
  }) async {
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    var clock = today;
    final notes = NotesStore(store, now: () => clock);
    final tags = TagStore(store);
    prefs = LayoutPrefs(store)..load();
    await notes.load();
    await tags.load();
    String write(String body, int daysAgo, int hour, int minute) {
      clock = DateTime(
        today.year,
        today.month,
        today.day - daysAgo,
        hour,
        minute,
      );
      return notes.create(body: body).id;
    }

    final trip = write('Lisbon trip\nFour days in May', 3, 8, 5);
    final offsite = write('Offsite agenda\nRoom, lunch, the deck', 3, 10, 0);
    final groceries = write('Groceries\nOat milk, lemons', 1, 18, 40);
    final reading = write('Reading list\nThe Overstory', 1, 21, 30);
    final call = write('Call with Arjun\nSend the deck', 0, 9, 12);
    for (final (index, body) in unfiled.indexed) {
      write(body, index * 2, 7 + index, 45);
    }
    clock = today;
    notes.togglePinned(trip);
    notes.togglePinned(reading);
    tags.addTag(groceries, tags.create('Errands')!.id);

    // M02's tree, opened down to Acme, with two drawings for its tile and a
    // note for a later day, which stays off the lists until its day.
    FolderStore? folderStore;
    NoteDayStore? days;
    if (folders) {
      days = NoteDayStore(store);
      await days.load();
      final renewal = write('Renewal notes\nRead the contract first', 0, 8, 30);
      days.setDay(renewal, DateTime(today.year, today.month, today.day + 2));
      folderStore = FolderStore(store);
      await folderStore.load();
      final work = folderStore.create('Work')!;
      final clients = folderStore.create('Clients', parentId: work.id)!;
      final acme = folderStore.create('Acme', parentId: clients.id)!;
      folderStore.create('Product');
      final personal = folderStore.create('Personal')!;
      folderStore.file([trip, reading], personal.id);
      folderStore.file([offsite], work.id);
      folderStore.file([call], acme.id);
      prefs.setFolderOpen(work.id, true);
      prefs.setFolderOpen(clients.id, true);
      for (final (title, hour) in [('Shelf plan', 8), ('Deck flow', 9)]) {
        clock = DateTime(today.year, today.month, today.day, hour, 40);
        final drawing = notes.create(drawing: true);
        notes.updateDrawing(drawing.id, NoteDrawing.empty, title: title);
      }
      clock = today;
    }

    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: tags,
        folders: folderStore,
        days: days,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final back = find.byKey(const ValueKey('page-home'));
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
      await tester.pumpAndSettle();
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    for (final mode in [AppearanceMode.light, AppearanceMode.dark]) {
      prefs.appearance = mode;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await screenshot('phone-home-$name-${mode.name}');
    }
  }

  final headings = find.byKey(const ValueKey('phone-day-heading'));
  final pinnedCards = find.byKey(const ValueKey('phone-pinned-cards'));
  final viewAll = find.byKey(const ValueKey('sidebar-view-all-pinned'));
  final pinnedPage = find.byKey(const ValueKey('pinned-page'));
  Finder row(String title) => find.widgetWithText(NoteRow, title);

  testWidgets("the list comes a day at a time, under Pinned's cards", (
    tester,
  ) async {
    await launch(tester);

    final days = [
      for (var i = 0; i < headings.evaluate().length; i++)
        tester
            .widgetList<Text>(
              find.descendant(
                of: headings.at(i),
                matching: find.byType(Text),
                matchRoot: true,
              ),
            )
            .map((text) => text.data ?? text.textSpan!.toPlainText())
            .join(' '),
    ];
    expect(days, hasLength(4));
    expect(days[0], startsWith('Pinned '));
    expect(days[1], startsWith('Today '));
    expect(days[2], startsWith('Yesterday '));
    expect(days[3], contains(' ${older.day} '));
    final tops = [
      for (var i = 0; i < days.length; i++)
        tester.getTopLeft(headings.at(i)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(tester.getTopLeft(pinnedCards).dy, greaterThan(tops[0]));
    expect(tester.getBottomLeft(pinnedCards).dy, lessThan(tops[1]));

    for (final (title, day, time) in [
      ('Call with Arjun', 0, '9:12'),
      ('Groceries', 1, '18:40'),
      ('Offsite agenda', 2, '10:00'),
    ]) {
      final top = tester.getTopLeft(row(title)).dy;
      expect(top, greaterThan(tops[day + 1]), reason: title);
      if (day < 2) expect(top, lessThan(tops[day + 2]), reason: title);
      expect(
        find.descendant(of: row(title), matching: find.text(time)),
        findsOneWidget,
        reason: title,
      );
    }
    final dots = find.descendant(
      of: row('Groceries'),
      matching: find.byType(TagDots),
    );
    expect(dots, findsOneWidget);
    expect(
      tester.getTopLeft(dots).dx,
      greaterThan(
        tester
            .getTopRight(
              find.descendant(
                of: row('Groceries'),
                matching: find.text('18:40'),
              ),
            )
            .dx,
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-pinned-heading')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    for (final title in ['Lisbon trip', 'Reading list']) {
      expect(
        find.descendant(of: pinnedCards, matching: find.text(title)),
        findsOneWidget,
        reason: title,
      );
    }
    await shot(tester, 'days');
  });

  testWidgets('View all opens the Pinned page, and Back returns to Notes', (
    tester,
  ) async {
    await launch(tester);

    final ways = [
      'arrow',
      'edge swipe',
      if (AppPlatform.isAndroid) 'system back',
    ];
    for (final way in ways) {
      await tester.tap(viewAll);
      await tester.pumpAndSettle();
      expect(pinnedPage, findsOneWidget);
      expect(pinnedCards, findsNothing);
      expect(row('Lisbon trip'), findsOneWidget);
      expect(row('Reading list'), findsOneWidget);
      expect(row('Groceries'), findsNothing);
      if (way == ways.first) await shot(tester, 'pinned');

      if (way == 'arrow') {
        await tester.tap(find.byKey(const ValueKey('page-back')));
      } else if (way == 'edge swipe') {
        // In from the very edge, as iOS's back swipe starts, beside a card.
        await tester.timedDragFrom(
          Offset(2, tester.getCenter(row('Lisbon trip')).dy),
          const Offset(200, 0),
          const Duration(milliseconds: 300),
        );
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(pinnedPage, findsNothing, reason: way);
      expect(pinnedCards, findsOneWidget, reason: way);
      expect(row('Groceries'), findsOneWidget, reason: way);
    }
    await shot(tester, 'back');
  });

  testWidgets('at 2× text the cards and days lay out whole', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester);
    expect(pinnedCards, findsOneWidget);
    expect(headings, findsWidgets);
    await shot(tester, 'large-text');
  });

  testWidgets("the bar's boards, dark: Folders with Drawings (M02), Drawings "
      'from Folders (M03) and the + menu open (M05)', (tester) async {
    await launch(tester, folders: true);
    prefs.appearance = AppearanceMode.dark;
    await tester.pumpAndSettle();
    Future<void> tap(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> board(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await screenshot('phone-bar-$name-dark');
    }

    final title = find.byKey(const ValueKey('phone-list-title'));
    await tap('bar-folders');
    expect(tester.widget<Text>(title).data, 'Folders');
    expect(find.byKey(const ValueKey('folders-drawings-tile')), findsOneWidget);
    expect(find.textContaining('Deck flow · '), findsOneWidget);
    for (final name in ['Work', 'Clients', 'Acme', 'Product', 'Personal']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(find.text('Not in a folder'), findsNothing);
    expect(find.byKey(const ValueKey('folders-upcoming-tile')), findsNothing);
    await board('m02-folders');

    await tap('folders-drawings-tile');
    expect(tester.widget<Text>(title).data, 'Drawings');
    expect(find.byKey(const ValueKey('page-back')), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    await board('m03-drawings');

    await tap('bar-notes');
    await tester.longPress(find.byKey(const ValueKey('phone-new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('phone-new-dim')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-new-close')), findsOneWidget);
    expect(find.text('New drawing'), findsOneWidget);
    await board('m05-plus');
    await tap('phone-new-close');
    expect(find.byKey(const ValueKey('phone-new-close')), findsNothing);
  });

  testWidgets("Folders lists only folders, and a folder's Add notes is a sheet "
      'of the notes in no folder: three ticked, then added, and Undo takes '
      'them back out (KAP-342)', (tester) async {
    await launch(
      tester,
      folders: true,
      unfiled: const [
        'Morning pages\nThree pages, longhand',
        'Kickoff agenda, Northwind\nGoals, people, dates',
        'Invoice, April\n1,200.00 EUR',
        'Pricing follow-up\nSend the new tiers',
      ],
    );
    Future<void> tap(Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> board(String name, AppearanceMode mode) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await screenshot('phone-$name-${mode.name}');
    }

    final sheet = find.byKey(const ValueKey('add-notes'));
    Finder inSheet(String text) =>
        find.descendant(of: sheet, matching: find.text(text));
    for (final mode in [AppearanceMode.dark, AppearanceMode.light]) {
      prefs.appearance = mode;
      await tap(find.byKey(const ValueKey('bar-folders')));
      expect(find.text('Not in a folder'), findsNothing);
      expect(row('Groceries'), findsNothing);
      await board('folders-only-folders', mode);

      await tap(find.text('Clients'));
      await tap(find.byKey(const ValueKey('phone-add-notes')));
      expect(inSheet('Add notes to Clients'), findsOneWidget);
      expect(inSheet('Groceries'), findsOneWidget);
      expect(inSheet('Call with Arjun'), findsNothing);
      for (final title in [
        'Kickoff agenda, Northwind',
        'Invoice, April',
        'Pricing follow-up',
      ]) {
        await tap(inSheet(title));
      }
      expect(inSheet('Add 3 notes'), findsOneWidget);
      await board('folder-add-notes', mode);

      // On a device a toast's lifetime is an animation, so pumpAndSettle
      // would run it out: it is waited for as it arrives, with the sheet
      // gone, and Undo is pressed right after the shot.
      final added = find.text('Added 3 notes to “Clients”');
      await tester.tap(find.byKey(const ValueKey('add-notes-add')));
      await pumpUntil(
        tester,
        () => shown(tester, added) && sheet.evaluate().isEmpty,
      );
      expect(sheet, findsNothing);
      expect(added, findsOneWidget);
      expect(row('Invoice, April'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot('phone-folder-notes-added-${mode.name}');

      await tester.tap(find.text('Undo'));
      await pumpUntil(tester, () => row('Invoice, April').evaluate().isEmpty);
      expect(row('Invoice, April'), findsNothing);
      await tap(find.byKey(const ValueKey('page-back')));
    }
  });
  testWidgets('Archive opens from the filter, and Back comes Home with the '
      'app still open (KAP-305)', (tester) async {
    await launch(tester);
    final homeTitle = find.byKey(const ValueKey('home-title-notes'));
    final ways = ['edge swipe', if (AppPlatform.isAndroid) 'system back'];
    for (final way in ways) {
      if (find.byKey(const ValueKey('phone-filter-row')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('phone-filters')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notes-filter-archive')));
      await tester.pumpAndSettle();
      expect(homeTitle, findsNothing, reason: way);

      if (way == 'edge swipe') {
        await tester.timedDragFrom(
          const Offset(2, 420),
          const Offset(200, 0),
          const Duration(milliseconds: 300),
        );
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(homeTitle, findsOneWidget, reason: way);
    }
  });
}
