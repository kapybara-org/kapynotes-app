// Tasks on a real Mac or phone: the whole app over notes kept in memory,
// walked through the boards' states with a clock the test moves.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/tasks_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The Mac walks D1 to D5 by keys and clicks; a phone walks D6 and D7 by taps
// and lays the pair and Do now out at 1×, 1.3× and 2× text. Each state is
// taken dark and light, as screenshots in build/screenshots.
import 'package:flutter/rendering.dart';
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
      await windowManager.setBounds(const Rect.fromLTWH(0, 0, 960, 680));
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
    prefs = LayoutPrefs(store)..load();
    await notes.load();
    await library.load();
    await tags.load();
    void later() => clock = clock.add(const Duration(minutes: 1));
    notes.create(
      body:
          'Lisbon trip\n☐ Ask Ana which Sintra palace to skip\n'
          '☐ Renew passport before the trip\n☐ Book the Sintra train tickets',
    );
    later();
    notes.create(body: 'Quote for the deck\n☐ Book the room');
    later();
    notes.create(
      body:
          'Call with Arjun\n☐ Send the deck\n'
          '    Slides 1 to 6 are done. The charts need the new numbers.',
    );
    later();
    await library.reconcileNow();
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
  }

  Future<void> shot(WidgetTester tester, String name) async {
    for (final mode in [AppearanceMode.dark, AppearanceMode.light]) {
      prefs.appearance = mode;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await screenshot('tasks-$name-${mode.name}');
    }
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

  testWidgets('a window walks D1 to D5', (tester) async {
    final semantics = tester.ensureSemantics();
    await launch(tester);
    await tap(tester, 'rail-tasks');

    expect(find.text('What do you want to work on next?'), findsOneWidget);
    expect(find.text('First on the list'), findsOneWidget);
    expect(find.byKey(const ValueKey('tasks-got-it')), findsOneWidget);
    expect(
      heard(tester, 'tasks-pair'),
      containsAll([
        contains('Ask Ana which Sintra palace to skip'),
        contains('Renew passport before the trip'),
      ]),
    );
    await shot(tester, 'window-d1-first-pair');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Your choice so far'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    await shot(tester, 'window-d2-mid-pair');

    await tap(tester, 'tasks-start');
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    expect(
      heard(tester, 'tasks-do-now'),
      containsAll([contains('Not finished'), contains('Done')]),
    );
    await shot(tester, 'window-d3-do-now');

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
    await shot(tester, 'window-d4-after-done');

    clock = DateTime(2026, 11, 19, 18, 30);
    await tap(tester, 'tasks-choose-again');
    expect(find.text('Done for today.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tasks-choose-again')), findsNothing);
    await shot(tester, 'window-d5-evening');

    await tap(tester, 'tasks-keep-going');
    expect(find.byKey(const ValueKey('tasks-pair')), findsOneWidget);
    semantics.dispose();
  }, skip: AppPlatform.isMobile);

  testWidgets('a phone walks D6 and D7, at 1×, 1.3× and 2× text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await launch(tester);
    await tap(tester, 'page-back');
    await tap(tester, 'bar-tasks');

    await tap(tester, 'tasks-pair-right');
    expect(find.text('Your choice so far'), findsOneWidget);
    expect(find.textContaining('Tap the one you’d rather do.'), findsOneWidget);
    expect(heard(tester, 'tasks-pair'), hasLength(greaterThanOrEqualTo(2)));
    for (final scale in [1.0, 1.3, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await shot(tester, 'phone-d6-pair-text-${(scale * 100).round()}');
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pumpAndSettle();

    await tap(tester, 'tasks-start');
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    final done = tester.getTopLeft(find.byKey(const ValueKey('tasks-done')));
    final notFinished = tester.getTopLeft(
      find.byKey(const ValueKey('tasks-not-finished')),
    );
    expect(done.dx < notFinished.dx || done.dy < notFinished.dy, isTrue);
    for (final scale in [1.0, 1.3, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await shot(tester, 'phone-d7-do-now-text-${(scale * 100).round()}');
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pumpAndSettle();

    await tap(tester, 'tasks-done');
    expect(find.byKey(const ValueKey('tasks-just-done')), findsOneWidget);
    semantics.dispose();
  }, skip: !AppPlatform.isMobile);
}
