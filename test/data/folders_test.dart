import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/stamped.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'folders-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const noteA = '0195f0d0-1111-4222-8333-00000000000a';
const noteB = '0195f0d0-1111-4222-8333-00000000000b';
const noteC = '0195f0d0-1111-4222-8333-00000000000c';
const idA = '0195f0d0-aaaa-4bbb-8ccc-00000000000a';
const idB = '0195f0d0-aaaa-4bbb-8ccc-00000000000b';
const idC = '0195f0d0-aaaa-4bbb-8ccc-00000000000c';

String noteIdFor(int i) =>
    '0195f0d0-2222-4333-8444-${i.toRadixString(16).padLeft(12, '0')}';

FolderRecord remoteFolder(
  String id,
  String name, {
  String? parent,
  int at = 1,
  int? parentAt,
  bool deleted = false,
}) => FolderRecord(
  id: id,
  name: Stamped(name, at),
  parent: Stamped(parent, parentAt ?? at),
  deleted: Stamped(deleted, at),
  createdAt: 1,
);

/// The tree as text, each folder indented under the one it sits in.
String shape(FolderTree tree) {
  final lines = <String>[];
  void walk(String? parent, String indent) {
    for (final folder in tree.childrenOf(parent)) {
      lines.add('$indent${folder.name}');
      walk(folder.id, '$indent  ');
    }
  }

  walk(null, '');
  return lines.join('\n');
}

/// What a push that the server took whole leaves behind.
void acknowledgeAll(FolderStore folders) {
  folders.hold();
  for (final record in folders.owed) {
    folders.acknowledge(record);
  }
  folders.release();
}

void main() {
  late _MemoryStore store;
  late DateTime clock;
  late FolderStore folders;

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  setUp(() {
    store = _MemoryStore();
    clock = DateTime.utc(2026, 11, 19, 9);
    folders = FolderStore(store, now: tick);
  });

  group('the tree', () {
    test('folders nest, sort by name ignoring case, and know their path', () {
      final work = folders.create('Work')!;
      final clients = folders.create('clients', parentId: work.id)!;
      folders.create('Admin', parentId: work.id);
      folders.create('trip');
      final tree = folders.tree;
      expect(shape(tree), 'trip\nWork\n  Admin\n  clients');
      expect(tree.pathOf(clients.id).map((f) => f.name), ['Work', 'clients']);
      expect(tree.byId(clients.id)!.depth, 2);
      expect(tree.byId(clients.id)!.parentId, work.id);
      expect(tree.isWithin(clients.id, work.id), isTrue);
      expect(tree.isWithin(work.id, clients.id), isFalse);
      expect(tree.folders, hasLength(4));
    });

    test(
      'a name is trimmed, line breaks become spaces, and one place holds it once',
      () {
        expect(folders.checkCreate('  \n '), FolderRefusal.emptyName);
        expect(folders.checkCreate('x' * 65), FolderRefusal.longName);
        expect(folders.checkCreate('x' * 64), isNull);
        final work = folders.create('  Work\nplans ')!;
        expect(work.name, 'Work plans');
        expect(folders.checkCreate('WORK PLANS'), FolderRefusal.nameTaken);
        expect(folders.create('work plans'), isNull);
        final inside = folders.create('Work plans', parentId: work.id)!;
        final trip = folders.create('Trip')!;
        expect(folders.rename(trip.id, 'work PLANS'), FolderRefusal.nameTaken);
        expect(folders.rename(work.id, 'WORK PLANS'), isNull);
        expect(folders.tree.byId(work.id)!.name, 'WORK PLANS');
        expect(
          folders.move(inside.id),
          FolderRefusal.nameTaken,
          reason: 'the top already has one',
        );
      },
    );

    test('a folder never goes into itself or one of its own', () {
      final work = folders.create('Work')!;
      final clients = folders.create('Clients', parentId: work.id)!;
      final acme = folders.create('Acme', parentId: clients.id)!;
      expect(
        folders.move(work.id, parentId: work.id),
        FolderRefusal.intoItself,
      );
      expect(
        folders.move(work.id, parentId: acme.id),
        FolderRefusal.intoItself,
      );
      expect(
        folders.checkMove(clients.id, parentId: acme.id),
        FolderRefusal.intoItself,
      );
      expect(folders.move(acme.id), isNull);
      expect(shape(folders.tree), 'Acme\nWork\n  Clients');
    });

    test('ten levels below My notes, counting what a moved folder holds', () {
      String? parent;
      final chain = <Folder>[];
      for (var level = 1; level <= folderDepthMax; level++) {
        chain.add(folders.create('Level $level', parentId: parent)!);
        parent = chain.last.id;
      }
      expect(chain.last.depth, folderDepthMax);
      expect(
        folders.checkCreate('Eleven', parentId: parent),
        FolderRefusal.tooDeep,
      );
      final pair = folders.create('Pair')!;
      folders.create('Inside', parentId: pair.id);
      expect(
        folders.move(pair.id, parentId: chain[8].id),
        FolderRefusal.tooDeep,
      );
      expect(folders.move(pair.id, parentId: chain[7].id), isNull);
      expect(folders.tree.byId(pair.id)!.depth, 9);
    });
  });

  group('notes', () {
    test(
      'filing is one write a note, and taking a note out deletes its placement',
      () {
        final work = folders.create('Work')!;
        final trip = folders.create('Trip')!;
        acknowledgeAll(folders);
        expect(folders.file([noteA, noteB], work.id), isNull);
        expect(folders.tree.folderOf(noteA), work.id);
        expect(folders.owed.map((r) => (r.kind, r.key)), [
          (NoteFolder.kind, noteA),
          (NoteFolder.kind, noteB),
        ]);
        acknowledgeAll(folders);
        expect(folders.file([noteA, noteB], work.id), isNull);
        expect(folders.owed, isEmpty, reason: 'nothing moved');
        folders.file([noteA], trip.id);
        expect(folders.owed.single.key, noteA);
        acknowledgeAll(folders);
        expect(folders.file([noteA, noteC], null), isNull);
        expect(folders.tree.folderOf(noteA), isNull);
        expect(folders.owed.single.key, noteA);
        expect(
          folders.owed.single.payload,
          isNull,
          reason: 'only a filed note holds a record',
        );
        expect(folders.file([noteA], idA), FolderRefusal.gone);
      },
    );

    test('a folder lists its notes, or its folders\' too, by a path', () async {
      final notes = NotesStore(store, now: tick);
      await notes.load();
      final a = notes.create(body: 'A');
      final b = notes.create(body: 'B');
      final c = notes.create(body: 'C');
      final work = folders.create('Work')!;
      final clients = folders.create('Clients', parentId: work.id)!;
      folders.file([a.id], work.id);
      folders.file([b.id], clients.id);
      final tree = folders.tree;
      expect(tree.notesIn(notes.notes, work.id).map((n) => n.id), [a.id]);
      expect(
        tree.notesIn(notes.notes, work.id, deep: true).map((n) => n.id),
        unorderedEquals([a.id, b.id]),
      );
      expect(tree.notesIn(notes.notes, null).map((n) => n.id), [c.id]);
      expect(tree.notesIn(notes.notes, null, deep: true), hasLength(3));
      expect(tree.pathOfNote(b.id).map((f) => f.name), ['Work', 'Clients']);
      expect(tree.pathOfNote(c.id), isEmpty);
    });

    test('folders hold notes only: a filed drawing is never listed', () async {
      final notes = NotesStore(store, now: tick);
      await notes.load();
      final a = notes.create(body: 'A');
      final sketch = notes.create();
      final loose = notes.create();
      expect(notes.setDrawingMode(sketch.id, drawing: true), isTrue);
      expect(notes.setDrawingMode(loose.id, drawing: true), isTrue);
      final work = folders.create('Work')!;
      folders.file([a.id, sketch.id], work.id);
      final tree = folders.tree;
      expect(notes.notes.where((n) => n.isDrawing), hasLength(2));
      expect(tree.folderOf(sketch.id), work.id, reason: 'filed all the same');
      expect(tree.notesIn(notes.notes, work.id).map((n) => n.id), [a.id]);
      expect(tree.notesIn(notes.notes, work.id, deep: true), hasLength(1));
      expect(tree.notesIn(notes.notes, null), isEmpty);
      expect(tree.notesIn(notes.notes, null, deep: true), hasLength(1));
    });
  });

  group('deleting a folder', () {
    test(
      'is one write: what it holds shows in its parent, and Undo puts it back',
      () {
        final work = folders.create('Work')!;
        final clients = folders.create('Clients', parentId: work.id)!;
        final acme = folders.create('Acme', parentId: clients.id)!;
        folders.file([noteA], clients.id);
        folders.file([noteB], acme.id);
        acknowledgeAll(folders);

        folders.delete(clients.id);
        expect(folders.owed.single.key, clients.id);
        expect(folders.owed.single.payload, isNotNull, reason: 'kept');
        final tree = folders.tree;
        expect(tree.byId(clients.id), isNull);
        expect(shape(tree), 'Work\n  Acme');
        expect(tree.folderOf(noteA), work.id);
        expect(tree.folderOf(noteB), acme.id);
        expect(tree.pathOf(acme.id).map((f) => f.name), ['Work', 'Acme']);
        expect(folders.file([noteC], clients.id), FolderRefusal.gone);
        expect(
          folders.checkMove(acme.id, parentId: clients.id),
          FolderRefusal.gone,
        );

        folders.file([noteA], work.id);
        folders.restore(clients.id);
        expect(shape(folders.tree), 'Work\n  Clients\n    Acme');
        expect(
          folders.tree.folderOf(noteA),
          work.id,
          reason: 'moved meanwhile, so it stays',
        );
        expect(folders.tree.folderOf(noteB), acme.id);
      },
    );
  });

  group('what other devices wrote', () {
    test(
      'two folders moved into each other: the earlier move goes to the top',
      () {
        folders.applyRemoteFolder(
          remoteFolder(idA, 'Work', parent: idB, parentAt: 5),
          10,
        );
        folders.applyRemoteFolder(
          remoteFolder(idB, 'Clients', parent: idA, parentAt: 7),
          11,
        );
        expect(shape(folders.tree), 'Work\n  Clients');
        expect(folders.owed, isEmpty, reason: 'read so until sync settles it');
        folders.settle();
        expect(folders.owed.single.key, idA);
        expect(folders.owed.single.payload!['parent'], {
          'v': null,
          'at': 6,
        }, reason: 'one past the move it overrules, as every device writes it');
        expect(shape(folders.tree), 'Work\n  Clients');
        folders.settle();
        expect(folders.owed, hasLength(1), reason: 'once');
        expect(folders.move(idB), isNull);
        expect(
          shape(folders.tree),
          'Clients\nWork',
          reason: 'the loop\'s earlier move does not come back',
        );

        final again = FolderStore(_MemoryStore());
        again.applyRemoteFolder(
          remoteFolder(idB, 'Clients', parent: idA, parentAt: 5),
          10,
        );
        again.applyRemoteFolder(
          remoteFolder(idA, 'Work', parent: idB, parentAt: 5),
          11,
        );
        again.applyRemoteFolder(remoteFolder(idC, 'Self', parent: idC), 12);
        expect(
          shape(again.tree),
          'Self\nWork\n  Clients',
          reason:
              'a tie goes to the lower id, and a folder in itself is a loop',
        );
        expect(again.checkMove(idA, parentId: idB), FolderRefusal.intoItself);
      },
    );

    test(
      'a parent or a placement this device does not hold reads as the top',
      () {
        folders.applyRemoteNote(
          NoteFolder(noteId: noteA, folder: const Stamped(idA, 3)),
          3,
        );
        folders.applyRemoteFolder(remoteFolder(idB, 'Clients', parent: idA), 4);
        expect(folders.tree.folderOf(noteA), isNull);
        expect(folders.tree.byId(idB)!.parentId, isNull);
        folders.applyRemoteFolder(remoteFolder(idA, 'Work'), 5);
        expect(folders.tree.folderOf(noteA), idA);
        expect(shape(folders.tree), 'Work\n  Clients');
      },
    );

    test(
      'a change outranks what it was made over, whatever this clock says',
      () {
        final ahead = clock.millisecondsSinceEpoch + 3600 * 1000;
        void fromAhead() {
          folders.applyRemoteFolder(
            remoteFolder(idA, 'Work', at: ahead, deleted: true),
            ahead,
          );
          folders.applyRemoteFolder(
            remoteFolder(idB, 'Clients', at: ahead),
            ahead,
          );
          folders.applyRemoteNote(
            NoteFolder(noteId: noteA, folder: Stamped(idB, ahead)),
            ahead,
          );
        }

        fromAhead();
        folders.restore(idA);
        expect(folders.rename(idB, 'Clients 2'), isNull);
        expect(folders.move(idB, parentId: idA), isNull);
        expect(folders.file([noteA], idA), isNull);
        final owed = {for (final r in folders.owed) r.key: r.payload!};
        expect((owed[idA]!['deleted'] as Map)['at'], ahead + 1);
        expect((owed[idB]!['name'] as Map)['at'], ahead + 1);
        expect((owed[idB]!['parent'] as Map)['at'], ahead + 1);
        expect((owed[noteA]!['folder'] as Map)['at'], ahead + 1);

        fromAhead();
        expect(shape(folders.tree), 'Work\n  Clients 2');
        expect(folders.tree.folderOf(noteA), idA);
      },
    );

    test(
      'a stamp past the largest safe integer is refused, and none is written past it',
      () {
        const max = 9007199254740991;
        Map<String, Object?> payload(int at) =>
            remoteFolder(idA, 'Work', at: at).toPayload();
        expect(FolderRecord.fromPayload(idA, payload(max)), isNotNull);
        expect(FolderRecord.fromPayload(idA, payload(max + 1)), isNull);
        expect(FolderRecord.fromPayload(idA, payload(-1)), isNull);
        expect(
          NoteFolder.fromPayload(
            NoteFolder(
              noteId: noteA,
              folder: const Stamped(idA, max + 1),
            ).toPayload(),
          ),
          isNull,
        );

        folders.applyRemoteFolder(remoteFolder(idA, 'Work', at: max - 1), 1);
        expect(folders.rename(idA, 'Office'), isNull);
        expect(folders.rename(idA, 'Studio'), isNull);
        final written = folders.owed.single.payload!;
        expect((written['name'] as Map)['at'], max);
        expect(FolderRecord.fromPayload(idA, written)?.name.v, 'Studio');
      },
    );

    test(
      'a note taken out ahead of this clock is held, so filing it again outranks that',
      () {
        final ahead = clock.millisecondsSinceEpoch + 3600 * 1000;
        folders.applyRemoteFolder(remoteFolder(idA, 'Work'), 1);
        folders.applyRemoteNote(
          NoteFolder(noteId: noteA, folder: Stamped(idA, ahead)),
          ahead,
        );
        folders.applyRemoteNote(
          NoteFolder(noteId: noteB, folder: const Stamped(idA, 2)),
          2,
        );
        expect(folders.file([noteA], null), isNull);
        acknowledgeAll(folders);
        folders.applyRemoteDelete('placement', ahead, noteId: noteB);
        expect(folders.tree.folderOf(noteB), isNull);
        expect(folders.noteIds, [
          noteA,
          noteB,
        ], reason: 'both deletes are ahead of this clock');

        expect(folders.file([noteA, noteB], idA), isNull);
        final owed = {for (final r in folders.owed) r.key: r};
        expect(owed[noteA]!.updatedAt, ahead + 2);
        expect(owed[noteA]!.payload!['folder'], {'v': idA, 'at': ahead + 2});
        expect(owed[noteB]!.updatedAt, ahead + 1);
        expect(owed[noteB]!.payload!['folder'], {'v': idA, 'at': ahead + 1});
      },
    );

    test(
      'a taken-out placement is let go once this clock passes it, when its note is deleted for good, and on signing out',
      () {
        final ahead = clock.millisecondsSinceEpoch + 3600 * 1000;
        final work = folders.create('Work')!;
        folders.file([noteA, noteB, noteC], work.id);
        acknowledgeAll(folders);
        folders.file([noteA], null);
        acknowledgeAll(folders);
        folders.applyRemoteDelete(
          'placement-b',
          clock.millisecondsSinceEpoch,
          noteId: noteB,
        );
        folders.applyRemoteDelete('placement-c', ahead, noteId: noteC);
        expect(folders.noteIds, [noteC]);

        folders.forgetNote(noteC);
        expect(folders.noteIds, isEmpty, reason: 'it is never filed again');
        expect(folders.owed, isEmpty);

        folders.applyRemoteNote(
          NoteFolder(noteId: noteA, folder: Stamped(work.id, ahead)),
          ahead,
        );
        expect(folders.file([noteA], null), isNull);
        folders.forgetAccount();
        expect(folders.noteIds, isEmpty);
        expect(folders.owed.map((r) => r.key), [work.id]);
      },
    );

    test('fields a later build wrote are kept and written back', () {
      final later = FolderRecord.fromPayload(idA, {
        ...remoteFolder(idA, 'Work').toPayload(),
        'colour': {'v': 'sage', 'at': 2},
      })!;
      folders.applyRemoteFolder(later, 2);
      expect(folders.rename(idA, 'Office'), isNull);
      expect(folders.owed.single.payload!['colour'], {'v': 'sage', 'at': 2});
    });

    test(
      'a payload names its own folder, and a name is read as one is written',
      () {
        final payload = remoteFolder(idA, 'Work').toPayload();
        expect(FolderRecord.fromPayload(idB, payload), isNull);
        expect(
          FolderRecord.fromPayload(idA, {
            ...payload,
            'name': {'v': ' Work\nplans ${'x' * 80}', 'at': 1},
          })!.name.v,
          startsWith('Work plans x'),
        );
        expect(
          FolderRecord.fromPayload(idA, {
            ...payload,
            'name': {'v': ' Work ${'x' * 80}', 'at': 1},
          })!.name.v.runes,
          hasLength(folderNameMax),
        );
        expect(
          FolderRecord.fromPayload(idA, {
            ...payload,
            'name': {'v': '\n\t', 'at': 1},
          }),
          isNull,
        );
        expect(
          NoteFolder.fromPayload({
            'kind': NoteFolder.kind,
            'noteId': noteA,
            'folder': {'v': null, 'at': 1},
          }),
          isNull,
        );
      },
    );
  });

  test(
    'what this device holds outlives a restart, owed records and all',
    () async {
      final work = folders.create('Work')!;
      folders.file([noteA], work.id);
      final again = FolderStore(store, now: tick);
      expect(await again.load(), isTrue);
      expect(shape(again.tree), 'Work');
      expect(again.tree.folderOf(noteA), work.id);
      expect(again.owed, hasLength(2));
      expect(
        await FolderStore(_MemoryStore()).load(),
        isFalse,
        reason: 'nothing held yet, as a build from before folders leaves it',
      );
    },
  );

  group('the budget', () {
    test(
      'an action that would pass it changes nothing; moving within it always works',
      () {
        final work = folders.create('Work')!;
        final trip = folders.create('Trip')!;
        final filed = [
          for (var i = 0; i < folderRecordsMax - 3; i++) noteIdFor(i),
        ];
        expect(folders.file(filed, work.id), isNull);
        expect(folders.room, 1);
        acknowledgeAll(folders);

        expect(folders.file([noteA, noteB], trip.id), FolderRefusal.full);
        expect(folders.owed, isEmpty, reason: 'neither of the two');
        expect(folders.tree.folderOf(noteA), isNull);
        expect(folders.file([noteA], trip.id), isNull);
        expect(folders.room, 0);
        expect(folders.checkCreate('More'), FolderRefusal.full);
        expect(folders.create('More'), isNull);

        expect(folders.file(filed.take(100), trip.id), isNull);
        expect(folders.tree.folderOf(filed.first), trip.id);
        expect(folders.rename(trip.id, 'Travel'), isNull);
        expect(folders.move(trip.id, parentId: work.id), isNull);
        folders.delete(trip.id);
        folders.restore(trip.id);
        expect(folders.room, 0, reason: 'none of those adds a record');
        expect(folders.file(filed.take(100), null), isNull);
        expect(folders.room, 100);
      },
    );
  });
}
