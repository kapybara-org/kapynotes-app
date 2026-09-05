import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tombstone.dart';
import 'package:kapy_notes/export/archive.dart';
import 'package:kapy_notes/export/importer.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'import-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

final _exported = DateTime.utc(2026, 9, 5, 10, 14);

Note _note(String id, String body, {DateTime? updatedAt}) => Note(
  id: id,
  body: body,
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: updatedAt ?? DateTime.utc(2026, 9, 1),
);

Uint8List _archiveOf(List<Note> notes) => buildExportArchive(
  notes: notes,
  appVersion: '1.6.0',
  exportedAt: _exported,
);

ImportPlan _plan(
  Uint8List bytes, {
  List<Note> existing = const [],
  List<Tombstone> tombstones = const [],
  ImportMode mode = ImportMode.restore,
  DateTime? now,
}) => ImportPlan.from(
  archive: readExportArchive(bytes),
  existing: existing,
  tombstones: tombstones,
  mode: mode,
  now: now ?? DateTime.utc(2026, 9, 10),
);

Future<NotesStore> _storeWith(List<Note> notes) async {
  final backing = _MemoryStore();
  if (notes.isNotEmpty) {
    backing.data['notes.v2'] = {
      'notes': notes
          .map((note) => note.markSynced(note.updatedAt).toJson())
          .toList(),
      'tombstones': const [],
    };
  }
  final store = NotesStore(backing);
  await store.load();
  return store;
}

void main() {
  group('restore', () {
    test('brings every note back into an empty device', () async {
      final archive = _archiveOf([
        _note('a1', 'Weekly review'),
        _note('b2', 'Grocery list'),
      ]);

      final plan = _plan(archive);
      expect(plan.applyCount, 2);

      final store = await _storeWith(const []);
      expect(applyImportPlan(store, plan), 2);
      expect(store.notes.map((note) => note.id), containsAll(['a1', 'b2']));
      expect(store.notes.map((note) => note.body), contains('Weekly review'));
    });

    test('keeps ids and timestamps, so a second run changes nothing', () async {
      final archive = _archiveOf([_note('a1', 'Weekly review')]);

      final store = await _storeWith(const []);
      applyImportPlan(store, _plan(archive));
      final restored = store.notes.single;

      // The trap the plan names: a re-import must not look like a failure.
      // Every note reports as already here, and nothing is written.
      final again = _plan(archive, existing: store.notes);
      expect(again.applyCount, 0);
      expect(again.countOf(ImportOutcome.alreadyHere), 1);
      expect(applyImportPlan(store, again), 0);
      expect(store.notes.single.id, restored.id);
      expect(
        store.notes.single.updatedAt.millisecondsSinceEpoch,
        restored.updatedAt.millisecondsSinceEpoch,
      );
    });

    test('leaves a newer copy alone', () {
      final archive = _archiveOf([_note('a1', 'Old text')]);
      final plan = _plan(
        archive,
        existing: [
          _note('a1', 'Newer text', updatedAt: DateTime.utc(2026, 9, 4)),
        ],
      );

      expect(plan.applyCount, 0);
      expect(plan.countOf(ImportOutcome.keptNewer), 1);
    });

    test('overwrites an older copy', () {
      final archive = _archiveOf([
        _note('a1', 'Newer text', updatedAt: DateTime.utc(2026, 9, 4)),
      ]);
      final plan = _plan(archive, existing: [_note('a1', 'Old text')]);

      expect(plan.applyCount, 1);
      expect(plan.applying.single.note!.body, 'Newer text');
    });

    test('a note deleted after the export stays deleted', () {
      final archive = _archiveOf([_note('a1', 'Weekly review')]);
      final plan = _plan(
        archive,
        tombstones: [Tombstone(id: 'a1', deletedAt: DateTime.utc(2026, 9, 3))],
      );

      expect(plan.applyCount, 0);
      expect(plan.countOf(ImportOutcome.deletedSince), 1);
    });

    test('an older deletion does not undo the note it restores', () async {
      final archive = _archiveOf([
        _note('a1', 'Weekly review', updatedAt: DateTime.utc(2026, 9, 4)),
      ]);
      final stone = Tombstone(id: 'a1', deletedAt: DateTime.utc(2026, 8, 20));

      final plan = _plan(archive, tombstones: [stone]);
      expect(plan.applyCount, 1);

      final store = await _storeWith(const []);
      store.applyRemote(tombstones: [stone]);
      applyImportPlan(store, plan);

      expect(store.notes.single.id, 'a1');
      // The pending deletion has to go, or the next push deletes what was
      // just restored.
      expect(store.tombstones, isEmpty);
    });

    test('what lands is dirty, so ordinary sync carries it up', () async {
      final store = await _storeWith(const []);
      applyImportPlan(store, _plan(_archiveOf([_note('a1', 'Weekly review')])));

      expect(store.dirtyNotes.map((note) => note.id), ['a1']);
    });

    test('a note listed but missing is reported, not fatal', () {
      final archive = _archiveOf([_note('a1', 'Kept'), _note('b2', 'Lost')]);
      final contents = readExportArchive(archive);
      final lost = contents.manifest!.notes.firstWhere((n) => n.id == 'b2');
      final trimmed = ArchiveContents(
        manifest: contents.manifest,
        markdown: {...contents.markdown}..remove(lost.path),
      );

      final plan = ImportPlan.from(
        archive: trimmed,
        existing: const [],
        tombstones: const [],
        mode: ImportMode.restore,
        now: DateTime.utc(2026, 9, 10),
      );

      expect(plan.applyCount, 1);
      expect(plan.countOf(ImportOutcome.missingFile), 1);
    });

    test('an unreadable archive plans nothing rather than throwing', () {
      final plan = _plan(Uint8List.fromList(List.filled(64, 7)));
      expect(plan.entries, isEmpty);
      expect(plan.isEmpty, isTrue);
    });
  });

  group('as copies', () {
    test('mints new ids and stamps them now', () {
      final archive = _archiveOf([_note('a1', 'Weekly review')]);
      final now = DateTime.utc(2026, 9, 10);
      final plan = _plan(archive, mode: ImportMode.copies, now: now);

      final copy = plan.applying.single.note!;
      expect(copy.id, isNot('a1'));
      expect(copy.body, 'Weekly review');
      expect(copy.updatedAt, now);
      // When it was written is a fact about the note, not about the import.
      expect(
        copy.createdAt.millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 1).millisecondsSinceEpoch,
      );
    });

    test('adds beside what is already here rather than judging it', () async {
      final archive = _archiveOf([_note('a1', 'Weekly review')]);
      final existing = [_note('a1', 'A different note with the same id')];

      final plan = _plan(archive, existing: existing, mode: ImportMode.copies);
      expect(plan.applyCount, 1);

      final store = await _storeWith(existing);
      applyImportPlan(store, plan);
      expect(store.notes, hasLength(2));
    });
  });
}
