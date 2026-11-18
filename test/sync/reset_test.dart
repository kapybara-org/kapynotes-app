import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_service.dart';

import 'account_test.dart' show Device;
import 'fake_server.dart';

void main() {
  late FakeServer server;
  setUp(() => server = FakeServer());

  Future<Device> signedIn({FakeAuth? auth, int? protocol}) async {
    final d = protocol == null
        ? Device(server, auth: auth)
        : Device(server, auth: auth, protocol: protocol);
    d.account.deviceName = (_) async => 'Sanjay’s MacBook';
    await d.boot();
    final who = d.auth;
    await d.account.signIn(email: who.email, password: 'x');
    return d;
  }

  Future<Device> unlocked(
    String passphrase, {
    bool create = false,
    FakeAuth? auth,
  }) async {
    final d = await signedIn(auth: auth);
    if (create) {
      await d.account.createPassphrase(passphrase);
    } else {
      expect(await d.account.unlock(passphrase), isTrue);
    }
    return d;
  }

  Future<String> proof(Device d) async {
    expect(await d.account.sendKeyCode(KeyProofAction.reset), isNull);
    final result = await d.account.verifyKeyCode(
      KeyProofAction.reset,
      '123456',
    );
    expect(result.problem, isNull);
    return result.proof!;
  }

  Future<KeyChangeResult> reset(Device d, String passphrase) async {
    final prepared = await d.account.prepareReset(passphrase);
    return d.account.commitReset(prepared, proof: await proof(d));
  }

  Future<void> settle(List<Device> devices) async {
    for (var round = 0; round < 3; round++) {
      for (final d in devices) {
        if (d.account.state == AccountState.ready) {
          await d.account.sync!.syncNow();
        }
        await pumpEventQueue();
      }
    }
  }

  Set<String> bodies(Device d) => {for (final n in d.notes.notes) n.body};

  Set<String> onServer() => {
    for (final row in server.personal('user-1').notes.values)
      if (row.deletedAt == null) row.id,
  };

  test('a reset keeps every note on every device, and each adds its notes '
      'back once it has the new passphrase', () async {
    final a = await unlocked('first passphrase', create: true);
    a.notes.create(body: 'From A');
    await settle([a]);
    final b = await unlocked('first passphrase');
    await settle([a, b]);

    // A device that lost its key, holding a note nobody else has.
    final c = Device(server)..account.deviceName = (_) async => 'Office iMac';
    await c.boot();
    c.notes.create(body: 'Only on C');
    await c.account.signIn(email: 'someone@example.com', password: 'x');
    expect(c.account.state, AccountState.locked);

    final preview = await c.account.resetPreview();
    expect(preview, isNotNull);
    expect(c.account.notesOnlyOnServer(preview!), 1);

    expect(await reset(c, 'new passphrase'), isA<KeyChangeDone>());
    expect(c.account.state, AccountState.ready);
    expect(c.account.recoveryKeyUnsaved, isTrue);
    expect(server.user('user-1').bundle!.generation, 2);
    expect(server.user('user-1').archive, isNotNull);
    expect(server.user('user-1').retired!.notes, isNotEmpty);
    await settle([c]);
    expect(onServer(), hasLength(1));

    // B keeps writing with the old key: refused, kept, and asked about.
    b.notes.create(body: 'Written on B after the reset');
    await settle([b]);
    expect(b.account.state, AccountState.keysChanged);
    expect(b.account.resetElsewhere?.device, 'Office iMac');
    expect(await b.keys.readMasterKey(), isNull);
    expect(bodies(b), containsAll(['From A', 'Written on B after the reset']));

    expect(await b.account.unlock('first passphrase'), isFalse);
    expect(b.account.typedOldKey, isTrue);
    expect(await b.account.unlock('nonsense'), isFalse);
    expect(b.account.typedOldKey, isFalse);
    expect(await b.account.unlock('new passphrase'), isTrue);

    // A was idle through all of it, and finds out on its next pass.
    await settle([a]);
    expect(a.account.state, AccountState.keysChanged);
    expect(await a.account.unlock('new passphrase'), isTrue);

    await settle([a, b, c]);
    for (final d in [a, b, c]) {
      expect(d.account.state, AccountState.ready);
      expect(d.account.sync!.status, isNot(SyncStatus.failed));
      expect(
        bodies(d),
        containsAll(['From A', 'Only on C', 'Written on B after the reset']),
      );
    }
    expect(onServer(), hasLength(3));
    for (final d in [a, b, c]) {
      d.dispose();
    }
  });

  test(
    'a device offline as it learns of a reset asks again until it can',
    () async {
      final a = await unlocked('first passphrase', create: true);
      a.notes.create(body: 'From A');
      await settle([a]);
      final b = await unlocked('first passphrase');
      await settle([a, b]);
      await a.account.signOut();
      await a.account.signIn(email: 'someone@example.com', password: 'x');
      expect(await reset(a, 'new passphrase'), isA<KeyChangeDone>());

      b.account.keysChangedRetry = const Duration(milliseconds: 1);
      server.failKeyFetches = 3;
      b.notes.create(body: 'Written on B while offline');
      await settle([b]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();

      expect(server.failKeyFetches, 0);
      expect(b.account.state, AccountState.keysChanged);
      expect(b.account.resetElsewhere, isNotNull);
      expect(await b.account.unlock('new passphrase'), isTrue);
      await settle([a, b]);
      expect(bodies(b), containsAll(['From A', 'Written on B while offline']));
      a.dispose();
      b.dispose();
    },
  );

  test(
    'a device already holding the new key carries on without asking',
    () async {
      final a = await unlocked('first passphrase', create: true);
      a.notes.create(body: 'Kept');
      await settle([a]);
      await a.account.signOut();
      await a.account.signIn(email: 'someone@example.com', password: 'x');
      expect(await reset(a, 'new passphrase'), isA<KeyChangeDone>());
      await settle([a]);
      final key = await a.keys.readMasterKey();

      // A build from before protocol 7, unlocked with the new passphrase and
      // then updated: the key it holds is current, its generation is not.
      final e = Device(server);
      await e.boot();
      await e.account.signIn(email: 'someone@example.com', password: 'x');
      expect(e.account.state, AccountState.locked);
      await e.keys.writeMasterKey(Uint8List.fromList(key!));
      await e.account.restore();
      await settle([e]);
      expect(e.account.state, AccountState.ready);
      expect(e.account.sync!.status, isNot(SyncStatus.keysChanged));
      expect(bodies(e), contains('Kept'));
      a.dispose();
      e.dispose();
    },
  );

  test(
    'a passphrase changed elsewhere first wins, and nothing is reset',
    () async {
      final a = await unlocked('first passphrase', create: true);
      await a.account.signOut();
      await a.account.signIn(email: 'someone@example.com', password: 'x');
      final prepared = await a.account.prepareReset('new passphrase');
      final code = await proof(a);
      server.beforeKeyChange = (user) {
        final bundle = user.bundle!;
        user.bundle = KeyBundle(
          wrappedMasterKey: bundle.wrappedMasterKey,
          kdf: bundle.kdf,
          recoveryWrappedMasterKey: bundle.recoveryWrappedMasterKey,
          identity: bundle.identity,
          version: bundle.version + 1,
          changes: KeyChanges(
            passphrase: KeyChange(
              at: DateTime.utc(2026, 11, 18),
              device: 'iPhone',
            ),
          ),
        );
      };
      final result = await a.account.commitReset(prepared, proof: code);
      expect(result, isA<KeyChangeLostRace>());
      expect((result as KeyChangeLostRace).byReset, isFalse);
      expect(result.change.device, 'iPhone');
      expect(server.user('user-1').bundle!.generation, 1);
      expect(a.account.state, AccountState.locked);
      expect(await a.keys.readPendingMasterKey(), isNull);
      a.dispose();
    },
  );

  test(
    'a build from before protocol 7 stops, says so, and keeps its notes',
    () async {
      final a = await unlocked('first passphrase', create: true);
      a.notes.create(body: 'Before');
      await settle([a]);
      final old = await signedIn(protocol: 6);
      expect(await old.account.unlock('first passphrase'), isTrue);
      await settle([old]);
      expect(bodies(old), contains('Before'));

      await a.account.signOut();
      await a.account.signIn(email: 'someone@example.com', password: 'x');
      expect(await reset(a, 'new passphrase'), isA<KeyChangeDone>());

      old.notes.create(body: 'Written on the old build');
      await settle([old]);
      expect(old.account.sync!.status, SyncStatus.outdated);
      expect(old.account.state, AccountState.ready);
      expect(bodies(old), containsAll(['Before', 'Written on the old build']));
      // The key routes stay open to it, so it can still unlock elsewhere.
      expect(server.user('user-1').bundle!.generation, 2);
      a.dispose();
      old.dispose();
    },
  );

  test('a reset leaves every shared space and note in place, and a '
      'co-editor grants the key again', () async {
    final a = await unlocked('first passphrase', create: true);
    final bob = await unlocked(
      'bob passphrase',
      create: true,
      auth: FakeAuth(id: 'user-2', email: 'user-2@example.com', name: 'Bob'),
    );
    final note = a.notes.create(body: 'Shared plan');
    await settle([a]);
    final space = await a.account.sharing!.shareNoteWith(
      note.id,
      email: 'user-2@example.com',
    );
    await bob.account.sharing!.acceptInvite(server.outbox.single.token);
    await settle([a, bob]);
    expect(bob.notes.notesIn(space.id), isNotEmpty);
    final before = {for (final n in a.notes.notesIn(space.id)) n.id};

    await a.account.signOut();
    await a.account.signIn(email: 'someone@example.com', password: 'x');
    expect(await reset(a, 'new passphrase'), isA<KeyChangeDone>());
    expect({for (final n in a.notes.notesIn(space.id)) n.id}, before);
    expect(
      server.spaces[space.id]!.members.keys,
      containsAll(['user-1', 'user-2']),
    );

    await settle([bob, a]);
    expect(a.account.sync!.status, isNot(SyncStatus.failed));
    expect(server.spaces[space.id]!.keys.containsKey('user-1'), isTrue);
    expect({for (final n in a.notes.notesIn(space.id)) n.id}, before);
    final seen = bob.account.sharing!.teams.single.members.firstWhere(
      (m) => m.userId == 'user-1',
    );
    expect(seen.identityResetAt, isNotNull);
    a.dispose();
    bob.dispose();
  });

  test('a note whose key moved on past this device becomes a personal '
      'note instead of a write nobody could read', () async {
    final a = await unlocked('first passphrase', create: true);
    final viewer = await unlocked(
      'viewer passphrase',
      create: true,
      auth: FakeAuth(id: 'user-2', email: 'user-2@example.com', name: 'Vi'),
    );
    final note = a.notes.create(body: 'Lagging note');
    await settle([a]);
    final space = await a.account.sharing!.shareNoteWith(
      note.id,
      email: 'user-2@example.com',
      role: SpaceRole.viewer,
    );
    await viewer.account.sharing!.acceptInvite(server.outbox.single.token);
    await settle([a, viewer]);

    // An editor since gone moved the note's key on while this device was
    // away, so the copy here is a version behind.
    final keys = server.spaces[space.id]!.noteKeys;
    final old = keys[note.id]!;
    keys[note.id] = FakeNoteKey(
      wrapped: old.wrapped,
      keyGeneration: old.keyGeneration,
      contentKeyEpoch: old.contentKeyEpoch + 1,
      contentKeyGeneration: old.contentKeyGeneration,
    );

    await a.account.signOut();
    await a.account.signIn(email: 'someone@example.com', password: 'x');
    expect(await reset(a, 'new passphrase'), isA<KeyChangeDone>());
    await settle([a]);

    final stored = server.spaces[space.id]!;
    expect(stored.keyGeneration, 2);
    expect(stored.noteKeys[note.id]!.keyGeneration, 1);
    final copies = [
      for (final n in a.notes.notes)
        if (n.spaceId == null && n.body == 'Lagging note') n,
    ];
    expect(copies, hasLength(1));
    expect(a.notes.byId(note.id), isNull);
    expect(onServer(), contains(copies.single.id));

    a.notes.updateBody(copies.single.id, 'Lagging note, edited');
    await settle([a]);
    expect(server.refusals, isNot(contains('content-key-epoch')));
    expect(a.account.sync!.status, isNot(SyncStatus.failed));
    expect(stored.noteKeys[note.id]!.keyGeneration, 1);
    expect(stored.notes[note.id]!.deletedAt, isNull);
    a.dispose();
    viewer.dispose();
  });

  test('a space only this account could grant in is rotated, and its '
      'viewers read on', () async {
    final a = await unlocked('first passphrase', create: true);
    final viewer = await unlocked(
      'viewer passphrase',
      create: true,
      auth: FakeAuth(id: 'user-2', email: 'user-2@example.com', name: 'Vi'),
    );
    final note = a.notes.create(body: 'Read only for Vi');
    await settle([a]);
    final space = await a.account.sharing!.shareNoteWith(
      note.id,
      email: 'user-2@example.com',
      role: SpaceRole.viewer,
    );
    await viewer.account.sharing!.acceptInvite(server.outbox.single.token);
    await settle([a, viewer]);
    expect(
      server.spaces[space.id]!.keys.keys,
      containsAll(['user-1', 'user-2']),
    );

    await a.account.signOut();
    await a.account.signIn(email: 'someone@example.com', password: 'x');
    final preview = await a.account.resetPreview();
    expect(preview!.orphanedSpaces, {space.id});
    expect(await reset(a, 'new passphrase'), isA<KeyChangeDone>());
    await settle([a]);

    final stored = server.spaces[space.id]!;
    expect(stored.keyGeneration, 2);
    expect(stored.keys.keys, containsAll(['user-1', 'user-2']));
    expect(a.account.sync!.status, isNot(SyncStatus.failed));

    a.notes.updateBody(note.id, 'Read only for Vi, edited after the reset');
    await settle([a, viewer]);
    expect(
      bodies(viewer),
      contains('Read only for Vi, edited after the reset'),
    );
    a.dispose();
    viewer.dispose();
  });
}
