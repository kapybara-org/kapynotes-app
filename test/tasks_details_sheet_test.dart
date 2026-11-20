import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/task_details_sheet.dart';
import 'package:kapy_notes/ui/tasks/task_marks.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tasks-details-sheet-test.json');

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

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: TasksScreen(
            controller: tasks,
            filter: const TaskFilter.all(),
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

  String noteBody() => notes.allNotes.first.body;

  /// Lets the store's own writes land, so no timer outlives the test.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
  }

  Finder rowOf(String id) => find.byKey(ValueKey(id));

  Finder nameIn(String id, String words) =>
      find.descendant(of: rowOf(id), matching: find.text(words));

  /// What the sheet is showing: the words of the task's details.
  String sheetDetails(WidgetTester tester) {
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(TaskDetailsSheet),
        matching: find.byType(TextField),
      ),
    );
    return field.controller!.text;
  }

  bool sheetOpen() => find.byType(TaskDetailsSheet).evaluate().isNotEmpty;

  testWidgets('clicking a task name opens its details, read from the note', (
    tester,
  ) async {
    await setUpTasks(
      tester,
      'Errands\n☐ Hide the menu\n  It shrinks to a pill after a few seconds.\n☐ Book flights',
    );
    await pumpScreen(tester);
    final hide = tasks.read().open.first;

    expect(sheetOpen(), isFalse);
    await tester.tap(nameIn(hide.id, 'Hide the menu'));
    await tester.pumpAndSettle();

    expect(sheetOpen(), isTrue);
    expect(find.text('Open in note'), findsOneWidget);
    expect(sheetDetails(tester), 'It shrinks to a pill after a few seconds.');
    await settle(tester);
  });

  testWidgets('the arrows move the sheet, Space marks done, Esc closes it', (
    tester,
  ) async {
    await setUpTasks(
      tester,
      'Errands\n☐ One\n  First detail\n☐ Two\n  Second detail',
    );
    await pumpScreen(tester);
    final open = tasks.read().open;

    await tester.tap(nameIn(open[0].id, 'One'));
    await tester.pumpAndSettle();
    expect(sheetDetails(tester), 'First detail');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(sheetDetails(tester), 'Second detail');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(noteBody(), contains('☑ Two'));
    expect(
      [for (final item in tasks.read().open) item.words],
      isNot(contains('Two')),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(sheetOpen(), isFalse);
    expect(noteBody(), 'Errands\n☐ One\n  First detail\n☑ Two\n  Second detail');
    await settle(tester);
  });

  testWidgets('Add details writes a line under the task, in its note', (
    tester,
  ) async {
    await setUpTasks(tester, 'Errands\n☐ Book flights');
    await pumpScreen(tester);
    final task = tasks.read().open.single;

    await tester.tap(nameIn(task.id, 'Book flights'));
    await tester.pumpAndSettle();
    expect(find.text('Add details'), findsOneWidget);

    await tester.tap(find.text('Add details'));
    await tester.pumpAndSettle();
    expect(noteBody(), 'Errands\n☐ Book flights\n  ');

    await tester.enterText(
      find.descendant(
        of: find.byType(TaskDetailsSheet),
        matching: find.byType(TextField),
      ),
      'Before Friday.',
    );
    await tester.pumpAndSettle();
    expect(noteBody(), 'Errands\n☐ Book flights\n  Before Friday.');
    await settle(tester);
  });

  testWidgets('a smaller task inside the details counts on its parent', (
    tester,
  ) async {
    await setUpTasks(
      tester,
      'Errands\n☐ Pack\n  ☐ Socks\n  ☑ Charger',
    );
    await pumpScreen(tester);
    final pack = tasks.read().open.single;

    expect(find.descendant(of: rowOf(pack.id), matching: find.textContaining('1 of 3')), findsOneWidget);
    expect(find.text('Socks'), findsNothing);
    expect(pack.groupTotal, 3);
    await settle(tester);
  });
}
