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

/// Sets up the two accounts Google Play and App Review sign in as.
///
/// Both stores need working credentials for anything behind a login, and
/// reviewers cannot create accounts, use their own, or ask us for help. Ours
/// are harder than most to hand over for two reasons, and this script exists
/// because both have to be solved before the credentials are worth anything:
///
///  * **Signing in is a code emailed to you.** A reviewer cannot receive our
///    email, so each account is given a password through the ordinary reset
///    flow first. That happens outside this file, over the auth API.
///  * **The notes are encrypted, so signing in is not enough.** An account
///    with no key bundle would land the reviewer on "choose a passphrase", and
///    one with a bundle they do not have the passphrase for would land them on
///    a locked app. Either reads as a broken build. So this creates the bundle
///    with a passphrase we then hand over.
///
/// It also leaves a shared space in place, because the features the stores
/// actually want to see — blocking, reporting, who can read this — only exist
/// once a note is shared with somebody. Setting that up requires two accounts
/// and four synchronisations, which is not a thing to ask a reviewer to do.
///
/// Re-runnable. Both accounts keep whatever they already have; a second run
/// adds another shared note rather than breaking anything.
///
///   KAPYNOTES_SEED_PLAY=1 \
///   KAPYNOTES_PLAY_PASSWORD=... KAPYNOTES_PLAY_PASSPHRASE=... \
///   flutter test test/sync/seed_play_review_test.dart --tags live
class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'play-review-seed.json');
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
  final go = Platform.environment['KAPYNOTES_SEED_PLAY'] ?? '';
  final password = Platform.environment['KAPYNOTES_PLAY_PASSWORD'] ?? '';
  final passphrase = Platform.environment['KAPYNOTES_PLAY_PASSPHRASE'] ?? '';
  if (go.isEmpty || password.isEmpty || passphrase.isEmpty) {
    test('seed the Play review accounts', () {}, skip: 'set KAPYNOTES_SEED_PLAY, _PASSWORD and _PASSPHRASE');
    return;
  }

  final base = Uri.parse(
    Platform.environment['KAPYNOTES_API'] ?? 'https://api.kapynotes.com/',
  );
  final emailA = Platform.environment['KAPYNOTES_PLAY_EMAIL_A']!;
  final emailB = Platform.environment['KAPYNOTES_PLAY_EMAIL_B']!;

  /// Signs in, and makes sure the account is unlocked on the other side —
  /// creating the key bundle the first time, opening it every time after.
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

    if (account.state == AccountState.needsPassphrase) {
      final recovery = await account.createPassphrase(passphrase);
      expect(recovery, isNotNull, reason: account.lastError ?? '');
      // Printed once, because it is the only moment it exists in the clear and
      // an account nobody can recover is a bad thing to hand anyone.
      stdout.writeln('recovery key for $email: ${recovery!.formatted}');
    } else if (account.state == AccountState.locked) {
      expect(
        await account.unlock(passphrase),
        isTrue,
        reason: 'the stored bundle for $email does not open with this passphrase',
      );
    }

    expect(account.state, AccountState.ready);

    // What the sheet does in the app. A reviewer signing in should not be
    // met by an agreement screen before they can look at anything, and the
    // account genuinely has agreed — we are the ones running it.
    await account.sharing!.refreshSafety();
    if (!account.sharing!.hasAcceptedTerms) {
      await account.sharing!.acceptTerms();
    }

    return (account: account, notes: notes);
  }

  test('both accounts sign in with a password and unlock with the passphrase', () async {
    for (final email in [emailA, emailB]) {
      final device = await ready(email);
      await device.account.sync!.syncNow();
      device.account.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a shared space is waiting, with a note in it', () async {
    final a = await ready(emailA);
    final b = await ready(emailB);

    // Something to look at that is obviously a demo and obviously harmless.
    if (a.notes.notes.isEmpty) {
      a.notes.create(
        body: 'Trip to Lisbon\n\n'
            'Flights: 412\n'
            'Hotel: 128 * 7\n'
            'Food: 55 * 7\n\n'
            'total',
      );
    }
    await a.account.sync!.syncNow();

    final sharing = a.account.sharing!;
    await sharing.refresh();

    // Only set the space up once; a second run leaves the first alone.
    if (sharing.teams.isEmpty) {
      final note = a.notes.notes.first;
      final space = await sharing.shareNoteWith(note.id, email: emailB);
      final token = space.invites.isEmpty ? null : space.invites.first.token;
      expect(token, isNotNull, reason: 'no invitation was created');

      await b.account.sharing!.acceptInvite(token!);
      // The grant only happens on a pass by somebody who holds the key.
      await a.account.sync!.syncNow();
      await b.account.sync!.syncNow();
    }

    await a.account.sync!.syncNow();
    await b.account.sync!.syncNow();
    await b.account.sharing!.refresh();

    final theirs = b.account.sharing!.teams;
    expect(theirs, isNotEmpty, reason: 'B is not in a shared space');
    expect(
      b.notes.notes.where((n) => n.isShared),
      isNotEmpty,
      reason: 'B cannot see the shared note, so a reviewer would not either',
    );

    stdout.writeln('shared space: ${theirs.first.displayName}');
    stdout.writeln('A notes: ${a.notes.notes.length}, B notes: ${b.notes.notes.length}');

    a.account.dispose();
    b.account.dispose();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
