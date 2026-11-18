import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/mcp/mcp_library.dart';

import 'mcp_test_helpers.dart';

void main() {
  late McpFixture f;
  setUp(() => f = McpFixture());

  Matcher refusedWith(String message) =>
      throwsA(isA<McpRefusal>().having((r) => r.message, 'message', message));

  group('Hidden notes', () {
    test('are never listed, searched or counted', () {
      final listed = f.library.list(includeArchived: true).map((n) => n.id);
      expect(listed, isNot(contains(f.hidden)));
      expect(f.library.list(query: 'diary', includeArchived: true), isEmpty);
      expect(
        f.library.tasks().map((t) => t.note.id),
        isNot(contains(f.hidden)),
      );
    });

    test('by id get exactly the words an unknown id gets', () {
      expect(
        () => f.library.read('no-such-id'),
        refusedWith(McpLibrary.notFound),
      );
      expect(() => f.library.read(f.hidden), refusedWith(McpLibrary.notFound));
      expect(
        () => f.library.tasks(noteId: f.hidden),
        refusedWith(McpLibrary.notFound),
      );
      expect(
        () => f.library.append(f.hidden, 'x'),
        refusedWith(McpLibrary.notFound),
      );
      expect(
        () => f.library.addTask(f.hidden, 'x'),
        refusedWith(McpLibrary.notFound),
      );
      expect(
        () =>
            f.library.setTaskDone('${f.hidden}~0000000000000000~0', done: true),
        refusedWith(McpLibrary.notFound),
      );
      expect(f.notes.byId(f.hidden)!.body, 'Secret diary\nnothing to see');
    });

    test('a note hidden after it was listed is refused at the write', () {
      final task = f.library.tasks(noteId: f.plain).first;
      f.notes.hide(f.plain);
      expect(
        () => f.library.append(f.plain, 'more'),
        refusedWith(McpLibrary.notFound),
      );
      expect(
        () => f.library.setTaskDone(task.id, done: true),
        refusedWith(McpLibrary.notFound),
      );
      expect(f.notes.byId(f.plain)!.body, isNot(contains('more')));
    });
  });

  group('Archived notes', () {
    test('are listed only when asked for, and read', () {
      expect(f.library.list().map((n) => n.id), isNot(contains(f.archived)));
      expect(
        f.library.list(includeArchived: true).map((n) => n.id),
        contains(f.archived),
      );
      expect(f.library.read(f.archived).id, f.archived);
      expect(
        f.library.tasks().map((t) => t.note.id),
        isNot(contains(f.archived)),
      );
    });

    test('are read-only', () {
      const refusal = 'Archived notes are read-only.';
      expect(() => f.library.append(f.archived, 'x'), refusedWith(refusal));
      expect(() => f.library.addTask(f.archived, 'x'), refusedWith(refusal));
    });
  });

  test('drawings show by title, with no body, and can’t be changed', () {
    final drawing = f.library.read(f.drawing);
    expect(drawing.title, 'Drawing');
    expect(f.library.bodyOf(drawing), isEmpty);
    expect(f.library.resultsOf(drawing), isEmpty);
    expect(
      () => f.library.append(f.drawing, 'x'),
      refusedWith('Drawings can’t be changed from an assistant.'),
    );
  });

  test('notes in shared spaces are read but never written', () {
    expect(f.library.read(f.shared).title, 'Team plan');
    final task = f.library.tasks(noteId: f.shared).single;
    const refusal = 'Notes in shared spaces are read-only here.';
    expect(() => f.library.append(f.shared, 'x'), refusedWith(refusal));
    expect(() => f.library.addTask(f.shared, 'x'), refusedWith(refusal));
    expect(
      () => f.library.setTaskDone(task.id, done: true),
      refusedWith(refusal),
    );
    expect(f.notes.byId(f.shared)!.body, 'Team plan\n☐ Ship it');
  });

  test('reads a note with what the calculator answers on each line', () {
    final note = f.library.read(f.plain);
    expect(f.library.bodyOf(note), startsWith('Trip budget\n'));
    expect(f.library.resultsOf(note), containsPair(2, '420'));
  });

  test('creates a note without counting it as the person’s writing', () {
    final note = f.library.create(title: 'Groceries', body: '☐ Milk');
    expect(note.body, 'Groceries\n☐ Milk');
    expect(note.isHidden, isFalse);
    expect(note.spaceId, isNull);
    f.library.append(note.id, 'Bread');
    expect(f.notes.streak.wroteToday, isFalse);
  });

  test('a create past the note limit is refused', () {
    final limited = McpFixture(canCreate: false);
    expect(
      () => limited.library.create(title: 'One more'),
      throwsA(isA<McpRefusal>()),
    );
  });

  group('a note Free holds read-only', () {
    setUp(() => f.locked.add(f.plain));

    test('refuses append_to_note', () {
      expect(
        () => f.library.append(f.plain, 'More'),
        refusedWith('Read-only on Free.'),
      );
      expect(f.notes.byId(f.plain)!.body, endsWith('☑ Pack bag'));
    });

    test('refuses add_task', () {
      expect(
        () => f.library.addTask(f.plain, 'Print tickets'),
        refusedWith('Read-only on Free.'),
      );
      expect(f.notes.byId(f.plain)!.body, endsWith('☑ Pack bag'));
    });

    test('refuses set_task_done, and stays readable', () {
      final taxi = f.library
          .tasks(noteId: f.plain)
          .firstWhere((t) => t.text == 'Book taxi');
      expect(
        () => f.library.setTaskDone(taxi.id, done: true),
        refusedWith('Read-only on Free.'),
      );
      expect(f.notes.byId(f.plain)!.body, contains('☐ Book taxi'));
      expect(
        f.library.bodyOf(f.library.read(f.plain)),
        startsWith('Trip budget\n'),
      );
    });
  });

  test('appends on a new line', () {
    final note = f.library.append(f.plain, 'Remember the charger');
    expect(note.body, endsWith('☑ Pack bag\nRemember the charger'));
  });

  test('adds a task in the style the note already uses', () {
    final task = f.library.addTask(f.plain, 'Print tickets');
    expect(f.notes.byId(f.plain)!.body, endsWith('\n☐ Print tickets'));
    expect(task.done, isFalse);

    final markdown = f.notes.create(body: 'Chores\n- [x] Laundry').id;
    f.library.addTask(markdown, 'Dishes');
    expect(f.notes.byId(markdown)!.body, 'Chores\n- [x] Laundry\n- [ ] Dishes');
  });

  test('ticks a task off and back on by swapping only its box', () {
    final taxi = f.library
        .tasks(noteId: f.plain)
        .firstWhere((t) => t.text == 'Book taxi');
    expect(f.library.setTaskDone(taxi.id, done: true).done, isTrue);
    expect(f.notes.byId(f.plain)!.body, contains('☑ Book taxi'));
    expect(f.library.setTaskDone(taxi.id, done: false).done, isFalse);
    expect(f.notes.byId(f.plain)!.body, contains('☐ Book taxi'));

    final markdown = f.notes.create(body: 'Chores\n- [ ] Laundry').id;
    final laundry = f.library.tasks(noteId: markdown).single;
    f.library.setTaskDone(laundry.id, done: true);
    expect(f.notes.byId(markdown)!.body, 'Chores\n- [x] Laundry');
  });

  test('a task whose line changed is refused rather than guessed at', () {
    final taxi = f.library
        .tasks(noteId: f.plain)
        .firstWhere((t) => t.text == 'Book taxi');
    f.notes.updateBody(
      f.plain,
      f.notes.byId(f.plain)!.body.replaceFirst('Book taxi', 'Call cab'),
    );
    expect(
      () => f.library.setTaskDone(taxi.id, done: true),
      refusedWith('That task changed; list the tasks again.'),
    );
  });

  test('refuses text that could fake an attachment or carry control bytes', () {
    expect(
      () => f.library.append(f.plain, 'a\uFFFCb'),
      throwsA(isA<McpRefusal>()),
    );
    expect(
      () => f.library.append(f.plain, 'a\u0000b'),
      throwsA(isA<McpRefusal>()),
    );
    expect(
      () => f.library.create(title: 'x' * (McpLibrary.maxTitle + 1)),
      throwsA(isA<McpRefusal>()),
    );
    expect(
      () => f.library.addTask(f.plain, 'two\nlines'),
      throwsA(isA<McpRefusal>()),
    );
  });

  test('an assistant’s write is a dirty local edit that syncs like typing', () {
    f.library.append(f.plain, 'More');
    expect(f.notes.dirtyNotes.map((n) => n.id), contains(f.plain));
    expect(f.notes.takeEdit(f.plain), isNotNull);
  });
}
