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
import 'package:flutter/rendering.dart';
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

    await tap('page-back');
    await tap('bar-tasks');

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
}
