import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';

import 'fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'account-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

/// One device: its own storage and keystore, the shared server.
class Device {
  Device(this.server, {FakeAuth? auth}) : auth = auth ?? FakeAuth() {
    store = MemoryStore();
    notes = NotesStore(store);
    keys = KeyStore(InMemorySecureStore());
    account = Account(
      auth: this.auth,
      syncApi: (_) => FakeApi(server),
      keys: keys,
      notes: notes,
      state: SyncState(store),
      store: store,
    );
  }

  final FakeServer server;
  final FakeAuth auth;
  late final MemoryStore store;
  late final NotesStore notes;
  late final KeyStore keys;
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

  test('a fresh install is signed out', () async {
    final d = Device(server);
    await d.boot();
    expect(d.account.state, AccountState.signedOut);
    d.dispose();
  });

  test('signing in with no key bundle asks for a passphrase', () async {
    final d = Device(server);
    await d.boot();

    await d.account.signIn(email: 'a@b.co', password: 'x');

    expect(d.account.state, AccountState.needsPassphrase);
    d.dispose();
  });

  test('choosing a passphrase publishes the bundle and starts syncing', () async {
    final d = Device(server);
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    d.notes.create(body: 'First note');

    final recovery = await d.account.createPassphrase('a good passphrase');

    expect(recovery, isNotNull);
    expect(recovery!.formatted, isNotEmpty);
    expect(d.account.state, AccountState.ready);
    expect(server.rows, hasLength(1), reason: 'the note went up');
    d.dispose();
  });

  test('a second device is locked until the passphrase arrives', () async {
    final first = Device(server);
    await first.boot();
    await first.account.signIn(email: 'a@b.co', password: 'x');
    await first.account.createPassphrase('a good passphrase');
    first.notes.create(body: 'Written on the first device');
    await first.account.sync!.syncNow();
    first.dispose();

    final second = Device(server);
    await second.boot();
    await second.account.signIn(email: 'a@b.co', password: 'x');
    expect(second.account.state, AccountState.locked);

    expect(await second.account.unlock('not the passphrase'), isFalse);
    expect(second.account.state, AccountState.locked);

    expect(await second.account.unlock('a good passphrase'), isTrue);
    expect(second.account.state, AccountState.ready);
    expect(second.notes.notes.single.body, 'Written on the first device');
    second.dispose();
  });

  test('the recovery key opens a device when the passphrase is gone', () async {
    final first = Device(server);
    await first.boot();
    await first.account.signIn(email: 'a@b.co', password: 'x');
    final recovery = await first.account.createPassphrase('forgotten already');
    first.notes.create(body: 'Still reachable');
    await first.account.sync!.syncNow();
    first.dispose();

    final second = Device(server);
    await second.boot();
    await second.account.signIn(email: 'a@b.co', password: 'x');

    expect(await second.account.unlockWithRecoveryKey('nonsense'), isFalse);
    expect(
      await second.account.unlockWithRecoveryKey(recovery!.formatted),
      isTrue,
    );
    expect(second.notes.notes.single.body, 'Still reachable');
    second.dispose();
  });

  test('a device that has unlocked once does not ask again', () async {
    final d = Device(server);
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    await d.account.createPassphrase('a good passphrase');
    d.dispose();

    // Same storage and keystore, new process.
    final restarted = Account(
      auth: d.auth,
      syncApi: (_) => FakeApi(server),
      keys: d.keys,
      notes: d.notes,
      state: SyncState(d.store),
      store: d.store,
    );
    await restarted.restore();

    expect(restarted.state, AccountState.ready, reason: 'the key was cached');
    restarted.dispose();
  });

  test('an expired session signs out but keeps the notes', () async {
    final d = Device(server);
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    await d.account.createPassphrase('a good passphrase');
    d.notes.create(body: 'Mine');
    d.dispose();

    d.auth.sessionValid = false;
    final restarted = Account(
      auth: d.auth,
      syncApi: (_) => FakeApi(server),
      keys: d.keys,
      notes: d.notes,
      state: SyncState(d.store),
      store: d.store,
    );
    await restarted.restore();

    expect(restarted.state, AccountState.signedOut);
    expect(d.notes.notes, hasLength(1), reason: 'a session is not the notes');
    restarted.dispose();
  });

  test('signing out drops the key but never the notes', () async {
    final d = Device(server);
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    await d.account.createPassphrase('a good passphrase');
    d.notes.create(body: 'Kept');

    await d.account.signOut();

    expect(d.account.state, AccountState.signedOut);
    expect(d.notes.notes, hasLength(1));
    expect(await d.keys.readMasterKey(), isNull);
    expect(await d.keys.readToken(), isNull);
    expect(d.auth.signOutCalls, 1);
    d.dispose();
  });

  test('signing in as somebody else asks before touching the notes', () async {
    final d = Device(server);
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    await d.account.createPassphrase('a good passphrase');
    d.notes.create(body: 'Belongs to the first person');
    await d.account.signOut();

    // A different account, on a device that still holds the first one's notes.
    d.auth.id = 'user-2';
    d.auth.email = 'someone-else@example.com';
    await d.account.signIn(email: 'c@d.co', password: 'y');

    expect(d.account.state, AccountState.needsAccountDecision);
    expect(d.notes.notes, hasLength(1), reason: 'nothing decided quietly');

    await d.account.resolveAccountSwitch(keepLocalNotes: false);
    expect(d.notes.notes, isEmpty);
    d.dispose();
  });

  test('deleting the account clears the session and keeps the notes', () async {
    final d = Device(server);
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    await d.account.createPassphrase('a good passphrase');
    d.notes.create(body: 'Written before closing the account');
    await d.account.sync!.syncNow();
    expect(server.rows, isNotEmpty);

    final ok = await d.account.deleteAccount('someone@example.com');

    expect(ok, isTrue);
    expect(server.deleted, isTrue);
    expect(d.account.state, AccountState.signedOut);
    expect(await d.keys.readToken(), isNull, reason: 'the session is gone');
    // A closed account is not a request to erase what the person wrote, which
    // is the same promise sign-out makes.
    expect(d.notes.notes.single.body, 'Written before closing the account');
    d.dispose();
  });

  test('a mistyped address is refused and the account survives', () async {
    final d = Device(server);
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    await d.account.createPassphrase('a good passphrase');

    final ok = await d.account.deleteAccount('not-the-address@example.com');

    expect(ok, isFalse);
    expect(server.deleted, isFalse);
    expect(d.account.state, AccountState.ready, reason: 'still signed in');
    expect(await d.keys.readToken(), isNotNull);
    expect(d.account.lastError, isNotNull);
    d.dispose();
  });

  test('the address is matched without case or padding mattering', () async {
    final d = Device(server);
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    await d.account.createPassphrase('a good passphrase');

    expect(await d.account.deleteAccount('  SomeOne@Example.COM '), isTrue);
    d.dispose();
  });

  test('a locked device can still delete the account', () async {
    final first = Device(server);
    await first.boot();
    await first.account.signIn(email: 'a@b.co', password: 'x');
    await first.account.createPassphrase('a good passphrase');
    first.notes.create(body: 'Sealed with a passphrase nobody remembers');
    await first.account.sync!.syncNow();
    first.dispose();

    final second = Device(server);
    await second.boot();
    await second.account.signIn(email: 'a@b.co', password: 'x');
    expect(second.account.state, AccountState.locked);

    // The whole point: this is the one person with no other move to make, and
    // a delete gated on the key they have lost would be no delete at all.
    expect(await second.account.deleteAccount('someone@example.com'), isTrue);
    expect(second.account.state, AccountState.signedOut);
    expect(server.deleted, isTrue);
    second.dispose();
  });
}
