// Tasks on a phone, for a reviewer to hold against boards D1 to D7: the
// whole app over four tasks kept in memory, with a clock the test moves.
// Three were added more than two weeks ago, so the one never picked asks
// whether it's still wanted.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_tasks_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Each state is taken dark, as the boards are drawn, and light: the first
// pair, mid-pair, Do now with a task left alone for two weeks, after Done
// with a task added since you chose, and the evening. The mid-pair (D6) and
// Do now (D7) are also taken at 1.3× and 2× text, and Do now with a row's
// menu open from a long press.
//
// A second walk takes the final boards dark, over their own notes: M13 with
// the search field, a search typed and the filter open; M13a, Do now over
// Up next with the line after it and Later; and M14, a task opened on
// its own page under the bar.
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:material_ui/material_ui.dart';

import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-tasks-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a phone walks the Tasks states, dark and light', (tester) async {
    final semantics = tester.ensureSemantics();
    var clock = DateTime(2026, 11, 4, 9);
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final prefs = LayoutPrefs(store)..load();
    final notes = NotesStore(store, now: () => clock);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => clock,
    );
    final tags = TagStore(store);
    await notes.load();
    await library.load();
    await tags.load();
    notes.create(
      body:
          'Lisbon trip\n☐ Ask Ana which Sintra palace to skip\n'
          '☐ Renew passport before the trip\n'
          '    The form is in Downloads. Bring two photos.\n'
          '☐ Book the Sintra train tickets',
    );
    await library.reconcileNow();
    clock = DateTime(2026, 11, 19, 9);
    notes.create(body: 'Quote for the deck\n☐ Book the room');
    await library.reconcileNow();
    clock = clock.add(const Duration(minutes: 1));
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: tags,
        tasks: library,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    Future<void> tap(String key) async {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    Future<void> shot(String name) async {
      for (final mode in [AppearanceMode.dark, AppearanceMode.light]) {
        prefs.appearance = mode;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: name);
        await screenshot('tasks-$name-${mode.name}');
      }
    }

    Future<void> scaledShots(String name) async {
      for (final (scale, label) in [(1.3, '130'), (2.0, '200')]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await shot('$name-text-$label');
      }
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pumpAndSettle();
    }

    /// What a screen reader hears for each control under [key].
    List<String> heard(String key) {
      final labels = <String>[];
      void walk(SemanticsNode node) {
        final data = node.getSemanticsData();
        if (data.hasAction(SemanticsAction.tap) && data.label.isNotEmpty) {
          labels.add(data.label);
        }
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(tester.getSemantics(find.byKey(ValueKey(key))));
      return labels;
    }

    await tap('page-home');
    await tap('home-title-tasks');

    expect(find.text('What do you want to work on next?'), findsOneWidget);
    expect(find.text('First on the list'), findsOneWidget);
    await shot('d1-first-pair');

    await tap('tasks-pair-right');
    expect(find.text('Your choice so far'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    expect(find.textContaining('Tap the one you’d rather do.'), findsOneWidget);
    expect(heard('tasks-pair'), hasLength(greaterThanOrEqualTo(2)));
    await shot('d2-mid-pair');
    await scaledShots('d6-pair');

    await tap('tasks-start');
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    final stale = find.textContaining('Still want this?');
    expect(stale, findsOneWidget);
    final done = tester.getTopLeft(find.byKey(const ValueKey('tasks-done')));
    final notFinished = tester.getTopLeft(
      find.byKey(const ValueKey('tasks-not-finished')),
    );
    expect(done.dx < notFinished.dx || done.dy < notFinished.dy, isTrue);
    expect(
      heard('tasks-do-now'),
      containsAll([contains('Done'), contains('Not finished')]),
    );
    await shot('d3-do-now');
    await scaledShots('d7-do-now');
    await tester.ensureVisible(stale);
    await shot('d3-stale-row');

    // The menu's route cancels the press it opens under, and the live
    // binding hands that cancel to its finder printer unless device pointer
    // events reach the app.
    binding.shouldPropagateDevicePointerEvents = true;
    final row = find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              RegExp(
                r'^phone-task-(?!box-)',
              ).hasMatch((widget.key! as ValueKey<String>).value),
        )
        .first;
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.longPress(row);
    await tester.pumpAndSettle();
    for (final entry in ['Do now', 'Move to the end', 'Remove…']) {
      expect(find.byKey(ValueKey('task-menu-$entry')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('task-menu-Details')), findsNothing);
    await shot('d7-row-menu');
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-menu-Do now')), findsNothing);
    binding.shouldPropagateDevicePointerEvents = false;

    clock = clock.add(const Duration(minutes: 30));
    final field = find.byKey(const ValueKey('tasks-add-field'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.enterText(field, 'Split the Acme invoice in two');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    clock = clock.add(const Duration(minutes: 30));
    await tap('tasks-done');
    expect(find.byKey(const ValueKey('tasks-just-done')), findsOneWidget);
    expect(find.text('New since you chose'), findsOneWidget);
    await shot('d4-after-done');

    clock = DateTime(2026, 11, 19, 18, 30);
    await tap('tasks-pair-left');
    await tap('tasks-not-finished');
    expect(find.text('Done for today.'), findsOneWidget);
    await shot('d5-evening');

    await tap('tasks-keep-going');
    expect(find.byKey(const ValueKey('tasks-pair')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a phone shows the boards M13, M13a and M14, dark', (
    tester,
  ) async {
    var clock = DateTime(2026, 11, 19, 9);
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = AppearanceMode.dark;
    final notes = NotesStore(store, now: () => clock);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => clock,
    );
    final tags = TagStore(store);
    final days = NoteDayStore(store, now: () => clock);
    await notes.load();
    await library.load();
    await tags.load();
    await days.load();
    Future<String> add(String body) async {
      final id = notes.create(body: body).id;
      await library.reconcileNow();
      clock = clock.add(const Duration(minutes: 1));
      return id;
    }

    final lisbon = await add(
      'Lisbon trip\n☐ Ask Ana which Sintra palace to skip\n'
      '☐ Renew passport before the trip\n☐ Book the Sintra train tickets',
    );
    await add('Tasks\n☐ Call Arjun');
    final quote = await add('Quote for the deck\n☐ Book the room');
    final call = await add(
      'Call with Arjun\n☐ Send the deck\n'
      '    Slides 1 to 6 are done. The charts need the new numbers.',
    );
    final renewal = await add(
      'Renewal notes\n☐ Send the renewal scope\n☐ Read the signed contract',
    );
    days.setDay(renewal, DateTime(2026, 11, 21));
    final travel = tags.create('Travel')!;
    tags.recolour(travel.id, 'sage');
    final work = tags.create('Work')!;
    tags.recolour(work.id, 'mustard');
    tags.setTags(lisbon, [travel.id]);
    tags.setTags(quote, [work.id]);
    tags.setTags(call, [work.id]);
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: tags,
        tasks: library,
        days: days,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    Future<void> tap(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> shot(String name) async {
      expect(tester.takeException(), isNull, reason: name);
      await screenshot('tasks-$name-dark', device: true);
    }

    if (find.byKey(const ValueKey('page-home')).evaluate().isNotEmpty) {
      await tap('page-home');
    }
    await tap('home-title-tasks');
    expect(find.text('Search tasks'), findsOneWidget);
    expect(find.text('6'), findsWidgets, reason: 'Tasks 6, Later left out');
    await shot('m13');

    final field = find.byKey(const ValueKey('tasks-search-field'));
    await tester.tap(field);
    await tester.enterText(field, 'sintra');
    await tester.pumpAndSettle();
    expect(find.text('Book the Sintra train tickets'), findsOneWidget);
    expect(find.text('Book the room'), findsNothing);
    await shot('m13-search');
    await tester.tap(find.byTooltip('Clear search'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    await tap('tasks-filters');
    expect(find.byKey(const ValueKey('tasks-filter-menu-all')), findsOneWidget);
    expect(find.byKey(ValueKey('tasks-filter-menu-$lisbon')), findsOneWidget);
    await shot('m13-filter');
    await tap('tasks-filter-menu-$quote');
    expect(find.text('Ask Ana which Sintra palace to skip'), findsNothing);
    await shot('m13-filter-one-note');
    await tap('tasks-filters');
    await tap('tasks-filter-menu-all');

    await tap('tasks-pair-right');
    await tap('tasks-pair-right');
    await tap('tasks-start');
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    await shot('m13a-up-next');

    final deck = find.text('Send the deck');
    await tester.ensureVisible(deck);
    await tester.pumpAndSettle();
    await tester.tap(deck);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('phone-task-open-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-back')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('phone-bar')).hitTestable(),
      findsOneWidget,
    );
    await shot('m14-task-opened');
  });
}
