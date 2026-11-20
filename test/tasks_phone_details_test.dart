import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/task_details_sheet.dart';
import 'package:kapy_notes/ui/tasks/task_marks.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tasks-phone-details-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  late DateTime clock;
  late NotesStore notes;
  late TaskLibrary library;
  late TasksController tasks;
  late FocusNode addFocus;
  late List<String> opened;

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  Future<void> pumpPhone(
    WidgetTester tester, {
    bool editable = true,
    bool narrowed = false,
  }) async {
    clock = DateTime(2026, 11, 20, 9);
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
    final note = notes.create(
      body:
          'Errands\n☐ Pay the rent\n☐ Call the bank\n☐ Hide the menu\n'
          '  It shrinks to a pill.\n☐ Book flights',
    );
    tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => editable,
      now: tick,
    );
    await tasks.reconcileNow();
    addFocus = FocusNode();
    opened = [];
    addTearDown(() {
      addFocus.dispose();
      tasks.dispose();
      library.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: TasksScreen(
            controller: tasks,
            filter: narrowed
                ? TaskFilter.note(note.id)
                : const TaskFilter.all(),
            addFocus: addFocus,
            labelOf: (note) => note.title,
            onOpenNote: opened.add,
            onOpenDone: () {},
            phone: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // The first two open tasks sit on the pair's cards, so the rows start at
  // the third.
  TaskItem listed() =>
      tasks.read().open.firstWhere((item) => item.words == 'Hide the menu');

  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey('phone-details-body'))).height;

  testWidgets('a phone row opens the details at half height', (tester) async {
    await pumpPhone(tester);
    final hide = listed();

    expect(find.byType(PhoneTaskDetailsSheet), findsNothing);
    await tester.tap(find.byKey(ValueKey('phone-task-${hide.id}')));
    await tester.pumpAndSettle();

    expect(find.byType(PhoneTaskDetailsSheet), findsOneWidget);
    expect(find.text('Close'), findsNothing, reason: 'pulled down to close');
    expect(
      find.descendant(
        of: find.byType(PhoneTaskDetailsSheet),
        matching: find.text('It shrinks to a pill.'),
      ),
      findsOneWidget,
    );
    expect(sheetHeight(tester), closeTo(844 / 2, 2));
    expect(opened, isEmpty, reason: 'the sheet opens, not the note');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'the grabber pulls the sheet to nearly the whole screen, and back down',
    (tester) async {
      await pumpPhone(tester);
      await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
      await tester.pumpAndSettle();
      final grabber = find.byKey(const ValueKey('phone-details-grabber'));

      await tester.drag(grabber, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(sheetHeight(tester), closeTo(844 * 0.92, 2));

      await tester.drag(grabber, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(sheetHeight(tester), closeTo(844 / 2, 2));
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('the sheet sits above the keyboard and the home indicator', (
    tester,
  ) async {
    await pumpPhone(tester);
    tester.view.padding = const FakeViewPadding(bottom: 102);
    addTearDown(tester.view.resetPadding);
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('phone-details-body'));
    final ratio = tester.view.devicePixelRatio;
    expect(
      tester
          .getBottomLeft(
            find.descendant(
              of: find.byType(PhoneTaskDetailsSheet),
              matching: find.text('Errands'),
            ),
          )
          .dy,
      lessThanOrEqualTo(844 - 102 / ratio),
    );

    tester.view.viewInsets = FakeViewPadding(bottom: 300 * ratio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(body).dy, closeTo(844 - 300, 1));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a short pull down closes the sheet', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('phone-details-grabber')),
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PhoneTaskDetailsSheet), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a tap on the dimmed list above the sheet closes it', (
    tester,
  ) async {
    await pumpPhone(tester);
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(195, 120));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneTaskDetailsSheet), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a pull down on the body, below half, closes the sheet', (
    tester,
  ) async {
    await pumpPhone(tester);
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.descendant(
        of: find.byType(PhoneTaskDetailsSheet),
        matching: find.text('Errands'),
      ),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PhoneTaskDetailsSheet), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the sheet closes when its task leaves the note', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneTaskDetailsSheet), findsOneWidget);

    notes.updateBody(notes.allNotes.first.id, 'Errands\n☐ Book flights');
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    expect(find.byType(PhoneTaskDetailsSheet), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Book flights'), findsWidgets);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the sheet edits the note it came from, and opens it', (
    tester,
  ) async {
    await pumpPhone(tester);
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(TaskDetailsSheet),
        matching: find.byType(TextField),
      ),
      'It shrinks to a pill after a few seconds.',
    );
    await tester.pumpAndSettle();
    expect(
      notes.allNotes.first.body,
      contains('  It shrinks to a pill after a few seconds.'),
    );

    await tester.tap(find.text('Open in note'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneTaskDetailsSheet), findsNothing);
    expect(opened, [notes.allNotes.first.id]);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the box in the sheet marks the task done in its note', (
    tester,
  ) async {
    await pumpPhone(tester);
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('phone-details-box')));
    await tester.pumpAndSettle();
    expect(notes.allNotes.first.body, contains('☑ Hide the menu'));
    expect(find.byType(PhoneTaskDetailsSheet), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'a note shared to view only shows its details and takes nothing',
    (tester) async {
      await pumpPhone(tester, editable: false);
      final before = notes.allNotes.first.body;
      await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(TaskDetailsSheet),
          matching: find.byType(TextField),
        ),
      );
      expect(field.readOnly, isTrue);
      expect(field.decoration?.hintText, isNull);
      expect(
        find.text('You can view this note, not change it.'),
        findsOneWidget,
      );
      final box = find.byKey(const ValueKey('phone-details-box'));
      expect(tester.widget<GestureDetector>(box).onTap, isNull);
      expect(
        find.descendant(
          of: box,
          matching: find.byWidgetPredicate(
            (widget) => widget is Opacity && widget.opacity == lockedBoxOpacity,
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Semantics>(
              find.ancestor(of: box, matching: find.byType(Semantics)).first,
            )
            .properties
            .onTap,
        isNull,
      );

      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(notes.allNotes.first.body, before);
      expect(find.text('Open in note'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'on a note shared to view only, a phone row\'s box is faint and takes no tap',
    (tester) async {
      await pumpPhone(tester, editable: false);
      final box = find.byKey(ValueKey('phone-task-box-${listed().id}'));
      expect(tester.widget<GestureDetector>(box).onTap, isNull);
      expect(
        tester
            .widget<Semantics>(
              find.ancestor(of: box, matching: find.byType(Semantics)).first,
            )
            .properties
            .onTap,
        isNull,
      );
      expect(
        find.descendant(
          of: box,
          matching: find.byWidgetPredicate(
            (widget) => widget is Opacity && widget.opacity == lockedBoxOpacity,
          ),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'a Do now task in a note shared to view only has no Done on a phone',
    (tester) async {
      await pumpPhone(tester, editable: false);
      tasks.doNow(tasks.read().open.first);
      await tester.pumpAndSettle();
      expect(tasks.read().open.first.doNow, isTrue);
      expect(find.byKey(const ValueKey('tasks-not-finished')), findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-done')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  for (final editable in [true, false]) {
    testWidgets(
      'on a phone, Tasks narrowed to ${editable ? 'a note you can change has' : 'a note shared to view only has no'} add row',
      (tester) async {
        await pumpPhone(tester, editable: editable, narrowed: true);
        expect(
          find.byKey(const ValueKey('tasks-add-row')),
          editable ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const ValueKey('tasks-add-view-only')),
          editable ? findsNothing : findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 3));
      },
    );
  }

  testWidgets('a phone row shows the lines mark, as the window does', (
    tester,
  ) async {
    await pumpPhone(tester);
    Finder markIn(String id) => find.descendant(
      of: find.byKey(ValueKey('phone-task-$id')),
      matching: find.byWidgetPredicate(
        (widget) => widget is KapyIcon && widget.icon == KapyIcons.alignLeft,
      ),
    );
    expect(markIn(listed().id), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
