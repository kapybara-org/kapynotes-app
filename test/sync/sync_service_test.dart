import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/trust.dart';

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

/// One simulated device: its own local store, document store and clock, the
/// shared server. Named, and the name is its device id on the server, so a
/// test can read who wrote an op.
class Device {
  Device(
    this.server, {
    required this.name,
    DateTime? startAt,
    Duration pollInterval = const Duration(seconds: 60),
    int snapshotEvery = 150,
  }) : clock = startAt ?? DateTime.utc(2026, 9, 1) {
    store = MemoryStore();
    store.data['sync.v1'] = {'deviceId': deviceIdFor(name)};
    notes = NotesStore(store, now: tick);
    state = SyncState(store)..load();
    api = FakeApi(server, device: state.deviceId);
    // An account that unlocked before sharing existed; the first pass adds
    // its identity keys.
    server.seedBundle(api.userId);
    keyring = SpaceKeyring(
      userId: api.userId,
      store: store,
      trust: TrustStore(store),
    );
    docs = DocStore(MemoryDocStorage(), replica: name);
    sync = SyncService(
      notes: notes,
      state: state,
      api: api,
      keyring: keyring,
      docs: docs,
      vault: sharedVault(),
      now: tick,
      sendDelay: const Duration(milliseconds: 1),
      pollInterval: pollInterval,
      snapshotEvery: snapshotEvery,
    );
  }

  final FakeServer server;
  final String name;

  /// Moved by hand so a test can put two devices minutes or days apart, and
  /// forward a millisecond on every read so two edits never share an
  /// instant — a real clock does not stand still either, and an edit stamped
  /// with the time its predecessor was synced at would not look dirty.
  DateTime clock;

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  late final MemoryStore store;
  late final NotesStore notes;
  late final SyncState state;
  late final FakeApi api;
  late final SpaceKeyring keyring;
  late final DocStore docs;
  late final SyncService sync;

  String get personalId => server.personal(api.userId).id;

  /// The personal space's cursor, which is what a single-account test means
  /// by "the cursor".
  int get cursor => state.cursorFor(personalId);

  Future<void> boot() async {
    await notes.load();
    state.load();
    await docs.load();
  }

  /// Brings the device to the foreground: the socket connects, the first
  /// pass runs, and the personal space is caught up.
  Future<void> goLive() async {
    sync.resume();
    await settle(server);
  }

  bool get isConnected => server.isConnected(api.device);

  /// This device's end of the socket, for a test that drops just this one.
  FakeSocket get socket => server.sockets[api.device]!;

  List<String> get bodies => notes.notes.map((n) => n.body).toList()..sort();

  String bodyOf(String id) => notes.byId(id)?.body ?? '<gone>';

  void dispose() => sync.dispose();
}

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  group('push over HTTP', () {
    test('a new note is seeded and the outbox emptied', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      device.notes.create(body: 'Sent up');

      await device.sync.syncNow();

      expect(server.rows, hasLength(1));
      expect(server.snapshotsIn(device.personalId), hasLength(1));
      expect(device.sync.pendingCount, 0);
      expect(device.notes.notes.single.isDirty, isFalse);
      expect(device.sync.status, SyncStatus.idle);
      expect(server.calls, contains('pushOps'));
      device.dispose();
    });

    test('a deletion is a tombstone and a marker, not a payload', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      final note = device.notes.create(body: 'Doomed');
      await device.sync.syncNow();

      device.clock = DateTime.utc(2026, 9, 2);
      device.notes.delete(note.id);
      await device.sync.syncNow();

      final row = server.rows[note.id]!;
      expect(row.isTombstone, isTrue);
      final marker = server.opsIn(device.personalId).last;
      expect(marker.isMarker, isTrue);
      expect(marker.deleted, isTrue);
      expect(marker.payload.isEmpty, isTrue);
      expect(device.notes.dirtyTombstones, isEmpty);
      device.dispose();
    });

    test('the server never receives readable text', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      device.notes.create(body: 'Salary is 95000 GBP');
      await device.sync.syncNow();
      device.notes.updateBody(device.notes.notes.single.id, 'Salary is 96000 GBP');
      await device.sync.syncNow();

      final stored = server.ciphertextIn(device.personalId);
      expect(stored, isNotEmpty);
      expect(stored, isNot(contains('Salary')));
      expect(stored, isNot(contains('95000')));
      expect(stored, isNot(contains('96000')));
      device.dispose();
    });

    test('a retried push is answered with the seqs it already has', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      final note = device.notes.create(body: 'Once');
      await device.sync.syncNow();
      device.notes.updateBody(note.id, 'Once, edited');
      await device.sync.syncNow();
      final before = server.opsIn(device.personalId).length;

      // The same op again, as a client whose ack was lost would send it.
      final op = server.opsIn(device.personalId).last;
      final replay = await device.api.pushOps(
        OpsPush(
          spaceId: device.personalId,
          noteId: note.id,
          ops: [
            WireOp(
              deviceSeq: op.deviceSeq,
              epoch: op.epoch,
              engine: op.engine,
              payload: op.payload,
            ),
          ],
        ),
      );

      expect(replay.seqs, [op.seq]);
      expect(server.opsIn(device.personalId), hasLength(before));
      device.dispose();
    });
  });

  group('pull over HTTP', () {
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
      expect(server.calls.where((c) => c.startsWith('pullOps')), isNotEmpty);
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
      expect(server.calls.where((c) => c.startsWith('pullOps')), hasLength(3));
      one.dispose();
      two.dispose();
    });

    test('the cursor is the last seq applied and never moves back', () async {
      final one = Device(server, name: 'one');
      await one.boot();
      one.notes.create(body: 'Only note');
      await one.sync.syncNow();
      await one.sync.syncNow();
      final cursor = one.cursor;
      expect(cursor, server.opSeqOf(one.personalId));

      await one.sync.syncNow();

      expect(one.cursor, cursor);
      one.dispose();
    });
  });

  group('over the socket', () {
    test('a note typed on one device appears on the other unasked', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      await one.goLive();
      await two.goLive();
      expect(one.isConnected, isTrue);
      expect(two.isConnected, isTrue);
      expect(two.sync.isLive, isTrue);
      final before = server.calls.length;

      final note = one.notes.create(body: 'Typed on one');
      await until(
        () => two.bodies.contains('Typed on one'),
        reason: 'two was never handed one\'s op',
      );
      one.notes.updateBody(note.id, 'Typed on one, then more');
      await until(() => two.bodyOf(note.id) == 'Typed on one, then more');

      // Nobody called syncNow: it all went over the socket.
      expect(server.calls.sublist(before).where((c) => c.startsWith('pullOps')), isEmpty);
      expect(server.calls.sublist(before), contains('ws:push'));
      expect(server.ciphertextIn(one.personalId), isNot(contains('Typed')));
      expect(two.notes.notes.single.isDirty, isFalse);
      one.dispose();
      two.dispose();
    });

    test('the author is handed its own op back and does not reapply it', () async {
      final one = Device(server, name: 'one');
      await one.boot();
      await one.goLive();

      final note = one.notes.create(body: 'Mine');
      await settle(server);
      one.notes.updateBody(note.id, 'Mine, edited');
      await settle(server);

      expect(one.bodyOf(note.id), 'Mine, edited');
      expect(one.sync.pendingCount, 0);
      // The echo moved the cursor past the device's own writes.
      expect(one.cursor, server.opSeqOf(one.personalId));
      one.dispose();
    });

    test('two devices editing the same note concurrently converge', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      await one.goLive();
      await two.goLive();

      final note = one.notes.create(body: 'Line 1\nLine 2');
      await until(() => two.bodyOf(note.id) == 'Line 1\nLine 2');

      // Different lines, at the same moment.
      one.notes.updateBody(note.id, 'Line 1 one\nLine 2');
      two.notes.updateBody(note.id, 'Line 1\nLine 2 two');
      await settle(server);
      expect(one.bodyOf(note.id), 'Line 1 one\nLine 2 two');
      expect(two.bodyOf(note.id), 'Line 1 one\nLine 2 two');

      // The same position, at the same moment: both append at the end.
      one.notes.updateBody(note.id, '${one.bodyOf(note.id)}\nfrom one');
      two.notes.updateBody(note.id, '${two.bodyOf(note.id)}\nfrom two');
      await settle(server);
      final merged = one.bodyOf(note.id);
      expect(two.bodyOf(note.id), merged);
      expect(merged, contains('from one'));
      expect(merged, contains('from two'));
      expect(merged, startsWith('Line 1 one\nLine 2 two'));

      // A third device joining later from cursor zero catches up to the
      // same text.
      final three = Device(server, name: 'three');
      await three.boot();
      await three.goLive();
      await until(() => three.bodyOf(note.id) == merged);
      expect(three.notes.notes, hasLength(1));
      one.dispose();
      two.dispose();
      three.dispose();
    });

    test('a delete on one device removes it on the other', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      await one.goLive();
      await two.goLive();

      final note = one.notes.create(body: 'Shared');
      await until(() => two.notes.byId(note.id) != null);

      one.notes.delete(note.id);
      await until(() => two.notes.byId(note.id) == null, reason: 'the delete never reached two');
      expect(one.notes.dirtyTombstones, isEmpty);
      expect(two.notes.tombstones.single.isDirty, isFalse);
      expect(server.rows[note.id]!.isTombstone, isTrue);
      one.dispose();
      two.dispose();
    });

    test('a note deleted on one does not come back from the other', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      await one.goLive();
      await two.goLive();

      final note = one.notes.create(body: 'Delete me');
      await until(() => two.notes.byId(note.id) != null);

      // Two goes dark, still holding its copy. One deletes.
      server.socketsAllowed = false;
      server.dropSockets();
      await settle(server);
      one.notes.delete(note.id);
      await settle(server);

      // Two comes back and syncs. Without the marker it would push its
      // stale copy and resurrect the note on every device.
      server.socketsAllowed = true;
      await settle(server);
      await two.sync.syncNow();
      await settle(server);

      expect(two.notes.notes, isEmpty);
      expect(one.notes.notes, isEmpty);
      one.dispose();
      two.dispose();
    });
  });

  group('offline', () {
    test('a device without a socket still syncs over HTTP, and converges when it is back', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      await one.goLive();
      await two.goLive();
      // Two's network stops carrying a socket: the one it had drops, and no
      // reconnect gets through.
      server.socketsAllowed = false;
      two.socket.drop();
      await settle(server);
      expect(two.isConnected, isFalse);
      expect(two.sync.isLive, isFalse);
      // One's is still up.
      expect(one.isConnected, isTrue);

      final note = one.notes.create(body: 'From one');
      await settle(server);
      expect(two.notes.byId(note.id), isNull, reason: 'nothing to deliver it on');

      // Two asks: the whole pass goes over HTTP.
      server.calls.clear();
      await two.sync.syncNow();
      expect(two.bodyOf(note.id), 'From one');
      expect(server.calls.where((c) => c.startsWith('pullOps')), isNotEmpty);

      // Two edits while socketless: the outbox drains over HTTP too.
      two.notes.updateBody(note.id, 'From one\nand two');
      await settle(server);
      expect(server.calls, contains('pushOps'));
      expect(two.sync.pendingCount, 0);
      await until(() => one.bodyOf(note.id) == 'From one\nand two');

      // The socket comes back; the edits made meanwhile flow both ways.
      server.socketsAllowed = true;
      await until(() => two.sync.isLive, reason: 'two never reconnected');
      await settle(server);
      one.notes.updateBody(note.id, 'From one\nand two\nand one again');
      await until(() => two.bodyOf(note.id) == 'From one\nand two\nand one again');
      two.notes.updateBody(note.id, 'From one\nand two\nand one again\nand two again');
      await until(() => one.bodyOf(note.id) == two.bodyOf(note.id));
      expect(server.calls.where((c) => c == 'ws:push'), isNotEmpty);
      one.dispose();
      two.dispose();
    });

    test('edits made offline go up when the network returns', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      await one.goLive();
      await two.goLive();
      final note = one.notes.create(body: 'Start');
      await until(() => two.bodyOf(note.id) == 'Start');

      // Two loses everything: the socket drops and every request fails.
      server.socketsAllowed = false;
      server.dropSockets();
      await settle(server);
      server.failNext = const SyncTransientException('no route to host');
      two.notes.updateBody(note.id, 'Start\nwritten in a tunnel');
      await settle(server);
      expect(two.sync.status, SyncStatus.offline);
      expect(two.sync.pendingCount, 1, reason: 'held, not lost');
      expect(server.opsIn(one.personalId).where((op) => op.deviceId == two.api.device), isEmpty);

      // Meanwhile one keeps typing.
      one.notes.updateBody(note.id, 'Start\nwritten at a desk');
      await settle(server);

      server.socketsAllowed = true;
      await until(() => two.sync.isLive);
      await settle(server);
      expect(two.sync.status, SyncStatus.idle);
      expect(two.sync.pendingCount, 0);
      expect(one.bodyOf(note.id), two.bodyOf(note.id));
      expect(one.bodyOf(note.id), contains('tunnel'));
      expect(one.bodyOf(note.id), contains('desk'));
      one.dispose();
      two.dispose();
    });

    test('a dropped socket falls back to polling until it is back', () async {
      final one = Device(server, name: 'one');
      final two = Device(
        server,
        name: 'two',
        pollInterval: const Duration(milliseconds: 30),
      );
      await one.boot();
      await two.boot();
      await one.goLive();
      await two.goLive();

      // A relay that lost its channel, and a socket that went with it.
      server.deliverLive = false;
      server.socketsAllowed = false;
      server.dropSockets();
      await settle(server);
      expect(two.sync.isLive, isFalse);

      one.notes.create(body: 'Written while two was deaf');
      await settle(server);

      await until(
        () => two.bodies.contains('Written while two was deaf'),
        reason: 'two never polled once its socket had gone',
      );
      expect(server.calls.where((c) => c.startsWith('pullOps')), isNotEmpty);

      server.deliverLive = true;
      server.socketsAllowed = true;
      await until(() => two.sync.isLive);
      one.dispose();
      two.dispose();
    });
  });

  group('two devices holding the same note', () {
    /// A note both devices already have — restored from a backup, or from
    /// the store as it was before sync existed.
    Note held(String id, String body, DateTime at) =>
        Note(id: id, body: body, createdAt: at, updatedAt: at);

    test('identical text is not duplicated', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      final at = DateTime.utc(2026, 8, 1);
      one.notes.importNotes([held('note-x', 'The same words', at)]);
      two.notes.importNotes([held('note-x', 'The same words', at)]);

      await one.sync.syncNow();
      await two.sync.syncNow();
      await settle(server);
      await one.sync.syncNow();

      expect(one.bodies, ['The same words']);
      expect(two.bodies, ['The same words']);
      expect(server.rows, hasLength(1));
      expect(one.sync.pendingCount, 0);
      expect(two.sync.pendingCount, 0);
      one.dispose();
      two.dispose();
    });

    test('older local text is kept beside the document as a copy', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      one.notes.importNotes([
        held('note-x', 'Newer, on one', DateTime.utc(2026, 8, 2)),
      ]);
      two.notes.importNotes([
        held('note-x', 'Older, on two', DateTime.utc(2026, 8, 1)),
      ]);
      // One seeds the document; its ops are stamped after two's edit.
      server.now = () => DateTime.utc(2026, 8, 3);

      await one.sync.syncNow();
      await two.sync.syncNow();
      await settle(server);
      await one.sync.syncNow();

      // The document holds one's words; two's are kept, once, as their own
      // note — and that note travels like any other.
      expect(two.bodyOf('note-x'), 'Newer, on one');
      expect(two.bodies, ['Newer, on one', 'Older, on two']);
      expect(one.bodies, ['Newer, on one', 'Older, on two']);
      expect(server.rows, hasLength(2));
      one.dispose();
      two.dispose();
    });

    test('newer local text wins onto the document', () async {
      final one = Device(server, name: 'one');
      final two = Device(server, name: 'two');
      await one.boot();
      await two.boot();
      one.notes.importNotes([
        held('note-x', 'Older, on one', DateTime.utc(2026, 8, 1)),
      ]);
      two.notes.importNotes([
        held('note-x', 'Newer, on two', DateTime.utc(2026, 8, 5)),
      ]);
      server.now = () => DateTime.utc(2026, 8, 3);

      await one.sync.syncNow();
      await two.sync.syncNow();
      await settle(server);
      await one.sync.syncNow();

      expect(two.bodyOf('note-x'), 'Newer, on two');
      expect(two.bodies, ['Newer, on two'], reason: 'nothing was copied aside');
      expect(one.bodyOf('note-x'), 'Newer, on two');
      expect(server.rows, hasLength(1));
      one.dispose();
      two.dispose();
    });
  });

  group('snapshots', () {
    test('compaction: a snapshot replaces the ops it covers', () async {
      final one = Device(server, name: 'one', snapshotEvery: 5);
      await one.boot();
      await one.goLive();

      final note = one.notes.create(body: 'v0');
      await settle(server);
      for (var i = 1; i <= 8; i++) {
        one.notes.updateBody(note.id, 'v$i');
        await settle(server);
      }

      final space = one.personalId;
      final ops = server.opsIn(space).where((op) => op.noteId == note.id);
      final snapshot = server.snapshotOf(space, note.id)!;
      expect(snapshot.seq, greaterThan(1), reason: 'a fresh snapshot was written');
      expect(ops.length, lessThan(8), reason: 'the covered ops were pruned');
      for (final op in ops) {
        expect(op.seq, greaterThan(snapshot.covers));
      }

      // A fresh device still gets the whole text.
      final fresh = Device(server, name: 'fresh');
      await fresh.boot();
      await fresh.sync.syncNow();
      expect(fresh.bodyOf(note.id), 'v8');
      one.dispose();
      fresh.dispose();
    });
  });

  group('status', () {
    test('an auth failure signs out and keeps the outbox', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      await device.sync.syncNow();
      device.notes.create(body: 'Not sent');
      server.failNext = const SyncAuthException('token rejected');

      await device.sync.syncNow();

      expect(device.sync.status, SyncStatus.signedOut);
      expect(device.sync.pendingCount, 1);
      expect(server.rows, isEmpty);
      device.dispose();
    });

    test('a network failure goes offline and retries later', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      await device.sync.syncNow();
      device.notes.create(body: 'Held back');
      server.failNext = const SyncTransientException('no route to host');

      await device.sync.syncNow();
      expect(device.sync.status, SyncStatus.offline);
      expect(device.sync.pendingCount, 1);

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

    test('a build the server no longer serves stops, and closes its socket', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      await device.goLive();
      expect(device.isConnected, isTrue);
      device.notes.create(body: 'Held');
      await settle(server);

      server.minProtocol = protocolVersion + 1;
      await device.sync.syncNow();

      expect(device.sync.status, SyncStatus.outdated);
      expect(device.sync.lastError, contains('update'));
      expect(device.isConnected, isFalse);
      expect(device.sync.isLive, isFalse);

      // No retry is scheduled and further requests are not made.
      device.notes.create(body: 'Also held');
      device.sync.requestSync();
      final before = server.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.calls.length, before);
      expect(device.isConnected, isFalse);
      device.dispose();
    });

    test('two concurrent passes collapse into one', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      await device.sync.syncNow();
      device.notes.create(body: 'Once only');

      await Future.wait([device.sync.syncNow(), device.sync.syncNow()]);

      expect(server.calls.where((c) => c == 'pushOps'), hasLength(1));
      device.dispose();
    });
  });

  group('the socket lifecycle', () {
    test('backgrounding closes the socket, resuming reopens it', () async {
      final device = Device(server, name: 'a');
      await device.boot();

      await device.goLive();
      expect(device.isConnected, isTrue);
      expect(device.sync.isLive, isTrue);

      device.sync.pause();
      await settle(server);
      expect(device.isConnected, isFalse);
      expect(device.sync.isLive, isFalse);

      await device.goLive();
      expect(device.isConnected, isTrue);
      device.dispose();
    });

    test('disposing lets go of the socket', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      await device.goLive();

      device.dispose();
      await settle(server);

      expect(server.sockets, isEmpty);
    });

    test('a socket that drops comes back on its own', () async {
      final device = Device(server, name: 'a');
      await device.boot();
      await device.goLive();

      server.dropSockets();
      await until(() => !device.sync.isLive);
      await until(() => device.sync.isLive, reason: 'never reconnected');
      expect(device.isConnected, isTrue);
      device.dispose();
    });
  });
}
