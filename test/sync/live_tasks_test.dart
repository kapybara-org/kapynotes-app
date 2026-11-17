@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/task_sync.dart';
import 'package:kapy_notes/sync/trust.dart';
import 'package:kapy_notes/sync/vault.dart';

/// The task index end to end against a real server, with the real client.
///
///   KAPYNOTES_E2E_URL=http://localhost:3000/ \
///   KAPYNOTES_E2E_TOKEN=\$TOKEN flutter test --tags live test/sync/live_tasks_test.dart
///
/// Shares its account and passphrase with live_e2e_test.dart, so the two can
/// run against one test account in either order.
class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'live-tasks.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  final token = Platform.environment['KAPYNOTES_E2E_TOKEN'] ?? '';
  if (token.isEmpty) {
    test('live tasks', () {}, skip: 'set KAPYNOTES_E2E_TOKEN to run');
    return;
  }

  const passphrase = 'correct horse battery staple';
  final base = Uri.parse(
    Platform.environment['KAPYNOTES_E2E_URL'] ?? 'https://api.kapynotes.com/',
  );
  final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  var devices = 0;

  ({NotesStore notes, TaskIndex tasks, SyncService sync}) device(Vault vault) {
    final store = MemoryStore();
    final notes = NotesStore(store);
    final state = SyncState(store)..load();
    final api = HttpSyncApi(
      baseUrl: base,
      token: () async => token,
      deviceId: 'tasks-$run-${devices++}',
    );
    final docs = DocStore(
      MemoryDocStorage(),
      replica: state.deviceId.substring(0, 12),
    );
    final tasks = TaskIndex(store);
    return (
      notes: notes,
      tasks: tasks,
      sync: SyncService(
        notes: notes,
        state: state,
        api: api,
        docs: docs,
        keyring: SpaceKeyring(
          userId: 'e2e',
          store: store,
          trust: TrustStore(store),
        ),
        tasks: TaskSync(
          api: api,
          vault: vault,
          index: tasks,
          docs: docs,
          noteIsLive: (id) => notes.byId(id) != null,
          delay: const Duration(milliseconds: 50),
        ),
        vault: vault,
      ),
    );
  }

  late Vault vault;
  late String noteId;

  Iterable<TaskEntry> ofThisRun(TaskIndex tasks) =>
      tasks.entries.where((e) => e.noteId == noteId);

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  setUpAll(() async {
    final api = HttpSyncApi(baseUrl: base, token: () async => token, deviceId: 'tasks-$run');
    var bundle = await api.fetchKeyBundle();
    if (bundle == null) {
      final setup = await Vault.create(passphrase: passphrase);
      await api.createKeyBundle(
        KeyBundle(
          wrappedMasterKey: setup.wrappedMasterKey,
          kdf: setup.kdf,
          recoveryWrappedMasterKey: setup.recoveryWrappedMasterKey,
        ),
      );
      bundle = await api.fetchKeyBundle();
    }
    vault = (await Vault.unlockWithPassphrase(
      passphrase: passphrase,
      kdf: bundle!.kdf,
      wrappedMasterKey: bundle.wrappedMasterKey,
    ))!;
  });

  test('1. a device writes tasks; the server holds only sealed records', () async {
    final a = device(vault);
    await a.notes.load();
    noteId = a.notes.create(body: '$run errands\n☐ Buy milk\n- [ ] Call mum').id;
    await a.sync.syncNow();
    expect(a.sync.status, SyncStatus.idle, reason: a.sync.lastError ?? '');
    expect(ofThisRun(a.tasks), hasLength(2));
    expect(a.tasks.owed, isEmpty, reason: 'every record acknowledged');

    final request = await HttpClient().getUrl(base.resolve('tasks'));
    request.headers.set('authorization', 'Bearer $token');
    request.headers.set('x-kapynotes-protocol', '$protocolVersion');
    final response = await request.close();
    final raw = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200);
    for (final secret in ['milk', 'mum', noteId, 'anchor']) {
      expect(raw, isNot(contains(secret)), reason: '"$secret" left the device');
    }
    a.sync.dispose();
  });

  test('2. a fresh device pulls the same tasks under the same ids', () async {
    final a = device(vault);
    await a.notes.load();
    await a.sync.syncNow();
    final b = device(vault);
    await b.notes.load();
    await b.sync.syncNow();
    expect(b.sync.status, SyncStatus.idle, reason: b.sync.lastError ?? '');
    expect(ofThisRun(b.tasks).toSet(), ofThisRun(a.tasks).toSet());
    expect(ofThisRun(b.tasks), hasLength(2));
    a.sync.dispose();
    b.sync.dispose();
  });

  test('3. a dot on one device reaches a listening one over the socket', () async {
    final a = device(vault);
    final b = device(vault);
    for (final d in [a, b]) {
      await d.notes.load();
      await d.sync.syncNow();
    }
    b.sync.resume();
    await until(() => b.sync.isLive);

    final task = ofThisRun(a.tasks).first;
    final at = DateTime.now().millisecondsSinceEpoch;
    a.tasks.update(task.copyWith(dot: Stamped(true, at)));
    await a.sync.syncNow();
    expect(a.tasks.owed, isEmpty);

    await until(() => b.tasks.byId(task.id)?.dot.v == true);
    expect(b.tasks.byId(task.id)?.dot, Stamped(true, at));
    a.sync.dispose();
    b.sync.dispose();
  });

  test('4. a tick on one device and a change on another both survive', () async {
    final a = device(vault);
    final b = device(vault);
    for (final d in [a, b]) {
      await d.notes.load();
      await d.sync.syncNow();
    }
    final task = ofThisRun(a.tasks).firstWhere((e) => !e.dot.v);
    final at = DateTime.now().millisecondsSinceEpoch;
    b.tasks.update(task.copyWith(doNow: Stamped(true, at)));
    a.notes.updateBody(
      noteId,
      a.notes.byId(noteId)!.body.replaceAll('☐', '☑').replaceAll('- [ ]', '- [x]'),
    );

    await a.sync.syncNow();
    await b.sync.syncNow();
    await a.sync.syncNow();
    for (final d in [a, b]) {
      final entry = d.tasks.byId(task.id)!;
      expect(entry.doNow.v, isTrue);
      expect(entry.doneAt.v, isNotNull);
      expect(d.tasks.owed, isEmpty);
    }
    expect(a.tasks.byId(task.id), b.tasks.byId(task.id));
    a.sync.dispose();
    b.sync.dispose();
  });
}
