import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:kapy_notes/ui/note_day_scope.dart';
import 'package:kapy_notes/ui/tasks/task_choice.dart';
import 'package:kapy_notes/ui/tasks/task_choice_cards.dart';
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
    ValueChanged<TaskFilter>? onFilter,
    NoteDayStore? days,
    double textScale = 1,
    Size? size,
    bool explainPair = true,
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
          body: withNoteDays(
            days,
            TasksScreen(
              controller: tasks,
              filter: filter,
              addFocus: addFocus,
              labelOf: (note) => note.title,
              onOpenNote: onOpenNote ?? (_) {},
              onOpenDone: onOpenDone ?? () {},
              onFilter: onFilter,
              newTaskShortcut: '⌘N',
              phone: phone,
              explainPair: explainPair,
            ),
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
    bool editable = true,
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

  group('search, the filter and Later (M13, M13a, D09)', () {
    Future<void> addNotes(List<String> bodies) async {
      for (final body in bodies) {
        notes.create(body: body);
      }
      await tasks.reconcileNow();
    }

    Future<NoteDayStore> waitingFor(String title, DateTime day) async {
      final days = NoteDayStore(_MemoryStore(), now: () => clock);
      await days.load();
      days.setDay(notes.allNotes.firstWhere((n) => n.title == title).id, day);
      return days;
    }

    Finder phoneRow(String words) =>
        find.byKey(ValueKey('phone-task-${item(words).id}'));

    testWidgets('a phone searches by the task\'s words and its note\'s name, '
        'across Up next, the pair and the rest of the list', (tester) async {
      await setUpTasks(tester, errands);
      await addNotes(['Lisbon trip\n☐ Book the Sintra train\n☐ Pack adapters']);
      await pumpScreen(tester, phone: true);
      await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
      await settle(tester);
      expect(find.text('Up next'), findsOneWidget);
      final upNext = tasks.choiceIn(null).upNext.single.words;

      final field = find.byKey(const ValueKey('tasks-search-field'));
      await tester.enterText(field, 'lisbon');
      await settle(tester);
      expect(phoneRow('Book the Sintra train'), findsOneWidget);
      expect(phoneRow('Pack adapters'), findsOneWidget);
      expect(phoneRow('Pay the rent'), findsNothing);
      expect(find.text('Up next'), findsNothing, reason: '$upNext is no match');
      expect(find.byKey(const ValueKey('tasks-pair')), findsNothing);

      await tester.enterText(field, 'BOOK  sintra');
      await settle(tester);
      expect(phoneRow('Book the Sintra train'), findsOneWidget);
      expect(phoneRow('Pack adapters'), findsNothing);

      await tester.enterText(field, upNext.split(' ').last);
      await settle(tester);
      expect(find.text('Up next'), findsOneWidget);

      await tester.enterText(field, 'passport');
      await settle(tester);
      expect(find.text('No tasks match “passport”.'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-pair')), findsOneWidget);
      expect(phoneRow('Pack adapters'), findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-search-empty')), findsNothing);
    });

    testWidgets('the pair stays while either card matches, and Do now while '
        'its task does', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);
      final field = find.byKey(const ValueKey('tasks-search-field'));
      await tester.enterText(field, 'flights');
      await settle(tester);
      expect(inPair('right', 'Book flights'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tasks-start')));
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-do-now')), findsNothing);
      await tester.enterText(field, 'report');
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    });

    testWidgets('on a touch phone, typing never makes the well taller, so the '
        'list stays put', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);
      final well = find.byKey(const ValueKey('sidebar-search-box'));
      final empty = tester.getSize(well).height;
      await tester.enterText(
        find.byKey(const ValueKey('tasks-search-field')),
        'sintra',
      );
      await settle(tester);
      expect(find.byTooltip('Clear search'), findsOneWidget);
      expect(tester.getSize(well).height, empty);
    });

    testWidgets('the search well is a 44 pt target read as Search tasks, and '
        'the filter beside it is 44 pt and says what it does', (tester) async {
      final semantics = tester.ensureSemantics();
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true, onFilter: (_) {});
      expect(
        tester.getSize(find.byKey(const ValueKey('sidebar-search-box'))).height,
        greaterThanOrEqualTo(44),
      );
      expect(find.bySemanticsLabel('Search tasks'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('tasks-filters'))),
        const Size.square(44),
      );
      expect(find.byTooltip('Filter tasks'), findsOneWidget);
      await settle(tester);
      semantics.dispose();
    });

    testWidgets('a desktop has no search over the page and no filter button', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, onFilter: (_) {});
      expect(find.byKey(const ValueKey('tasks-search-field')), findsNothing);
      expect(find.byKey(const ValueKey('tasks-filters')), findsNothing);
      await settle(tester);
    });

    for (final phone in [true, false]) {
      testWidgets('a ${phone ? 'phone' : 'desktop'} Tasks only 30 pt wide '
          'lays out without an error', (tester) async {
        await setUpTasks(tester, errands);
        await pumpScreen(
          tester,
          phone: phone,
          onFilter: (_) {},
          size: const Size(30, 600),
        );
        expect(tester.takeException(), isNull);
        await settle(tester);
      });
    }

    testWidgets('the filter offers Today, Done and each note with its count, '
        'ticks the one showing, and narrows to the one picked', (tester) async {
      await setUpTasks(tester, errands);
      await addNotes([
        'Lisbon trip\n☐ Book the Sintra train\n☐ Pack adapters',
        'Tasks\n☐ Call Arjun',
      ]);
      final picked = <TaskFilter>[];
      await pumpScreen(tester, phone: true, onFilter: picked.add);
      await tester.tap(find.byKey(const ValueKey('tasks-filters')));
      await settle(tester);

      String row(String key) => [
        for (final text in tester.widgetList<Text>(
          find.descendant(
            of: find.byKey(ValueKey('tasks-filter-menu-$key')),
            matching: find.byType(Text),
          ),
        ))
          text.data!,
      ].join(' ');
      final lisbon = item('Pack adapters').note.id;
      final errandsNote = item('Pay the rent').note.id;
      expect(row('all'), 'Today 7');
      expect(row('done'), 'Done 0');
      expect(row(errandsNote), 'Errands 4');
      expect(row(lisbon), 'Lisbon trip 2');
      expect(row('no-note'), 'No note 1');
      expect(
        tester
            .getSize(find.byKey(const ValueKey('tasks-filter-menu-all')))
            .height,
        greaterThanOrEqualTo(44),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tasks-filter-menu-all')),
          matching: find.byType(KapyIcon),
        ),
        findsNWidgets(2),
        reason: 'Today\'s mark and its tick',
      );

      await tester.tap(find.byKey(ValueKey('tasks-filter-menu-$lisbon')));
      await settle(tester);
      expect(picked, [TaskFilter.note(lisbon)]);

      await pumpScreen(
        tester,
        phone: true,
        filter: TaskFilter.note(lisbon),
        onFilter: picked.add,
      );
      expect(phoneRow('Pay the rent'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tasks-filters')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('tasks-filter-menu-done')));
      await settle(tester);
      expect(picked.last, const TaskFilter.done());
    });

    testWidgets('Later counts the tasks whose note waits for its day, names '
        'the soonest day, and opens that note', (tester) async {
      await setUpTasks(tester, errands);
      await addNotes(['Renewal notes\n☐ Renew the domain\n☐ Renew the van']);
      final days = await waitingFor('Renewal notes', DateTime(2026, 11, 20));
      final opened = <String>[];
      await pumpScreen(tester, days: days, onOpenNote: opened.add);

      expect(find.text('Later'), findsOneWidget);
      expect(find.text('2 tasks wait for their day'), findsOneWidget);
      expect(find.text('Fri 20'), findsOneWidget);
      expect(find.text('Renew the domain'), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('tasks-later'))).height,
        36,
      );
      await tester.tap(find.byKey(const ValueKey('tasks-later')));
      await settle(tester);
      expect(opened, [item('Renew the domain').note.id]);
    });

    testWidgets('a phone\'s Later is a 44 pt row, and goes while searching', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      await addNotes(['Renewal notes\n☐ Renew the domain']);
      final days = await waitingFor('Renewal notes', DateTime(2026, 11, 20));
      await pumpScreen(tester, phone: true, days: days);
      final later = find.byKey(const ValueKey('tasks-later'));
      await tester.ensureVisible(later);
      expect(find.text('1 task waits for its day'), findsOneWidget);
      expect(tester.getSize(later).height, 44);
      await tester.enterText(
        find.byKey(const ValueKey('tasks-search-field')),
        'rent',
      );
      await settle(tester);
      expect(later, findsNothing);
    });

    testWidgets('while a waiting task matches the search, Later stays with '
        'the matching count rather than "No tasks match"', (tester) async {
      await setUpTasks(tester, errands);
      await addNotes(['Renewal notes\n☐ Renew the domain\n☐ Renew the van']);
      final days = await waitingFor('Renewal notes', DateTime(2026, 11, 20));
      await pumpScreen(tester, phone: true, days: days);
      await tester.enterText(
        find.byKey(const ValueKey('tasks-search-field')),
        'domain',
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-later')), findsOneWidget);
      expect(find.text('1 task waits for its day'), findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-search-empty')), findsNothing);
    });

    testWidgets('Later with two waiting notes names the soonest day and '
        'opens the soonest note', (tester) async {
      await setUpTasks(tester, errands);
      await addNotes([
        'Renewal notes\n☐ Renew the domain',
        'Garden\n☐ Plant the bulbs',
      ]);
      final days = await waitingFor('Renewal notes', DateTime(2026, 11, 24));
      days.setDay(
        notes.allNotes.firstWhere((n) => n.title == 'Garden').id,
        DateTime(2026, 11, 20),
      );
      final opened = <String>[];
      await pumpScreen(tester, days: days, onOpenNote: opened.add);
      expect(find.text('2 tasks wait for their day'), findsOneWidget);
      expect(find.text('Fri 20'), findsOneWidget);
      expect(find.text('Tue 24'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tasks-later')));
      await settle(tester);
      expect(opened, [item('Plant the bulbs').note.id]);
    });

    testWidgets('every typed word must match, not any one of them', (
      tester,
    ) async {
      await setUpTasks(
        tester,
        'Errands\n☐ Pay the rent\n☐ Call the bank\n☐ Book flights\n'
        '☐ Book the Sintra train\n☐ Pack for Sintra',
      );
      await pumpScreen(tester, phone: true);
      await tester.enterText(
        find.byKey(const ValueKey('tasks-search-field')),
        'book sintra',
      );
      await settle(tester);
      expect(phoneRow('Book the Sintra train'), findsOneWidget);
      expect(phoneRow('Book flights'), findsNothing);
      expect(phoneRow('Pack for Sintra'), findsNothing);
    });

    testWidgets('"No tasks match" never shows beside a matching pair or Do '
        'now', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);
      final field = find.byKey(const ValueKey('tasks-search-field'));
      final empty = find.byKey(const ValueKey('tasks-search-empty'));
      await tester.enterText(field, 'flights');
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-pair')), findsOneWidget);
      expect(empty, findsNothing);

      await tester.enterText(field, '');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('tasks-start')));
      await settle(tester);
      await tester.enterText(field, 'report');
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
      expect(empty, findsNothing);
    });

    testWidgets('in the evening, search narrows the card\'s rows, and the card '
        'goes once none match', (tester) async {
      await setUpTasks(
        tester,
        'Errands\n☐ Done one\n☐ Left one\n☐ Left two',
        at: DateTime(2026, 11, 19, 18, 30),
      );
      await tester.runAsync(
        () => tasks.setDone(tasks.read().open.first, done: true),
      );
      await pumpScreen(tester, phone: true);
      expect(find.byKey(const ValueKey('tasks-evening')), findsOneWidget);
      final field = find.byKey(const ValueKey('tasks-search-field'));

      await tester.enterText(field, 'two');
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-evening')), findsOneWidget);
      expect(phoneRow('Left two'), findsOneWidget);
      expect(phoneRow('Left one'), findsNothing);
      expect(find.byKey(const ValueKey('tasks-search-empty')), findsNothing);

      await tester.enterText(field, 'garage');
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-evening')), findsNothing);
      expect(find.text('No tasks match “garage”.'), findsOneWidget);
    });

    testWidgets('search narrows Done too, and says so when nothing matches; '
        'the well and its filter stay', (tester) async {
      await setUpTasks(tester, errands);
      for (final words in ['Pay the rent', 'Book flights']) {
        await tester.runAsync(() => tasks.setDone(item(words), done: true));
      }
      await pumpScreen(
        tester,
        phone: true,
        filter: const TaskFilter.done(),
        onFilter: (_) {},
      );
      expect(find.text('Pay the rent'), findsOneWidget);
      expect(find.text('Book flights'), findsOneWidget);
      final field = find.byKey(const ValueKey('tasks-search-field'));

      await tester.enterText(field, 'rent');
      await settle(tester);
      expect(find.text('Pay the rent'), findsOneWidget);
      expect(find.text('Book flights'), findsNothing);

      await tester.enterText(field, 'garage');
      await settle(tester);
      expect(find.text('Pay the rent'), findsNothing);
      expect(find.text('No tasks match “garage”.'), findsOneWidget);
      expect(field, findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-filters')), findsOneWidget);
    });

    testWidgets('Clear empties the search and keeps the keyboard up, from a '
        '32 pt button', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);
      final field = find.byKey(const ValueKey('tasks-search-field'));
      await tester.tap(field);
      await tester.enterText(field, 'rent');
      await settle(tester);
      final focus = tester.widget<TextField>(field).focusNode!;
      expect(focus.hasFocus, isTrue);
      final clear = find.byTooltip('Clear search');
      expect(tester.getSize(clear), const Size.square(32));

      await tester.tap(clear);
      await settle(tester);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('the filter button carries its dot while a filter is on', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      final dot = find.byKey(const ValueKey('phone-filters-dot'));
      await pumpScreen(tester, phone: true, onFilter: (_) {});
      expect(dot, findsNothing);
      await pumpScreen(
        tester,
        phone: true,
        filter: TaskFilter.note(item('Pay the rent').note.id),
        onFilter: (_) {},
      );
      expect(dot, findsOneWidget);
      await pumpScreen(
        tester,
        phone: true,
        filter: const TaskFilter.done(),
        onFilter: (_) {},
      );
      expect(dot, findsOneWidget);
    });

    testWidgets('M13a: one hairline, after the last Up next row, full width', (
      tester,
    ) async {
      await setUpTasks(tester, '$errands\n☐ Water the plants\n☐ Fix the bike');
      await pumpScreen(tester, phone: true);
      await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('tasks-start')));
      await settle(tester);
      final choice = tasks.choiceIn(null);
      expect(choice.upNext, hasLength(2));

      final palette = tester.element(find.byType(TasksScreen)).palette;
      final lines = find.byWidgetPredicate(
        (widget) => switch (widget) {
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(:final color, :final width)),
            ),
          ) =>
            color == palette.separator && width == 1,
          _ => false,
        },
      );
      expect(lines, findsOneWidget);
      final line = tester.getRect(lines);
      final lastUpNext = tester.getRect(
        find.byKey(ValueKey('phone-task-${choice.upNext.last.id}')),
      );
      expect(line.top, greaterThanOrEqualTo(lastUpNext.bottom));
      expect(line.width, 393 - 42);
    });
  });

  group('the pair', () {
    testWidgets(
      'with nothing chosen: the first task on the list against the '
      'next with "or" between, the count, Stop choosing, and the rest below',
      (tester) async {
        await setUpTasks(tester, errands);
        await pumpScreen(tester);

        expect(find.text('Which is more important?'), findsOneWidget);
        expect(inPair('left', 'First on your list'), findsOneWidget);
        expect(inPair('left', 'Send the report'), findsOneWidget);
        expect(inPair('left', 'Pick'), findsOneWidget);
        expect(inPair('right', 'Next on your list'), findsOneWidget);
        expect(inPair('right', 'Book flights'), findsOneWidget);
        expect(inPair('right', 'Pick'), findsOneWidget);
        expect(find.text('or'), findsOneWidget);
        expect(find.text('2 of 4 seen'), findsOneWidget);
        expect(find.byKey(const ValueKey('tasks-pair-explain')), findsOneWidget);
        expect(
          find.text(
            'Nothing comes off your list. Earlier picks wait in Up next.',
          ),
          findsNothing,
          reason: 'the line under the question says it until the first pick',
        );
        expect(
          find.text('Stop choosing and start Send the report'),
          findsOneWidget,
        );
        expect(find.text('↵'), findsOneWidget);
        expect(find.text('esc'), findsNothing);
        expect(find.text('Up next'), findsNothing);
        expect(box('Call the garage'), findsOneWidget);
        expect(box('Send the report'), findsNothing);
        expect(find.text('←'), findsOneWidget);
        expect(find.text('→'), findsOneWidget);
        await settle(tester);
      },
    );

    testWidgets('a click on the left keeps your choice; a click on the right '
        'makes it your choice and the old one waits in Up next', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester);

      await tester.tap(find.byKey(const ValueKey('tasks-pair-left')));
      await settle(tester);
      expect(inPair('left', 'Most important so far'), findsOneWidget);
      expect(inPair('right', 'Call the garage'), findsOneWidget);
      expect(find.text('3 of 4 seen'), findsOneWidget);
      expect(
        find.text('Nothing comes off your list. Earlier picks wait in Up next.'),
        findsOneWidget,
      );
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

    testWidgets('on the last pair Stop choosing goes, the count says Last one '
        'and the foot says the pick becomes Do now', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ One\n☐ Two');
      await pumpScreen(tester, explainPair: false);
      expect(find.byKey(const ValueKey('tasks-start')), findsNothing);
      expect(find.text('Your pick becomes Do now.'), findsOneWidget);
      expect(find.text('Last one'), findsOneWidget);
      expect(find.textContaining(' seen'), findsNothing);
      final screen = tester.state<TasksScreenState>(find.byType(TasksScreen));
      expect(screen.startEarly(), isFalse);

      await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
      await settle(tester);
      expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
      expect(item('Two').doNow, isTrue);
      expect(find.text('Up next'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('Stop choosing names the whole task, on up to two lines', (
      tester,
    ) async {
      await setUpTasks(
        tester,
        'Errands\n☐ Ask Ana which Sintra palace to skip\n☐ B\n☐ C',
      );
      await pumpScreen(tester);
      const label =
          'Stop choosing and start Ask Ana which Sintra palace to skip';
      expect(find.text(label), findsOneWidget);
      expect(tester.widget<Text>(find.text(label)).maxLines, 2);
      expect(find.bySemanticsLabel(label), findsOneWidget);
      await settle(tester);
    });

    testWidgets('a round\'s first pair says how choosing works until a pick, '
        'and not once How Tasks works is put away', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester);
      const line =
          'Tasks shows two at a time. Pick the more important one. The most '
          'important becomes Do now.';
      expect(find.text(line), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tasks-pair-left')));
      await settle(tester);
      expect(find.text(line), findsNothing);

      tasks.chooseAgain();
      await pumpScreen(tester, explainPair: false);
      expect(inPair('left', 'First on your list'), findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-pair-explain')), findsNothing);
      await settle(tester);
    });

    testWidgets(
      'hovering or focusing Stop choosing outlines the task it starts, and ↵ '
      'on it starts that task',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        await setUpTasks(tester, errands);
        await pumpScreen(tester);
        final ink = TaskInk.of(tester.element(find.byType(TasksScreen)));
        Color edgeOf(String side) {
          final box = tester.widget<Container>(
            find
                .descendant(
                  of: find.byKey(ValueKey('tasks-pair-$side')),
                  matching: find.byType(Container),
                )
                .first,
          );
          return ((box.decoration! as BoxDecoration).border! as Border)
              .top
              .color;
        }

        final start = find.byKey(const ValueKey('tasks-start'));
        expect(edgeOf('left'), ink.edge);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(start));
        await tester.pump();
        expect(edgeOf('left'), ink.sage);
        expect(edgeOf('right'), ink.edge);
        await mouse.moveTo(Offset.zero);
        await tester.pump();
        expect(edgeOf('left'), ink.edge);

        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(
          () => FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.automatic,
        );
        Focus.of(
          tester.element(
            find.descendant(of: start, matching: find.byType(GestureDetector)),
          ),
        ).requestFocus();
        // Focus lands in a microtask, so the outline it asks for paints on the
        // frame after.
        await tester.pump();
        await tester.pump();
        expect(edgeOf('left'), ink.sage);
        expect(edgeOf('right'), ink.edge);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
        expect(item('Send the report').doNow, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('screen readers hear what each card is and what a tap does', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await setUpTasks(tester, errands);
      await pumpScreen(tester);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('tasks-pair-left'))),
        matchesSemantics(
          label: 'First on your list: Send the report',
          hint: 'Pick',
          isButton: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tasks-pair-left')));
      await settle(tester);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('tasks-pair-right'))),
        matchesSemantics(
          label: 'Next on your list: Call the garage',
          hint: 'Pick',
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

    testWidgets('on a note shared to view only, Do now shows no Done and ⌘↵ '
        'leaves the task to do', (tester) async {
      await setUpTasks(tester, errands, editable: false);
      final first = tasks.read().open.first;
      tasks.doNow(first);
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-done')), findsNothing);
      expect(find.text('⌘↵'), findsNothing);

      tester.state<TasksScreenState>(find.byType(TasksScreen)).completeDoNow();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await settle(tester);
      expect(notes.notes.single.body, errands);
      expect(tasks.read().done, isEmpty);
      expect(item('Send the report').doNow, isTrue);
      expect(tasks.justDone, isNull);
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
      expect(inPair('left', 'Most important so far'), findsOneWidget);
      expect(inPair('left', 'One'), findsOneWidget);
      expect(inPair('right', 'New since you started'), findsOneWidget);
      expect(find.text('Last one'), findsOneWidget);
      expect(inPair('right', 'Four'), findsOneWidget);
      expect(find.textContaining('added 9:'), findsOneWidget);
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

    testWidgets('a task sent to the end shows ↺ with what it means', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      final item = tasks.read().open.first;
      tasks.doNow(item);
      tasks.notFinished(item);
      tasks.doNow(tasks.read().open.firstWhere((other) => other.id != item.id));
      await pumpScreen(tester, phone: true);
      expect(
        find.descendant(
          of: find.byKey(ValueKey('phone-task-${item.id}')),
          matching: find.byTooltip('Not finished, moved to the end'),
        ),
        findsOneWidget,
      );
      await settle(tester);
    });

    testWidgets('Today with its date and count, the pair as two stacked cards '
        'you tap with "or" between, and Stop choosing under them; no keys', (
      tester,
    ) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Tue 17'), findsOneWidget);
      expect(find.text('0 of 4 done'), findsOneWidget);
      expect(find.byType(Keycap), findsNothing);
      expect(find.text('←'), findsNothing);
      expect(find.text('esc'), findsNothing);
      expect(find.text('↵'), findsNothing);
      expect(find.text('Pick'), findsNWidgets(2));
      expect(find.text('2 of 4 seen'), findsOneWidget);
      expect(
        find.text(
          'Tasks shows two at a time. Tap the more important one. The most '
          'important becomes Do now.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Nothing comes off your list. Earlier picks wait in Up next.',
        ),
        findsNothing,
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

    testWidgets('the card with First on your list is radius 12 on the 4% fill, '
        '14 in at the top and 16 at the sides and bottom', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);

      final pair = find.byKey(const ValueKey('tasks-pair'));
      expect(
        find.descendant(of: pair, matching: find.text('First on your list')),
        findsOneWidget,
      );
      final card = tester.widget<Container>(pair);
      expect(card.padding, const EdgeInsets.fromLTRB(16, 14, 16, 16));
      final fill = card.decoration! as BoxDecoration;
      expect(fill.borderRadius, BorderRadius.circular(12));
      expect(fill.color, KapyTheme.darkPalette.cardBackground);
      expect(fill.color, const Color(0xFF24221E));
      await settle(tester);
    });

    testWidgets('the note picker sits inside Add a task at its right end: a '
        '32 high, radius 9 control on the 6% fill, in a 44 high, radius 9, '
        '4% field', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);

      const palette = KapyTheme.darkPalette;
      final row = find.byKey(const ValueKey('tasks-add-row'));
      final field = tester.widget<Container>(row).decoration! as BoxDecoration;
      expect(tester.getSize(row).height, 44);
      expect(field.borderRadius, BorderRadius.circular(9));
      expect(field.color, palette.cardBackground);
      final chip = find
          .descendant(
            of: find.byKey(const ValueKey('tasks-note-picker')),
            matching: find.byType(Container),
          )
          .first;
      final control =
          tester.widget<Container>(chip).decoration! as BoxDecoration;
      expect(tester.getSize(chip).height, 32);
      expect(control.borderRadius, BorderRadius.circular(9));
      // 6% over the 4% field, as the spec composes it.
      expect(control.color, const Color(0xFF2F2D29));
      final outer = tester.getRect(row);
      final inner = tester.getRect(chip);
      expect(outer.contains(inner.topLeft), isTrue);
      expect(outer.contains(inner.bottomRight - const Offset(1, 1)), isTrue);
      expect(outer.right - inner.right, lessThanOrEqualTo(8));
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

    testWidgets('the rows lose their lines, and the note reads 13 on 18 in '
        'the quiet ink', (tester) async {
      await setUpTasks(tester, errands);
      await pumpScreen(tester, phone: true);
      final row = find.byKey(ValueKey('phone-task-${item('Pay the rent').id}'));
      final palette = tester.element(row).palette;

      expect([
        for (final box in tester.widgetList<Container>(
          find.descendant(of: row, matching: find.byType(Container)),
        ))
          if (box.decoration case BoxDecoration(
            border: Border(:final top, :final bottom),
          ) when top == BorderSide.none && bottom != BorderSide.none)
            box,
      ], isEmpty);
      final note = tester
          .widgetList<Text>(
            find.descendant(of: row, matching: find.byType(Text)),
          )
          .firstWhere((text) => text.data == 'Errands')
          .style!;
      expect(note.fontFamily, AppFonts.ui);
      expect(note.fontSize, 13);
      expect(note.height, 18 / 13);
      expect(note.color, palette.textTertiary);
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
      expect(find.byType(PhoneTaskPage), findsOneWidget);
      expect(opened, isNull);

      await tester.tap(find.text('Open in note'));
      await settle(tester);
      expect(find.byType(PhoneTaskPage), findsNothing);
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

    for (final increaseContrast in [false, true]) {
      testWidgets('D1 on a phone in Midnight, increaseContrast: '
          '$increaseContrast', (tester) async {
        await canonical(tester);
        await pumpScreen(
          tester,
          phone: true,
          theme: KapyTheme.dark(
            theme: AppTheme.midnight,
            increaseContrast: increaseContrast,
          ),
        );
        await settle(tester);
        await expectLater(
          find.byType(TasksScreen),
          matchesGoldenFile(
            'goldens/tasks_pair_midnight${increaseContrast ? '_contrast' : ''}.png',
          ),
        );
        await settle(tester);
      });
    }

    testWidgets('on a phone, Increase contrast outlines the pair\'s choices '
        'in the theme\'s contrast line, and moves nothing', (tester) async {
      await canonical(tester);
      final rects = <bool, List<Rect>>{};
      for (final increaseContrast in [false, true]) {
        final theme = KapyTheme.dark(
          theme: AppTheme.midnight,
          increaseContrast: increaseContrast,
        );
        await pumpScreen(tester, phone: true, theme: theme);
        await settle(tester);
        final line = theme.extension<CalcPalette>()!.controlBorder;
        rects[increaseContrast] = [];
        for (final side in ['tasks-pair-left', 'tasks-pair-right']) {
          final card = find.descendant(
            of: find.byKey(ValueKey(side)),
            matching: find.byType(Container),
          );
          final box = tester.widget<Container>(card.first);
          final borders = [
            (box.decoration as BoxDecoration?)?.border,
            (box.foregroundDecoration as BoxDecoration?)?.border,
          ].nonNulls;
          expect(
            borders,
            increaseContrast ? [Border.all(color: line)] : isEmpty,
            reason: '$side, increaseContrast: $increaseContrast',
          );
          rects[increaseContrast]!.addAll([
            tester.getRect(card.first),
            tester.getRect(
              find
                  .descendant(of: card.first, matching: find.byType(Text))
                  .first,
            ),
          ]);
        }
      }
      expect(rects[true], rects[false]);
      await settle(tester);
    });

    testWidgets('on a desktop, Increase contrast adds no outline over the '
        'pair\'s choices: their own border stays the only one', (tester) async {
      await canonical(tester);
      final theme = KapyTheme.dark(
        theme: AppTheme.midnight,
        increaseContrast: true,
      );
      await pumpScreen(tester, theme: theme);
      await settle(tester);
      final line = theme.extension<CalcPalette>()!.controlBorder;
      for (final side in ['tasks-pair-left', 'tasks-pair-right']) {
        final box = tester.widget<Container>(
          find
              .descendant(
                of: find.byKey(ValueKey(side)),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(box.foregroundDecoration, isNull, reason: side);
        expect(
          (box.decoration as BoxDecoration?)?.border,
          Border.all(color: line),
          reason: side,
        );
      }
      await settle(tester);
    });

    testWidgets('Increase contrast outlines the add row, its note chip and '
        'Stop choosing in the theme\'s contrast line, and moves nothing', (
      tester,
    ) async {
      await canonical(tester);
      for (final phone in [false, true]) {
        final rects = <bool, List<Rect>>{};
        for (final increaseContrast in [false, true]) {
          final theme = KapyTheme.dark(
            theme: AppTheme.midnight,
            increaseContrast: increaseContrast,
          );
          await pumpScreen(tester, phone: phone, theme: theme);
          await settle(tester);
          final line = theme.extension<CalcPalette>()!.controlBorder;
          rects[increaseContrast] = [];
          for (final key in [
            'tasks-add-row',
            'tasks-note-picker',
            'tasks-start',
          ]) {
            final control = find
                .descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(Container),
                  matchRoot: true,
                )
                .first;
            final box = tester.widget<Container>(control);
            final reason =
                '$key, phone: $phone, '
                'increaseContrast: $increaseContrast';
            expect(
              (box.decoration as BoxDecoration?)?.border,
              isNull,
              reason: reason,
            );
            expect(
              (box.foregroundDecoration as BoxDecoration?)?.border,
              increaseContrast ? Border.all(color: line) : isNull,
              reason: reason,
            );
            expect(
              (box.foregroundDecoration as BoxDecoration?)?.borderRadius,
              increaseContrast
                  ? (box.decoration as BoxDecoration?)?.borderRadius
                  : isNull,
              reason: reason,
            );
            rects[increaseContrast]!.addAll([
              tester.getRect(control),
              tester.getRect(
                find.descendant(of: control, matching: find.byType(Text)).first,
              ),
            ]);
          }
        }
        expect(rects[true], rects[false], reason: 'phone: $phone');
      }
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
