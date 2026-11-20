import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:kapy_notes/ui/tasks/task_choice.dart';
import 'package:kapy_notes/ui/tasks/task_details_sheet.dart';
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
    bool phone = false,
    ValueChanged<String>? onOpenNote,
    VoidCallback? onOpenDone,
    double textScale = 1,
    Size? size,
  }) async {
    await tester.binding.setSurfaceSize(
      size ?? (phone ? const Size(393, 852) : const Size(900, 1000)),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? KapyTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: TasksScreen(
            controller: tasks,
            filter: filter,
            addFocus: addFocus,
            labelOf: (note) => note.title,
            onOpenNote: onOpenNote ?? (_) {},
            onOpenDone: onOpenDone ?? () {},
            newTaskShortcut: '⌘N',
            phone: phone,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  Future<void> setUpTasks(
    WidgetTester tester,
    String body, {
    DateTime? at,
  }) async {
    clock = at ?? DateTime(2026, 11, 17, 9);
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

  TaskItem item(String words) =>
      tasks.read().open.firstWhere((item) => item.words == words);

  Finder inPair(String key, String text) => find.descendant(
    of: find.byKey(ValueKey('tasks-pair-$key')),
    matching: find.text(text),
  );

  Future<void> hoverOn(WidgetTester tester, Finder target) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();
  }

  const errands =
      'Errands\n☐ Send the report\n☐ Book flights\n☐ Call the garage\n'
      '☐ Pay the rent';

  group('the pair', () {
    testWidgets('with nothing chosen: the first task on the list against the '
        'next, the count, Start with, and the rest below', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester);

      expect(find.text('What do you want to work on next?'), findsOneWidget);
      expect(inPair('left', 'First on the list'), findsOneWidget);
      expect(inPair('left', 'Send the report'), findsOneWidget);
      expect(inPair('right', 'Next on the list'), findsOneWidget);
      expect(inPair('right', 'Book flights'), findsOneWidget);
      expect(find.text('2 more pairs after this'), findsOneWidget);
      expect(
        find.text('The one you don’t pick waits its turn.'),
        findsOneWidget,
      );
      expect(find.text('Start with Send the report'), findsOneWidget);
      expect(find.text('esc'), findsOneWidget);
      expect(find.text('Up next'), findsNothing);
      expect(box('Call the garage'), findsOneWidget);
      expect(box('Send the report'), findsNothing);
      expect(find.text('←'), findsOneWidget);
      expect(find.text('→'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('a click on the left keeps your choice; a click on the right '
        'makes it your choice and the old one waits in Up next', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester);

      await tester.tap(find.byKey(const ValueKey('tasks-pair-left')));
      await settle(tester);
      expect(inPair('left', 'Your choice so far'), findsOneWidget);
      expect(inPair('right', 'Call the garage'), findsOneWidget);
      expect(find.text('1 more pair after this'), findsOneWidget);
      expect(box('Book flights'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
      await settle(tester);
      expect(inPair('left', 'Call the garage'), findsOneWidget);
      expect(inPair('right', 'Pay the rent'), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);
      expect(box('Send the report'), findsOneWidget);
      expect(
        tester.getTopLeft(box('Send the report')).dy,
        lessThan(tester.getTopLeft(box('Book flights')).dy),
      );
      await settle(tester);
    });

    testWidgets('the keys: ← keeps, → takes, esc starts with your choice', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester);
      final screen = tester.state<TasksScreenState>(find.byType(TasksScreen));
      expect(screen.takeNext(), isTrue);
      await settle(tester);
      expect(inPair('left', 'Book flights'), findsOneWidget);
      tasks.chooseAgain();
      await settle(tester);

      expect(screen.keepChoice(), isTrue);
      await settle(tester);
      expect(inPair('right', 'Call the garage'), findsOneWidget);
      expect(screen.startEarly(), isTrue);
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
      expect(item('Send the report').doNow, isTrue);
      expect(screen.keepChoice(), isFalse);
      expect(screen.takeNext(), isFalse);
      expect(screen.startEarly(), isFalse);
      await settle(tester);
    });

    testWidgets('on the last pair Start with goes and the foot says the pick '
        'becomes Do now', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('tasks-start')), findsNothing);
      expect(
        find.text('Your pick becomes Do now. The other waits its turn.'),
        findsOneWidget,
      );
      expect(find.textContaining('more pair'), findsNothing);
      final screen = tester.state<TasksScreenState>(find.byType(TasksScreen));
      expect(screen.startEarly(), isFalse);

      await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
      expect(item('Two').doNow, isTrue);
      expect(find.text('Up next'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('Start with uses the task\'s first words', (tester) async {
      await setUpTasks(
        tester,
        'Errands\n☐ Ask Ana which Sintra palace to skip\n☐ B\n☐ C',
      );
      await pumpScreen(tester);
      expect(find.text('Start with Ask Ana'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Start with Ask Ana which Sintra palace to skip'),
        findsOneWidget,
      );
      await settle(tester);
    });

    testWidgets('screen readers hear what each card is and what a tap does', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await setUpTasks(tester, errands);
      await pumpScreen(tester);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('tasks-pair-left'))),
        matchesSemantics(
          label: 'First on the list: Send the report',
          hint: 'Choose',
          isButton: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tasks-pair-left')));
      await settle(tester);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('tasks-pair-right'))),
        matchesSemantics(
          label: 'Next on the list: Call the garage',
          hint: 'Choose this instead',
          isButton: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
      await settle(tester);
    });
  });

  group('Do now', () {
    testWidgets('Done ticks it in its note; with nothing new, the first task '
        'in Up next is Do now', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two\n☐ Three');
      final open = tasks.read().open;
      tasks.dot(open[0]);
      tasks.doNow(open[1]);
      await pumpScreen(tester);
      expect(find.text('Do now'), findsOneWidget);
      expect(find.text('⌘↵'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tasks-done')));
      await settle(tester);
      expect(notes.notes.single.body, 'Errands\n☐ One\n☑ Two\n☐ Three');
      expect(item('One').doNow, isTrue);
      expect(find.text('Three'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('after Done, a task added since you chose comes back as a '
        'pair, under a line saying what was done', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two\n☐ Three');
      final open = tasks.read().open;
      tasks.dot(open[0]);
      tasks.doNow(open[1]);
      await pumpScreen(tester);
      await tester.runAsync(() => tasks.add('Four', noteId: open[0].note.id));
      await tester.pump();

      tester.state<TasksScreenState>(find.byType(TasksScreen)).completeDoNow();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await settle(tester);
      expect(find.text('Two is done.'), findsOneWidget);
      expect(inPair('left', 'Your choice so far'), findsOneWidget);
      expect(inPair('left', 'One'), findsOneWidget);
      expect(inPair('right', 'New since you chose'), findsOneWidget);
      expect(inPair('right', 'Four'), findsOneWidget);
      expect(find.textContaining('added 09:'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('Not finished sends Do now to the end of the list with ↺', (
      tester,
    ) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two\n☐ Three');
      final open = tasks.read().open;
      tasks.dot(open[1]);
      tasks.doNow(open[0]);
      await pumpScreen(tester);

      await tester.tap(find.byKey(const ValueKey('tasks-not-finished')));
      await settle(tester);
      expect(
        [for (final i in tasks.read().open) i.words],
        ['Two', 'Three', 'One'],
      );
      expect(item('Two').doNow, isTrue);
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Not finished, moved to the end',
        ),
        findsOneWidget,
      );
      await settle(tester);
    });

    testWidgets('Not finished and Done sit at the right edge of the card, '
        'with the note on the left', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      tasks.doNow(tasks.read().open[0]);
      await pumpScreen(tester);

      final card = tester.getRect(find.byKey(const ValueKey('tasks-do-now')));
      final done = tester.getRect(find.byKey(const ValueKey('tasks-done')));
      final notFinished = tester.getRect(
        find.byKey(const ValueKey('tasks-not-finished')),
      );
      final note = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('tasks-do-now')),
          matching: find.text('Errands'),
        ),
      );
      expect(card.right - done.right, lessThan(24));
      expect(notFinished.right, lessThanOrEqualTo(done.left));
      expect(note.left - card.left, lessThan(40));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('tasks-done'))),
        matchesSemantics(label: 'Done', isButton: true, hasTapAction: true),
      );
      await settle(tester);
    });
  });

  testWidgets('in the evening, with something finished and nothing chosen, '
      'the day closes; Keep going brings the pair back, and the finished '
      'line opens Done', (tester) async {
    await setUpTasks(
      tester,
      'Errands\n☐ Done one\n☐ Left one\n☐ Left two',
      at: DateTime(2026, 11, 19, 18, 30),
    );
    await tester.runAsync(
      () => tasks.setDone(tasks.read().open.first, done: true),
    );
    var opened = false;
    await pumpScreen(tester, onOpenDone: () => opened = true);

    expect(find.text('Done for today.'), findsOneWidget);
    expect(
      find.text(
        '1 finished. The 2 left wait here for tomorrow, in this order.',
      ),
      findsOneWidget,
    );
    expect(find.text('1 finished today'), findsOneWidget);
    expect(find.byKey(const ValueKey('tasks-pair')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tasks-finished-today')));
    expect(opened, isTrue);

    await tester.tap(find.byKey(const ValueKey('tasks-keep-going')));
    await settle(tester);
    expect(find.byKey(const ValueKey('tasks-pair')), findsOneWidget);
    await settle(tester);
  });

  group('rows', () {
    testWidgets('a hovered row says when it was added and offers its menu', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester);
      await hoverOn(tester, find.text('Pay the rent'));
      expect(find.text('Added Tue 17 Nov'), findsOneWidget);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      for (final entry in [
        'Do now',
        'Add to Up next',
        'Move to the end',
        'Details',
        'Open “Errands”',
        'Remove…',
      ]) {
        expect(find.byKey(ValueKey('task-menu-$entry')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('task-menu-Add to Up next')));
      await settle(tester);
      expect(item('Pay the rent').dotted, isTrue);
      await settle(tester);
    });

    testWidgets(
      'an Up next row offers Take out of Up next, from a right-click',
      (tester) async {
        await setUpTasks(tester, errands);
        tasks.dot(tasks.read().open[0]);
        tasks.doNow(tasks.read().open[1]);
        await pumpScreen(tester);
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await mouse.addPointer(
          location: tester.getCenter(find.text('Send the report')),
        );
        await mouse.down(tester.getCenter(find.text('Send the report')));
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('task-menu-Take out of Up next')),
        );
        await settle(tester);
        expect(item('Send the report').dotted, isFalse);
        expect(find.text('Up next'), findsNothing);
      },
    );

    testWidgets('the menu reads out to screen readers as actions', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await setUpTasks(tester, errands);
      await pumpScreen(tester);
      final node = tester.getSemantics(
        find
            .ancestor(
              of: find.text('Pay the rent'),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Semantics &&
                    w.properties.customSemanticsActions != null,
              ),
            )
            .first,
      );
      expect(node.getSemanticsData().customSemanticsActionIds, hasLength(6));
      semantics.dispose();
      await settle(tester);
    });

    testWidgets('a task untouched for two weeks asks Still want this?; Keep '
        'stops asking', (tester) async {
      await setUpTasks(tester, errands);
      clock = clock.add(const Duration(days: 15));
      await pumpScreen(tester);
      expect(find.text('Still want this?'), findsNWidgets(2));
      await tester.tap(find.text('Keep').first);
      await settle(tester);
      expect(find.text('Still want this?'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('a row ticked in Tasks leaves the list for Done, and unticking '
        'it there brings it back at the end', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester);

      await tester.tap(box('Pay the rent'));
      await settle(tester);
      expect(item('Call the garage').words, 'Call the garage');
      expect(tasks.read().open.length, 3);

      await pumpScreen(tester, filter: const TaskFilter.done());
      expect(find.text('1 completed'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);

      clock = clock.add(const Duration(minutes: 5));
      await tester.tap(box('Pay the rent'));
      await settle(tester);
      expect(tasks.read().open.last.words, 'Pay the rent');
      await settle(tester);
    });
  });

  testWidgets('the add row adds at the end, says so, and keeps the field for '
      'the next one; Escape leaves it', (tester) async {
    await setUpTasks(tester, 'Errands\n☐ One');
    await pumpScreen(tester);
    expect(addFocus.hasFocus, isFalse);
    expect(find.text('No note'), findsOneWidget);
    expect(find.text('⌘N'), findsOneWidget);

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
    await settle(tester);
  });

  testWidgets('nothing on the list says so, with no pair', (tester) async {
    await setUpTasks(tester, 'Errands\n☑ Done');
    await pumpScreen(tester);
    expect(find.text('Nothing on the list.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tasks-pair')), findsNothing);
    await settle(tester);
  });

  group('the band', () {
    Future<void> pumpBand(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: Row(
              children: [
                TasksTodayCrumb(title: 'Today', now: clock),
                const Spacer(),
                TasksBandActions(
                  controller: tasks,
                  filter: const TaskFilter.all(),
                  onChooseAgain: () => tasks.chooseAgain(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('Today and the date, how much is done today, and Choose again '
        'only while something is chosen', (tester) async {
      await setUpTasks(tester, errands);
      await pumpBand(tester);
      expect(find.text('Tue 17'), findsOneWidget);
      expect(find.text('0 of 4 done today'), findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-choose-again')), findsNothing);

      tasks.keepChoice(tasks.choiceIn(null).stage as PairStage);
      await tester.pump();
      expect(find.byKey(const ValueKey('tasks-choose-again')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tasks-choose-again')));
      await tester.pump();
      expect(tasks.read().open.any((i) => i.dotted), isFalse);
      expect(find.byKey(const ValueKey('tasks-choose-again')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
    });
  });

  group('on a phone', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);

    Finder phoneBox(TaskItem item) =>
        find.byKey(ValueKey('phone-task-box-${item.id}'));

    Finder words(TaskItem item) => find.descendant(
      of: find.byKey(ValueKey('phone-task-${item.id}')),
      matching: find.text(item.words),
    );

    testWidgets('Today with its date and count, the pair as two stacked cards '
        'you tap, and Start with under them; no keys', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Tue 17'), findsOneWidget);
      expect(find.text('0 of 4 done'), findsOneWidget);
      expect(find.byType(Keycap), findsNothing);
      expect(find.text('←'), findsNothing);
      expect(find.text('esc'), findsNothing);
      expect(
        find.text('Tap the one you’d rather do. 2 more pairs after this.'),
        findsOneWidget,
      );
      final left = tester.getRect(
        find.byKey(const ValueKey('tasks-pair-left')),
      );
      final right = tester.getRect(
        find.byKey(const ValueKey('tasks-pair-right')),
      );
      final start = tester.getRect(find.byKey(const ValueKey('tasks-start')));
      expect(right.top, greaterThan(left.bottom));
      expect(start.top, greaterThan(right.bottom));
      expect(start.height, greaterThanOrEqualTo(44));

      await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
      await settle(tester);
      expect(inPair('left', 'Book flights'), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('in the sheet over a note: Today and the count, then Do now '
        'first and the list, with no add row', (tester) async {
      await setUpTasks(tester, errands);
      tasks.dot(tasks.read().open[2]);
      tasks.doNow(tasks.read().open[0]);
      await tester.binding.setSurfaceSize(const Size(393, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
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
              onOpenDone: () {},
              phone: true,
              sheet: true,
              scrollController: scroll,
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-add-row')), findsNothing);
      expect(find.text('0 of 4 done'), findsOneWidget);
      final today = tester.getRect(find.text('Today'));
      final card = tester.getRect(find.byKey(const ValueKey('tasks-do-now')));
      expect(today.top, lessThan(8));
      expect(card.top - today.bottom, lessThan(24));
      expect(find.text('Up next'), findsOneWidget);
      expect(scroll.hasClients, isTrue);
      await settle(tester);
    });

    testWidgets('Do now puts Done first, then Not finished', (tester) async {
      await setUpTasks(tester, errands);
      tasks.doNow(tasks.read().open[0]);
      await pumpScreen(tester, phone: true);
      final done = tester.getRect(find.byKey(const ValueKey('tasks-done')));
      final notFinished = tester.getRect(
        find.byKey(const ValueKey('tasks-not-finished')),
      );
      expect(done.left, lessThan(notFinished.left));
      expect(done.height, greaterThanOrEqualTo(44));
      expect(find.text('⌘↵'), findsNothing);
      await settle(tester);
    });

    testWidgets('a checked row stays, struck through, and unchecks again', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);
      final rent = item('Pay the rent');

      await tester.tap(phoneBox(rent));
      await settle(tester);
      expect(tasks.read().open.length, 3);
      expect(
        tester.widget<Text>(words(rent)).style?.decoration,
        TextDecoration.lineThrough,
      );

      await tester.tap(phoneBox(rent));
      await settle(tester);
      expect(tasks.read().open.length, 4);
      expect(
        tester.widget<Text>(words(item('Pay the rent'))).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
      await settle(tester);
    });

    testWidgets('a tap on the words opens its details, Open in note opens '
        'the note; a long press opens the row menu', (tester) async {
      await setUpTasks(tester, errands);
      String? opened;
      await pumpScreen(tester, phone: true, onOpenNote: (id) => opened = id);
      final rent = item('Pay the rent');

      await tester.tap(words(rent));
      await settle(tester);
      expect(find.byType(PhoneTaskDetailsSheet), findsOneWidget);
      expect(opened, isNull);

      await tester.tap(find.text('Open in note'));
      await settle(tester);
      expect(find.byType(PhoneTaskDetailsSheet), findsNothing);
      expect(opened, rent.note.id);

      await tester.longPress(words(rent));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task-menu-Details')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('task-menu-Add to Up next')));
      await settle(tester);
      expect(item('Pay the rent').dotted, isTrue);
      await settle(tester);
    });

    for (final scale in [1.0, 1.3, 2.0]) {
      for (final size in [const Size(393, 852), const Size(320, 568)]) {
        testWidgets('holds at ${scale}x text on ${size.width.toInt()} points', (
          tester,
        ) async {
          await setUpTasks(
            tester,
            'Errands\n☐ Ask Ana which Sintra palace to skip before the trip\n'
            '☐ Renew passport before the trip\n☐ Book the Sintra train '
            'tickets\n☐ Call Arjun',
          );
          await pumpScreen(tester, phone: true, textScale: scale, size: size);
          await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
          await settle(tester);
          clock = clock.add(const Duration(days: 15));
          tasks.startWith(item('Renew passport before the trip'));
          await settle(tester);
          expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
          expect(find.text('Still want this?'), findsNothing);
          expect(tester.takeException(), isNull);
          await settle(tester);
        });
      }
    }
  });

  group('goldens', () {
    Future<void> canonical(WidgetTester tester, {DateTime? at}) async {
      final morning = at ?? DateTime(2026, 11, 19, 9);
      await setUpTasks(
        tester,
        'Lisbon trip\n☐ Ask Ana which Sintra palace to skip\n'
        '☐ Renew passport before the trip\n☐ Book the Sintra train tickets',
        at: DateTime(2026, 11, 3, 10),
      );
      clock = morning;
      tasks.keep(item('Ask Ana which Sintra palace to skip'));
      tasks.keep(item('Book the Sintra train tickets'));
      notes.create(body: 'Tasks\n☐ Call Arjun');
      await tester.runAsync(tasks.reconcileNow);
      notes.create(body: 'Quote for the deck\n☐ Book the room');
      await tester.runAsync(tasks.reconcileNow);
      notes.create(
        body:
            'Call with Arjun\n☐ Send the deck\n'
            '  Slides 1 to 6 are done. The charts need the new numbers from '
            'Finance.',
      );
      await tester.runAsync(tasks.reconcileNow);
    }

    Future<void> golden(WidgetTester tester, String name) async {
      await pumpScreen(tester, size: const Size(760, 900));
      await settle(tester);
      await expectLater(
        find.byType(TasksScreen),
        matchesGoldenFile('goldens/tasks_$name.png'),
      );
    }

    PairStage pair() => tasks.choiceIn(null).stage as PairStage;

    testWidgets('D1 morning, the first pair', (tester) async {
      await canonical(tester);
      await golden(tester, 'd1_first_pair');
      await settle(tester);
    });

    testWidgets('D2 morning, mid-pair', (tester) async {
      await canonical(tester);
      tasks.keepChoice(pair());
      tasks.takeNext(pair());
      tasks.keepChoice(pair());
      await golden(tester, 'd2_mid_pair');
      await settle(tester);
    });

    testWidgets('D3 during the day, Do now', (tester) async {
      await canonical(tester);
      tasks.keepChoice(pair());
      tasks.takeNext(pair());
      tasks.keepChoice(pair());
      tasks.keepChoice(pair());
      tasks.takeNext(pair());
      await pumpScreen(tester, size: const Size(760, 900));
      await hoverOn(tester, find.text('Book the room'));
      await settle(tester);
      await expectLater(
        find.byType(TasksScreen),
        matchesGoldenFile('goldens/tasks_d3_do_now.png'),
      );
      await settle(tester);
    });

    testWidgets('D4 after Done, a new task', (tester) async {
      await canonical(tester);
      tasks.keepChoice(pair());
      tasks.takeNext(pair());
      tasks.keepChoice(pair());
      tasks.keepChoice(pair());
      tasks.takeNext(pair());
      clock = DateTime(2026, 11, 19, 9, 58);
      await tester.runAsync(
        () => tasks.add(
          'Split the Acme invoice in two',
          noteId: item('Send the deck').note.id,
        ),
      );
      clock = DateTime(2026, 11, 19, 10, 2);
      final doNow = (tasks.choiceIn(null).stage as DoNowStage).item;
      await tester.runAsync(() => tasks.finish(doNow));
      await golden(tester, 'd4_after_done');
      await settle(tester);
    });

    testWidgets('D5 evening, done for today', (tester) async {
      await canonical(tester, at: DateTime(2026, 11, 19, 18, 40));
      for (final words in [
        'Send the deck',
        'Call Arjun',
        'Book the room',
        'Ask Ana which Sintra palace to skip',
      ]) {
        await tester.runAsync(() => tasks.setDone(item(words), done: true));
      }
      tasks.sendToEnd(item('Book the Sintra train tickets'));
      await golden(tester, 'd5_evening');
      await settle(tester);
    });
  });
}
