import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_state.dart';

import 'fake_server.dart';
import 'record_device.dart';

/// One device signed in through [Account], for the first run of this build
/// and for signing out.
class AccountDevice {
  AccountDevice(this.server, {MemoryStore? store})
    : store = store ?? MemoryStore() {
    notes = NotesStore(this.store);
    tags = TagStore(this.store);
    folders = FolderStore(this.store);
    final state = SyncState(this.store);
    tasks = TaskLibrary(
      notes: notes,
      store: this.store,
      state: state,
      storage: MemoryDocStorage(),
    );
    account = Account(
      auth: auth,
      syncApi: (_) => FakeApi(server, userId: auth.id),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: state,
      store: this.store,
      tasks: tasks,
      tags: tags,
      folders: folders,
    );
  }

  final FakeServer server;
  final MemoryStore store;
  final auth = FakeAuth(id: 'user-1');
  late final NotesStore notes;
  late final TaskLibrary tasks;
  late final TagStore tags;
  late final FolderStore folders;
  late final Account account;

  Future<void> boot() async {
    await notes.load();
    await account.restore();
  }

  void dispose() => account.dispose();
}

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Map<String, ({WireTaskRecord record, int seq})> stored() =>
      server.tasks['user-1'] ?? {};

  String placementOf(String noteId) => sharedVault().noteFolderRecordId(noteId);

  Future<(Device, Device)> pair() async {
    final laptop = Device(server, name: 'laptop');
    final phone = Device(server, name: 'phone');
    await laptop.boot();
    await phone.boot();
    return (laptop, phone);
  }

  Future<void> passes(List<Device> devices) async {
    for (final d in devices) {
      await d.pass();
    }
  }

  void later(Device d) => d.clock = d.clock.add(const Duration(seconds: 1));

  /// The tree as text, each folder under the one it sits in, then where each
  /// of [noteIds] is.
  String shape(Device d, [List<String> noteIds = const []]) {
    final tree = d.folders.tree;
    final lines = <String>[];
    void walk(String? parent, String indent) {
      for (final folder in tree.childrenOf(parent)) {
        lines.add('$indent${folder.name}');
        walk(folder.id, '$indent  ');
      }
    }

    walk(null, '');
    for (final id in noteIds) {
      final path = tree.pathOfNote(id).map((f) => f.name);
      lines.add(
        '${d.notes.byId(id)!.title}: ${path.isEmpty ? 'My notes' : path.join(' › ')}',
      );
    }
    return lines.join('\n');
  }

  void expectSettled(Device a, Device b, [List<String> noteIds = const []]) {
    expect(shape(b, noteIds), shape(a, noteIds));
    expect(a.folders.owed, isEmpty, reason: a.name);
    expect(b.folders.owed, isEmpty, reason: b.name);
  }

  group('the stream', () {
    test(
      'folders and placements reach another device, sealed, under the ids they should',
      () async {
        final (laptop, phone) = await pair();
        final note = laptop.notes.create(body: 'Invoice for Acme');
        final work = laptop.folders.create('Work')!;
        final clients = laptop.folders.create('Clients', parentId: work.id)!;
        laptop.folders.file([note.id], clients.id);
        await laptop.pass();

        final placement = placementOf(note.id);
        expect(stored().keys.toSet(), {work.id, clients.id, placement});
        expect(placement, isNot(note.id));
        expect(placement, isNot(sharedVault().noteTagsRecordId(note.id)));
        expect(placement[14], '8', reason: 'a version-8 UUID');
        for (final row in stored().values) {
          final bytes = utf8.decode(
            row.record.payload!.cipherText,
            allowMalformed: true,
          );
          for (final plain in ['Work', 'Clients', note.id, clients.id]) {
            expect(bytes, isNot(contains(plain)));
          }
        }

        await phone.pass();
        expect(
          shape(phone, [note.id]),
          'Work\n  Clients\nInvoice for Acme: Work › Clients',
        );
        expectSettled(laptop, phone, [note.id]);
        laptop.dispose();
        phone.dispose();
      },
    );

    test('every change reaches the other device', () async {
      final (a, b) = await pair();
      final one = a.notes.create(body: 'One');
      final two = a.notes.create(body: 'Two');
      final work = a.folders.create('Work')!;
      final trip = a.folders.create('Trip')!;
      a.folders.file([one.id, two.id], work.id);
      await passes([a, b]);
      expectSettled(a, b, [one.id, two.id]);

      b.folders.rename(work.id, 'Office');
      b.folders.move(trip.id, parentId: work.id);
      b.folders.file([two.id], trip.id);
      await passes([b, a]);
      expect(
        shape(a, [one.id, two.id]),
        'Office\n  Trip\nOne: Office\nTwo: Office › Trip',
      );
      expectSettled(a, b, [one.id, two.id]);

      a.folders.delete(trip.id);
      a.folders.file([one.id], null);
      await passes([a, b]);
      expect(shape(b, [one.id, two.id]), 'Office\nOne: My notes\nTwo: Office');
      expect(stored()[placementOf(one.id)]!.record.deletedAt, isNotNull);
      expectSettled(a, b, [one.id, two.id]);

      b.folders.restore(trip.id);
      await passes([b, a]);
      expect(
        shape(a, [one.id, two.id]),
        'Office\n  Trip\nOne: My notes\nTwo: Office › Trip',
      );
      expectSettled(a, b, [one.id, two.id]);
      a.dispose();
      b.dispose();
    });

    test(
      'folder payloads and placements swapped between records are refused',
      () async {
        final (laptop, phone) = await pair();
        final one = laptop.notes.create(body: 'One');
        final two = laptop.notes.create(body: 'Two');
        final work = laptop.folders.create('Work')!;
        final trip = laptop.folders.create('Trip')!;
        laptop.folders.file([one.id], work.id);
        laptop.folders.file([two.id], trip.id);
        await laptop.pass();

        final rows = stored();
        WireTaskRecord swapped(String id, String other) => WireTaskRecord(
          id: id,
          updatedAt: rows[id]!.record.updatedAt.add(const Duration(seconds: 1)),
          payload: rows[other]!.record.payload,
        );
        server.pushTasks('user-1', 'mallory', [
          swapped(work.id, trip.id),
          swapped(trip.id, work.id),
          swapped(placementOf(one.id), placementOf(two.id)),
          swapped(placementOf(two.id), placementOf(one.id)),
        ]);
        await phone.pass();
        expect(phone.folders.tree.folders, isEmpty);
        expect(phone.folders.noteIds, isEmpty);
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'a note deleted for good takes its placement off the server',
      () async {
        final (a, b) = await pair();
        final note = a.notes.create(body: 'Old');
        final work = a.folders.create('Work')!;
        a.folders.file([note.id], work.id);
        await passes([a, b]);
        expect(b.folders.noteIds, [note.id]);

        a.notes.delete(note.id);
        await passes([a, b]);
        expect(stored()[placementOf(note.id)]!.record.deletedAt, isNotNull);
        expect(a.folders.noteIds, isEmpty);
        expect(b.folders.noteIds, isEmpty);
        expectSettled(a, b);
        a.dispose();
        b.dispose();
      },
    );

    test(
      'a push the server refuses keeps every placement owed until it is taken',
      () async {
        final (a, b) = await pair();
        final notes = [
          for (final title in ['One', 'Two', 'Three'])
            a.notes.create(body: title),
        ];
        final work = a.folders.create('Work')!;
        await passes([a, b]);

        server.tasksFull = true;
        expect(a.folders.file([for (final n in notes) n.id], work.id), isNull);
        await a.pass();
        expect(a.folders.owed, hasLength(3));
        expect(a.folders.tree.notesIn(a.notes.notes, work.id), hasLength(3));

        server.tasksFull = false;
        await passes([a, b]);
        expect(b.folders.tree.notesIn(b.notes.notes, work.id), hasLength(3));
        expectSettled(a, b, [for (final n in notes) n.id]);
        a.dispose();
        b.dispose();
      },
    );
  });

  group('two devices at once', () {
    test(
      'two moves of one note: the later wins, whichever reaches the server first',
      () async {
        final (a, b) = await pair();
        final note = a.notes.create(body: 'Plan');
        final x = a.folders.create('X')!;
        final y = a.folders.create('Y')!;
        await passes([a, b]);

        a.folders.file([note.id], x.id);
        later(b);
        b.folders.file([note.id], y.id);
        await passes([a, b, a, b]);
        expect(a.folders.tree.folderOf(note.id), y.id);
        expectSettled(a, b, [note.id]);

        later(a);
        later(a);
        a.folders.file([note.id], x.id);
        b.folders.file([note.id], null);
        await passes([a, b, a, b]);
        expect(
          b.folders.tree.folderOf(note.id),
          x.id,
          reason:
              'the earlier move out lost, though it reached the server last',
        );
        expectSettled(a, b, [note.id]);
        a.dispose();
        b.dispose();
      },
    );

    test(
      'a folder renamed on one device and moved on the other is both',
      () async {
        final (a, b) = await pair();
        final work = a.folders.create('Work')!;
        final old = a.folders.create('Old')!;
        await passes([a, b]);

        a.folders.rename(work.id, 'Office');
        later(b);
        b.folders.move(work.id, parentId: old.id);
        await passes([a, b, a, b]);
        expect(shape(a), 'Old\n  Office');
        expectSettled(a, b);
        a.dispose();
        b.dispose();
      },
    );

    test(
      'a folder deleted while a note is filed into it: the note shows in its parent, and Undo brings both back',
      () async {
        final (a, b) = await pair();
        final work = a.folders.create('Work')!;
        final clients = a.folders.create('Clients', parentId: work.id)!;
        final note = b.notes.create(body: 'Call Acme');
        await passes([a, b, a]);

        a.folders.delete(clients.id);
        b.folders.file([note.id], clients.id);
        await passes([a, b, a, b]);
        expect(shape(a, [note.id]), 'Work\nCall Acme: Work');
        expectSettled(a, b, [note.id]);

        a.folders.restore(clients.id);
        await passes([a, b]);
        expect(
          shape(b, [note.id]),
          'Work\n  Clients\nCall Acme: Work › Clients',
        );
        expectSettled(a, b, [note.id]);
        a.dispose();
        b.dispose();
      },
    );

    test(
      'two folders moved into each other read as one tree on both, with no loop',
      () async {
        final (a, b) = await pair();
        final work = a.folders.create('Work')!;
        final clients = a.folders.create('Clients')!;
        await passes([a, b]);

        a.folders.move(work.id, parentId: clients.id);
        later(b);
        b.folders.move(clients.id, parentId: work.id);
        await passes([a, b, a, b]);
        expect(shape(a), 'Work\n  Clients', reason: 'the later move stays');
        expectSettled(a, b);

        expect(a.folders.move(clients.id), isNull);
        await passes([a, b]);
        expect(shape(b), 'Clients\nWork');
        expectSettled(a, b);
        a.dispose();
        b.dispose();
      },
    );
  });

  group('builds from before folders', () {
    test(
      'keep every note, and never write or rewrite a folder record',
      () async {
        final newer = Device(server, name: 'laptop');
        final older = Device(server, name: 'phone', withFolders: false);
        await newer.boot();
        await older.boot();
        final notes = [
          for (final title in ['One', 'Two', 'Three'])
            newer.notes.create(body: title),
        ];
        final work = newer.folders.create('Work')!;
        newer.folders.file([notes[0].id, notes[1].id], work.id);
        await passes([newer, older]);
        expect(
          older.notes.notes.map((n) => n.id),
          unorderedEquals([for (final n in notes) n.id]),
        );

        final folderIds = {
          work.id,
          placementOf(notes[0].id),
          placementOf(notes[1].id),
        };
        final before = {
          for (final id in folderIds)
            id: (stored()[id]!.seq, stored()[id]!.record.updatedAt),
        };
        final kept = (older.store.data['tags.v1'] as Map)['unknown'] as List;
        expect(
          {for (final entry in kept) (entry as Map)['id']},
          folderIds,
          reason: 'kept by id and time alone',
        );

        older.tags.addTag(notes[0].id, older.tags.create('Home')!.id);
        final fresh = older.notes.create(body: 'Four');
        server.taskPushes.clear();
        await older.pass();
        expect(server.taskPushes, isNotEmpty);
        expect(
          server.taskPushes
              .expand((ids) => ids)
              .toSet()
              .intersection(folderIds),
          isEmpty,
        );
        for (final id in folderIds) {
          expect((
            stored()[id]!.seq,
            stored()[id]!.record.updatedAt,
          ), before[id]);
        }

        await passes([newer, older]);
        expect(older.notes.notes, hasLength(4));
        expect(newer.notes.byId(fresh.id), isNotNull);
        expect(
          shape(newer, [for (final n in notes) n.id]),
          'Work\nOne: Work\nTwo: Work\nThree: My notes',
        );
        expect(newer.tags.tagsOf(notes[0].id).single.name.v, 'Home');
        newer.dispose();
        older.dispose();
      },
    );

    test(
      'the first run of a folders build reads the stream again once, and every folder arrives',
      () async {
        final first = AccountDevice(server);
        await first.boot();
        await first.account.signIn(email: 'a@b.co', password: 'x');
        await first.account.createPassphrase('a good passphrase');
        final note = first.notes.create(body: 'Invoice');
        final work = first.folders.create('Work')!;
        first.folders.file([note.id], work.id);
        await first.account.sync!.syncNow();
        await until(
          () => first.folders.owed.isEmpty && stored().length == 2,
          reason: 'the first device never sent its folders',
        );
        final seq = stored().values.map((r) => r.seq).reduce(max);
        first.dispose();

        // A device on a build from before folders, which read past them and
        // kept their ids alone.
        final second = AccountDevice(server);
        second.store.data['tasks.v1'] = {
          'cursor': seq,
          'scanned': true,
          'entries': <Object?>[],
          'stones': <String, Object?>{},
        };
        second.store.data['tags.v1'] = {
          'tags': <Object?>[],
          'notes': <Object?>[],
          'unknown': [
            for (final MapEntry(:key, :value) in stored().entries)
              {
                'id': key,
                'updatedAt': value.record.updatedAt.millisecondsSinceEpoch,
              },
          ],
        };
        await second.boot();
        await second.account.signIn(email: 'a@b.co', password: 'x');
        expect(await second.account.unlock('a good passphrase'), isTrue);
        await until(
          () => second.folders.tree.folderOf(note.id) == work.id,
          reason: 'the folders never came down',
        );
        expect(second.tasks.index.cursor, seq);
        expect((second.store.data['tags.v1'] as Map)['unknown'], isEmpty);
        second.dispose();

        final relaunched = AccountDevice(server, store: second.store);
        await relaunched.boot();
        expect(relaunched.folders.tree.byId(work.id)!.name, 'Work');
        expect(
          relaunched.tasks.index.cursor,
          seq,
          reason: 'once, not every launch',
        );
        relaunched.dispose();
      },
    );

    test('signing out keeps the folders, owed to the next account', () async {
      final d = AccountDevice(server);
      await d.boot();
      await d.account.signIn(email: 'a@b.co', password: 'x');
      await d.account.createPassphrase('a good passphrase');
      final note = d.notes.create(body: 'Trip');
      final work = d.folders.create('Work')!;
      d.folders.file([note.id], work.id);
      await d.account.sync!.syncNow();
      await until(() => d.folders.owed.isEmpty);

      await d.account.signOut();
      expect(d.folders.tree.folderOf(note.id), work.id);
      expect(d.folders.owed.map((r) => r.key).toSet(), {work.id, note.id});
      d.dispose();
    });
  });
}
