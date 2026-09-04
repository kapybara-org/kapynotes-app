import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/notes_store.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'notes-store-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// The note array inside the `notes.v2` record.
List<Object?> storedNotes(LocalStore store) =>
    (store.data['notes.v2'] as Map<String, Object?>)['notes'] as List<Object?>;

void main() {
  test('sorts persisted notes by most recent update on load', () async {
    final store = _MemoryStore();
    store.data['notes.v1'] = [
      {
        'id': 'oldest',
        'body': 'Oldest',
        'createdAt': DateTime.utc(2026, 8, 1).millisecondsSinceEpoch,
        'updatedAt': DateTime.utc(2026, 8, 2).millisecondsSinceEpoch,
      },
      {
        'id': 'latest',
        'body': 'Latest',
        'createdAt': DateTime.utc(2026, 8, 2).millisecondsSinceEpoch,
        'updatedAt': DateTime.utc(2026, 9, 2).millisecondsSinceEpoch,
      },
      {
        'id': 'middle',
        'body': 'Middle',
        'createdAt': DateTime.utc(2026, 8, 3).millisecondsSinceEpoch,
        'updatedAt': DateTime.utc(2026, 9, 1).millisecondsSinceEpoch,
      },
    ];
    final notes = NotesStore(store);

    await notes.load();

    expect(notes.notes.map((note) => note.id), ['latest', 'middle', 'oldest']);
    expect(notes.lastEditedNote?.id, 'latest');
  });

  test('moves an edited note to the top and persists that order', () async {
    var now = DateTime.utc(2026, 9, 1, 8);
    final store = _MemoryStore();
    final notes = NotesStore(store, now: () => now);
    await notes.load();

    final first = notes.create(body: 'First note');
    now = DateTime.utc(2026, 9, 1, 9);
    final second = notes.create(body: 'Second note');
    expect(notes.notes.map((note) => note.id), [second.id, first.id]);

    now = DateTime.utc(2026, 9, 2, 10, 15);
    notes.updateBody(first.id, 'First note\nChanged');

    expect(notes.notes.map((note) => note.id), [first.id, second.id]);
    expect(notes.notes.first.updatedAt, now);
    expect(notes.search('note').map((note) => note.id), [first.id, second.id]);
    final stored = storedNotes(store);
    expect(stored.map((entry) => (entry as Map<String, Object?>)['id']), [
      first.id,
      second.id,
    ]);
  });

  test('persists text formatting and restores it with the note', () async {
    final store = _MemoryStore();
    final notes = NotesStore(store);
    await notes.load();
    final note = notes.create(body: 'Formatting demo\nBold and italic');
    const formats = [
      NoteFormatRange(start: 0, end: 15, format: NoteFormat.heading),
      NoteFormatRange(start: 16, end: 20, format: NoteFormat.bold),
      NoteFormatRange(start: 25, end: 31, format: NoteFormat.italic),
    ];

    notes.updateDocument(note.id, note.body, formats);

    final json = storedNotes(store).single as Map<String, Object?>;
    expect(json['formats'], isNotNull);

    final restored = NotesStore(store);
    await restored.load();
    expect(restored.notes.single.formats, formats);
  });
}
