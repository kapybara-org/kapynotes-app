import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
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
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: TasksScreen(
            controller: tasks,
            filter: filter,
            query: '',
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
    tasks.doNow(open[1], open);
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
    tasks.doNow(open[1], open);
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
      tasks.doNow(open[0], open);
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
    tasks.doNow(open[0], open);
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
}
