import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/task_choice.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'task-choice-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// A note of [body] whose random id [wanted] accepts, so a test can rely on
/// note createdAt alone for an order the id would break.
Note _createWith(
  NotesStore notes,
  String body,
  bool Function(String id) wanted,
) {
  while (true) {
    final note = notes.create(body: body);
    if (wanted(note.id)) return note;
    notes.delete(note.id);
  }
}

void main() {
  late DateTime clock;
  late _MemoryStore store;
  late NotesStore notes;
  late TaskLibrary library;
  late TasksController tasks;

  /// The app over [store] as it stands, as after a relaunch: the notes, the
  /// task index and Tasks, read afresh.
  Future<void> launch() async {
    notes = NotesStore(store, now: () => clock);
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
    final (held, heldLibrary) = (tasks, library);
    addTearDown(() {
      held.dispose();
      heldLibrary.dispose();
    });
  }

  /// A list from [body], and from [then] too when given: a note made a
  /// minute later whose id sorts first, both picked up in one reconcile.
  Future<String> start(String body, {DateTime? at, String? then}) async {
    clock = at ?? DateTime(2026, 11, 19, 9);
    store = _MemoryStore();
    await launch();
    final note = notes.create(body: body);
    if (then != null) {
      clock = clock.add(const Duration(minutes: 1));
      _createWith(notes, then, (id) => id.compareTo(note.id) < 0);
    }
    await tasks.reconcileNow();
    return note.id;
  }

  void later() => clock = clock.add(const Duration(minutes: 1));

  TaskChoice choice() => tasks.choiceIn(null);
  List<String> words(List<TaskItem> items) => [for (final i in items) i.words];

  PairStage pair() {
    final stage = choice().stage;
    expect(stage, isA<PairStage>());
    return stage as PairStage;
  }

  TaskItem doNow() {
    final stage = choice().stage;
    expect(stage, isA<DoNowStage>());
    return (stage as DoNowStage).item;
  }

  void keep() {
    later();
    tasks.keepChoice(pair());
  }

  void take() {
    later();
    tasks.takeNext(pair());
  }

  const six = 'List\n☐ A\n☐ B\n☐ C\n☐ D\n☐ E\n☐ F';
  const three = 'List\n☐ A\n☐ B\n☐ C';
  const trip = 'Trip\n☐ A1\n☐ A2';
  const car = 'Car\n☐ B1\n☐ B2';

  /// The left card, then every right card ← meets until the round ends;
  /// a round that outruns the list fails rather than hangs.
  List<String> keepToTheEnd() {
    final asked = [pair().left.words];
    final most = 3 * tasks.read().open.length;
    while (choice().stage is PairStage) {
      if (asked.length > most) fail('the pair kept asking: $asked');
      asked.add(pair().right.words);
      keep();
    }
    return asked;
  }

  test('with nothing chosen, the first task on the list meets the next one, '
      'and the count says how many pairs follow', () async {
    await start(six);
    final first = pair();
    expect(first.left.words, 'A');
    expect(first.chosen, isFalse);
    expect(first.right.words, 'B');
    expect(first.joined, isFalse);
    expect(first.pairsLeft, 4);
    expect(first.seen, 2);
    expect(first.total, 6);
    expect(choice().upNext, isEmpty);
    expect(words(choice().rest), ['C', 'D', 'E', 'F']);
    expect(choice().chosen, isFalse);
  });

  test('← keeps your choice so far, and the next task on the list comes in '
      'on the right; the one passed over waits its turn', () async {
    await start(six);
    keep();
    final next = pair();
    expect(next.left.words, 'A');
    expect(next.chosen, isTrue);
    expect(next.right.words, 'C');
    expect(next.pairsLeft, 3);
    expect(next.seen, 3);
    expect(next.total, 6);
    expect(choice().upNext, isEmpty);
    expect(words(choice().rest), ['B', 'D', 'E', 'F']);
    expect(choice().chosen, isTrue);
  });

  test('→ makes the right card your choice so far, and the old choice joins '
      'the top of Up next', () async {
    await start(six);
    keep();
    take();
    expect(pair().left.words, 'C');
    expect(pair().right.words, 'D');
    expect(words(choice().upNext), ['A']);
    take();
    expect(pair().left.words, 'D');
    expect(words(choice().upNext), ['C', 'A']);
    expect(pair().pairsLeft, 1);
  });

  test('the last pick becomes Do now, and earlier picks wait in Up next in '
      'the order they will come', () async {
    await start(three);
    take();
    expect(pair().pairsLeft, 0);
    take();
    expect(doNow().words, 'C');
    expect(doNow().doNow, isTrue);
    expect(words(choice().upNext), ['B', 'A']);
    expect(choice().rest, isEmpty);
  });

  test('← on the last pair makes your choice so far Do now', () async {
    await start(three);
    take();
    keep();
    expect(doNow().words, 'B');
    expect(words(choice().upNext), ['A']);
    expect(words(choice().rest), ['C']);
  });

  test('Stop choosing makes your choice so far Do now; earlier picks stay in Up '
      'next and the tasks not yet shown stay on the list', () async {
    await start(six);
    keep();
    take();
    later();
    tasks.startWith(pair().left);
    expect(doNow().words, 'C');
    expect(words(choice().upNext), ['A']);
    expect(words(choice().rest), ['B', 'D', 'E', 'F']);
  });

  test('tasks of notes picked up together are each asked about, a note\'s '
      'tasks together, oldest note first', () async {
    await start(trip, then: car);
    expect(keepToTheEnd(), ['A1', 'A2', 'B1', 'B2']);
    expect(doNow().words, 'A1');
  });

  test('tasks that share a place, as when two devices pick them up in the '
      'same millisecond, are each asked about in list order', () async {
    await start(trip, then: car);
    final tied = clock.millisecondsSinceEpoch;
    for (final item in tasks.read().open) {
      tasks.index.update(item.entry.copyWith(enteredAt: tied));
    }
    expect({for (final i in tasks.read().open) i.entry.position}, {tied});
    expect(words(tasks.read().open), ['A1', 'A2', 'B1', 'B2']);
    expect(keepToTheEnd(), ['A1', 'A2', 'B1', 'B2']);
    expect(doNow().words, 'A1');
  });

  /// [body]'s six tasks, sharing one place, asked about with an edit to
  /// [edited] and [rekey] between the first pair and the rest.
  Future<List<String>> askAcrossAnEdit(
    String body,
    String edited, {
    bool rekey = false,
  }) async {
    final note = await start(body);
    final tied = clock.millisecondsSinceEpoch;
    for (final item in tasks.read().open) {
      tasks.index.update(item.entry.copyWith(enteredAt: tied));
    }
    final asked = [pair().left.words, pair().right.words];
    keep();
    if (rekey) tasks.index.rekey((noteId, anchor) => 'rekeyed-$anchor');
    notes.updateBody(note, edited);
    await tasks.reconcileNow();
    return [...asked, ...keepToTheEnd().skip(1)];
  }

  const tasksOfSix = '☐ A\n☐ B\n☐ C\n☐ D\n☐ E\n☐ F';

  test('tasks that share a place are each asked about once when the title '
      'grows mid-pair', () async {
    final asked = await askAcrossAnEdit(
      'List\n$tasksOfSix',
      'List for the whole week\n$tasksOfSix',
    );
    expect(asked, ['A', 'B', 'C', 'D', 'E', 'F']);
    expect(doNow().words, 'A');
  });

  test('tasks that share a place are each asked about once when the title '
      'shrinks mid-pair', () async {
    final asked = await askAcrossAnEdit(
      'List for the whole week\n$tasksOfSix',
      'List\n$tasksOfSix',
    );
    expect(asked, ['A', 'B', 'C', 'D', 'E', 'F']);
    expect(doNow().words, 'A');
  });

  test('tasks that share a place are each asked about once when their ids '
      'change and the title shrinks mid-pair', () async {
    final asked = await askAcrossAnEdit(
      'List for the whole week\n$tasksOfSix',
      'List\n$tasksOfSix',
      rekey: true,
    );
    expect(tasks.read().open.first.id, startsWith('rekeyed-'));
    expect(asked, ['A', 'B', 'C', 'D', 'E', 'F']);
    expect(doNow().words, 'A');
  });

  test('after a restart mid-round, the pair carries on from the last dot and '
      'never asks about the tasks above it', () async {
    await start(six);
    later();
    tasks.dot(tasks.read().open[1]);
    later();
    tasks.dot(tasks.read().open[3]);
    tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => true,
      now: () => clock,
    );
    addTearDown(tasks.dispose);
    expect(keepToTheEnd(), ['D', 'E', 'F']);
    expect(doNow().words, 'D');
  });

  test('a task shown on the right and then moved to the end leaves the pair '
      'where it was', () async {
    await start(six);
    final passed = pair().right;
    keep();
    later();
    tasks.moveToEnd(passed);
    expect(words(tasks.read().open), ['A', 'C', 'D', 'E', 'F', 'B']);
    expect(pair().left.words, 'A');
    expect(pair().right.words, 'C');
  });

  test('with one task on the list there is no pair: it is Do now', () async {
    await start('List\n☐ Only');
    expect(doNow().words, 'Only');
    expect(choice().chosen, isFalse);
  });

  test('after Done with nothing new, the first task in Up next becomes Do now '
      'and nothing is asked', () async {
    await start(three);
    take();
    take();
    later();
    await tasks.finish(doNow());
    expect(doNow().words, 'B');
    expect(doNow().doNow, isTrue);
    expect(words(choice().upNext), ['A']);
    expect(tasks.justDone, isNull);
  });

  test('after Done, a task that joined the list since you chose meets your '
      'choice so far, and says it is new', () async {
    final note = await start(three);
    take();
    take();
    later();
    await tasks.add('D', noteId: note);
    later();
    await tasks.finish(doNow());
    final again = pair();
    expect(again.left.words, 'B');
    expect(again.chosen, isTrue);
    expect(again.right.words, 'D');
    expect(again.joined, isTrue);
    expect(again.pairsLeft, 0);
    expect(again.seen, 1);
    expect(again.total, 1);
    expect(tasks.justDone?.words, 'C');
    expect(words(choice().upNext), ['A']);

    keep();
    expect(doNow().words, 'B');
    expect(words(choice().rest), ['D']);
    expect(tasks.justDone, isNull);
  });

  test(
    'after Done with several new tasks, the pairs carry on one by one',
    () async {
      final note = await start(three);
      take();
      take();
      later();
      await tasks.add('D', noteId: note);
      await tasks.add('E', noteId: note);
      later();
      await tasks.finish(doNow());
      expect(pair().right.words, 'D');
      expect(pair().pairsLeft, 1);
      take();
      expect(pair().left.words, 'D');
      expect(pair().right.words, 'E');
      expect(pair().joined, isTrue);
      expect(words(choice().upNext), ['B', 'A']);
      take();
      expect(doNow().words, 'E');
      expect(words(choice().upNext), ['D', 'B', 'A']);
    },
  );

  test('after Done, only a task added after you chose is new, when the list '
      'was picked up in one go at the instant you chose', () async {
    final note = await start(six);
    tasks.takeNext(pair());
    tasks.startWith(pair().left);
    expect(doNow().words, 'B');
    later();
    await tasks.add('G', noteId: note);
    later();
    await tasks.finish(doNow());
    expect(pair().left.words, 'A');
    expect(pair().right.words, 'G');
    expect(pair().joined, isTrue);
    expect(pair().pairsLeft, 0);
  });

  test('after Done, a task already on the list is not new even when its '
      'stamp runs ahead of the clock you chose by', () async {
    final note = await start(six);
    final pickedUp = clock;
    clock = pickedUp.subtract(const Duration(minutes: 1));
    tasks.takeNext(pair());
    tasks.startWith(pair().left);
    expect(doNow().words, 'B');
    clock = pickedUp.add(const Duration(minutes: 1));
    await tasks.add('G', noteId: note);
    later();
    await tasks.finish(doNow());
    expect(pair().right.words, 'G');
    expect(pair().pairsLeft, 0);
  });

  test('after a relaunch between choosing and Done, a task already on the '
      'list is still not new when its stamp runs ahead of the clock you '
      'chose by', () async {
    final note = await start(six);
    final pickedUp = clock;
    clock = pickedUp.subtract(const Duration(minutes: 1));
    tasks.takeNext(pair());
    tasks.startWith(pair().left);
    await launch();
    await tasks.reconcileNow();
    expect(doNow().words, 'B');
    clock = pickedUp.add(const Duration(minutes: 1));
    await tasks.add('G', noteId: note);
    later();
    await tasks.finish(doNow());
    expect(pair().right.words, 'G');
    expect(pair().pairsLeft, 0);
  });

  test('a task that was on the list before you chose is not asked about '
      'again after Done', () async {
    await start(six);
    keep();
    take();
    later();
    tasks.startWith(pair().left);
    expect(doNow().words, 'C');
    later();
    await tasks.finish(doNow());
    expect(doNow().words, 'A');
    expect(words(choice().rest), ['B', 'D', 'E', 'F']);
  });

  test(
    'after Done with Up next empty, a new round starts at the first pair',
    () async {
      await start(three);
      keep();
      later();
      tasks.startWith(pair().left);
      later();
      await tasks.finish(doNow());
      final round = pair();
      expect(round.left.words, 'B');
      expect(round.right.words, 'C');
      expect(round.chosen, isFalse);
      expect(tasks.justDone, isNull);
    },
  );

  test('Not finished sends Do now to the end of the list, unchosen and marked '
      'as come back, and the first task in Up next becomes Do now', () async {
    await start(three);
    take();
    take();
    later();
    tasks.notFinished(doNow());
    expect(words(tasks.read().open), ['A', 'B', 'C']);
    final c = tasks.read().open.last;
    expect(c.dotted, isFalse);
    expect(c.entry.enteredAt, isNot(0));
    expect(doNow().words, 'B');
    expect(words(choice().upNext), ['A']);
    expect(words(choice().rest), ['C']);
  });

  test('Not finished with nothing in Up next starts a new round', () async {
    await start(three);
    later();
    tasks.startWith(pair().left);
    later();
    tasks.notFinished(doNow());
    expect(words(tasks.read().open), ['B', 'C', 'A']);
    expect(pair().left.words, 'B');
    expect(pair().chosen, isFalse);
  });

  test('Not finished at the instant you chose asks about nothing already on '
      'the list, when it was picked up in one go', () async {
    await start(six);
    tasks.takeNext(pair());
    tasks.startWith(pair().left);
    expect(doNow().words, 'B');
    tasks.notFinished(doNow());
    expect(doNow().words, 'A');
    expect(words(choice().upNext), isEmpty);
  });

  test(
    'Choose again clears every choice and starts at the first pair',
    () async {
      await start(six);
      keep();
      take();
      later();
      tasks.chooseAgain();
      expect(tasks.read().open.any((i) => i.dotted || i.doNow), isFalse);
      expect(pair().left.words, 'A');
      expect(pair().right.words, 'B');
      expect(choice().chosen, isFalse);
    },
  );

  test('the row menu: Do now keeps the old Do now in Up next, Add to Up next '
      'and Take out of Up next move only the dot, Move to the end sends it '
      'last', () async {
    await start(six);
    final open = tasks.read().open;
    later();
    tasks.makeDoNow(open[1]);
    expect(doNow().words, 'B');
    later();
    tasks.makeDoNow(open[3]);
    expect(doNow().words, 'D');
    expect(words(choice().upNext), ['B']);
    later();
    tasks.dot(tasks.read().open[0]);
    expect(words(choice().upNext), ['B', 'A']);
    later();
    tasks.takeOutOfUpNext(tasks.read().open[1]);
    expect(words(choice().upNext), ['A']);
    expect(words(choice().rest), ['B', 'C', 'E', 'F']);
    later();
    tasks.moveToEnd(tasks.read().open[2]);
    expect(words(tasks.read().open), ['A', 'B', 'D', 'E', 'F', 'C']);
  });

  test(
    'after 6 pm, once a round ends with nothing chosen, the day closes '
    'with the tasks left in order; Keep going brings back the first pair',
    () async {
      await start(three, at: DateTime(2026, 11, 19, 18, 30));
      later();
      tasks.startWith(pair().left);
      later();
      await tasks.finish(doNow());
      final stage = choice().stage;
      expect(stage, isA<EveningStage>());
      expect(words((stage as EveningStage).left), ['B', 'C']);
      expect(choice().rest, isEmpty);
      expect(choice().chosen, isFalse);

      tasks.keepGoing();
      expect(pair().left.words, 'B');
    },
  );

  test('before 6 pm, or with nothing finished today, the pair stays', () async {
    await start(three, at: DateTime(2026, 11, 19, 17));
    later();
    tasks.startWith(pair().left);
    later();
    await tasks.finish(doNow());
    expect(choice().stage, isA<PairStage>());

    await start(three, at: DateTime(2026, 11, 19, 20));
    expect(choice().stage, isA<PairStage>());
  });

  test('the evening gives way to a new day', () async {
    await start(three, at: DateTime(2026, 11, 19, 18, 30));
    later();
    tasks.startWith(pair().left);
    later();
    await tasks.finish(doNow());
    expect(choice().stage, isA<EveningStage>());
    clock = DateTime(2026, 11, 20, 8);
    expect(choice().stage, isA<PairStage>());
  });

  test(
    'a note filter narrows the pair, Up next and the list to that note',
    () async {
      final first = await start(three);
      final other = notes.create(body: 'Other\n☐ X\n☐ Y');
      await tasks.reconcileNow();
      final narrowed = tasks.choiceIn(other.id);
      expect((narrowed.stage as PairStage).left.words, 'X');
      expect((narrowed.stage as PairStage).right.words, 'Y');
      expect(words(tasks.choiceIn(first).rest), ['C']);
    },
  );

  test('choosing writes only the dot and Do now main already keeps', () async {
    await start(six);
    final before = {
      for (final e in tasks.index.entries) e.id: e.toPayload().keys.toSet(),
    };
    keep();
    take();
    later();
    tasks.startWith(pair().left);
    for (final e in tasks.index.entries) {
      expect(e.toPayload().keys.toSet(), before[e.id]);
    }
  });
}
