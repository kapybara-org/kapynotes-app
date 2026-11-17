import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tasks-controller-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  late DateTime clock;
  late NotesStore notes;
  late TaskLibrary library;
  late TasksController tasks;

  setUp(() async {
    clock = DateTime(2026, 11, 17, 9);
    final store = _MemoryStore();
    notes = NotesStore(store);
    library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => clock,
    );
    await notes.load();
    await library.load();
    tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => true,
      now: () => clock,
    );
  });

  tearDown(() {
    tasks.dispose();
    library.dispose();
  });

  void later() => clock = clock.add(const Duration(minutes: 1));

  List<String> open() => [for (final item in tasks.read().open) item.words];

  test('a task with no note goes into a Tasks note made on first use, and '
      'the next one joins it at the end', () async {
    final first = await tasks.add('Pay the electricity bill');
    later();
    final second = await tasks.add('  Renew the domain  ');

    final board = tasks.read();
    expect(
      board.home?.body,
      'Tasks\n☐ Pay the electricity bill\n☐ Renew the domain',
    );
    expect([for (final item in board.open) item.id], [first, second]);
    expect(board.open.every(board.isHome), isTrue);
  });

  test('a task added to a note goes at the end of its text', () async {
    final note = notes.create(body: 'Trip\n☐ Book flights');
    await tasks.reconcileNow();
    later();
    await tasks.add('Learn phrases', noteId: note.id);

    expect(notes.byId(note.id)!.body, 'Trip\n☐ Book flights\n☐ Learn phrases');
    expect(open(), ['Book flights', 'Learn phrases']);
  });

  test('ticking writes the box in the note, both styles, and unticking from '
      'Done puts the task back at the end', () async {
    final note = notes.create(body: 'Car\n- [ ] Call the garage\n☐ Wash it');
    await tasks.reconcileNow();
    later();
    await tasks.setDone(tasks.read().open.first, done: true);

    expect(notes.byId(note.id)!.body, 'Car\n- [x] Call the garage\n☐ Wash it');
    expect(open(), ['Wash it']);
    expect(tasks.read().done.single.doneAt, clock);

    later();
    await tasks.setDone(tasks.read().done.single, done: false);
    expect(notes.byId(note.id)!.body, 'Car\n- [ ] Call the garage\n☐ Wash it');
    expect(open(), ['Wash it', 'Call the garage']);
  });

  test('a tick in the note itself reaches Tasks', () async {
    final note = notes.create(body: 'Car\n☐ Call the garage');
    await tasks.reconcileNow();
    notes.updateBody(note.id, 'Car\n☑ Call the garage');
    await tasks.reconcileNow();

    expect(open(), isEmpty);
    expect(tasks.read().done.single.words, 'Call the garage');
  });

  test('Not finished sends a task to the end without its dot', () async {
    notes.create(body: 'List\n☐ One\n☐ Two\n☐ Three');
    await tasks.reconcileNow();
    final one = tasks.read().open.first;
    tasks.doNow(one, tasks.read().open);
    expect(tasks.read().open.first.doNow, isTrue);

    later();
    tasks.sendToEnd(tasks.read().open.first);
    final board = tasks.read();
    expect(open(), ['Two', 'Three', 'One']);
    expect(board.open.last.dotted || board.open.last.doNow, isFalse);
  });

  test(
    'one task is Do now at a time, and Pick again clears every dot',
    () async {
      notes.create(body: 'List\n☐ One\n☐ Two\n☐ Three');
      await tasks.reconcileNow();
      var board = tasks.read();
      tasks.dot(board.open[0]);
      tasks.doNow(board.open[1], board.open);
      board = tasks.read();
      tasks.doNow(board.open[2], board.open);

      board = tasks.read();
      expect([for (final i in board.open) i.doNow], [false, false, true]);
      expect([for (final i in board.open) i.dotted], [true, true, true]);

      tasks.clearPicks(board.open);
      board = tasks.read();
      expect(board.open.any((i) => i.dotted || i.doNow), isFalse);
    },
  );

  test('Remove takes the line out, and undo puts it back in its place in '
      'the list', () async {
    final note = notes.create(body: 'List\n☐ One\n☐ Two\n☐ Three');
    await tasks.reconcileNow();
    final two = tasks.read().open[1];
    tasks.dot(two);

    later();
    final undo = await tasks.remove(tasks.read().open[1]);
    expect(notes.byId(note.id)!.body, 'List\n☐ One\n☐ Three');
    expect(open(), ['One', 'Three']);

    later();
    await undo!();
    expect(notes.byId(note.id)!.body, 'List\n☐ One\n☐ Two\n☐ Three');
    expect(open(), ['One', 'Two', 'Three']);
    expect(tasks.read().open[1].dotted, isTrue);
  });

  test(
    'a task in a note this person cannot change is only dismissed',
    () async {
      final note = notes.create(body: 'Shared\n☐ Theirs');
      await tasks.reconcileNow();
      final readOnly = TasksController(
        notes: notes,
        library: library,
        canEdit: (_) => false,
        now: () => clock,
      );
      addTearDown(readOnly.dispose);

      final undo = await readOnly.remove(readOnly.read().open.single);
      expect(notes.byId(note.id)!.body, 'Shared\n☐ Theirs');
      expect(readOnly.read().open, isEmpty);
      await undo!();
      expect(readOnly.read().open.single.words, 'Theirs');
    },
  );

  test('a task untouched for 14 days asks whether it is still wanted until '
      'it is kept', () async {
    notes.create(body: 'List\n☐ Old');
    await tasks.reconcileNow();
    clock = clock.add(TaskBoard.staleAfter);
    final item = tasks.read().open.single;
    expect(
      clock.millisecondsSinceEpoch - item.lastTouched >=
          TaskBoard.staleAfter.inMilliseconds,
      isTrue,
    );
    tasks.keep(item);
    expect(tasks.read().open.single.lastTouched, clock.millisecondsSinceEpoch);
  });
}
