import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/sync/aead.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/image_sync.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/trust.dart';

import 'fake_server.dart';

const anchor = NoteAttachmentRef.placeholder;

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'image-sync-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

class FailsSecondAttachmentOnce extends FakeApi {
  FailsSecondAttachmentOnce(super.server, {required super.device});

  var creates = 0;

  @override
  Future<AttachmentSlot> createAttachment({
    required String noteId,
    String? spaceId,
    required int bytes,
  }) {
    creates++;
    if (creates == 2) {
      throw const SyncTransientException('thumbnail upload interrupted');
    }
    return super.createAttachment(noteId: noteId, spaceId: spaceId, bytes: bytes);
  }
}

class FailsFirstDownloadOnce extends FakeApi {
  FailsFirstDownloadOnce(super.server, {required super.device});

  var attempts = 0;

  @override
  Future<Map<String, Uri>> attachmentUrls(List<String> ids) {
    attempts++;
    if (attempts == 1) {
      throw const SyncTransientException('phone changed networks');
    }
    return super.attachmentUrls(ids);
  }
}

/// One device, with its own disk for pictures.
class Device {
  Device(
    this.server, {
    required this.name,
    required Directory dir,
    FakeApi Function(FakeServer server, String device)? apiFor,
  }) {
    store = MemoryStore();
    images = BlobStore(directory: dir);
    notes = NotesStore(store, now: () => clock, blobs: images);
    state = SyncState(store);
    api = apiFor?.call(server, name) ?? FakeApi(server, device: name);
    server.seedBundle(api.userId);
    keyring = SpaceKeyring(
      userId: api.userId,
      store: store,
      trust: TrustStore(store),
    );
    imageSync = ImageSync(api: api, store: images, notes: notes);
    docs = DocStore(MemoryDocStorage(), replica: name);
    sync = SyncService(
      notes: notes,
      state: state,
      api: api,
      keyring: keyring,
      docs: docs,
      images: imageSync,
      vault: sharedVault(),
      now: () => clock,
      sendDelay: const Duration(milliseconds: 1),
    );
  }

  final FakeServer server;
  final String name;
  DateTime clock = DateTime.utc(2026, 9, 1);

  late final MemoryStore store;
  late final BlobStore images;
  late final NotesStore notes;
  late final SyncState state;
  late final FakeApi api;
  late final SpaceKeyring keyring;
  late final ImageSync imageSync;
  late final DocStore docs;
  late final SyncService sync;

  Future<void> boot() async {
    await notes.load();
    state.load();
    await docs.load();
  }

  void dispose() => sync.dispose();
}

/// Bytes that compress badly, so a test asserting on sizes is not measuring
/// the compressor's luck.
Uint8List picture(int seed) =>
    Uint8List.fromList(List.generate(4096, (i) => (i * 31 + seed) & 0xFF));

void main() {
  late FakeServer server;
  late Directory root;

  setUp(() async {
    server = FakeServer();
    root = await Directory.systemTemp.createTemp('kapy-image-sync');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<Directory> dirFor(String name) =>
      Directory('${root.path}/$name').create(recursive: true);

  test('an image reaches the other device, and opens there', () async {
    final one = Device(server, name: 'one', dir: await dirFor('one'));
    final two = Device(
      server,
      name: 'two',
      dir: await dirFor('two'),
    );
    addTearDown(one.dispose);
    addTearDown(two.dispose);
    await one.boot();
    await two.boot();

    final bytes = picture(1);
    final hash = await one.images.put(bytes);
    final key = randomKey();

    final id = one.notes.create().id;
    one.notes.updateDocument(id, 'look at this\n$anchor', const [], [
      NoteImageRef(
        offset: 13,
        hash: hash,
        key: key,
        mime: 'image/png',
        width: 64,
        height: 64,
        bytes: bytes.length,
      ),
    ]);
    await one.sync.syncNow();
    // The picture goes up first and the words follow, on their own timers.
    await settle(server);

    // The picture went up, and was billed on what actually landed.
    expect(server.blobs, hasLength(1));
    expect(server.pendingBlobs, isEmpty);
    expect(server.storageUsed[one.api.userId], greaterThan(bytes.length));
    // Ciphertext, not the picture: the server holds bytes it cannot read.
    expect(server.blobs.values.single, isNot(bytes));

    // The id is recorded locally, and recording it did not dirty the note.
    final uploaded = one.notes.notes.single.attachments.single;
    expect(uploaded.isUploaded, isTrue);
    expect(one.notes.notes.single.isDirty, isFalse);
    await two.sync.syncNow();
    final arrived = two.notes.notes.single.attachments.single;
    expect(arrived.hash, hash);
    expect(arrived.attachmentId, uploaded.attachmentId);
    expect(arrived.key, key);

    // The second device does not have the bytes yet, and can get them.
    expect(await two.images.has(hash), isFalse);
    final fetched = await two.imageSync.fetch(hash);
    expect(fetched, bytes);
    // Cached on the way through, so opening the note again costs nothing.
    expect(await two.images.read(hash), bytes);
  });

  test('a note still syncs when its picture will not fit', () async {
    server.storageQuota = 8;
    final one = Device(server, name: 'one', dir: await dirFor('one'));
    addTearDown(one.dispose);
    await one.boot();

    final bytes = picture(2);
    final hash = await one.images.put(bytes);
    final id = one.notes.create().id;
    one.notes.updateDocument(id, 'over quota\n$anchor', const [], [
      NoteImageRef(
        offset: 11,
        hash: hash,
        key: randomKey(),
        mime: 'image/png',
        width: 64,
        height: 64,
        bytes: bytes.length,
      ),
    ]);

    await one.sync.syncNow();
    await settle(server);

    // The words wait for the picture: an op that described a picture nobody
    // could ask for would be worse than a note that is late. Nothing is
    // lost — the note is still here, still dirty, still on disk.
    expect(one.notes.notes.single.isDirty, isTrue);
    expect(server.blobs, isEmpty);
    expect(server.rows, isEmpty);
    expect(one.notes.notes.single.attachments.single.isUploaded, isFalse);

    // And both go up on the next pass once there is room. The edit is made
    // after the anchor so its offset is unchanged: moving a placeholder
    // without rebasing the refs is what deleting an image looks like.
    server.storageQuota = 1 << 20;
    one.clock = one.clock.add(const Duration(minutes: 1));
    one.notes.updateDocument(id, 'over quota\n$anchor and then not', const []);
    await one.sync.syncNow();
    await settle(server);
    expect(server.blobs, hasLength(1));
    expect(one.notes.notes.single.attachments.single.isUploaded, isTrue);
    expect(one.notes.notes.single.isDirty, isFalse);
    expect(server.rows, hasLength(1));
  });

  test('one picture in two notes is downloaded once', () async {
    final one = Device(server, name: 'one', dir: await dirFor('one'));
    final two = Device(server, name: 'two', dir: await dirFor('two'));
    addTearDown(one.dispose);
    addTearDown(two.dispose);
    await one.boot();
    await two.boot();

    final bytes = picture(3);
    final hash = await one.images.put(bytes);
    final key = randomKey();
    NoteAttachmentRef ref(int offset) => NoteImageRef(
      offset: offset,
      hash: hash,
      key: key,
      mime: 'image/png',
      width: 64,
      height: 64,
      bytes: bytes.length,
    );

    for (final title in ['first', 'second']) {
      final id = one.notes.create().id;
      one.notes.updateDocument(id, '$title\n$anchor', const [], [
        ref(title.length + 1),
      ]);
    }
    await one.sync.syncNow();
    await settle(server);
    await two.sync.syncNow();

    final before = server.blobs.length;
    final results = await Future.wait([
      two.imageSync.fetch(hash),
      two.imageSync.fetch(hash),
    ]);
    expect(results, [bytes, bytes]);
    expect(server.blobs.length, before);
  });

  test('a transient mobile download retries inside the same image load', () async {
    final one = Device(server, name: 'one', dir: await dirFor('one'));
    final two = Device(
      server,
      name: 'two',
      dir: await dirFor('two'),
      apiFor: (server, device) => FailsFirstDownloadOnce(server, device: device),
    );
    addTearDown(one.dispose);
    addTearDown(two.dispose);
    await one.boot();
    await two.boot();

    final bytes = picture(6);
    final hash = await one.images.put(bytes);
    final note = one.notes.create();
    one.notes.updateDocument(note.id, anchor, const [], [
      NoteImageRef(
        offset: 0,
        hash: hash,
        key: randomKey(),
        mime: 'image/png',
        width: 900,
        height: 600,
        bytes: bytes.length,
      ),
    ]);
    await one.sync.syncNow();
    await settle(server);
    await two.sync.syncNow();

    expect(await two.imageSync.fetch(hash), bytes);
    expect((two.api as FailsFirstDownloadOnce).attempts, 2);
  });

  test('a failed thumbnail resumes without uploading the full image twice', () async {
    final one = Device(
      server,
      name: 'one',
      dir: await dirFor('one'),
      apiFor: (server, device) => FailsSecondAttachmentOnce(server, device: device),
    );
    addTearDown(one.dispose);
    await one.boot();

    final full = picture(4);
    final thumbnail = picture(5);
    final fullHash = await one.images.put(full);
    final thumbHash = await one.images.put(thumbnail);
    final note = one.notes.create();
    one.notes.updateDocument(note.id, anchor, const [], [
      NoteImageRef(
        offset: 0,
        hash: fullHash,
        thumbHash: thumbHash,
        key: randomKey(),
        mime: 'image/png',
        width: 1200,
        height: 800,
        bytes: full.length,
      ),
    ]);

    final first = await one.imageSync.upload(one.notes.byId(note.id)!);
    final partial = first.attachments.single as NoteImageRef;
    expect(partial.attachmentId, isNotNull);
    expect(partial.thumbId, isNull);
    expect(server.attachments, hasLength(1));

    final second = await one.imageSync.upload(first);
    final complete = second.attachments.single as NoteImageRef;
    expect(complete.attachmentId, partial.attachmentId);
    expect(complete.thumbId, isNotNull);
    expect(server.attachments, hasLength(2));
  });
}
