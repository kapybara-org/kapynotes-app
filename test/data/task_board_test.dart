import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/note_doc.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/stamped.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_index.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'task-board-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  late DateTime clock;
  late TaskIndex index;
  late Map<String, NoteDoc> docs;
  late List<Note> notes;

  setUp(() {
    clock = DateTime(2026, 11, 17, 9);
    index = TaskIndex(_MemoryStore(), now: () => clock);
    docs = {};
    notes = [];
  });

  Note note(
    String id,
    String body, {
    DateTime? archivedAt,
    DateTime? hiddenAt,
    DateTime? createdAt,
  }) {
    final made = Note(
      id: id,
      body: body,
      createdAt: createdAt ?? DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 1),
      archivedAt: archivedAt,
      hiddenAt: hiddenAt,
    );
    final doc = docs[id] ??= NoteDoc(replica: 'aaaaaaaaaaaa');
    doc.reconcile(
      body: body,
      formats: const [],
      attachments: const [],
      createdAt: made.createdAt,
    );
    index.reconcileNote(id, doc, idFor: (anchor) => '$id:$anchor');
    notes.removeWhere((n) => n.id == id);
    notes.add(made);
    return made;
  }

  TaskBoard read() => TaskBoard.read(
    entries: index.entries,
    notes: notes,
    docOf: (id) => docs[id],
  );

  List<String> words(List<TaskItem> items) => [for (final i in items) i.words];

  test('the list keeps the order tasks were added in, across notes', () {
    note('a', 'Trip\n☐ Book flights\n☐ Learn phrases');
    clock = clock.add(const Duration(minutes: 1));
    note('b', 'Car\n- [ ] Call the garage');
    clock = clock.add(const Duration(minutes: 1));
    note('a', 'Trip\n☐ Book flights\n☐ Learn phrases\n☐ Pack');

    expect(words(read().open), [
      'Book flights',
      'Learn phrases',
      'Call the garage',
      'Pack',
    ]);
  });

  test('a task that went back in at the end sits there', () {
    note('a', 'Trip\n☐ Book flights\n☐ Learn phrases');
    final first = read().open.first;
    clock = clock.add(const Duration(hours: 1));
    index.update(first.entry.copyWith(enteredAt: clock.millisecondsSinceEpoch));

    expect(words(read().open), ['Learn phrases', 'Book flights']);
  });

  test('done is newest first, and counts by day', () {
    note('a', 'Trip\n☐ One\n☐ Two\n☐ Three');
    clock = DateTime(2026, 11, 16, 20);
    note('a', 'Trip\n☑ One\n☐ Two\n☐ Three');
    clock = DateTime(2026, 11, 17, 10);
    note('a', 'Trip\n☑ One\n☑ Two\n☐ Three');

    final board = read();
    expect(words(board.done), ['Two', 'One']);
    expect(words(board.open), ['Three']);
    expect(board.doneSince(DateTime(2026, 11, 17)), 1);
  });

  test('archived, hidden and dismissed tasks are left out', () {
    note('a', 'Trip\n☐ Book flights');
    note('b', 'Old\n☐ Archived task', archivedAt: DateTime(2026, 11, 2));
    note('c', 'Secret\n☐ Hidden task', hiddenAt: DateTime(2026, 11, 2));
    note('d', 'Shop\n☐ Dismissed task');
    final dismissed = read().open.firstWhere((i) => i.note.id == 'd');
    index.update(dismissed.entry.copyWith(dismissed: const Stamped(true, 1)));

    expect(words(read().open), ['Book flights']);
  });

  test('the oldest of my notes called Tasks holds tasks with no note', () {
    note('new', 'Tasks\n☐ Later', createdAt: DateTime(2026, 11, 10));
    note('old', 'Tasks\n☐ Earlier', createdAt: DateTime(2026, 11, 3));
    note('other', 'Trip\n☐ Book flights');

    final board = read();
    expect(board.home?.id, 'old');
    expect(
      [for (final item in board.open) board.isHome(item)],
      [false, true, false],
    );
  });

  test('a filter narrows the list to one note', () {
    note('a', 'Trip\n☐ Book flights');
    note('b', 'Car\n☐ Call the garage');

    expect(words(read().openIn('b')), ['Call the garage']);
  });

  test('a smaller task inside the details has no row of its own', () {
    note('a', 'Trip\n☐ Parent\n  ☐ Child\n  ☑ Finished\n☐ Sibling');

    final board = read();
    expect(words(board.open), ['Parent', 'Sibling']);
    expect(board.open.first.groupTotal, 3);
    expect(board.open.first.groupDone, 1);
  });

  test('reading one note of many tasks takes time in step with its size', () {
    TaskBoard Function() reader(int tasks) {
      final big = note(
        'big$tasks',
        [
          'Big list',
          for (var i = 0; i < tasks; i++) ...['☐ Task $i', '  A detail for $i'],
        ].join('\n'),
      );
      final entries = [
        for (final entry in index.entries)
          if (entry.noteId == big.id) entry,
      ];
      return () => TaskBoard.read(
        entries: entries,
        notes: [big],
        docOf: (id) => docs[id],
      );
    }

    int took(TaskBoard Function() read) {
      final watch = Stopwatch()..start();
      read();
      return watch.elapsedMicroseconds;
    }

    final small = reader(100);
    final large = reader(800);
    expect(small().open, hasLength(100));
    expect(large().open, hasLength(800));

    // The fastest of many reads of each, taken in turns: by the last rounds
    // the compiler has optimised both, a busy machine slows both alike, and
    // a read it interrupted doesn't count. Twice linear growth still passes;
    // a board that scans the note for every task takes about 64 times as long.
    var fastSmall = 1 << 40;
    var fastLarge = 1 << 40;
    for (var round = 0; round < 20; round++) {
      fastSmall = math.min(fastSmall, took(small));
      fastLarge = math.min(fastLarge, took(large));
    }
    expect(
      fastLarge,
      lessThan(fastSmall * 32),
      reason:
          'eight times the tasks took ${fastLarge / fastSmall} times as long',
    );
  });
}
