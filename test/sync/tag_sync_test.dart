import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_state.dart';

import 'fake_server.dart';
import 'record_device.dart';

/// One device signed in through [Account], for what happens around the
/// stream: the first run of this build, and signing out.
class AccountDevice {
  AccountDevice(this.server, {MemoryStore? store, String userId = 'user-1'})
    : store = store ?? MemoryStore(),
      auth = FakeAuth(id: userId) {
    notes = NotesStore(this.store);
    tags = TagStore(this.store);
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
    );
  }

  final FakeServer server;
  final MemoryStore store;
  final FakeAuth auth;
  late final NotesStore notes;
  late final TaskLibrary tasks;
  late final TagStore tags;
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

  Map<String, ({WireTaskRecord record, int seq})> stored([
    String user = 'user-1',
  ]) => server.tasks[user] ?? {};

  Future<Map<String, Object?>?> opened(WireTaskRecord record) async {
    final payload = record.payload;
    if (payload == null) return null;
    final bytes = await sharedVault().openRaw(payload, null);
    return jsonDecode(utf8.decode(bytes!)) as Map<String, Object?>;
  }

  List<String> namesOn(Device d, String noteId) => [
    for (final tag in d.tags.tagsOf(noteId)) tag.name.v,
  ];

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

  void expectSettled(Device a, Device b, String noteId) {
    expect(namesOn(b, noteId), namesOn(a, noteId));
    expect(
      b.tags.tags.map((t) => jsonEncode(t.toPayload())),
      a.tags.tags.map((t) => jsonEncode(t.toPayload())),
    );
    for (final d in [a, b]) {
      expect(d.tags.owed, isEmpty, reason: d.name);
    }
  }

  void later(Device d) => d.clock = d.clock.add(const Duration(seconds: 1));

  group('the stream', () {
    test(
      'a tag and a note\'s tags reach another device, sealed, under the ids they should',
      () async {
        final (laptop, phone) = await pair();
        final note = laptop.notes.create(body: 'Trip to Kochi');
        final work = laptop.tags.create('Work')!;
        laptop.tags.addTag(note.id, work.id);
        await laptop.pass();

        final noteRecordId = sharedVault().noteTagsRecordId(note.id);
        expect(stored().keys.toSet(), {work.id, noteRecordId});
        expect(noteRecordId, isNot(note.id));
        expect(noteRecordId[14], '8', reason: 'a version-8 UUID');
        for (final row in stored().values) {
          final bytes = utf8.decode(
            row.record.payload!.cipherText,
            allowMalformed: true,
          );
          expect(bytes, isNot(contains('Work')));
          expect(bytes, isNot(contains(note.id)));
        }
        expect(laptop.tags.owed, isEmpty);

        await phone.pass();
        expect(namesOn(phone, note.id), ['Work']);
        expect(phone.tags.owed, isEmpty);
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'tasks and tags share one pull and one cursor, and the task index takes only tasks',
      () async {
        final (laptop, phone) = await pair();
        final note = laptop.notes.create(body: 'Errands\n☐ Buy milk');
        laptop.tags.addTag(note.id, laptop.tags.create('Home')!.id);
        await laptop.pass();
        expect(stored(), hasLength(3));

        server.log.clear();
        await phone.pass();
        final pulls = [
          for (final e in server.log)
            if (e.device == phone.api.device && e.call.startsWith('pullTasks'))
              e.call,
        ];
        expect(pulls, ['pullTasks:0']);
        expect(
          phone.tasks.cursor,
          stored().values.map((r) => r.seq).reduce(max),
        );
        expect(phone.tasks.entries.single.noteId, note.id);
        expect(phone.tasks.owed, isEmpty);
        expect(namesOn(phone, note.id), ['Home']);

        for (final row in stored().values) {
          final payload = (await opened(row.record))!;
          final task = TaskEntry.fromPayload(row.record.id, payload);
          expect(
            task == null,
            payload.containsKey('kind'),
            reason: 'a reader of tasks alone takes nothing with a kind',
          );
        }
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'a record of a kind this build does not know is kept and never sent',
      () async {
        final (laptop, phone) = await pair();
        const id = '0195f0d0-aaaa-4bbb-8ccc-dddddddddddd';
        server.pushTasks('user-1', 'later-build', [
          WireTaskRecord(
            id: id,
            updatedAt: DateTime.utc(2026, 11, 17, 9),
            payload: await sharedVault().sealRaw(
              utf8.encode(jsonEncode({'kind': 'folder', 'name': 'Later'})),
              null,
            ),
          ),
        ]);
        await phone.pass();
        expect(jsonEncode(phone.store.data['tags.v1']), contains('Later'));
        expect(phone.tags.owed, isEmpty);
        expect(phone.tasks.entries, isEmpty);
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'a note\'s tags moved onto another note\'s id is not taken for it',
      () async {
        final (laptop, phone) = await pair();
        final note = laptop.notes.create(body: 'Real');
        laptop.tags.addTag(note.id, laptop.tags.create('Work')!.id);
        await laptop.pass();

        final real = stored()[sharedVault().noteTagsRecordId(note.id)]!.record;
        const other = '0195f0d0-1111-4222-8333-000000000000';
        server.pushTasks('user-1', 'mallory', [
          WireTaskRecord(
            id: sharedVault().noteTagsRecordId(other),
            updatedAt: real.updatedAt,
            payload: real.payload,
          ),
        ]);
        await phone.pass();
        expect(phone.tags.tagsOf(other), isEmpty);
        expect(phone.tags.noteIds, [note.id]);
        laptop.dispose();
        phone.dispose();
      },
    );

    test('tag payloads swapped between two records are both refused', () async {
      final (laptop, phone) = await pair();
      final work = laptop.tags.create('Work')!;
      final travel = laptop.tags.create('Travel')!;
      await laptop.pass();

      final records = stored();
      final workRecord = records[work.id]!.record;
      final travelRecord = records[travel.id]!.record;
      server.pushTasks('user-1', 'mallory', [
        WireTaskRecord(
          id: work.id,
          updatedAt: workRecord.updatedAt.add(const Duration(seconds: 1)),
          payload: travelRecord.payload,
        ),
        WireTaskRecord(
          id: travel.id,
          updatedAt: travelRecord.updatedAt.add(const Duration(seconds: 1)),
          payload: workRecord.payload,
        ),
      ]);
      await phone.pass();
      expect(phone.tags.tags, isEmpty);
      laptop.dispose();
      phone.dispose();
    });

    test('a tag payload replayed under another id is refused', () async {
      final (laptop, phone) = await pair();
      final work = laptop.tags.create('Work')!;
      await laptop.pass();

      final real = stored()[work.id]!.record;
      const replayed = '0195f0d0-aaaa-4bbb-8ccc-000000000000';
      server.pushTasks('user-1', 'mallory', [
        WireTaskRecord(
          id: replayed,
          updatedAt: real.updatedAt,
          payload: real.payload,
        ),
      ]);
      await phone.pass();
      expect(phone.tags.byId(replayed), isNull);
      expect([for (final tag in phone.tags.tags) tag.id], [work.id]);
      laptop.dispose();
      phone.dispose();
    });

    test(
      'a note deleted for good takes its tags record off the server; an archived one keeps it',
      () async {
        final (laptop, phone) = await pair();
        final gone = laptop.notes.create(body: 'Going');
        final kept = laptop.notes.create(body: 'Filed');
        final work = laptop.tags.create('Work')!;
        laptop.tags.addTag(gone.id, work.id);
        laptop.tags.addTag(kept.id, work.id);
        await laptop.pass();

        laptop.notes.archive(kept.id);
        laptop.notes.delete(gone.id);
        await laptop.pass();
        expect(
          stored()[sharedVault().noteTagsRecordId(gone.id)]!.record.deletedAt,
          isNotNull,
        );
        expect(
          stored()[sharedVault().noteTagsRecordId(kept.id)]!.record.deletedAt,
          isNull,
        );
        expect(namesOn(laptop, kept.id), ['Work']);
        expect(laptop.tags.owed, isEmpty);

        await phone.pass();
        expect(phone.tags.noteIds, [kept.id]);
        laptop.dispose();
        phone.dispose();
      },
    );
  });

  group('two devices at once', () {
    test('A adds Work and B adds Travel to one note: both stay', () async {
      final (a, b) = await pair();
      final note = a.notes.create(body: 'Trip');
      final work = a.tags.create('Work')!;
      final travel = a.tags.create('Travel')!;
      await passes([a, b]);

      a.tags.addTag(note.id, work.id);
      later(b);
      b.tags.addTag(note.id, travel.id);
      await passes([a, b, a, b]);
      expect(namesOn(a, note.id), ['Travel', 'Work']);
      expectSettled(a, b, note.id);
      a.dispose();
      b.dispose();
    });

    test(
      'A removes Work while B reorders: the removal holds and B\'s order the rest',
      () async {
        final (a, b) = await pair();
        final note = a.notes.create(body: 'Trip');
        final ids = [
          for (final name in ['Work', 'Travel', 'Home'])
            a.tags.create(name)!.id,
        ];
        a.tags.setTags(note.id, ids);
        await passes([a, b]);

        a.tags.removeTag(note.id, ids[0]);
        later(b);
        b.tags.setTags(note.id, [ids[2], ids[1], ids[0]]);
        await passes([a, b, a, b]);
        expect(namesOn(a, note.id), ['Home', 'Travel']);
        expectSettled(a, b, note.id);
        a.dispose();
        b.dispose();
      },
    );

    test(
      'a rename and a recolour both hold; of two renames the later wins',
      () async {
        final (a, b) = await pair();
        final note = a.notes.create(body: 'Plan');
        final work = a.tags.create('Work')!;
        a.tags.addTag(note.id, work.id);
        await passes([a, b]);

        later(a);
        a.tags.rename(work.id, 'Office');
        b.tags.recolour(work.id, 'rose');
        server.log.clear();
        await passes([a, b, a, b]);
        final bPushes = server.log.where(
          (e) => e.device == b.api.device && e.call == 'pushTasks',
        );
        expect(
          bPushes,
          hasLength(greaterThanOrEqualTo(2)),
          reason: 'the lost push came back, merged, and went again',
        );
        expect(a.tags.byId(work.id)!.name.v, 'Office');
        expect(a.tags.byId(work.id)!.colour.v, 'rose');
        expectSettled(a, b, note.id);

        a.tags.rename(work.id, 'Desk');
        later(b);
        later(b);
        b.tags.rename(work.id, 'Studio');
        await passes([b, a, b]);
        expect(a.tags.byId(work.id)!.name.v, 'Studio');
        expectSettled(a, b, note.id);
        a.dispose();
        b.dispose();
      },
    );

    test(
      '"Work" created offline on both becomes one tag, each note moved in place',
      () async {
        final (a, b) = await pair();
        final first = a.notes.create(body: 'One');
        final second = a.notes.create(body: 'Two');
        final home = a.tags.create('Home')!;
        a.tags.addTag(second.id, home.id);
        await passes([a, b]);

        final mine = a.tags.create('Work')!;
        a.tags.addTag(first.id, mine.id);
        later(b);
        final theirs = b.tags.create('work')!;
        b.tags.setTags(second.id, [theirs.id, home.id]);
        await passes([a, b, a, b]);

        for (final d in [a, b]) {
          expect(d.tags.tags.map((t) => t.id), [
            home.id,
            mine.id,
          ], reason: d.name);
          expect(namesOn(d, first.id), ['Work'], reason: d.name);
          expect(namesOn(d, second.id), ['Work', 'Home'], reason: d.name);
        }
        expect(stored()[theirs.id]!.record.deletedAt, isNotNull);
        expectSettled(a, b, second.id);
        a.dispose();
        b.dispose();
      },
    );

    test(
      'A deletes a tag while B renames it: the later wins either way',
      () async {
        final (a, b) = await pair();
        final note = a.notes.create(body: 'Plan');
        final work = a.tags.create('Work')!;
        final home = a.tags.create('Home')!;
        a.tags.setTags(note.id, [work.id, home.id]);
        await passes([a, b]);

        a.tags.delete(work.id);
        later(b);
        b.tags.rename(work.id, 'Office');
        await passes([a, b, a, b]);
        expect(namesOn(a, note.id), [
          'Office',
          'Home',
        ], reason: 'back, notes intact');
        expectSettled(a, b, note.id);

        b.tags.rename(work.id, 'Desk');
        later(a);
        later(a);
        a.tags.delete(work.id);
        await passes([b, a, b]);
        expect(a.tags.byId(work.id), isNull);
        expect(namesOn(b, note.id), ['Home']);
        expectSettled(a, b, note.id);
        a.dispose();
        b.dispose();
      },
    );

    test(
      'reordering on both: each tag\'s place is the later one, and both agree',
      () async {
        final (a, b) = await pair();
        final ids = [
          for (final name in ['A', 'B', 'C']) a.tags.create(name)!.id,
        ];
        await passes([a, b]);

        a.tags.reorder([ids[2], ids[0], ids[1]]);
        later(b);
        b.tags.reorder([ids[1], ids[2], ids[0]]);
        await passes([a, b, a, b]);
        expect(a.tags.tags.map((t) => t.id), [ids[1], ids[2], ids[0]]);
        expect(b.tags.tags.map((t) => t.id), a.tags.tags.map((t) => t.id));
        expect(a.tags.owed, isEmpty);
        expect(b.tags.owed, isEmpty);
        a.dispose();
        b.dispose();
      },
    );
  });

  group('the account', () {
    test(
      'the first run of this build reads the stream again once, and every tag arrives',
      () async {
        final first = AccountDevice(server);
        await first.boot();
        await first.account.signIn(email: 'a@b.co', password: 'x');
        await first.account.createPassphrase('a good passphrase');
        final note = first.notes.create(body: '☐ Pack');
        final work = first.tags.create('Work')!;
        first.tags.addTag(note.id, work.id);
        await first.account.sync!.syncNow();
        await until(
          () =>
              first.tasks.index.entries.isNotEmpty &&
              first.tasks.index.owed.isEmpty &&
              first.tags.owed.isEmpty,
          reason: 'the first device never sent its records',
        );
        expect(stored(), hasLength(3));
        final seq = stored().values.map((r) => r.seq).reduce(max);
        first.dispose();

        // A device whose protocol-6 build from before tags read past them all.
        final second = AccountDevice(server);
        second.store.data['tasks.v1'] = {
          'cursor': seq,
          'scanned': true,
          'entries': <Object?>[],
          'stones': <String, Object?>{},
        };
        await second.boot();
        await second.account.signIn(email: 'a@b.co', password: 'x');
        expect(await second.account.unlock('a good passphrase'), isTrue);
        await until(
          () => second.tags.tagsOf(note.id).isNotEmpty,
          reason: 'the tag never came down',
        );
        expect(second.tags.tagsOf(note.id).single.name.v, 'Work');
        await until(
          () => second.tasks.index.entries.isNotEmpty,
          reason: 'the task did not merge in again',
        );
        expect(second.tasks.index.cursor, seq);
        second.dispose();

        final relaunched = AccountDevice(server, store: second.store);
        await relaunched.boot();
        expect(relaunched.tags.tags.single.name.v, 'Work');
        expect(
          relaunched.tasks.index.cursor,
          seq,
          reason: 'once, not every launch',
        );
        relaunched.dispose();
      },
    );

    test(
      'signing out keeps the tags, and the next account gets them under its own ids',
      () async {
        final d = AccountDevice(server);
        await d.boot();
        await d.account.signIn(email: 'a@b.co', password: 'x');
        await d.account.createPassphrase('a good passphrase');
        final note = d.notes.create(body: 'Trip');
        final travel = d.tags.create('Travel')!;
        d.tags.addTag(note.id, travel.id);
        await d.account.sync!.syncNow();
        await until(() => d.tags.owed.isEmpty);
        final firstIds = stored().keys.toSet();

        await d.account.signOut();
        expect(d.tags.tagsOf(note.id).single.name.v, 'Travel');
        expect(d.tags.owed.map((r) => r.key).toSet(), {travel.id, note.id});

        d.auth.id = 'user-2';
        d.auth.email = 'someone-else@example.com';
        await d.account.signIn(email: 'c@d.co', password: 'y');
        await d.account.resolveAccountSwitch(keepLocalNotes: true);
        if (d.account.state == AccountState.needsPassphrase) {
          await d.account.createPassphrase('another good passphrase');
        }
        await until(
          () => stored('user-2').length == 2,
          reason: 'nothing went up',
        );
        final secondIds = stored('user-2').keys.toSet();
        expect(secondIds, contains(travel.id));
        expect(
          secondIds.difference({travel.id}),
          isNot(firstIds.difference({travel.id})),
          reason: "a note's tags record id is the account's own",
        );
        d.dispose();
      },
    );

    test(
      'letting go of the notes on an account switch lets go of their tags',
      () async {
        final d = AccountDevice(server);
        await d.boot();
        await d.account.signIn(email: 'a@b.co', password: 'x');
        await d.account.createPassphrase('a good passphrase');
        final note = d.notes.create(body: 'Theirs');
        d.tags.addTag(note.id, d.tags.create('Private')!.id);
        await d.account.signOut();

        d.auth.id = 'user-2';
        await d.account.signIn(email: 'c@d.co', password: 'y');
        await d.account.resolveAccountSwitch(keepLocalNotes: false);
        expect(d.tags.tags, isEmpty);
        expect(d.tags.owed, isEmpty);
        d.dispose();
      },
    );
  });
}
