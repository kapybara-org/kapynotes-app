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

  Future<void> setUpTasks(
    WidgetTester tester,
    String body, {
    bool editable = true,
  }) async {
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
      canEdit: (_) => editable,
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

  testWidgets('a task with details shows the lines mark, and one without shows none', (
    tester,
  ) async {
    await setUpTasks(
      tester,
      'Errands\n☐ Hide the menu\n  It shrinks to a pill.\n☐ Book flights',
    );
    await pumpScreen(tester);
    final open = tasks.read().open;

    Finder markIn(String id) => find.descendant(
      of: rowOf(id),
      matching: find.byWidgetPredicate(
        (widget) => widget is KapyIcon && widget.icon == KapyIcons.alignLeft,
      ),
    );
    expect(markIn(open[0].id), findsOneWidget);
    expect(markIn(open[1].id), findsNothing);
    await settle(tester);
  });

  testWidgets(
    'a note shared to view only shows its details and takes nothing',
    (tester) async {
      await setUpTasks(
        tester,
        'Errands\n☐ Hide the menu\n  It shrinks to a pill.\n☐ Book flights',
        editable: false,
      );
      await pumpScreen(tester);
      final open = tasks.read().open;

      await tester.tap(nameIn(open[0].id, 'Hide the menu'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(TaskDetailsSheet),
          matching: find.byType(TextField),
        ),
      );
      expect(field.readOnly, isTrue);
      expect(sheetDetails(tester), 'It shrinks to a pill.');
      expect(
        find.text('You can view this note, not change it.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(nameIn(open[1].id, 'Book flights'));
      await tester.pumpAndSettle();
      expect(find.text('Add details'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(TaskDetailsSheet),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
      await settle(tester);
    },
  );

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
    expect([
      for (final item in tasks.read().open) item.words,
    ], isNot(contains('Two')));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(sheetOpen(), isFalse);
    expect(
      noteBody(),
      'Errands\n☐ One\n  First detail\n☑ Two\n  Second detail',
    );
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

  testWidgets('an ask made before the screen opened still opens its sheet', (
    tester,
  ) async {
    await setUpTasks(
      tester,
      'Errands\n☐ One\n  First detail\n☐ Two\n  Second detail',
    );
    final two = tasks.read().open.last;
    // The menu bar click that happens while the app is still showing Notes.
    tasks.requestSheet(two.id);
    await pumpScreen(tester);

    expect(sheetOpen(), isTrue);
    expect(sheetDetails(tester), 'Second detail');

    // The same task asked for again still arrives.
    tasks.requestSheet(two.id);
    await tester.pumpAndSettle();
    expect(sheetOpen(), isTrue);
    await settle(tester);
  });

  testWidgets('typing in the sheet leaves a picture line exactly as it was', (
    tester,
  ) async {
    await setUpTasks(
      tester,
      'Errands\n☐ Hide the menu\n  The menu stays up.\n  ￼\n☐ Book flights',
    );
    final hide = tasks.read().open.first;
    await pumpScreen(tester);

    await tester.tap(nameIn(hide.id, 'Hide the menu'));
    await tester.pumpAndSettle();

    final field = find.descendant(
      of: find.byType(TaskDetailsSheet),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'The menu stays up, then shrinks.\n￼');
    await tester.pumpAndSettle();

    expect(
      noteBody(),
      'Errands\n☐ Hide the menu\n  The menu stays up, then shrinks.\n  ￼\n☐ Book flights',
    );
    expect(noteBody().contains('picture'), isFalse);
    await settle(tester);
  });

  testWidgets('a smaller task inside the details counts on its parent', (
    tester,
  ) async {
    await setUpTasks(tester, 'Errands\n☐ Pack\n  ☐ Socks\n  ☑ Charger');
    await pumpScreen(tester);
    final pack = tasks.read().open.single;

    expect(
      find.descendant(
        of: rowOf(pack.id),
        matching: find.textContaining('1 of 3'),
      ),
      findsOneWidget,
    );
    expect(find.text('Socks'), findsNothing);
    expect(pack.groupTotal, 3);
    await settle(tester);
  });
}
