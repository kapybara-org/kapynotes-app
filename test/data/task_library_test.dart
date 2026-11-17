import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/stamped.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/data/task_lines.dart';
import 'package:kapy_notes/sync/doc_store.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'task-library-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  late NotesStore notes;
  late TaskLibrary library;

  setUp(() async {
    final store = _MemoryStore();
    notes = NotesStore(store);
    library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
    );
    await notes.load();
    await library.load();
  });

  tearDown(() => library.dispose());

  /// The words on the line [entry] is anchored to, or null once it has gone.
  String? wordsOf(TaskEntry entry) {
    final doc = library.docs.get(entry.noteId)!.doc;
    final lines = taskLines(doc.text);
    final index = taskLineIndex(doc, lines, entry.anchor);
    return index < 0
        ? null
        : doc.text.substring(lines[index].textStart, lines[index].end);
  }

  test('a note with checklist lines gets a document and its tasks, with no '
      'account and no call; one without gets neither', () async {
    final listed = notes.create(body: 'Errands\n☐ Buy milk');
    final plain = notes.create(body: 'Just words');
    await Future<void>.delayed(Duration.zero);

    expect(library.docs.get(listed.id), isNotNull);
    expect(library.docs.get(listed.id)!.offline, isTrue);
    expect(library.docs.get(plain.id), isNull);
    final task = library.index.entries.single;
    expect(task.id, startsWith(localTaskIdPrefix));
    expect(wordsOf(task), 'Buy milk');
  });

  test(
    'reconcileNow makes the index current before anything else runs',
    () async {
      var told = 0;
      library.addListener(() => told++);
      final note = notes.create(body: '☐ Call mum');
      await library.reconcileNow();
      expect(library.index.entries.single.noteId, note.id);
      expect(told, greaterThan(0));
    },
  );

  test('a deleted note takes its document and its tasks with it', () async {
    final note = notes.create(body: '☐ Call mum');
    await library.reconcileNow();
    notes.delete(note.id);
    await library.reconcileNow();
    expect(library.docs.get(note.id), isNull);
    expect(library.index.entries, isEmpty);
    expect(library.index.owed, isEmpty);
  });

  test('a middle line deleted in the editor keeps each task on its own line, '
      'state and all', () async {
    final note = notes.create(body: '☐ Buy oats\n☐ Buy milk\n☐ Buy eggs\n');
    await library.reconcileNow();
    TaskEntry reading(String words) =>
        library.index.entries.firstWhere((e) => wordsOf(e) == words);
    final eggs = reading('Buy eggs');
    library.index.update(eggs.copyWith(dot: const Stamped(true, 1)));

    notes.updateDocument(
      note.id,
      '☐ Buy oats\n☐ Buy eggs\n',
      const [],
      const [],
      (start: 11, oldEnd: 22, newEnd: 11),
    );
    await library.reconcileNow();

    expect(library.index.entries.map(wordsOf).toSet(), {
      'Buy oats',
      'Buy eggs',
    });
    expect(reading('Buy eggs').id, eggs.id);
    expect(reading('Buy eggs').dot.v, isTrue);
  });
}
