import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';

import 'fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'sync-service-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// One simulated device: its own local store and clock, the shared server.
class Device {
  Device(this.server, {required this.name, DateTime? startAt})
    : clock = startAt ?? DateTime.utc(2026, 9, 1) {
    store = MemoryStore();
    notes = NotesStore(store, now: () => clock);
    state = SyncState(store);
    api = FakeApi(server);
    sync = SyncService(
      notes: notes,
      state: state,
      api: api,
      vault: sharedVault(),
      now: () => clock,
      debounce: const Duration(milliseconds: 1),
    );
  }

  final FakeServer server;
  final String name;

  /// Moved by hand so a test can put two devices minutes or days apart.
  DateTime clock;

  late final MemoryStore store;
  late final NotesStore notes;
  late final SyncState state;
  late final FakeApi api;
  late final SyncService sync;

  Future<void> boot() async {
    await notes.load();
    state.load();
  }

  List<String> get bodies => notes.notes.map((n) => n.body).toList()..sort();

  void dispose() => sync.dispose();
}

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  group('push', () {
    test('sends dirty notes and marks them clean', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      device.notes.create(body: 'Sent up');

      await device.sync.syncNow();

      expect(server.rows, hasLength(1));
      expect(device.notes.notes.single.isDirty, isFalse);
      expect(device.sync.status, SyncStatus.idle);
      device.dispose();
    });

    test('sends deletions as tombstones', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      final note = device.notes.create(body: 'Doomed');
      await device.sync.syncNow();

      device.clock = DateTime.utc(2026, 9, 2);
      device.notes.delete(note.id);
      await device.sync.syncNow();

      expect(server.rows[note.id]!.isTombstone, isTrue);
      expect(server.rows[note.id]!.payload, isNull);
      expect(device.notes.dirtyTombstones, isEmpty);
      device.dispose();
    });

    test('the server never receives readable text', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      device.notes.create(body: 'Salary is 95000 GBP');
      await device.sync.syncNow();

      final stored = server.rows.values.single;
      final ciphertext = String.fromCharCodes(stored.payload!.cipherText);
      expect(ciphertext, isNot(contains('Salary')));
      expect(ciphertext, isNot(contains('95000')));
      device.dispose();
    });
  });

  group('pull', () {
    test('brings down what another device wrote', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();

      one.notes.create(body: 'Written on one');
      await one.sync.syncNow();
      await two.sync.syncNow();

      expect(two.bodies, ['Written on one']);
      expect(two.notes.notes.single.isDirty, isFalse);
      one.dispose();
      two.dispose();
    });

    test('follows pagination to the end', () async {
      final one = Device(server, name: 'one');
      await one.boot();
      for (var i = 0; i < 25; i++) {
        one.clock = DateTime.utc(2026, 9, 1).add(Duration(minutes: i));
        one.notes.create(body: 'Note $i');
      }
      await one.sync.syncNow();
      expect(server.rows, hasLength(25));

      server.pageSize = 10;
      final two = Device(server, name: 'two');
      await two.boot();
      server.calls.clear();
      await two.sync.syncNow();

      expect(two.notes.notes, hasLength(25));
      // 10, 10, 5 — the third page reports no more and ends the loop.
      expect(server.calls.where((c) => c.startsWith('pull')), hasLength(3));
      one.dispose();
      two.dispose();
    });

    test('an empty pull does not rewind the cursor', () async {
      final one = Device(server, name: 'one');
      await one.boot();
      one.notes.create(body: 'Only note');
      // A pass pulls before it pushes, so the first pull sees an empty server.
      // The second establishes a real cursor over the note just pushed.
      await one.sync.syncNow();
      await one.sync.syncNow();
      final cursor = one.state.cursor;
      expect(cursor, isNotEmpty);

      await one.sync.syncNow();

      expect(one.state.cursor, cursor);
      one.dispose();
    });
  });

  group('two devices', () {
    test('a note edited on one reaches the other', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();

      final note = one.notes.create(body: 'First draft');
      await one.sync.syncNow();
      await two.sync.syncNow();
      expect(two.bodies, ['First draft']);

      one.clock = DateTime.utc(2026, 9, 3);
      one.notes.updateBody(note.id, 'Second draft');
      await one.sync.syncNow();

      two.clock = DateTime.utc(2026, 9, 4);
      await two.sync.syncNow();

      expect(two.bodies, ['Second draft']);
      expect(two.notes.notes, hasLength(1), reason: 'an edit is not a new note');
      one.dispose();
      two.dispose();
    });

    test('a delete on one removes it from the other', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();

      final note = one.notes.create(body: 'Shared');
      await one.sync.syncNow();
      await two.sync.syncNow();
      expect(two.notes.notes, hasLength(1));

      one.clock = DateTime.utc(2026, 9, 5);
      one.notes.delete(note.id);
      await one.sync.syncNow();

      two.clock = DateTime.utc(2026, 9, 6);
      await two.sync.syncNow();

      expect(two.notes.notes, isEmpty);
      one.dispose();
      two.dispose();
    });

    test('a note deleted on one does not come back from the other', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();

      final note = one.notes.create(body: 'Delete me');
      await one.sync.syncNow();
      await two.sync.syncNow();

      // One deletes. Two is offline and still holds its copy.
      one.clock = DateTime.utc(2026, 9, 5);
      one.notes.delete(note.id);
      await one.sync.syncNow();

      // Two comes back and syncs. Without a tombstone it would push its stale
      // copy and resurrect the note on every device.
      two.clock = DateTime.utc(2026, 9, 6);
      await two.sync.syncNow();
      await one.sync.syncNow();

      expect(two.notes.notes, isEmpty);
      expect(one.notes.notes, isEmpty);
      one.dispose();
      two.dispose();
    });

    test('both editing offline keeps the losing text as a copy', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();

      final note = one.notes.create(body: 'Shared start');
      await one.sync.syncNow();
      await two.sync.syncNow();

      // Both edit while apart. Two's edit is later, so two wins.
      one.clock = DateTime.utc(2026, 9, 5);
      one.notes.updateBody(note.id, 'Edited on one');
      two.clock = DateTime.utc(2026, 9, 6);
      two.notes.updateBody(note.id, 'Edited on two');

      await two.sync.syncNow();
      await one.sync.syncNow();

      // One loses the race but does not lose the words.
      expect(one.bodies, ['Edited on one', 'Edited on two']);
      one.dispose();
      two.dispose();
    });

    test('a conflicted copy propagates to the other device', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();

      final note = one.notes.create(body: 'Start');
      await one.sync.syncNow();
      await two.sync.syncNow();

      one.clock = DateTime.utc(2026, 9, 5);
      one.notes.updateBody(note.id, 'One version');
      two.clock = DateTime.utc(2026, 9, 6);
      two.notes.updateBody(note.id, 'Two version');

      await two.sync.syncNow();
      await one.sync.syncNow();
      // One's copy is dirty; push it, then let two pull it down.
      await one.sync.syncNow();
      two.clock = DateTime.utc(2026, 9, 7);
      await two.sync.syncNow();

      expect(two.bodies, ['One version', 'Two version']);
      one.dispose();
      two.dispose();
    });

    test('a fresh install pulls the whole corpus', () async {
      final one = Device(server, name: 'one');
      await one.boot();
      for (var i = 0; i < 5; i++) {
        one.clock = DateTime.utc(2026, 9, 1).add(Duration(hours: i));
        one.notes.create(body: 'Note $i');
      }
      await one.sync.syncNow();

      final fresh = Device(server, name: 'fresh');
      await fresh.boot();
      await fresh.sync.syncNow();

      expect(fresh.notes.notes, hasLength(5));
      expect(fresh.notes.hasPendingChanges, isFalse);
      one.dispose();
      fresh.dispose();
    });
  });

  group('failure', () {
    test('an auth failure signs out and keeps the notes dirty', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      device.notes.create(body: 'Not sent');
      server.failNext = const SyncAuthException('token rejected');

      await device.sync.syncNow();

      expect(device.sync.status, SyncStatus.signedOut);
      expect(device.notes.dirtyNotes, hasLength(1));
      expect(server.rows, isEmpty);
      device.dispose();
    });

    test('a network failure goes offline and retries later', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      device.notes.create(body: 'Held back');
      server.failNext = const SyncTransientException('no route to host');

      await device.sync.syncNow();
      expect(device.sync.status, SyncStatus.offline);
      expect(device.notes.dirtyNotes, hasLength(1));

      // The next attempt succeeds and the note goes up unchanged.
      await device.sync.syncNow();
      expect(device.sync.status, SyncStatus.idle);
      expect(server.rows, hasLength(1));
      device.dispose();
    });

    test('a locked vault does not touch the network', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      device.notes.create(body: 'Sealed away');
      device.sync.lock();

      await device.sync.syncNow();

      expect(device.sync.status, SyncStatus.locked);
      expect(server.calls, isEmpty);
      device.dispose();
    });

    test('two concurrent passes collapse into one', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      device.notes.create(body: 'Once only');

      await Future.wait([device.sync.syncNow(), device.sync.syncNow()]);

      expect(server.calls.where((c) => c.startsWith('push')), hasLength(1));
      device.dispose();
    });
  });
}
