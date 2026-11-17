import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/task_sync.dart';
import 'package:kapy_notes/sync/trust.dart';

import 'fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'signed-out-tasks-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Every push, as it went.
class RecordingApi extends FakeApi {
  RecordingApi(super.server, {super.device});

  final List<OpsPush> pushes = [];

  @override
  Future<OpsPushResult> pushOps(OpsPush push) {
    pushes.add(push);
    return super.pushOps(push);
  }
}

/// One device, signed out until [signIn]: what the app's Account does with
/// its task library, with the sync it starts and stops.
class Device {
  Device(this.server, {required this.name}) {
    store.data['sync.v1'] = {'deviceId': deviceIdFor(name)};
    notes = NotesStore(store, now: tick);
    state = SyncState(store);
    library = TaskLibrary(
      notes: notes,
      store: store,
      state: state,
      storage: MemoryDocStorage(),
      now: tick,
    );
  }

  final FakeServer server;
  final String name;
  final MemoryStore store = MemoryStore();
  late final NotesStore notes;
  late final SyncState state;
  late final TaskLibrary library;
  late final RecordingApi api;
  SyncService? sync;

  DateTime clock = DateTime.utc(2026, 11, 17, 9);
  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  String get personalId => server.personal(api.userId).id;

  Future<void> boot() async {
    await library.load();
    api = RecordingApi(server, device: state.deviceId);
    server.seedBundle(api.userId);
  }

  void signIn() {
    final service = SyncService(
      notes: notes,
      state: state,
      api: api,
      keyring: SpaceKeyring(
        userId: api.userId,
        store: store,
        trust: TrustStore(store),
      ),
      docs: library.docs,
      tasks: TaskSync(
        api: api,
        vault: sharedVault(),
        index: library.index,
        docs: library.docs,
        noteIsLive: (id) => notes.byId(id) != null,
        delay: const Duration(milliseconds: 1),
      ),
      vault: sharedVault(),
      now: tick,
      sendDelay: const Duration(milliseconds: 1),
    );
    library.attachSync(service.reconcileTasksNow);
    sync = service;
  }

  void signOut() {
    sync?.dispose();
    sync = null;
    library.detachSync();
    state.clearCursor();
    library.index.clear();
  }

  Future<void> pass() async {
    await sync!.syncNow();
    await settle(server);
  }

  Iterable<OpsPush> pushesOf(String noteId) =>
      api.pushes.where((push) => push.noteId == noteId);
}

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Map<String, ({WireTaskRecord record, int seq})> stored(Device d) =>
      server.tasks[d.api.userId] ?? {};

  test('a note kept signed out goes up as a seed snapshot, never ops, and '
      'its tasks keep their anchors and state under the account ids', () async {
    final laptop = Device(server, name: 'laptop');
    await laptop.boot();
    final note = laptop.notes.create(body: 'Errands\n☐ Buy oats\n☐ Buy milk');
    await laptop.library.reconcileNow();
    laptop.notes.updateBody(note.id, 'Errands\n☐ Buy oats\n☐ Buy eggs');
    await laptop.library.reconcileNow();
    final oats = laptop.library.index.entries.firstWhere(
      (e) =>
          e.addedAt ==
          laptop.library.index.entries
              .map((e) => e.addedAt)
              .reduce((a, b) => a < b ? a : b),
    );
    laptop.library.index.update(
      oats.copyWith(dot: Stamped(true, laptop.tick().millisecondsSinceEpoch)),
    );
    final anchors = {for (final e in laptop.library.index.entries) e.anchor};
    expect(laptop.library.index.entries, hasLength(2));
    expect(
      laptop.library.index.entries.map((e) => e.id),
      everyElement(startsWith(localTaskIdPrefix)),
    );

    laptop.signIn();
    await laptop.pass();

    final push = laptop.pushesOf(note.id).single;
    expect(push.seed, isTrue);
    expect(push.snapshot, isNotNull);
    expect(push.ops, isEmpty);
    expect(
      server.opsIn(laptop.personalId).where((op) => op.noteId == note.id),
      isEmpty,
    );
    expect(laptop.library.docs.get(note.id)!.offline, isFalse);

    final tasks = laptop.library.index;
    expect({for (final e in tasks.entries) e.anchor}, anchors);
    for (final e in tasks.entries) {
      expect(e.id, sharedVault().taskRecordId(e.noteId, e.anchor));
    }
    expect(
      tasks.byId(sharedVault().taskRecordId(note.id, oats.anchor))!.dot.v,
      isTrue,
    );
    expect(tasks.owed, isEmpty);
    expect(stored(laptop).keys.toSet(), {for (final e in tasks.entries) e.id});
    expect(
      stored(laptop).values.map((r) => r.record.payload),
      everyElement(isNotNull),
    );

    final phone = Device(server, name: 'phone');
    await phone.boot();
    phone.signIn();
    await phone.pass();
    expect(phone.notes.byId(note.id)!.body, 'Errands\n☐ Buy oats\n☐ Buy eggs');
    expect(phone.library.index.entries.toSet(), tasks.entries.toSet());
    laptop.signOut();
    phone.signOut();
  });

  test('a note the server has, edited signed out, goes up whole once sync '
      'is back, and the index is rebuilt in between', () async {
    final laptop = Device(server, name: 'laptop');
    await laptop.boot();
    laptop.signIn();
    final note = laptop.notes.create(body: '☐ Write report');
    await laptop.pass();
    final anchor = laptop.library.index.entries.single.anchor;

    laptop.signOut();
    await laptop.library.reconcileNow();
    expect(
      laptop.library.index.entries.single.id,
      startsWith(localTaskIdPrefix),
    );
    expect(laptop.library.index.entries.single.anchor, anchor);

    laptop.notes.updateBody(note.id, '☐ Write report\n☐ Send it');
    await laptop.library.reconcileNow();
    expect(laptop.library.index.entries, hasLength(2));
    final before = laptop.pushesOf(note.id).length;

    laptop.signIn();
    await laptop.pass();

    final pushes = laptop.pushesOf(note.id).skip(before).toList();
    expect(pushes, hasLength(1));
    expect(pushes.single.seed, isFalse);
    expect(pushes.single.snapshot, isNotNull);
    expect(pushes.single.ops, isEmpty);

    final phone = Device(server, name: 'phone');
    await phone.boot();
    phone.signIn();
    await phone.pass();
    expect(phone.notes.byId(note.id)!.body, '☐ Write report\n☐ Send it');
    expect(
      phone.library.index.entries.toSet(),
      laptop.library.index.entries.toSet(),
    );
    laptop.signOut();
    phone.signOut();
  });

  test('signed in, nothing changes: a new note seeds as before and its '
      'edits go up as ops', () async {
    final laptop = Device(server, name: 'laptop');
    await laptop.boot();
    laptop.signIn();
    final note = laptop.notes.create(body: '☐ Buy milk');
    await laptop.pass();
    laptop.notes.updateBody(note.id, '☐ Buy milk\n☐ Buy oats');
    await laptop.pass();

    final pushes = laptop.pushesOf(note.id).toList();
    expect(pushes, hasLength(2));
    expect(pushes.first.seed, isTrue);
    expect(pushes.last.seed, isFalse);
    expect(pushes.last.ops, isNotEmpty);
    expect(pushes.last.snapshot, isNull);
    expect(
      laptop.library.index.entries.map((e) => e.id),
      everyElement(isNot(startsWith(localTaskIdPrefix))),
    );
    laptop.signOut();
  });
}
