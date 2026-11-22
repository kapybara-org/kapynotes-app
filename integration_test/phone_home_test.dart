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
// dot after the time. Pinned's card (#230) counts its notes and names them,
// opens the pinned list, and Back returns to Notes: Pinned's own arrow and a
// swipe in from the left edge on both phones, and Android's system back.
// Without an account there is no Shared card; sharing is KAP-256's. Each
// state is taken light and dark, and the list again at 2× text, as
// screenshots in build/screenshots.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:material_ui/material_ui.dart';

import 'screenshot.dart';

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

  Future<void> launch(WidgetTester tester) async {
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
    write('Offsite agenda\nRoom, lunch, the deck', 3, 10, 0);
    final groceries = write('Groceries\nOat milk, lemons', 1, 18, 40);
    final reading = write('Reading list\nThe Overstory', 1, 21, 30);
    write('Call with Arjun\nSend the deck', 0, 9, 12);
    clock = today;
    notes.togglePinned(trip);
    notes.togglePinned(reading);
    tags.addTag(groceries, tags.create('Errands')!.id);

    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: tags,
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
  final pinnedCard = find.byKey(const ValueKey('home-pinned-card'));
  final pinnedBack = find.byKey(const ValueKey('sidebar-pinned-back'));
  Finder row(String title) => find.widgetWithText(NoteRow, title);

  testWidgets('the list comes a day at a time, under the Pinned card', (
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
    expect(days, hasLength(3));
    expect(days[0], startsWith('Today '));
    expect(days[1], startsWith('Yesterday '));
    expect(days[2], contains(' ${older.day} '));
    final tops = [
      for (var i = 0; i < days.length; i++)
        tester.getTopLeft(headings.at(i)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(tester.getBottomLeft(pinnedCard).dy, lessThan(tops.first));

    for (final (title, day, time) in [
      ('Call with Arjun', 0, '9:12'),
      ('Groceries', 1, '18:40'),
      ('Offsite agenda', 2, '10:00'),
    ]) {
      final top = tester.getTopLeft(row(title)).dy;
      expect(top, greaterThan(tops[day]), reason: title);
      if (day < 2) expect(top, lessThan(tops[day + 1]), reason: title);
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
      find.descendant(of: pinnedCard, matching: find.text('2')),
      findsOneWidget,
    );
    for (final title in ['Lisbon trip', 'Reading list']) {
      expect(
        find.descendant(of: pinnedCard, matching: find.textContaining(title)),
        findsOneWidget,
        reason: title,
      );
    }
    await shot(tester, 'days');
  });

  testWidgets('Pinned opens its list, and Back returns to Notes', (
    tester,
  ) async {
    await launch(tester);

    final ways = [
      'arrow',
      'edge swipe',
      if (AppPlatform.isAndroid) 'system back',
    ];
    for (final way in ways) {
      await tester.tap(pinnedCard);
      await tester.pumpAndSettle();
      expect(pinnedBack, findsOneWidget);
      expect(pinnedCard, findsNothing);
      expect(row('Lisbon trip'), findsOneWidget);
      expect(row('Reading list'), findsOneWidget);
      expect(row('Groceries'), findsNothing);
      if (way == ways.first) await shot(tester, 'pinned');

      if (way == 'arrow') {
        await tester.tap(pinnedBack);
      } else if (way == 'edge swipe') {
        // In from the very edge, as iOS's back swipe starts, over a row
        // whose own swipe the edge has to win.
        await tester.timedDragFrom(
          Offset(2, tester.getCenter(row('Lisbon trip')).dy),
          const Offset(200, 0),
          const Duration(milliseconds: 300),
        );
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(pinnedBack, findsNothing, reason: way);
      expect(pinnedCard, findsOneWidget, reason: way);
      expect(row('Groceries'), findsOneWidget, reason: way);
    }
    await shot(tester, 'back');
  });

  testWidgets('at 2× text the cards and days lay out whole', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester);
    expect(pinnedCard, findsOneWidget);
    expect(headings, findsWidgets);
    await shot(tester, 'large-text');
  });
}
