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

/// Retires a superseded pair of store review accounts.
///
/// Throwaway. It exists so that closing them goes through the same code a
/// person would, rather than a hand-rolled sequence of curl calls that could
/// leave a space half-deleted in production.
///
///   KAPYNOTES_RETIRE=1 KAPYNOTES_REVIEW_PASSWORD=... \
///   KAPYNOTES_REVIEW_PASSPHRASE=... \
///   KAPYNOTES_RETIRE_EMAIL_A=... KAPYNOTES_RETIRE_EMAIL_B=... \
///   flutter test test/sync/retire_old_review_accounts_test.dart --tags live
class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'store-review-retire.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

void main() {
  final go = Platform.environment['KAPYNOTES_RETIRE'] ?? '';
  final password = Platform.environment['KAPYNOTES_REVIEW_PASSWORD'] ?? '';
  final passphrase = Platform.environment['KAPYNOTES_REVIEW_PASSPHRASE'] ?? '';
  if (go.isEmpty || password.isEmpty || passphrase.isEmpty) {
    test('retire the old review accounts', () {}, skip: 'set KAPYNOTES_RETIRE');
    return;
  }

  final base = Uri.parse(
    Platform.environment['KAPYNOTES_API'] ?? 'https://api.kapynotes.com/',
  );
  final emailA = Platform.environment['KAPYNOTES_RETIRE_EMAIL_A']!;
  final emailB = Platform.environment['KAPYNOTES_RETIRE_EMAIL_B']!;

  Future<({Account account, NotesStore notes})> ready(String email) async {
    final store = MemoryStore();
    final notes = NotesStore(store);
    final state = SyncState(store);
    final account = Account(
      auth: HttpAuthApi(baseUrl: base),
      syncApi: (token) => HttpSyncApi(
        baseUrl: base,
        token: () async => token,
        deviceId: state.deviceId,
      ),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: state,
      store: store,
    );

    await notes.load();
    await account.restore();
    await account.signIn(email: email, password: password);
    expect(
      account.state,
      isNot(AccountState.signedOut),
      reason: 'could not sign in as $email: ${account.lastError}',
    );
    if (account.state == AccountState.locked) {
      expect(await account.unlock(passphrase), isTrue, reason: account.lastError ?? '');
    }
    expect(account.state, AccountState.ready);
    await account.sync!.syncNow();
    return (account: account, notes: notes);
  }

  test('the old pair is closed, owner last', () async {
    // A owns the shared space, so it comes home before either account goes.
    final a = await ready(emailA);
    await a.account.sharing!.refresh();
    for (final space in [...a.account.sharing!.teams]) {
      if (space.isOwner) {
        stdout.writeln('stopping ${space.displayName}');
        await a.account.sharing!.stopSharing(space.id);
      } else {
        stdout.writeln('leaving ${space.displayName}');
        await a.account.sharing!.leave(space.id);
      }
    }

    final b = await ready(emailB);
    await b.account.sharing!.refresh();
    for (final space in [...b.account.sharing!.teams]) {
      if (space.isOwner) {
        await b.account.sharing!.stopSharing(space.id);
      } else {
        await b.account.sharing!.leave(space.id);
      }
    }

    expect(await b.account.deleteAccount(emailB), isTrue, reason: b.account.lastError ?? '');
    stdout.writeln('closed $emailB');
    expect(await a.account.deleteAccount(emailA), isTrue, reason: a.account.lastError ?? '');
    stdout.writeln('closed $emailA');

    a.account.dispose();
    b.account.dispose();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
