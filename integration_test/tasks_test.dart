// Tasks on a real Mac: the whole app over notes kept in memory,
// walked through the boards' states with a clock the test moves.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/tasks_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The Mac walks the final boards' Tasks states by keys and clicks, in a
// 1440 × 900 window over the boards' notes: Lisbon trip in green, the two
// work notes in mustard, a task with no note, a task that came back (↺) and
// Renewal notes waiting for Sat 21, so Later shows. Each state is the whole
// window, dark, as screenshots in build/screenshots: D09a, the first pair
// with How Tasks works; D09b, mid-pair; D09, Do now with a task's details
// beside the list; D09d, after Done with a task added since you chose; and
// D09e, the evening.
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tasks-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  var clock = DateTime(2026, 11, 19, 9);
  late LayoutPrefs prefs;

  Future<void> launch(WidgetTester tester) async {
    if (AppPlatform.isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.setBounds(const Rect.fromLTWH(0, 0, 1440, 900));
    }
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final notes = NotesStore(store, now: () => clock);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => clock,
    );
    final tags = TagStore(store);
    final days = NoteDayStore(store, now: () => clock);
    prefs = LayoutPrefs(store)..load();
    prefs.appearance = AppearanceMode.dark;
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
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: tags,
        tasks: library,
        days: days,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: name);
    await screenshot('tasks-$name-dark');
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  /// What a screen reader hears for each control under [key].
  List<String> heard(WidgetTester tester, String key) {
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

  testWidgets('a 1440 × 900 window walks D09 and D09a to D09e', (tester) async {
    final semantics = tester.ensureSemantics();
    await launch(tester);
    final window = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(window.width, 1440, reason: 'the shots are of a 1440 wide window');
    await tap(tester, 'rail-tasks');

    // Ask Ana comes back: Start with makes it Do now, and Not finished sends
    // it to the end of the list with ↺.
    expect(find.text('First on the list'), findsOneWidget);
    await tap(tester, 'tasks-start');
    await tap(tester, 'tasks-not-finished');
    expect(find.byTooltip('Not finished, moved to the end'), findsOneWidget);

    expect(find.text('What do you want to work on next?'), findsOneWidget);
    expect(find.byKey(const ValueKey('tasks-how-it-works')), findsOneWidget);
    expect(find.text('Based on FVP by Mark Forster'), findsOneWidget);
    expect(find.text('2 tasks wait for their day'), findsOneWidget);
    expect(find.text('Sat 21'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tasks-filter-all')),
        matching: find.text('6'),
      ),
      findsOneWidget,
    );
    expect(find.text('Renewal notes'), findsNothing);
    expect(
      heard(tester, 'tasks-pair'),
      containsAll([
        contains('Renew passport before the trip'),
        contains('Book the Sintra train tickets'),
      ]),
    );
    await shot(tester, 'window-d09a');

    await tap(tester, 'tasks-got-it');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Your choice so far'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    expect(find.byKey(const ValueKey('tasks-choose-again')), findsOneWidget);
    await shot(tester, 'window-d09b');

    await tap(tester, 'tasks-start');
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    expect(
      heard(tester, 'tasks-do-now'),
      containsAll([contains('Not finished'), contains('Done')]),
    );
    await tester.tap(find.text('Send the deck'));
    await tester.pumpAndSettle();
    expect(find.text('Open in note'), findsOneWidget);
    await shot(tester, 'window-d09');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    clock = clock.add(const Duration(minutes: 30));
    final field = find.byKey(const ValueKey('tasks-add-field'));
    await tester.tap(field);
    await tester.enterText(field, 'Split the Acme invoice in two');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    clock = clock.add(const Duration(minutes: 30));
    await tap(tester, 'tasks-done');
    expect(find.byKey(const ValueKey('tasks-just-done')), findsOneWidget);
    expect(find.text('New since you chose'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tasks-pair-right')),
        matching: find.text('Split the Acme invoice in two'),
      ),
      findsOneWidget,
    );
    await shot(tester, 'window-d09d');

    clock = DateTime(2026, 11, 19, 18, 30);
    await tap(tester, 'tasks-choose-again');
    expect(find.text('Done for today.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tasks-choose-again')), findsNothing);
    await shot(tester, 'window-d09e');

    await tap(tester, 'tasks-keep-going');
    expect(find.byKey(const ValueKey('tasks-pair')), findsOneWidget);
    semantics.dispose();
  }, skip: AppPlatform.isMobile);
}
