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
// with a task added since you chose, and the evening.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:material_ui/material_ui.dart';

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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a phone walks the Tasks states, dark and light', (tester) async {
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
        rates: RatesRepository(store),
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

    await tap('page-back');
    await tap('bar-tasks');

    expect(find.text('What do you want to work on next?'), findsOneWidget);
    expect(find.text('First on the list'), findsOneWidget);
    await shot('d1-first-pair');

    await tap('tasks-pair-right');
    expect(find.text('Your choice so far'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    await shot('d2-mid-pair');

    await tap('tasks-start');
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    final stale = find.textContaining('Still want this?');
    expect(stale, findsOneWidget);
    await shot('d3-do-now');
    await tester.ensureVisible(stale);
    await shot('d3-stale-row');

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
  });
}
