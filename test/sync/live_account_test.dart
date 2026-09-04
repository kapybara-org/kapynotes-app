@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/auth_api.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_state.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'live-account.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  final email = Platform.environment['KAPYNOTES_E2E_EMAIL'] ?? '';
  final password = Platform.environment['KAPYNOTES_E2E_PASSWORD'] ?? '';
  if (email.isEmpty || password.isEmpty) {
    test('live account', () {}, skip: 'set KAPYNOTES_E2E_EMAIL/PASSWORD');
    return;
  }
  final base = Uri.parse('https://api.kapynotes.com/');
  const passphrase = 'a good long passphrase';

  ({Account account, NotesStore notes, KeyStore keys}) device() {
    final store = MemoryStore();
    final notes = NotesStore(store);
    final keys = KeyStore(InMemorySecureStore());
    return (
      account: Account(
        auth: HttpAuthApi(baseUrl: base),
        syncApi: (token) =>
            HttpSyncApi(baseUrl: base, token: () async => token),
        keys: keys,
        notes: notes,
        state: SyncState(store),
      ),
      notes: notes,
      keys: keys,
    );
  }

  late String recovery;

  test('first device: sign in, choose a passphrase, sync a note', () async {
    final d = device();
    await d.notes.load();
    await d.account.restore();
    expect(d.account.state, AccountState.signedOut);

    await d.account.signIn(email: email, password: password);
    expect(
      d.account.state,
      AccountState.needsPassphrase,
      reason: d.account.lastError ?? '',
    );

    final key = await d.account.createPassphrase(passphrase);
    expect(key, isNotNull, reason: d.account.lastError ?? '');
    recovery = key!.formatted;
    expect(d.account.state, AccountState.ready);

    d.notes.create(body: 'Written before any other device existed');
    await d.account.sync!.syncNow();
    expect(d.notes.hasPendingChanges, isFalse);
    d.account.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('second device: locked, then opened by the passphrase', () async {
    final d = device();
    await d.notes.load();
    await d.account.restore();
    await d.account.signIn(email: email, password: password);

    expect(d.account.state, AccountState.locked);
    expect(await d.account.unlock('not it'), isFalse);
    expect(await d.account.unlock(passphrase), isTrue);
    expect(d.account.state, AccountState.ready);
    expect(
      d.notes.notes.map((n) => n.body),
      contains('Written before any other device existed'),
    );
    d.account.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('third device: opened by the recovery key alone', () async {
    final d = device();
    await d.notes.load();
    await d.account.restore();
    await d.account.signIn(email: email, password: password);

    expect(await d.account.unlockWithRecoveryKey(recovery), isTrue);
    expect(
      d.notes.notes.map((n) => n.body),
      contains('Written before any other device existed'),
    );

    // And signing out keeps them here while forgetting how to read new ones.
    await d.account.signOut();
    expect(d.account.state, AccountState.signedOut);
    expect(d.notes.notes, isNotEmpty);
    expect(await d.keys.readMasterKey(), isNull);
    d.account.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
