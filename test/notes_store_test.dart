import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'dart:typed_data';

import 'package:kapy_notes/data/note_attachment.dart';
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

  test(
    'pins notes above recency without turning pinning into an edit',
    () async {
      var now = DateTime.utc(2026, 9, 1, 8);
      final storage = _MemoryStore();
      final notes = NotesStore(storage, now: () => now);
      await notes.load();
      final older = notes.create(body: 'Reference');
      now = DateTime.utc(2026, 9, 1, 9);
      final newer = notes.create(body: 'Today');
      final olderUpdatedAt = older.updatedAt;

      expect(notes.togglePinned(older.id), isTrue);
      expect(notes.notes.map((note) => note.id), [newer.id, older.id]);
      expect(notes.search('').map((note) => note.id), [older.id, newer.id]);
      expect(notes.byId(older.id)!.updatedAt, olderUpdatedAt);
      expect(notes.isPinned(older.id), isTrue);

      final restored = NotesStore(storage);
      await restored.load();
      expect(restored.isPinned(older.id), isTrue);
      expect(restored.search('').first.id, older.id);

      expect(restored.togglePinned(older.id), isFalse);
      expect(restored.pinnedNoteIds, isEmpty);
      expect(restored.search('').map((note) => note.id), [newer.id, older.id]);
    },
  );

  test('deleting a pinned note clears its organization state', () async {
    final storage = _MemoryStore();
    final notes = NotesStore(storage);
    await notes.load();
    final note = notes.create(body: 'Temporary');
    notes.togglePinned(note.id);

    notes.delete(note.id);

    expect(notes.pinnedNoteIds, isEmpty);
    expect(storage.data['pinnedNoteIds.v1'], isEmpty);
  });

  test('deleting many notes is one change with a tombstone each', () async {
    final storage = _MemoryStore();
    final notes = NotesStore(storage);
    await notes.load();
    final first = notes.create(body: 'One');
    final second = notes.create(body: 'Two');
    final kept = notes.create(body: 'Three');
    var rebuilds = 0;
    notes.addListener(() => rebuilds++);

    // An id that is not there is not an error: a list picked in the UI can
    // have lost a note to a sync between the pick and the press.
    final deleted = notes.deleteAll([first.id, second.id, 'never-existed']);

    expect(deleted, 2);
    expect(notes.notes.map((note) => note.id), [kept.id]);
    expect(
      notes.tombstones.map((stone) => stone.id),
      unorderedEquals([first.id, second.id]),
    );
    // One save and one rebuild, not one per note.
    expect(rebuilds, 1);
  });

  test('deleting nothing writes nothing', () async {
    final storage = _MemoryStore();
    final notes = NotesStore(storage);
    await notes.load();
    notes.create(body: 'One');
    var rebuilds = 0;
    notes.addListener(() => rebuilds++);

    expect(notes.deleteAll(const []), 0);
    expect(notes.deleteAll(['gone-already']), 0);
    expect(rebuilds, 0);
    expect(notes.tombstones, isEmpty);
  });

  test('archives a note without deleting it and restores it later', () async {
    var now = DateTime.utc(2026, 9, 4, 8);
    final store = _MemoryStore();
    final notes = NotesStore(store, now: () => now);
    await notes.load();
    final kept = notes.create(body: 'Keep me');
    final archived = notes.create(body: 'Bring me back');

    now = DateTime.utc(2026, 9, 4, 9);
    notes.archive(archived.id);

    expect(notes.notes.map((note) => note.id), [kept.id]);
    expect(notes.archivedNotes.single.id, archived.id);
    expect(notes.allNotes, hasLength(2));
    expect(notes.byId(archived.id)?.archivedAt, now);
    expect(notes.search('bring'), isEmpty);
    expect(notes.searchArchived('bring').single.id, archived.id);
    expect(notes.tombstones, isEmpty, reason: 'archive is not a deletion');

    now = DateTime.utc(2026, 9, 4, 10);
    notes.restore(archived.id);

    expect(notes.archivedNotes, isEmpty);
    expect(notes.notes.first.id, archived.id);
    expect(notes.byId(archived.id)?.archivedAt, isNull);
  });

  test('archive state survives a restart', () async {
    final store = _MemoryStore();
    final notes = NotesStore(store, now: () => DateTime.utc(2026, 9, 4));
    await notes.load();
    final note = notes.create(body: 'Stored safely');
    notes.archive(note.id);

    final restored = NotesStore(store);
    await restored.load();

    expect(restored.notes, isEmpty);
    expect(restored.archivedNotes.single.id, note.id);
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

  group('updateAttachment', () {
    const anchor = NoteAttachmentRef.placeholder;

    NoteImageRef picture({String? attachmentId}) => NoteImageRef(
      offset: 0,
      hash: 'pic',
      key: Uint8List(32),
      mime: 'image/png',
      width: 4,
      height: 3,
      bytes: 12,
      attachmentId: attachmentId,
    );

    Future<NotesStore> seeded() async {
      final store = NotesStore(_MemoryStore());
      await store.load();
      final note = store.create();
      store.updateDocument(note.id, '$anchor Notes', const [], [picture()]);
      return store;
    }

    test('learning a server id is not an edit', () async {
      final store = await seeded();
      final before = store.notes.single.updatedAt;

      final ok = store.updateAttachment(
        store.notes.single.id,
        'pic',
        (ref) => ref.copyWith(attachmentId: 'server-1'),
      );

      expect(ok, isTrue);
      expect(store.notes.single.attachments.single.attachmentId, 'server-1');
      expect(store.notes.single.updatedAt, before);
    });

    test('a transcript is an edit, and does not reorder the list', () async {
      final store = await seeded();
      final first = store.notes.single.id;
      final second = store.create().id;
      final before = store.byId(first)!.updatedAt;

      final ok = store.updateAttachment(
        first,
        'pic',
        (ref) => ref.copyWith(attachmentId: 'server-1'),
        touch: true,
      );

      expect(ok, isTrue);
      expect(store.byId(first)!.updatedAt.isAfter(before), isTrue);
      // Bumped, but still where it was: a transcript arriving must not shuffle
      // the sidebar under someone who is reading it.
      expect(store.notes.first.id, second);
    });

    test('a write racing an edit keeps both', () async {
      final store = await seeded();
      final id = store.notes.single.id;

      // The user types while an upload is in flight.
      store.updateDocument(id, '$anchor Notes, edited', const [], [picture()]);
      // ...and the upload lands afterwards, holding a stale snapshot.
      store.updateAttachment(
        id,
        'pic',
        (ref) => ref.copyWith(attachmentId: 'server-1'),
      );

      expect(store.byId(id)!.body, '$anchor Notes, edited');
      expect(store.byId(id)!.attachments.single.attachmentId, 'server-1');
    });

    test('a note or a hash that is gone is not an error', () async {
      final store = await seeded();
      final id = store.notes.single.id;
      NoteAttachmentRef keep(NoteAttachmentRef ref) => ref;

      expect(store.updateAttachment('no-such-note', 'pic', keep), isFalse);
      expect(store.updateAttachment(id, 'no-such-hash', keep), isFalse);
    });
  });

  group('title', () {
    test('a line holding only an attachment is not the title', () {
      const anchor = NoteAttachmentRef.placeholder;
      final store = NotesStore(_MemoryStore());
      final note = store.create();
      store.updateDocument(note.id, '$anchor\nGroceries', const [], const []);
      expect(store.byId(note.id)!.title, 'Groceries');
    });
  });
}
