import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/editor/image_insertion.dart';
import 'package:kapy_notes/ui/editor/task_details_editing.dart';
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

  Future<void> pumpScreen(
    WidgetTester tester, {
    String? noteId,
    ValueChanged<String>? onOpenNote,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: TasksScreen(
            controller: tasks,
            filter: noteId == null
                ? const TaskFilter.all()
                : TaskFilter.note(noteId),
            addFocus: addFocus,
            labelOf: (note) => note.title,
            onOpenNote: onOpenNote ?? (_) {},
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

  testWidgets(
    'a task with details shows the lines mark, and one without shows none',
    (tester) async {
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
    },
  );

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
      expect(field.decoration?.hintText, isNull);
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

  testWidgets(
    'typing in the sheet leaves a dropped picture exactly as it was',
    (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Book flights');
      final note = notes.allNotes.first;
      final caret = note.body.indexOf('\n☐ Book');
      final dropped = attachMediaUnderTask(
        bodyBefore: note.body,
        inserted: insertImagesIntoBody(
          body: note.body,
          existing: note.attachments,
          caret: caret,
          incoming: [
            NoteImageRef(
              offset: 0,
              hash: 'menu-picture',
              key: Uint8List(32),
              mime: 'image/png',
              width: 10,
              height: 10,
              bytes: 8,
            ),
          ],
        ),
      );
      notes.updateDocument(
        note.id,
        dropped.body,
        note.formats,
        dropped.attachments,
      );
      await tasks.reconcileNow();
      final hide = tasks.read().open.first;
      await pumpScreen(tester);

      await tester.tap(nameIn(hide.id, 'Hide the menu'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(TaskDetailPicture),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KapyIcon && widget.icon == KapyIcons.imageOutlined,
          ),
        ),
        findsOneWidget,
      );

      final field = find.descendant(
        of: find.byType(TaskDetailsSheet),
        matching: find.byType(TextField),
      );
      await tester.enterText(
        field,
        'The menu stays up, then shrinks.\n${sheetDetails(tester)}',
      );
      await tester.pumpAndSettle();

      final body = noteBody();
      expect(
        body,
        'Errands\n☐ Hide the menu\n  The menu stays up, then shrinks.\n  ￼\n\n'
        '☐ Book flights',
      );
      final picture = notes.allNotes.first.attachments.single as NoteImageRef;
      expect(picture.hash, 'menu-picture');
      expect(picture.offset, body.indexOf('￼'));
      await settle(tester);
    },
  );

  group('typing in a parent\'s sheet keeps the nesting inside its details', () {
    const before =
        'Errands\n☐ Pack\n  Bring the big bag\n  \n  ☐ Socks\n'
        '    three pairs\n      • wool ones\n  ☑ Charger\n☐ Book flights';
    final cases = <String, (String Function(String), String)>{
      'an edit in the middle': (
        (words) => words.replaceFirst('three pairs', 'four pairs'),
        before.replaceFirst('    three pairs', '    four pairs'),
      ),
      'a new line': (
        (words) => words.replaceFirst('big bag', 'big bag\nand a lock'),
        before.replaceFirst('big bag\n', 'big bag\n  and a lock\n'),
      ),
      'a deleted line': (
        (words) => words.replaceFirst('\n    • wool ones', ''),
        before.replaceFirst('\n      • wool ones', ''),
      ),
    };
    for (final MapEntry(key: name, value: (edit, after)) in cases.entries) {
      testWidgets(name, (tester) async {
        await setUpTasks(tester, before);
        await pumpScreen(tester);
        final pack = tasks.read().open.first;
        await tester.tap(nameIn(pack.id, 'Pack  1 of 3'));
        await tester.pumpAndSettle();
        expect(
          sheetDetails(tester),
          'Bring the big bag\n\n☐ Socks\n  three pairs\n    • wool ones\n'
          '☑ Charger',
        );

        await tester.enterText(
          find.descendant(
            of: find.byType(TaskDetailsSheet),
            matching: find.byType(TextField),
          ),
          edit(sheetDetails(tester)),
        );
        await tester.pumpAndSettle();

        expect(noteBody(), after);
        expect(tasks.read().open.map((item) => item.words), [
          'Pack',
          'Book flights',
        ]);
        expect(tasks.read().open.first.groupTotal, 3);
        await settle(tester);
      });
    }
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets('at ${scale}x text, the sheet scrolls to Open in note and '
        'nothing overflows', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final lines = [
        for (var i = 1; i <= 9; i++) '  Line $i of the details',
      ].join('\n');
      await setUpTasks(
        tester,
        'Errands\n☐ Ask the landlord about the boiler service, the latch on '
        'the back bedroom window, the parking permit and spare keys\n  ￼\n'
        '$lines',
      );
      final opened = <String>[];
      await pumpScreen(tester, onOpenNote: opened.add);
      final item = tasks.read().open.single;
      await tester.tap(
        find
            .descendant(
              of: rowOf(item.id),
              matching: find.textContaining('Ask the landlord'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final open = find.descendant(
        of: find.byType(TaskDetailsSheet),
        matching: find.text('Open in note'),
      );
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      final sheet = tester.getRect(find.byType(TaskDetailsSheet));
      expect(sheet.contains(tester.getCenter(open)), isTrue);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(opened, [item.note.id]);
      expect(tester.takeException(), isNull);
      await settle(tester);
    });
  }

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

  testWidgets(
    'on a note shared to view only, a row\'s box is faint and takes no tap',
    (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Hide the menu', editable: false);
      await pumpScreen(tester);
      final faint = find.descendant(
        of: rowOf(tasks.read().open.first.id),
        matching: find.byWidgetPredicate(
          (widget) => widget is Opacity && widget.opacity == lockedBoxOpacity,
        ),
      );
      expect(faint, findsOneWidget);
      expect(
        tester
            .widget<InkResponse>(
              find
                  .ancestor(of: faint, matching: find.byType(InkResponse))
                  .first,
            )
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<Semantics>(
              find.ancestor(
                of: faint,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics && widget.properties.checked != null,
                ),
              ),
            )
            .properties
            .enabled,
        isFalse,
      );
      await settle(tester);
    },
  );

  testWidgets('a row\'s box on a note you can change is drawn in full', (
    tester,
  ) async {
    await setUpTasks(tester, 'Errands\n☐ Hide the menu');
    await pumpScreen(tester);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Opacity && widget.opacity == lockedBoxOpacity,
      ),
      findsNothing,
    );
    await settle(tester);
  });

  testWidgets('a Do now task in a note shared to view only has no Done', (
    tester,
  ) async {
    await setUpTasks(tester, 'Errands\n☐ Hide the menu', editable: false);
    tasks.doNow(tasks.read().open.first);
    await pumpScreen(tester);
    expect(tasks.read().open.first.doNow, isTrue);
    expect(find.text('Not finished'), findsOneWidget);
    expect(find.byKey(const ValueKey('tasks-done')), findsNothing);
    await settle(tester);
  });

  testWidgets('adding a task refuses a note shared to view only', (
    tester,
  ) async {
    await setUpTasks(tester, 'Errands\n☐ Hide the menu', editable: false);
    final note = notes.allNotes.first;
    expect(await tasks.add('Book flights', noteId: note.id), isNull);
    expect(notes.allNotes.first.body, 'Errands\n☐ Hide the menu');
    await settle(tester);
  });

  for (final editable in [true, false]) {
    testWidgets(
      'the Add into list ${editable ? 'offers a note you can change' : 'leaves out a note shared to view only'}',
      (tester) async {
        await setUpTasks(
          tester,
          'Errands\n☐ Hide the menu',
          editable: editable,
        );
        await pumpScreen(tester);
        await tester.tap(find.byKey(const ValueKey('tasks-note-picker')));
        await tester.pumpAndSettle();
        expect(
          find.byType(PopupMenuItem<String>),
          findsNWidgets(editable ? 2 : 1),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
      },
    );

    testWidgets(
      'Tasks narrowed to ${editable ? 'a note you can change has' : 'a note shared to view only has no'} add row',
      (tester) async {
        await setUpTasks(
          tester,
          'Errands\n☐ Hide the menu',
          editable: editable,
        );
        await pumpScreen(tester, noteId: notes.allNotes.first.id);
        expect(
          find.byKey(const ValueKey('tasks-add-row')),
          editable ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('You can view this note, not change it.'),
          editable ? findsNothing : findsOneWidget,
        );
        await settle(tester);
      },
    );
  }

  testWidgets(
    'removing a task from a note shared to view only says it only leaves '
    'your list',
    (tester) async {
      await setUpTasks(
        tester,
        'Errands\n☐ Hide the menu\n☐ Book flights',
        editable: false,
      );
      clock = clock.add(const Duration(days: 365));
      await pumpScreen(tester);
      await tester.tap(find.text('Remove').first);
      await tester.pumpAndSettle();
      expect(find.text('Remove this task from your list?'), findsOneWidget);
      expect(
        find.text(
          'It stays in “Errands” for you and everyone it’s shared with. '
          'You can undo this.',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Remove'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Removed from your list'), findsOneWidget);
      expect(
        notes.allNotes.first.body,
        'Errands\n☐ Hide the menu\n☐ Book flights',
      );
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
    },
  );
}
