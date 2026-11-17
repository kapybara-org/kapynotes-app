import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/task_sync.dart';
import 'package:kapy_notes/sync/trust.dart';

import 'fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'task-sync-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// One device of the account: its notes, documents and task index, and the
/// shared fake server.
class Device {
  Device(this.server, {required this.name, int protocol = protocolVersion}) {
    store.data['sync.v1'] = {'deviceId': deviceIdFor(name)};
    notes = NotesStore(store, now: tick);
    state = SyncState(store)..load();
    api = FakeApi(server, device: state.deviceId)..protocol = protocol;
    server.seedBundle(api.userId);
    docs = DocStore(MemoryDocStorage(), replica: name.padRight(12, '0'));
    tasks = TaskIndex(store, now: tick);
    sync = SyncService(
      notes: notes,
      state: state,
      api: api,
      keyring: SpaceKeyring(
        userId: api.userId,
        store: store,
        trust: TrustStore(store),
      ),
      docs: docs,
      tasks: TaskSync(
        api: api,
        vault: sharedVault(),
        index: tasks,
        docs: docs,
        noteIsLive: (id) => notes.byId(id) != null,
        delay: const Duration(milliseconds: 1),
      ),
      vault: sharedVault(),
      now: tick,
      sendDelay: const Duration(milliseconds: 1),
    );
  }

  final FakeServer server;
  final String name;
  final MemoryStore store = MemoryStore();
  late final NotesStore notes;
  late final SyncState state;
  late final FakeApi api;
  late final DocStore docs;
  late final TaskIndex tasks;
  late final SyncService sync;

  DateTime clock = DateTime.utc(2026, 11, 17, 9);
  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  Future<void> boot() async {
    await notes.load();
    await docs.load();
  }

  Future<void> pass() async {
    await sync.syncNow();
    await settle(server);
  }

  void dispose() => sync.dispose();
}

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Map<String, ({WireTaskRecord record, int seq})> stored(Device d) =>
      server.tasks[d.api.userId] ?? {};

  test('a task written on one device reaches another with the same id, sealed', () async {
    final laptop = Device(server, name: 'laptop');
    final phone = Device(server, name: 'phone');
    await laptop.boot();
    await phone.boot();

    laptop.notes.create(body: 'Errands\n☐ Buy milk\n- [ ] Call mum');
    await laptop.pass();

    expect(stored(laptop), hasLength(2));
    for (final row in stored(laptop).values) {
      final bytes = utf8.decode(row.record.payload!.cipherText, allowMalformed: true);
      expect(bytes, isNot(contains('milk')));
      expect(bytes, isNot(contains('anchor')));
    }
    expect(laptop.tasks.owed, isEmpty);

    await phone.pass();
    expect(phone.tasks.entries.toSet(), laptop.tasks.entries.toSet());
    expect(phone.tasks.entries, hasLength(2));
    expect(phone.tasks.owed, isEmpty);
    laptop.dispose();
    phone.dispose();
  });

  test('a dot on one device and a tick on the other both survive', () async {
    final laptop = Device(server, name: 'laptop');
    final phone = Device(server, name: 'phone');
    await laptop.boot();
    await phone.boot();
    final note = laptop.notes.create(body: '☐ Write report');
    await laptop.pass();
    await phone.pass();

    final mine = laptop.tasks.entries.single;
    laptop.tasks.update(
      mine.copyWith(dot: Stamped(true, laptop.tick().millisecondsSinceEpoch)),
    );
    phone.notes.updateBody(note.id, '☑ Write report');

    await phone.pass();
    await laptop.pass();
    await phone.pass();

    for (final device in [laptop, phone]) {
      final entry = device.tasks.entries.single;
      expect(entry.id, mine.id, reason: device.name);
      expect(entry.dot.v, isTrue, reason: device.name);
      expect(entry.doneAt.v, isNotNull, reason: device.name);
      expect(device.tasks.owed, isEmpty, reason: device.name);
    }
    expect(laptop.tasks.entries.single, phone.tasks.entries.single);
    laptop.dispose();
    phone.dispose();
  });

  test('the socket tells the other protocol-6 device to pull, and not an older build', () async {
    final laptop = Device(server, name: 'laptop');
    final phone = Device(server, name: 'phone');
    final old = Device(server, name: 'old', protocol: 5);
    for (final d in [laptop, phone, old]) {
      await d.boot();
      d.sync.resume();
    }
    await settle(server);
    server.log.clear();

    laptop.notes.create(body: '☐ Book flights');
    await laptop.pass();
    await settle(server);

    expect(phone.tasks.entries, hasLength(1));
    final heard = [
      for (final e in server.log)
        if (e.device == phone.api.device) e.call,
    ];
    expect(heard, contains(startsWith('pullTasks')));
    final oldHeard = [
      for (final e in server.log)
        if (e.device == old.api.device) e.call,
    ];
    // Nothing told it the records moved, so it never asked for them.
    expect(oldHeard.where((c) => c.startsWith('pullTasks')), isEmpty);
    for (final d in [laptop, phone, old]) {
      d.dispose();
    }
  });

  test('a server without the task index leaves note sync alone, and the records wait', () async {
    server.tasksServed = false;
    final laptop = Device(server, name: 'laptop');
    await laptop.boot();
    laptop.notes.create(body: '☐ Renew passport');
    await laptop.pass();

    expect(laptop.sync.status, SyncStatus.idle);
    expect(server.rows, hasLength(1));
    expect(laptop.tasks.owed, hasLength(1));

    server.tasksServed = true;
    await laptop.pass();
    expect(laptop.tasks.owed, isEmpty);
    expect(stored(laptop), hasLength(1));
    laptop.dispose();
  });

  test('a deleted note takes its records off the server', () async {
    final laptop = Device(server, name: 'laptop');
    await laptop.boot();
    final note = laptop.notes.create(body: '☐ Alpha\n☐ Bravo');
    await laptop.pass();

    laptop.notes.delete(note.id);
    await laptop.pass();
    expect(laptop.tasks.entries, isEmpty);
    expect(stored(laptop), hasLength(2));
    expect(stored(laptop).values.every((r) => r.record.deletedAt != null), isTrue);
    laptop.dispose();
  });

  test('a payload moved onto another id is not taken for that task', () async {
    final laptop = Device(server, name: 'laptop');
    final phone = Device(server, name: 'phone');
    await laptop.boot();
    await phone.boot();
    laptop.notes.create(body: '☐ Alpha');
    await laptop.pass();

    final real = stored(laptop).values.single.record;
    const forged = '00000000-0000-8000-8000-000000000000';
    server.pushTasks(laptop.api.userId, 'mallory', [
      WireTaskRecord(id: forged, updatedAt: real.updatedAt, payload: real.payload),
    ]);
    await phone.pass();
    expect(phone.tasks.byId(forged), isNull);
    expect(phone.tasks.entries.single.id, real.id);
    laptop.dispose();
    phone.dispose();
  });
}
