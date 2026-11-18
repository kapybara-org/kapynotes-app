import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/task_marks.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tasks-screen-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  late DateTime clock;
  late NotesStore notes;
  late TaskLibrary library;
  late TasksController tasks;
  late FocusNode addFocus;

  Future<void> pumpScreen(
    WidgetTester tester, {
    TaskFilter filter = const TaskFilter.all(),
    ThemeData? theme,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? KapyTheme.dark(),
        home: Scaffold(
          body: TasksScreen(
            controller: tasks,
            filter: filter,
            addFocus: addFocus,
            labelOf: (note) => note.title,
            onOpenNote: (_) {},
            newTaskShortcut: '⌘N',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  Future<void> setUpTasks(WidgetTester tester, String body) async {
    clock = DateTime(2026, 11, 17, 9);
    final store = _MemoryStore();
    notes = NotesStore(store);
    library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: tick,
    );
    await notes.load();
    await library.load();
    notes.create(body: body);
    tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => true,
      now: tick,
    );
    await tasks.reconcileNow();
    addFocus = FocusNode();
    addTearDown(() {
      addFocus.dispose();
      tasks.dispose();
      library.dispose();
    });
  }

  Finder box(String words) => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.checked != null &&
        w.properties.label == words,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('with nothing in Do now, the first task is asked about, then '
      'each later one against the newest dot, until Do now is chosen', (
    tester,
  ) async {
    await setUpTasks(
      tester,
      'Errands\n☐ Send the report\n☐ Book flights\n☐ Call the garage',
    );
    await pumpScreen(tester);

    expect(find.text('Ready to do this now?'), findsOneWidget);
    expect(find.text('First on the list'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tasks-ready-not-yet')));
    await settle(tester);
    expect(
      find.textContaining('What do you want to do more than'),
      findsOneWidget,
    );
    expect(find.text('None. Do “Send the report”'), findsOneWidget);

    final book = tasks.read().open[1];
    await tester.tap(find.byKey(ValueKey('tasks-candidate-${book.id}')));
    await settle(tester);
    expect(find.text('None. Do “Book flights”'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tasks-pick-none')));
    await settle(tester);
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    expect(tasks.read().open[1].doNow, isTrue);
    expect(tasks.read().open[0].dotted, isTrue);
  });

  testWidgets('Done ticks Do now in its note, and only tasks after it are '
      'asked about next', (tester) async {
    await setUpTasks(tester, 'Errands\n☐ One\n☐ Two\n☐ Three');
    final open = tasks.read().open;
    tasks.dot(open[0]);
    tasks.doNow(open[1]);
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('tasks-done')));
    await settle(tester);

    expect(notes.notes.single.body, 'Errands\n☐ One\n☑ Two\n☐ Three');
    expect(
      find.textContaining('What do you want to do more than'),
      findsOneWidget,
    );
    final three = tasks.read().open.last;
    expect(find.byKey(ValueKey('tasks-candidate-${three.id}')), findsOneWidget);
  });

  testWidgets('the last dot becomes Do now on its own once nothing after it '
      'is left to ask about', (tester) async {
    await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
    final open = tasks.read().open;
    tasks.dot(open[0]);
    tasks.doNow(open[1]);
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('tasks-done')));
    await settle(tester);

    expect(tasks.read().open.single.doNow, isTrue);
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
  });

  testWidgets(
    'Not finished and Done sit at the right edge of the card, with the '
    'note on the left',
    (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      final open = tasks.read().open;
      tasks.doNow(open[0]);
      await pumpScreen(tester);

      final card = tester.getRect(find.byKey(const ValueKey('tasks-do-now')));
      final done = tester.getRect(find.byKey(const ValueKey('tasks-done')));
      final note = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('tasks-do-now')),
          matching: find.text('Errands'),
        ),
      );
      expect(card.right - done.right, lessThan(24));
      expect(note.left - card.left, lessThan(60));
      await settle(tester);
    },
  );

  testWidgets('Not finished sends Do now to the end of the list', (
    tester,
  ) async {
    await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
    final open = tasks.read().open;
    tasks.doNow(open[0]);
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('tasks-not-finished')));
    await settle(tester);

    expect([for (final i in tasks.read().open) i.words], ['Two', 'One']);
  });

  testWidgets('the add row adds at the end, says so, and keeps the field for '
      'the next one; Escape leaves it', (tester) async {
    await setUpTasks(tester, 'Errands\n☐ One');
    await pumpScreen(tester);
    expect(addFocus.hasFocus, isFalse);
    expect(find.text('No note'), findsOneWidget);

    addFocus.requestFocus();
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('tasks-add-field')),
      'Book the dentist',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('tasks-added-notice')), findsOneWidget);
    expect(addFocus.hasFocus, isTrue);
    expect(
      [for (final i in tasks.read().open) i.words],
      ['One', 'Book the dentist'],
    );
    expect(tasks.read().home?.body, 'Tasks\n☐ Book the dentist');

    await settle(tester);
    expect(find.byKey(const ValueKey('tasks-added-notice')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(addFocus.hasFocus, isFalse);
  });

  testWidgets('a row ticked in Tasks leaves the list for Done, and unticking '
      'it there brings it back at the end', (tester) async {
    await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
    await pumpScreen(tester);

    await tester.tap(box('One'));
    await settle(tester);
    expect([for (final i in tasks.read().open) i.words], ['Two']);

    await pumpScreen(tester, filter: const TaskFilter.done());
    expect(find.text('1 completed'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);

    clock = clock.add(const Duration(minutes: 5));
    await tester.tap(box('One'));
    await settle(tester);
    expect([for (final i in tasks.read().open) i.words], ['Two', 'One']);
  });

  group('picking by clicking the mark', () {
    Finder markOf(TaskItem item) =>
        find.byKey(ValueKey('task-mark-${item.id}'));

    /// The mark's drawing: the hollow hint, the dot or the ring, told apart
    /// by their decoration.
    Finder shape({bool hollow = false, bool ring = false}) =>
        find.byWidgetPredicate((w) {
          if (w is! Container) return false;
          final decoration = w.decoration;
          if (decoration is! BoxDecoration) return false;
          if (decoration.shape != BoxShape.circle &&
              decoration.borderRadius == null) {
            return false;
          }
          final hasShadow = decoration.boxShadow != null;
          if (hollow) {
            return decoration.color == null && decoration.border != null;
          }
          if (ring) return decoration.color != null && hasShadow;
          return decoration.color != null && !hasShadow;
        });

    Finder tip(String message) =>
        find.byWidgetPredicate((w) => w is Tooltip && w.message == message);

    TaskItem row(String words) =>
        tasks.read().open.firstWhere((item) => item.words == words);

    Future<void> hover(WidgetTester tester, String words) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(markOf(row(words))));
      await tester.pump();
    }

    testWidgets('a hovered row with no pick shows a hollow dot, and only '
        'that row', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      await pumpScreen(tester);
      for (final words in ['One', 'Two']) {
        expect(
          find.descendant(
            of: markOf(row(words)),
            matching: shape(hollow: true),
          ),
          findsNothing,
        );
      }

      await hover(tester, 'Two');
      expect(
        find.descendant(of: markOf(row('Two')), matching: shape(hollow: true)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: markOf(row('One')), matching: shape(hollow: true)),
        findsNothing,
      );
      expect(tip('Pick to do next'), findsNWidgets(2));
      await settle(tester);
    });

    testWidgets('each click goes one step: picked, then Do now, then clear; '
        'a tap works without hover', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two\n☐ Three');
      await pumpScreen(tester);

      await tester.tap(markOf(row('Two')));
      await settle(tester);
      expect(row('Two').dotted, isTrue);
      expect(row('Two').doNow, isFalse);
      expect(
        find.descendant(of: markOf(row('Two')), matching: shape()),
        findsOneWidget,
      );
      expect(tip('Picked to do next · click for Do now'), findsOneWidget);

      await tester.tap(markOf(row('Two')));
      await settle(tester);
      expect(row('Two').doNow, isTrue);
      expect(row('Two').dotted, isTrue);
      expect(
        find.descendant(of: markOf(row('Two')), matching: shape(ring: true)),
        findsOneWidget,
      );
      expect(tip('Do now · click to clear'), findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);

      await tester.tap(markOf(row('Two')));
      await settle(tester);
      expect(row('Two').dotted, isFalse);
      expect(row('Two').doNow, isFalse);
      expect(find.text('Ready to do this now?'), findsOneWidget);
    });

    testWidgets('a task picked last stays picked until it is clicked again', (
      tester,
    ) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      await pumpScreen(tester);

      await tester.tap(markOf(row('Two')));
      await settle(tester);
      expect(row('Two').dotted, isTrue);
      expect(row('Two').doNow, isFalse);

      await tester.tap(markOf(row('Two')));
      await settle(tester);
      expect(row('Two').doNow, isTrue);
    });

    testWidgets('making another task Do now leaves the first one picked', (
      tester,
    ) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two\n☐ Three');
      await pumpScreen(tester);

      for (final words in ['One', 'One', 'Two', 'Two']) {
        await tester.tap(markOf(row(words)));
        await settle(tester);
        if (words == 'One' && row('One').doNow) {
          expect(row('Two').doNow, isFalse);
        }
      }

      expect(row('Two').doNow, isTrue);
      expect(row('One').doNow, isFalse);
      expect(row('One').dotted, isTrue);
      expect(row('Three').dotted, isFalse);
    });

    testWidgets('Do now in a filtered view clears the one in another note', (
      tester,
    ) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      notes.create(body: 'Home\n☐ Sweep\n☐ Mop');
      await tasks.reconcileNow();
      tasks.doNow(row('Sweep'));
      await pumpScreen(tester, filter: TaskFilter.note(row('One').note.id));

      await tester.tap(markOf(row('One')));
      await settle(tester);
      await tester.tap(markOf(row('One')));
      await settle(tester);

      expect(row('One').doNow, isTrue);
      expect(row('Sweep').entry.doNow.v, isFalse);
      expect(row('Sweep').dotted, isTrue);
    });

    testWidgets('on a phone the mark is a 44 point target beside the text, '
        'and a tap near the dot picks', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      await pumpScreen(tester);

      tasks.dot(row('One'));
      Finder dotOf(String words) =>
          find.descendant(of: markOf(row(words)), matching: shape());
      double heading() => tester.getTopLeft(find.text('The list')).dx;
      (double, double, double) offsets() => (
        tester.getTopLeft(dotOf('One')).dx - heading(),
        tester.getTopLeft(box('One')).dx - heading(),
        tester.getTopLeft(find.text('One')).dx - heading(),
      );

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      await pumpScreen(tester);
      final onDesktop = offsets();

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      await pumpScreen(tester);
      expect(offsets(), onDesktop, reason: 'the dot, box and words stay put');

      final slot = tester.getRect(markOf(row('Two')));
      expect(slot.width, greaterThanOrEqualTo(44));
      expect(slot.height, greaterThanOrEqualTo(44));
      expect(slot.left, greaterThanOrEqualTo(0), reason: 'inside the screen');
      expect(slot.right, lessThanOrEqualTo(tester.getTopLeft(box('Two')).dx));
      expect(
        find.descendant(of: markOf(row('Two')), matching: shape(hollow: true)),
        findsNothing,
      );

      await tester.tapAt(Offset(slot.left + 34 - 18, slot.center.dy + 16));
      await settle(tester);
      expect(row('Two').dotted, isTrue);
      expect(row('One').doNow, isFalse);
      expect(dotOf('Two'), findsOneWidget);
    });

    testWidgets('on desktop the mark keeps its 20 by 38 slot', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One');
      await pumpScreen(tester);

      expect(tester.getSize(markOf(row('One'))), const Size(20, 38));
      await settle(tester);
    });

    testWidgets('the questions follow a pick made by hand', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two\n☐ Three');
      await pumpScreen(tester);
      expect(find.text('Ready to do this now?'), findsOneWidget);

      await tester.tap(markOf(row('Two')));
      await settle(tester);

      expect(find.text('Ready to do this now?'), findsNothing);
      expect(
        find.textContaining('What do you want to do more than'),
        findsOneWidget,
      );
      expect(find.text('None. Do “Two”'), findsOneWidget);
      expect(
        find.byKey(ValueKey('tasks-candidate-${row('Three').id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('tasks-candidate-${row('One').id}')),
        findsNothing,
      );
    });

    testWidgets('the mark is a button that says what a click does and which '
        'task it is on', (tester) async {
      final handle = tester.ensureSemantics();
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      await pumpScreen(tester);

      SemanticsNode node(String words) =>
          tester.getSemantics(markOf(row(words)));

      expect(node('One').label, 'Pick: One');
      expect(node('One').flagsCollection.isButton, isTrue);

      await tester.tap(markOf(row('One')));
      await settle(tester);
      expect(node('One').label, 'Make Do now: One');

      await tester.tap(markOf(row('One')));
      await settle(tester);
      expect(node('One').label, 'Clear pick: One');
      handle.dispose();
    });

    testWidgets('the Done view has no marks', (tester) async {
      await setUpTasks(tester, 'Errands\n☑ One\n☐ Two');
      await pumpScreen(tester, filter: const TaskFilter.done());
      await settle(tester);
      expect(tip('Pick to do next'), findsNothing);
    });

    for (final (name, theme) in [
      ('dark', KapyTheme.dark()),
      ('light', KapyTheme.light()),
    ]) {
      testWidgets('hover hint, $name', (tester) async {
        await setUpTasks(tester, 'Errands\n☐ One\n☐ Two\n☐ Three');
        tasks.dot(tasks.read().open.first);
        await pumpScreen(tester, theme: theme);
        await hover(tester, 'Two');
        await settle(tester);
        await expectLater(
          find.byType(TasksScreen),
          matchesGoldenFile('goldens/tasks_pick_hover_$name.png'),
        );
      });
    }
  });
}
