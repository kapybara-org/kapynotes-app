import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/crdt.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/note_payload.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'trash-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  final start = DateTime.utc(2026, 11, 1, 8);
  late DateTime now;
  late _MemoryStore store;
  late NotesStore notes;

  setUp(() async {
    now = start;
    store = _MemoryStore();
    notes = NotesStore(store, now: () => now);
    await notes.load();
  });

  group('Recently deleted', () {
    test('a deleted note leaves every other list, and is filed in Archive '
        'for builds from before the trash', () {
      final kept = notes.create(body: 'Kept');
      final gone = notes.create(body: 'Gone soon');

      now = start.add(const Duration(hours: 1));
      notes.trashAll([gone.id]);

      expect(notes.notes.map((note) => note.id), [kept.id]);
      expect(notes.trashedNotes.single.id, gone.id);
      expect(notes.archivedNotes, isEmpty);
      expect(notes.hiddenNotes, isEmpty);
      expect(notes.search('gone'), isEmpty);
      expect(notes.searchArchived('gone'), isEmpty);
      expect(notes.tombstones, isEmpty, reason: 'nothing is deleted yet');

      final trashed = notes.byId(gone.id)!;
      expect(trashed.trashedAt, now);
      expect(trashed.archivedAt, now);
      expect(trashed.trashEndsAt, now.add(Note.trashKept));

      expect(notes.togglePinned(gone.id), isNull);
      notes
        ..archiveAll([gone.id])
        ..restoreAll([gone.id])
        ..hideAll([gone.id]);
      expect(notes.byId(gone.id), same(trashed));
    });

    test('Put back returns a note to its list, and an archived one to '
        'Archive', () {
      final plain = notes.create(body: 'Plain');
      final filed = notes.create(body: 'Filed');
      notes.archive(filed.id);
      final archivedAt = notes.byId(filed.id)!.archivedAt;

      now = start.add(const Duration(days: 3));
      notes.trashAll([plain.id, filed.id]);
      expect(notes.trashedNotes, hasLength(2));
      expect(notes.byId(filed.id)!.archivedAt, archivedAt);

      now = start.add(const Duration(days: 4));
      notes.putBackAll([plain.id, filed.id]);

      expect(notes.trashedNotes, isEmpty);
      expect(notes.notes.single.id, plain.id);
      expect(notes.byId(plain.id)!.archivedAt, isNull);
      expect(notes.archivedNotes.single.id, filed.id);
      expect(notes.byId(filed.id)!.archivedAt, archivedAt);
      expect(notes.byId(plain.id)!.updatedAt, now);
    });

    test('Undo takes a delete straight back, to the same place', () {
      final a = notes.create(body: 'A');
      now = start.add(const Duration(minutes: 1));
      final b = notes.create(body: 'B');
      now = start.add(const Duration(minutes: 2));
      final c = notes.create(body: 'C');
      notes.markSynced(notes: [notes.byId(b.id)!]);
      final order = notes.notes.map((note) => note.id).toList();

      now = start.add(const Duration(hours: 1));
      final before = notes.trashAll([b.id, a.id]);
      expect(notes.notes.single.id, c.id);

      notes.undoTrash(before);

      expect(notes.notes.map((note) => note.id), order);
      expect(notes.trashedNotes, isEmpty);
      expect(notes.byId(a.id)!.archivedAt, isNull);
      expect(notes.byId(a.id)!.updatedAt, a.updatedAt);
      // The server holds b as it was, so b goes back a moment on, to be
      // sent again.
      expect(
        notes.byId(b.id)!.updatedAt,
        b.updatedAt.add(const Duration(milliseconds: 1)),
      );
      expect(notes.byId(b.id)!.isDirty, isTrue);
    });

    test('a hidden note waits only behind Hidden', () {
      final hidden = notes.create(body: 'Secret', hidden: true);

      notes.trashAll([hidden.id]);

      expect(notes.trashedNotes, isEmpty);
      expect(notes.hiddenNotes, isEmpty);
      expect(notes.hiddenTrashedNotes.single.id, hidden.id);

      notes.putBackAll([hidden.id]);
      expect(notes.hiddenNotes.single.id, hidden.id);
      expect(notes.hiddenTrashedNotes, isEmpty);
      expect(notes.byId(hidden.id)!.archivedAt, isNull);
    });

    test('notes go for good once their 30 days are up', () {
      final old = notes.create(body: 'Old');
      final fresh = notes.create(body: 'Fresh');
      notes.trashAll([old.id]);
      now = start.add(const Duration(days: 10));
      notes.trashAll([fresh.id]);

      now = start.add(const Duration(days: 29, hours: 23));
      expect(notes.emptyExpiredTrash(), 0);

      now = start.add(const Duration(days: 30));
      expect(notes.emptyExpiredTrash(), 1);
      expect(notes.byId(old.id), isNull);
      expect(notes.tombstones.single.id, old.id);
      expect(notes.trashedNotes.single.id, fresh.id);
    });

    test('a note held for Undo is left to its toast', () {
      final note = notes.create(body: 'Held');
      notes.trashAll([note.id]);
      notes.holdDelete([note.id]);

      now = start.add(const Duration(days: 31));
      expect(notes.emptyExpiredTrash(), 0);
      expect(notes.trashedNotes, isEmpty);
      notes.undoDelete([note.id]);
      expect(notes.trashedNotes.single.id, note.id);
    });

    test('an edit after the delete starts the 30 days again', () {
      final note = Note(
        id: 'n',
        body: 'Edited by an older build',
        createdAt: start,
        updatedAt: start.add(const Duration(days: 5)),
        archivedAt: start,
        trashedAt: start,
      );
      expect(note.trashEndsAt, start.add(const Duration(days: 35)));
    });

    test('Recently deleted is kept across a restart', () async {
      final note = notes.create(body: 'Still here');
      notes.trashAll([note.id]);

      final reopened = NotesStore(store, now: () => now);
      await reopened.load();

      expect(reopened.trashedNotes.single.id, note.id);
      expect(
        reopened.byId(note.id)!.trashedAt!.millisecondsSinceEpoch,
        start.millisecondsSinceEpoch,
      );
    });
  });

  group('the note document', () {
    DocView trash(NoteDoc doc, {DateTime? archivedAt, DateTime? trashedAt}) {
      final view = doc.view;
      doc.reconcile(
        body: view.body.isEmpty ? 'Shopping' : view.body,
        formats: view.formats,
        attachments: view.attachments,
        createdAt: view.createdAt ?? start,
        archivedAt: archivedAt,
        trashedAt: trashedAt,
        now: start.add(const Duration(hours: 1)),
      );
      return doc.view;
    }

    test('holds the delete in its own register beside the archive', () {
      final at = start.add(const Duration(hours: 1));
      final doc = NoteDoc(replica: 'new');
      final view = trash(doc, archivedAt: at, trashedAt: at);
      expect(view.trashedAt, at);
      expect(view.archivedAt, at);

      final copy = NoteDoc.fromSnapshot(
        jsonDecode(jsonEncode(doc.toSnapshot())) as Map<String, Object?>,
        replica: 'other',
      );
      expect(copy.view.trashedAt, at);

      final back = trash(copy);
      expect(back.trashedAt, isNull);
      expect(back.archivedAt, isNull);
    });

    test('an older build passes the delete on, and taking the note out of '
        'Archive puts it back', () {
      final at = start.add(const Duration(hours: 1));
      final doc = NoteDoc(replica: 'new');
      trash(doc, archivedAt: at, trashedAt: at);

      // An older build keeps a register it does not know, and writes it
      // back out untouched.
      final old = NoteDoc.fromSnapshot(doc.toSnapshot(), replica: 'old');
      final relayed = NoteDoc.fromSnapshot(old.toSnapshot(), replica: 'new2');
      expect(relayed.view.trashedAt, at);

      // There it shows in Archive. Taking it out clears only the archive.
      final restore = [
        [
          'r',
          'archived',
          null,
          at.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
          'old',
        ],
      ];
      expect(doc.apply(restore), isTrue);
      expect(doc.view.archivedAt, isNull);
      expect(doc.view.trashedAt, isNull);
    });

    test('a note an older build took out of Archive is back among the '
        "person's notes, and never deleted for good", () {
      final at = start.add(const Duration(hours: 1));
      final doc = NoteDoc(replica: 'new');
      trash(doc, archivedAt: at, trashedAt: at);
      final restoredAt = at.add(const Duration(minutes: 1));
      doc.apply([
        ['r', 'archived', null, restoredAt.millisecondsSinceEpoch, 'old'],
      ]);

      final view = doc.view;
      notes.applyDoc(
        Note(
          id: 'n',
          body: view.body,
          createdAt: start,
          updatedAt: restoredAt,
          archivedAt: view.archivedAt,
          hiddenAt: view.hiddenAt,
          trashedAt: view.trashedAt,
          syncedAt: restoredAt,
        ),
      );
      expect(notes.notes.map((note) => note.id), contains('n'));
      expect(notes.trashedNotes, isEmpty);

      now = restoredAt.add(const Duration(days: 31));
      expect(notes.emptyExpiredTrash(), 0);
      expect(notes.byId('n'), isNotNull);
    });
  });

  group('the sealed payload', () {
    test('carries the delete, and the archive an older build reads', () {
      final at = start.add(const Duration(hours: 1));
      final note = Note(
        id: 'n',
        body: 'Gone',
        createdAt: start,
        updatedAt: at,
        archivedAt: at,
        trashedAt: at,
      );

      final json = jsonDecode(jsonEncode(NotePayload.fromNote(note).toJson()));
      expect((json as Map)['archivedAt'], at.millisecondsSinceEpoch);

      final back = NotePayload.fromJson(json)!.toNote(id: 'n', updatedAt: at);
      expect(back.trashedAt, at.toLocal());
      expect(back.isTrashed, isTrue);

      final older = Map<String, Object?>.of(json.cast<String, Object?>())
        ..remove('trashedAt');
      final asOlder = NotePayload.fromJson(
        older,
      )!.toNote(id: 'n', updatedAt: at);
      expect(asOlder.isTrashed, isFalse);
      expect(asOlder.isArchived, isTrue);
    });
  });
}
