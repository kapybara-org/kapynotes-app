import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
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

  final Map<String, int> puts = {};

  @override
  void put(String key, Object? value) {
    puts[key] = (puts[key] ?? 0) + 1;
    data[key] = value;
  }
}

/// One device of the account: its notes, documents, task index and tags, and
/// the shared fake server.
class Device {
  Device(this.server, {required this.name, int protocol = protocolVersion}) {
    store.data['sync.v1'] = {'deviceId': deviceIdFor(name)};
    notes = NotesStore(store, now: tick);
    state = SyncState(store)..load();
    api = FakeApi(server, device: state.deviceId)..protocol = protocol;
    server.seedBundle(api.userId);
    docs = DocStore(MemoryDocStorage(), replica: name.padRight(12, '0'));
    tasks = TaskIndex(store, now: tick);
    tags = TagStore(store, now: tick);
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
        tags: tags,
        docs: docs,
        noteIsLive: (id) => notes.byId(id) != null,
        deletedNotes: () => [
          for (final stone in notes.tombstones)
            if (notes.byId(stone.id) == null) stone.id,
        ],
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
  late final TagStore tags;
  late final SyncService sync;

  DateTime clock = DateTime.utc(2026, 11, 17, 9);
  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  Future<void> boot() async {
    await notes.load();
    await docs.load();
    await tags.load();
  }

  Future<void> pass() async {
    await sync.syncNow();
    await settle(server);
  }

  void dispose() => sync.dispose();
}
