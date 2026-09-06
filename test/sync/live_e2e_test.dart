@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/trust.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/vault.dart';

/// End-to-end against the deployed server, using the real client code.
///
/// The offline suite runs against a fake transport, which proves the merge
/// rules and proves nothing whatever about the SQL underneath them. This is
/// what caught a keyset cursor that threw on every pull after the first — a
/// bug invisible to a fake server and to any device that only ever synced once.
///
///   `KAPYNOTES_E2E_TOKEN=<bearer> flutter test --tags live`
///
/// Re-runnable: it reuses the account's key bundle if one exists, and scopes
/// every assertion to its own run so previous runs' notes do not interfere.
class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'live-e2e.json');
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
    // No credential, no run. Gated here rather than in dart_test.yaml so that
    // `--tags live` can actually execute it when the token is supplied.
    test('live end-to-end', () {}, skip: 'set KAPYNOTES_E2E_TOKEN to run');
    return;
  }

  const passphrase = 'correct horse battery staple';
  final base = Uri.parse(
    Platform.environment['KAPYNOTES_E2E_URL'] ?? 'https://api.kapynotes.com/',
  );
  final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  // Distinct per connection, because the server skips waking the device that
  // pushed: two "devices" sharing one id would be one device as far as the
  // wake-up channel is concerned, and this suite would never see one.
  var connections = 0;
  SyncApi api() => HttpSyncApi(
    baseUrl: base,
    token: () async => token,
    deviceId: '$run-${connections++}',
  );

  /// A device: its own local storage, the shared account.
  ({NotesStore notes, SyncService sync}) device(Vault vault) {
    final store = MemoryStore();
    final notes = NotesStore(store);
    final state = SyncState(store)..load();
    final connection = api();
    return (
      notes: notes,
      sync: SyncService(
        notes: notes,
        state: state,
        api: connection,
        keyring: SpaceKeyring(
          userId: 'e2e',
          store: store,
          trust: TrustStore(store),
        ),
        vault: vault,
      ),
    );
  }

  late Vault vault;
  late String editId;
  late String deleteId;

  test('1. key bundle: reachable from the passphrase, and only from it', () async {
    var bundle = await api().fetchKeyBundle();
    if (bundle == null) {
      final setup = await Vault.create(passphrase: passphrase);
      await api().createKeyBundle(
        KeyBundle(
          wrappedMasterKey: setup.wrappedMasterKey,
          kdf: setup.kdf,
          recoveryWrappedMasterKey: setup.recoveryWrappedMasterKey,
        ),
      );
      bundle = await api().fetchKeyBundle();
    }
    expect(bundle, isNotNull);

    // A new device holds nothing but the passphrase and what the server sends.
    final unlocked = await Vault.unlockWithPassphrase(
      passphrase: passphrase,
      kdf: bundle!.kdf,
      wrappedMasterKey: bundle.wrappedMasterKey,
    );
    expect(unlocked, isNotNull, reason: 'the passphrase must reach the key');

    expect(
      await Vault.unlockWithPassphrase(
        passphrase: 'not the passphrase',
        kdf: bundle.kdf,
        wrappedMasterKey: bundle.wrappedMasterKey,
      ),
      isNull,
      reason: 'and nothing else may',
    );
    vault = unlocked!;
  });

  test('2. a device pushes notes', () async {
    final d = device(vault);
    await d.notes.load();
    await d.sync.syncNow();
    expect(d.sync.status, SyncStatus.idle, reason: d.sync.lastError ?? '');

    editId = d.notes.create(body: '$run rent 1800 + 240').id;
    deleteId = d.notes.create(body: '$run doomed').id;
    d.notes.create(body: '$run groceries 62.40');

    await d.sync.syncNow();
    expect(d.sync.status, SyncStatus.idle, reason: d.sync.lastError ?? '');
    expect(d.notes.hasPendingChanges, isFalse);
    d.sync.dispose();
  });

  test('3. a fresh device pulls them and can read them', () async {
    final d = device(vault);
    await d.notes.load();
    await d.sync.syncNow();

    expect(d.sync.status, SyncStatus.idle, reason: d.sync.lastError ?? '');
    final mine = d.notes.notes.where((n) => n.body.startsWith(run));
    expect(mine.map((n) => n.body).toSet(), {
      '$run rent 1800 + 240',
      '$run doomed',
      '$run groceries 62.40',
    });
    expect(d.notes.hasPendingChanges, isFalse, reason: 'pulled notes are clean');
    d.sync.dispose();
  });

  test('4. an edit on one device reaches another', () async {
    final a = device(vault);
    await a.notes.load();
    await a.sync.syncNow();
    a.notes.updateBody(editId, '$run rent 1800 + 240 + 95');
    await a.sync.syncNow();
    expect(a.sync.status, SyncStatus.idle, reason: a.sync.lastError ?? '');
    a.sync.dispose();

    final b = device(vault);
    await b.notes.load();
    await b.sync.syncNow();
    expect(b.notes.byId(editId)?.body, '$run rent 1800 + 240 + 95');
    b.sync.dispose();
  });

  test('5. a delete propagates and does not come back', () async {
    final a = device(vault);
    await a.notes.load();
    await a.sync.syncNow();
    a.notes.delete(deleteId);
    await a.sync.syncNow();
    expect(a.sync.status, SyncStatus.idle, reason: a.sync.lastError ?? '');
    a.sync.dispose();

    final b = device(vault);
    await b.notes.load();
    await b.sync.syncNow();
    expect(b.notes.byId(deleteId), isNull);
    // And pushing again must not resurrect it from the device that still had it.
    await b.sync.syncNow();
    expect(b.notes.byId(deleteId), isNull);
    b.sync.dispose();
  });

  test('6. the server holds nothing it can read', () async {
    final request = await HttpClient().getUrl(base.resolve('sync/pull?limit=200'));
    request.headers.set('authorization', 'Bearer $token');
    final response = await request.close();
    final raw = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200);

    for (final secret in ['rent', '1800', 'groceries', '62.40', 'doomed']) {
      expect(raw, isNot(contains(secret)), reason: '"$secret" left the device');
    }

    final rows = (jsonDecode(raw) as Map<String, Object?>)['notes'] as List<Object?>;
    final live = rows.firstWhere((r) => (r as Map)['deletedAt'] == null) as Map;
    // All the server gets: an id, a timestamp, and bytes it cannot open.
    expect((live['payload'] as Map).keys.toSet(), {'ct', 'n', 'v'});
    final stone = rows.firstWhere((r) => (r as Map)['deletedAt'] != null) as Map;
    expect(stone['payload'], isNull, reason: 'a delete keeps no ciphertext');
  });
}
