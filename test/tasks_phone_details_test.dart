import 'package:flutter/foundation.dart';
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

  final page = find.byType(PhoneTaskPage);

  Future<void> openListed(WidgetTester tester) async {
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();
  }

  testWidgets('a phone row pushes the task\'s page: ← Tasks, Open in note, '
      'the task, its note and day, and its details', (tester) async {
    await pumpPhone(tester);

    expect(page, findsNothing);
    await openListed(tester);

    expect(page, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Close'), findsNothing);
    Finder inPage(Finder finder) => find.descendant(of: page, matching: finder);
    expect(inPage(find.byKey(const ValueKey('page-back'))), findsOneWidget);
    expect(inPage(find.text('Tasks')), findsOneWidget);
    expect(inPage(find.text('Open in note')), findsOneWidget);
    expect(inPage(find.text('Hide the menu')), findsOneWidget);
    expect(inPage(find.text('Errands · Today, Fri 20')), findsOneWidget);
    expect(inPage(find.text('It shrinks to a pill.')), findsOneWidget);
    final back = tester.getRect(find.byKey(const ValueKey('page-back')));
    final open = tester.getRect(
      find.byKey(const ValueKey('phone-task-open-note')),
    );
    expect(back.left, lessThan(40), reason: 'top left');
    expect(open.right, greaterThan(390 - 40), reason: 'top right');
    expect(open.center.dy, closeTo(back.center.dy, 1), reason: 'on one row');
    expect(opened, isEmpty, reason: 'the page opens, not the note');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('← Tasks goes back to the list where it was scrolled to', (
    tester,
  ) async {
    await pumpPhone(tester);
    final note = notes.allNotes.first;
    notes.updateBody(
      note.id,
      '${note.body}\n${[for (var index = 0; index < 20; index++) '☐ Errand $index'].join('\n')}',
    );
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
    final scrolled = tester.state<ScrollableState>(list).position.pixels;
    expect(scrolled, greaterThan(0));

    final row = find
        .byWidgetPredicate(
          (widget) => switch (widget.key) {
            ValueKey<String>(:final value) =>
              value.startsWith('phone-task-') &&
                  !value.startsWith('phone-task-box-'),
            _ => false,
          },
        )
        .hitTestable()
        .first;
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(page, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('page-back')));
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(tester.state<ScrollableState>(list).position.pixels, scrolled);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the system back goes back to Tasks', (tester) async {
    await pumpPhone(tester);
    await openListed(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.byType(TasksScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("iOS's swipe from the left edge goes back to Tasks", (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pumpPhone(tester);
    await openListed(tester);
    await tester.dragFrom(const Offset(4, 400), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.byType(TasksScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('every control on the page is 44 pt to tap, and says what it '
      'does to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPhone(tester);
    await openListed(tester);
    for (final key in [
      'page-back',
      'phone-task-open-note',
      'phone-details-box',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
      expect(size.height, greaterThanOrEqualTo(44), reason: key);
    }
    expect(find.bySemanticsLabel('Back to Tasks'), findsOneWidget);
    expect(find.bySemanticsLabel('Open in note'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('phone-details-box'))),
      matchesSemantics(
        label: 'Hide the menu',
        hasCheckedState: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('long details scroll clear of the home indicator, and of the '
      'keyboard while typed into', (tester) async {
    await pumpPhone(tester);
    notes.updateBody(
      notes.allNotes.first.id,
      'Errands\n☐ Pay the rent\n☐ Call the bank\n☐ Hide the menu\n'
      '${[for (var line = 1; line <= 40; line++) '  Line $line'].join('\n')}',
    );
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    tester.view.padding = const FakeViewPadding(bottom: 102);
    addTearDown(tester.view.resetPadding);
    final ratio = tester.view.devicePixelRatio;
    await openListed(tester);
    expect(page, findsOneWidget);
    final field = find.descendant(of: page, matching: find.byType(TextField));

    await tester.drag(field, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(field).dy,
      lessThanOrEqualTo(844 - 102 / ratio),
    );

    tester.view.viewInsets = FakeViewPadding(bottom: 300 * ratio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.drag(field, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(field).dy, lessThanOrEqualTo(844 - 300));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the page goes back when its task leaves the note', (
    tester,
  ) async {
    await pumpPhone(tester);
    await openListed(tester);
    expect(page, findsOneWidget);

    notes.updateBody(notes.allNotes.first.id, 'Errands\n☐ Book flights');
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.text('Book flights'), findsWidgets);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the page edits the note it came from, and Open in note opens '
      'it', (tester) async {
    await pumpPhone(tester);
    await openListed(tester);

    await tester.enterText(
      find.descendant(of: page, matching: find.byType(TextField)),
      'It shrinks to a pill after a few seconds.',
    );
    await tester.pumpAndSettle();
    expect(
      notes.allNotes.first.body,
      contains('  It shrinks to a pill after a few seconds.'),
    );

    await tester.tap(find.text('Open in note'));
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(opened, [notes.allNotes.first.id]);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the box on the page marks the task done in its note, and '
      'back again', (tester) async {
    await pumpPhone(tester);
    await openListed(tester);
    final box = find.byKey(const ValueKey('phone-details-box'));

    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(notes.allNotes.first.body, contains('☑ Hide the menu'));
    expect(page, findsOneWidget);

    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(notes.allNotes.first.body, contains('☐ Hide the menu'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a task with no details offers Add details, which writes '
      'under it', (tester) async {
    await pumpPhone(tester);
    final flights = tasks.read().open.firstWhere(
      (item) => item.words == 'Book flights',
    );
    await tester.tap(find.byKey(ValueKey('phone-task-${flights.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Writes under the task, in its note.'), findsOneWidget);

    await tester.tap(find.text('Add details'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(of: page, matching: find.byType(TextField)),
      'Window seat',
    );
    await tester.pumpAndSettle();
    expect(
      notes.allNotes.first.body,
      endsWith('☐ Book flights\n  Window seat'),
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'a note shared to view only shows its details and takes nothing',
    (tester) async {
      await pumpPhone(tester, editable: false);
      final before = notes.allNotes.first.body;
      await openListed(tester);

      final field = tester.widget<TextField>(
        find.descendant(of: page, matching: find.byType(TextField)),
      );
      expect(field.readOnly, isTrue);
      expect(field.decoration?.hintText, isNull);
      expect(find.text('Add details'), findsNothing);
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
