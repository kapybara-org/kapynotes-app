import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tombstone.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'notes-sync-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

DateTime at(int day, [int hour = 0]) => DateTime.utc(2026, 9, day, hour);

Note remoteNote(String id, String body, DateTime updatedAt) =>
    Note(id: id, body: body, createdAt: at(1), updatedAt: updatedAt);

void main() {
  group('migration', () {
    test('reads a v1 store, rewrites it as v2, and leaves it pending', () async {
      final store = _MemoryStore();
      store.data['notes.v1'] = [
        {
          'id': 'a',
          'body': 'Legacy note',
          'createdAt': at(1).millisecondsSinceEpoch,
          'updatedAt': at(2).millisecondsSinceEpoch,
        },
      ];

      final notes = NotesStore(store);
      await notes.load();

      expect(notes.notes.single.body, 'Legacy note');
      // The server has never seen it, so the first sync must push it.
      expect(notes.dirtyNotes, hasLength(1));
      expect(store.data['notes.v2'], isNotNull);
      // The old key is cleared in the same atomic write, not left to diverge.
      expect(store.data['notes.v1'], isNull);
    });

    test('a v2 store is read as-is without re-migrating', () async {
      final store = _MemoryStore();
      store.data['notes.v2'] = {
        'notes': [
          {
            'id': 'a',
            'body': 'Synced already',
            'createdAt': at(1).millisecondsSinceEpoch,
            'updatedAt': at(2).millisecondsSinceEpoch,
            'syncedAt': at(2).millisecondsSinceEpoch,
          },
        ],
        'tombstones': [
          {'id': 'gone', 'deletedAt': at(2).millisecondsSinceEpoch},
        ],
      };

      final notes = NotesStore(store);
      await notes.load();

      expect(notes.notes.single.isDirty, isFalse);
      expect(notes.tombstones.single.id, 'gone');
    });
  });

  group('deletion', () {
    test('leaves a tombstone behind', () async {
      final store = _MemoryStore();
      final notes = NotesStore(store, now: () => at(3));
      await notes.load();
      final note = notes.create(body: 'Doomed');

      notes.delete(note.id);

      expect(notes.notes, isEmpty);
      expect(notes.tombstones.single.id, note.id);
      expect(notes.dirtyTombstones, hasLength(1));
    });

    test('drops synced tombstones once they age out, and keeps the rest', () async {
      final store = _MemoryStore();
      final old = at(1).subtract(const Duration(days: 60));
      store.data['notes.v2'] = {
        'notes': const [],
        'tombstones': [
          // Synced and long past retention: safe to forget.
          {
            'id': 'expired',
            'deletedAt': old.millisecondsSinceEpoch,
            'syncedAt': old.millisecondsSinceEpoch,
          },
          // Just as old but never pushed — dropping it would resurrect the note.
          {'id': 'unsynced', 'deletedAt': old.millisecondsSinceEpoch},
          // Synced but recent.
          {
            'id': 'recent',
            'deletedAt': at(2).millisecondsSinceEpoch,
            'syncedAt': at(2).millisecondsSinceEpoch,
          },
        ],
      };

      final notes = NotesStore(store, now: () => at(5));
      await notes.load();

      expect(
        notes.tombstones.map((stone) => stone.id).toSet(),
        {'unsynced', 'recent'},
      );
    });
  });

  group('markSynced', () {
    test('clears the dirty flag', () async {
      final notes = NotesStore(_MemoryStore(), now: () => at(3));
      await notes.load();
      final note = notes.create(body: 'Push me');
      expect(note.isDirty, isTrue);

      notes.markSynced(notes: [note]);

      expect(notes.notes.single.isDirty, isFalse);
      expect(notes.hasPendingChanges, isFalse);
    });

    test('leaves a note edited mid-push dirty', () async {
      var now = at(3);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'First');

      // The push carries this revision; the user types before it lands.
      now = at(3, 1);
      notes.updateBody(note.id, 'Edited while in flight');
      notes.markSynced(notes: [note]);

      // Acknowledging the old revision must not mark the new one clean, or the
      // edit would never be pushed.
      expect(notes.notes.single.body, 'Edited while in flight');
      expect(notes.notes.single.isDirty, isTrue);
    });
  });

  group('dirty tracking', () {
    test('a synced note stays clean across a UTC/local round trip', () {
      // `updatedAt` as the wire delivers it, `syncedAt` as storage returns it:
      // the same instant, different UTC flags. Comparing with `==` would call
      // this dirty forever and re-push the note on every single sync.
      final utc = DateTime.utc(2026, 9, 3, 12);
      final local = DateTime.fromMillisecondsSinceEpoch(
        utc.millisecondsSinceEpoch,
      );
      expect(utc == local, isFalse, reason: 'the trap this guards against');

      final note = Note(
        id: 'a',
        body: 'x',
        createdAt: utc,
        updatedAt: utc,
        syncedAt: local,
      );
      expect(note.isDirty, isFalse);
    });

    test('a tombstone does the same', () {
      final utc = DateTime.utc(2026, 9, 3, 12);
      final stone = Tombstone(
        id: 'a',
        deletedAt: utc,
        syncedAt: DateTime.fromMillisecondsSinceEpoch(utc.millisecondsSinceEpoch),
      );
      expect(stone.isDirty, isFalse);
    });
  });

  group('applyRemote', () {
    test('inserts an unseen remote note as already synced', () async {
      final notes = NotesStore(_MemoryStore(), now: () => at(5));
      await notes.load();

      notes.applyRemote(notes: [remoteNote('r1', 'From another device', at(4))]);

      expect(notes.notes.single.body, 'From another device');
      expect(notes.notes.single.isDirty, isFalse);
    });

    test('a newer remote edit replaces a clean local note', () async {
      var now = at(3);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'Local');
      notes.markSynced(notes: [note]);

      notes.applyRemote(notes: [remoteNote(note.id, 'Remote wins', at(4))]);

      expect(notes.notes.single.body, 'Remote wins');
      expect(notes.notes.single.isDirty, isFalse);
    });

    test('an older remote edit loses to a newer local one', () async {
      var now = at(6);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'Newer local');

      notes.applyRemote(notes: [remoteNote(note.id, 'Stale remote', at(4))]);

      expect(notes.notes.single.body, 'Newer local');
      expect(notes.notes.single.isDirty, isTrue);
    });

    test('a lost race keeps the local text as a conflicted copy', () async {
      var now = at(3);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'Written on the plane');

      now = at(5);
      final created = notes.applyRemote(
        notes: [remoteNote(note.id, 'Written at the desk', at(4))],
      );

      // The remote copy wins the note, but the local text is not destroyed.
      expect(created, hasLength(1));
      expect(
        notes.notes.map((n) => n.body).toSet(),
        {'Written at the desk', 'Written on the plane'},
      );
      final copy = notes.byId(created.single)!;
      expect(copy.isDirty, isTrue, reason: 'the copy has to be pushed too');
    });

    test('no conflicted copy when the local note was already synced', () async {
      var now = at(3);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'Local');
      notes.markSynced(notes: [note]);

      final created = notes.applyRemote(
        notes: [remoteNote(note.id, 'Remote', at(4))],
      );

      expect(created, isEmpty);
      expect(notes.notes, hasLength(1));
    });

    test('a remote delete newer than the local edit removes the note', () async {
      var now = at(3);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'Deleted elsewhere');

      now = at(6);
      notes.applyRemote(
        tombstones: [Tombstone(id: note.id, deletedAt: at(5))],
      );

      expect(notes.notes, isEmpty);
      expect(notes.tombstones.single.id, note.id);
      expect(notes.tombstones.single.isDirty, isFalse);
    });

    test('a local edit newer than the remote delete keeps the note', () async {
      var now = at(6);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'Edited after the delete');

      notes.applyRemote(
        tombstones: [Tombstone(id: note.id, deletedAt: at(4))],
      );

      // The note survives and stays dirty, so the next push sends it back up.
      expect(notes.notes.single.body, 'Edited after the delete');
      expect(notes.notes.single.isDirty, isTrue);
    });

    test('a local delete newer than the remote edit stays deleted', () async {
      var now = at(3);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'Gone');

      now = at(6);
      notes.delete(note.id);
      notes.applyRemote(notes: [remoteNote(note.id, 'Resurrected?', at(5))]);

      expect(notes.notes, isEmpty);
      expect(notes.dirtyTombstones, hasLength(1));
    });

    test('a remote edit newer than the local delete brings the note back', () async {
      var now = at(3);
      final notes = NotesStore(_MemoryStore(), now: () => now);
      await notes.load();
      final note = notes.create(body: 'Gone');

      now = at(4);
      notes.delete(note.id);
      notes.applyRemote(notes: [remoteNote(note.id, 'Edited later', at(6))]);

      expect(notes.notes.single.body, 'Edited later');
      expect(notes.tombstones, isEmpty);
    });
  });

  group('persistence', () {
    test('tombstones and sync state survive a reload', () async {
      final store = _MemoryStore();
      var now = at(3);
      final notes = NotesStore(store, now: () => now);
      await notes.load();
      final kept = notes.create(body: 'Kept');
      final doomed = notes.create(body: 'Doomed');
      notes.markSynced(notes: [kept]);
      now = at(4);
      notes.delete(doomed.id);

      final reloaded = NotesStore(store, now: () => now);
      await reloaded.load();

      expect(reloaded.notes.single.id, kept.id);
      expect(reloaded.notes.single.isDirty, isFalse);
      expect(reloaded.tombstones.single.id, doomed.id);
      expect(reloaded.dirtyTombstones, hasLength(1));
    });

    test('the encoding cache reflects the latest edit', () async {
      final store = _MemoryStore();
      var now = at(3);
      final notes = NotesStore(store, now: () => now);
      await notes.load();
      final note = notes.create(body: 'One');

      now = at(3, 1);
      notes.updateBody(note.id, 'Two');
      now = at(3, 2);
      notes.updateBody(note.id, 'Three');

      final stored = (store.data['notes.v2'] as Map<String, Object?>)['notes']
          as List<Object?>;
      expect((stored.single as Map<String, Object?>)['body'], 'Three');
    });
  });
}
