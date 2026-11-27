import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:kapy_notes/ui/tasks/task_marks.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:kapy_notes/ui/tasks/tasks_sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tasks-sidebar-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// The Tasks sidebar as D09 draws it, and the note's coloured marker.
void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  late NotesStore notes;
  late TasksController tasks;

  Future<void> setUpTasks() async {
    var clock = DateTime(2026, 11, 19, 9);
    final store = _MemoryStore();
    notes = NotesStore(store);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => clock = clock.add(const Duration(milliseconds: 1)),
    );
    await notes.load();
    await library.load();
    for (final body in [
      'Lisbon trip\n☐ Ask Ana which Sintra palace to skip\n'
          '☐ Renew passport before the trip\n☐ Book the Sintra train tickets',
      'Tasks\n☐ Call Arjun',
      'Quote for the deck\n☐ Book the room',
      'Call with Arjun\n☐ Send the deck',
      'Renewal notes\n☐ Renew the domain\n☐ Renew the van insurance',
    ]) {
      notes.create(body: body);
    }
    tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => true,
      now: () => clock,
    );
    await tasks.reconcileNow();
    addTearDown(() {
      tasks.dispose();
      library.dispose();
    });
  }

  Note note(String title) => notes.allNotes.firstWhere((n) => n.title == title);

  List<TagMark> marksOf(String noteId) => switch (notes.byId(noteId)?.title) {
    'Lisbon trip' => const [(name: 'Travel', colour: TagColour.sage)],
    'Quote for the deck' => const [(name: 'Work', colour: TagColour.mustard)],
    _ => const [],
  };

  Future<void> pumpSidebar(WidgetTester tester) async {
    final renewal = note('Renewal notes').id;
    tasks.waits = (item) => item.note.id == renewal;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: TagMarks(
            marksOf: marksOf,
            child: SizedBox(
              width: 344,
              child: TasksSidebar(
                board: tasks.read(),
                today: tasks.openIn(null),
                filter: const TaskFilter.all(),
                onFilter: (_) {},
                labelOf: (note) => note.title,
                windowBar: const SizedBox.shrink(),
                onSearch: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
  }

  String row(WidgetTester tester, String key) => [
    for (final text in tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(ValueKey('tasks-filter-$key')),
        matching: find.byType(Text),
      ),
    ))
      text.data!,
  ].join(' ');

  testWidgets('Today counts today\'s list, and a note whose tasks all wait '
      'for a later day is not under From notes', (tester) async {
    await setUpTasks();
    await pumpSidebar(tester);

    expect(row(tester, 'all'), 'Today 6');
    expect(row(tester, 'done'), 'Done 0');
    expect(row(tester, note('Lisbon trip').id), 'Lisbon trip 3');
    expect(row(tester, 'no-note'), 'No note 1');
    expect(find.text('Renewal notes'), findsNothing);
    expect(find.text('All tasks'), findsNothing);
  });

  testWidgets('rows are 32 tall in 13 on 18, From notes is a 12 on 16 label, '
      'and the credit reads 12 on 16 at 20 in', (tester) async {
    await setUpTasks();
    await pumpSidebar(tester);

    final today = find.byKey(const ValueKey('tasks-filter-all'));
    expect(tester.getSize(today).height, 32);
    final label = tester.widget<Text>(
      find.descendant(of: today, matching: find.text('Today')),
    );
    expect(label.style!.fontSize, 13);
    expect(label.style!.height! * 13, closeTo(18, 0.01));
    final heading = tester.widget<Text>(find.text('From notes'));
    expect(heading.style!.fontSize, 12);
    final credit = find.text('Based on FVP by Mark Forster');
    expect(tester.widget<Text>(credit).style!.fontSize, 12);
    expect(
      tester.getTopLeft(credit).dx -
          tester.getTopLeft(find.byType(TasksSidebar)).dx,
      20,
    );
    expect(
      tester.getTopLeft(today).dx -
          tester.getTopLeft(find.byType(TasksSidebar)).dx,
      8,
    );
  });

  testWidgets('the chosen list sits on the selected fill, drawn over the '
      "sidebar's colour, and the others on none", (tester) async {
    await setUpTasks();
    await pumpSidebar(tester);
    final palette = tester.element(find.byType(TasksSidebar)).palette;
    final today = find.byKey(const ValueKey('tasks-filter-all'));
    Color? fill(Finder row) =>
        (tester
                    .widget<Ink>(
                      find.descendant(of: row, matching: find.byType(Ink)),
                    )
                    .decoration
                as BoxDecoration?)
            ?.color;

    expect(fill(today), palette.selectedBackground);
    expect(fill(find.byKey(const ValueKey('tasks-filter-done'))), isNull);
    expect(
      fill(find.byKey(ValueKey('tasks-filter-${note('Lisbon trip').id}'))),
      isNull,
    );
    final ink = find.ancestor(of: today, matching: find.byType(Material)).first;
    expect(
      find.descendant(of: find.byType(TasksSidebar), matching: ink),
      findsOneWidget,
      reason: 'the fill lands on a Material over the sidebar, not under it',
    );
    expect(
      tester.renderObject(ink),
      paints..rrect(color: palette.selectedBackground),
    );
  });

  Color swatchColour(WidgetTester tester, Finder swatch) {
    final box = tester.widget<Container>(
      find.descendant(of: swatch, matching: find.byType(Container)),
    );
    return (box.decoration! as BoxDecoration).color!;
  }

  testWidgets('a note\'s marker takes its first tag\'s colour, and a note '
      'without one stays grey', (tester) async {
    await setUpTasks();
    await pumpSidebar(tester);
    final palette = tester.element(find.byType(TasksSidebar)).palette;

    Finder swatchIn(String title) => find.descendant(
      of: find.byKey(ValueKey('tasks-filter-${note(title).id}')),
      matching: find.byType(NoteSwatch),
    );
    expect(
      swatchColour(tester, swatchIn('Lisbon trip')),
      TagColour.sage.dot(palette),
    );
    expect(
      swatchColour(tester, swatchIn('Quote for the deck')),
      TagColour.mustard.dot(palette),
    );
    expect(
      swatchColour(tester, swatchIn('Call with Arjun')),
      palette.switchTrackOff,
    );
    expect(tester.getSize(swatchIn('Lisbon trip')), const Size.square(8));
  });

  testWidgets('the same colours mark the rows and the pair on the page', (
    tester,
  ) async {
    await setUpTasks();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: TagMarks(
            marksOf: marksOf,
            child: TasksScreen(
              controller: tasks,
              filter: const TaskFilter.all(),
              addFocus: focus,
              labelOf: (note) => note.title,
              onOpenNote: (_) {},
              onOpenDone: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final palette = tester.element(find.byType(TasksScreen)).palette;
    final colours = {
      for (final swatch in tester.widgetList<NoteSwatch>(
        find.byType(NoteSwatch),
      ))
        if (swatch.note case final note?)
          note.title: swatchColour(tester, find.byWidget(swatch)),
    };
    expect(colours['Lisbon trip'], TagColour.sage.dot(palette));
    expect(colours['Quote for the deck'], TagColour.mustard.dot(palette));
    expect(colours['Call with Arjun'], palette.switchTrackOff);
    await tester.pump(const Duration(seconds: 3));
  });
}
