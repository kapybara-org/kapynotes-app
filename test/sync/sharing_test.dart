import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/identity.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/sharing.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/trust.dart';
import 'package:kapy_notes/sync/vault.dart';

import 'fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'sharing-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// The one clock every device in a test reads, so that "later" is never a
/// coincidence of two clocks agreeing.
DateTime now = DateTime.utc(2026, 9, 1);

/// One person on one device: their own master key and storage.
class Person {
  Person(this.server, {required this.userId, required this.device}) {
    server.seedBundle(userId);
    store = MemoryStore();
    notes = NotesStore(store, now: () => now);
    state = SyncState(store);
    api = FakeApi(server, device: device, userId: userId);
    vault = vaultFor(userId);
    keyring = SpaceKeyring(
      userId: userId,
      store: store,
      trust: TrustStore(store),
    );
    sync = SyncService(
      notes: notes,
      state: state,
      api: api,
      keyring: keyring,
      vault: vault,
      now: () => now,
      debounce: const Duration(milliseconds: 1),
    );
    sharing = Sharing(
      api: api,
      vault: vault,
      keyring: keyring,
      notes: notes,
      sync: sync,
    );
  }

  final FakeServer server;
  final String userId;
  final String device;
  late final MemoryStore store;
  late final NotesStore notes;
  late final SyncState state;
  late final FakeApi api;
  late final Vault vault;
  late final SpaceKeyring keyring;
  late final SyncService sync;
  late final Sharing sharing;

  String get email => server.user(userId).email;

  Future<void> boot() async {
    await notes.load();
    state.load();
    await sync.syncNow();
  }

  /// Moves the clock on, so the next write is unambiguously later.
  void tick([int hours = 1]) => now = now.add(Duration(hours: hours));

  List<String> get bodies => notes.notes.map((n) => n.body).toList()..sort();

  Space? spaceNamed(String name) {
    for (final space in sharing.teams) {
      if (space.name == name) return space;
    }
    return null;
  }

  void dispose() {
    sharing.dispose();
    sync.dispose();
  }
}

void main() {
  late FakeServer server;
  late Person alice;
  late Person bob;

  setUp(() async {
    now = DateTime.utc(2026, 9, 1);
    server = FakeServer();
    alice = Person(server, userId: 'user-1', device: 'alice-mac');
    bob = Person(server, userId: 'user-2', device: 'bob-phone');
    await alice.boot();
    await bob.boot();
  });

  tearDown(() {
    alice.dispose();
    bob.dispose();
  });

  /// Alice shares a note with Bob and Bob accepts; the grant needs one more
  /// pass from somebody who holds the key.
  Future<Note> shareWithBob(String body) async {
    final note = alice.notes.create(body: body);
    await alice.sync.syncNow();
    alice.tick();
    await alice.sharing.shareNoteWith(note.id, email: bob.email);

    final invite = server.outbox.last;
    expect(invite.to, bob.email);
    await bob.sharing.acceptInvite(invite.token);
    await alice.sync.syncNow(); // grants
    await bob.sync.syncNow(); // pulls
    return note;
  }

  group('first sync', () {
    test('publishes identity keys and learns the personal space', () async {
      final bundle = server.user(alice.userId).bundle!;
      expect(bundle.identity, isNotNull);
      expect(alice.keyring.identity, isNotNull);
      expect(alice.keyring.personal, isNotNull);
      expect(alice.state.personalSpaceId, alice.keyring.personal!.id);
      // The server never sees a private half in the clear.
      expect(
        bundle.identity!.x25519Wrapped.cipherText,
        isNot(alice.keyring.identity!.x25519Private),
      );
    });

    test('a cursor from before spaces becomes the personal space\'s', () async {
      final store = MemoryStore();
      store.data['sync.v1'] = {'cursor': 'legacy-cursor', 'accountId': 'user-1'};
      final state = SyncState(store)..load();
      expect(state.cursorFor('anything'), isNull);
      state.adoptPersonalSpace('personal-user-1');
      expect(state.cursorFor('personal-user-1'), 'legacy-cursor');
      expect(state.cursorFor('other'), isNull);
    });
  });

  group('sharing a note with a person', () {
    test('invites them, grants the key on the next pass, and delivers the note', () async {
      final note = alice.notes.create(body: 'Groceries: milk 2.40');
      await alice.sync.syncNow();
      alice.tick();

      final space = await alice.sharing.shareNoteWith(
        note.id,
        email: bob.email,
      );
      expect(space.isTeam, isTrue);
      expect(space.name, 'With user-2');
      expect(space.invites.single.email, bob.email);
      expect(alice.notes.byId(note.id)!.spaceId, space.id);
      expect(alice.notes.byId(note.id)!.contentKey, isNotNull);
      // The move went up as a tombstone at home and a live note in the space.
      expect(server.rowsIn(alice.keyring.personal!.id)[note.id]!.isTombstone, isTrue);
      expect(server.rowsIn(space.id)[note.id]!.isTombstone, isFalse);
      // And the server holds the text under a key it does not have.
      final stored = server.rowsIn(space.id)[note.id]!;
      expect(String.fromCharCodes(stored.payload!.cipherText), isNot(contains('milk')));

      // Bob sees the invitation, addressed to him.
      await bob.sync.syncNow();
      expect(bob.sharing.invites.single.spaceName, 'With user-2');
      expect(bob.sharing.invites.single.invitedBy, alice.email);

      await bob.sharing.acceptInvite(bob.sharing.invites.single.token);
      await bob.sync.syncNow();
      // Member, no key, nothing readable yet.
      final asBob = bob.sharing.spaceById(space.id)!;
      expect(asBob.role, SpaceRole.member);
      expect(asBob.hasKey, isFalse);
      expect(bob.notes.notes, isEmpty);

      // Alice's next pass grants; Bob's next pass reads.
      await alice.sync.syncNow();
      expect(server.calls, contains('grant:user-2'));
      await bob.sync.syncNow();
      expect(bob.bodies, ['Groceries: milk 2.40']);
      final theirs = bob.notes.notes.single;
      expect(theirs.spaceId, space.id);
      expect(theirs.contentKey, alice.notes.byId(note.id)!.contentKey);
      expect(theirs.isDirty, isFalse);
    });

    test('sharing a second note with the same person reuses the space', () async {
      final first = await shareWithBob('First');
      final second = alice.notes.create(body: 'Second');
      alice.tick();
      final space = await alice.sharing.shareNoteWith(second.id, email: bob.email);
      expect(space.id, alice.notes.byId(first.id)!.spaceId);
      expect(alice.sharing.teams, hasLength(1));
      await bob.sync.syncNow();
      expect(bob.bodies, ['First', 'Second']);
    });

    test('edits flow both ways under the same content key', () async {
      final note = await shareWithBob('Shopping');
      bob.tick(2);
      bob.notes.updateBody(note.id, 'Shopping\nmilk 2.40');
      await bob.sync.syncNow();
      alice.tick(3);
      await alice.sync.syncNow();
      expect(alice.bodies, ['Shopping\nmilk 2.40']);
      expect(alice.notes.notes.single.contentKeyEpoch, 1);

      alice.tick();
      alice.notes.updateBody(note.id, 'Shopping\nmilk 2.40\nbread 1.10');
      await alice.sync.syncNow();
      bob.tick(5);
      await bob.sync.syncNow();
      expect(bob.bodies, ['Shopping\nmilk 2.40\nbread 1.10']);
    });

    test('a note created straight into the space reaches the other member', () async {
      await shareWithBob('Seed');
      final space = bob.sharing.teams.single;
      bob.tick();
      final fresh = bob.sharing.createNoteIn(space.id);
      bob.notes.updateBody(fresh.id, 'Written by Bob');
      await bob.sync.syncNow();
      alice.tick(2);
      await alice.sync.syncNow();
      expect(alice.bodies, ['Seed', 'Written by Bob']);
    });

    test('both editing apart keeps the loser\'s words as a personal copy', () async {
      final note = await shareWithBob('Start');
      alice.tick(1);
      alice.notes.updateBody(note.id, 'Alice version');
      bob.tick(2);
      bob.notes.updateBody(note.id, 'Bob version');

      await bob.sync.syncNow();
      await alice.sync.syncNow();

      expect(alice.bodies, ['Alice version', 'Bob version']);
      final copy = alice.notes.notes.firstWhere((n) => n.body == 'Alice version');
      expect(copy.spaceId, isNull, reason: 'the copy is hers, at home');
      expect(alice.notes.byId(note.id)!.body, 'Bob version');
    });

    test('the sidebar can tell a shared note from a private one', () async {
      final note = await shareWithBob('Shared');
      alice.notes.create(body: 'Private');
      expect(alice.notes.byId(note.id)!.isShared, isTrue);
      expect(alice.notes.notesIn(null).single.body, 'Private');
      expect(alice.sharing.spaceOf(alice.notes.byId(note.id)!)!.name, 'With user-2');
    });
  });

  group('taking a note back', () {
    test('un-sharing moves it home under a new key and out of the space', () async {
      final note = await shareWithBob('Shared then not');
      final oldKey = bob.notes.byId(note.id)!.contentKey;
      bob.tick();
      await bob.sharing.unshareNote(note.id);

      final mine = bob.notes.byId(note.id)!;
      expect(mine.spaceId, isNull);
      expect(mine.contentKey, isNull);
      expect(mine.isDirty, isFalse);
      expect(server.rowsIn(bob.keyring.personal!.id)[note.id]!.isTombstone, isFalse);
      expect(oldKey, isNotNull);

      alice.tick(2);
      await alice.sync.syncNow();
      expect(alice.notes.byId(note.id), isNull, reason: 'gone from the space');
      // The space still stands: two members, even with nothing in it.
      expect(alice.sharing.teams, hasLength(1));
    });

    test('stop sharing brings every note home and ends the space', () async {
      final a = await shareWithBob('One');
      final space = alice.sharing.teams.single;
      bob.tick();
      final b = bob.sharing.createNoteIn(space.id);
      bob.notes.updateBody(b.id, 'Two');
      await bob.sync.syncNow();
      alice.tick(2);
      await alice.sync.syncNow();
      expect(alice.bodies, ['One', 'Two']);

      await alice.sharing.stopSharing(space.id);

      expect(alice.sharing.teams, isEmpty);
      for (final id in [a.id, b.id]) {
        final home = alice.notes.byId(id)!;
        expect(home.spaceId, isNull);
        expect(home.contentKey, isNull);
        expect(home.isDirty, isFalse);
      }
      expect(alice.bodies, ['One', 'Two']);
      expect(server.spaces.containsKey(space.id), isFalse);

      bob.tick(3);
      await bob.sync.syncNow();
      expect(bob.sharing.teams, isEmpty);
      expect(bob.notes.notes, isEmpty, reason: 'nothing of his was unsynced');
    });

    test('the last member leaving leaves the owner owed a trip home, taken on the next sync', () async {
      final note = await shareWithBob('Lonely');
      final space = alice.sharing.teams.single;
      bob.tick();
      await bob.sharing.leave(space.id);
      expect(bob.sharing.teams, isEmpty);

      alice.tick(2);
      await alice.sync.syncNow();
      expect(server.calls, contains('stop'));
      expect(alice.sharing.teams, isEmpty);
      final home = alice.notes.byId(note.id)!;
      expect(home.spaceId, isNull);
      expect(home.body, 'Lonely');
      expect(home.isDirty, isFalse);
    });
  });

  group('removal', () {
    test('cuts the member off, rotates the space key, and rotates the content key on the next write', () async {
      final note = await shareWithBob('Before');
      final space = alice.sharing.teams.single;
      // Carol is in it too, so the space outlives Bob's removal.
      final carol = Person(server, userId: 'user-3', device: 'carol-ipad');
      await carol.boot();
      await alice.sharing.invite(space.id, carol.email);
      await carol.sharing.acceptInvite(server.outbox.last.token);
      await alice.sync.syncNow();
      await carol.sync.syncNow();
      expect(carol.bodies, ['Before']);
      final oldContentKey = alice.notes.byId(note.id)!.contentKey!;

      await alice.sharing.removeMember(space.id, bob.userId);
      // Cut off server-side at once.
      expect(() => bob.api.pull(space: space.id), throwsA(isA<SyncRefusedException>()));

      // Alice's next pass rotates the space key. The content key is not
      // touched by the batch — Bob already had it.
      alice.tick();
      await alice.sync.syncNow();
      expect(server.calls, contains('rotate'));
      final rotated = alice.sharing.spaceById(space.id)!;
      expect(rotated.keyGeneration, 2);
      expect(rotated.rotationPending, isFalse);
      expect(rotated.members.map((m) => m.userId), isNot(contains(bob.userId)));
      expect(alice.notes.byId(note.id)!.contentKey, oldContentKey);

      // The next write seals under a fresh content key, epoch two.
      alice.tick();
      alice.notes.updateBody(note.id, 'After');
      await alice.sync.syncNow();
      final after = alice.notes.byId(note.id)!;
      expect(after.contentKey, isNot(oldContentKey));
      expect(after.contentKeyEpoch, 2);
      expect(after.contentKeyGeneration, 2);
      final stored = server.spaces[space.id]!.noteKeys[note.id]!;
      expect(stored.contentKeyEpoch, 2);
      expect(stored.keyGeneration, 2);

      // Carol, still in, reads it under the new keys.
      carol.tick();
      await carol.sync.syncNow();
      expect(carol.bodies, ['After']);
      expect(carol.notes.byId(note.id)!.contentKey, after.contentKey);

      // Bob's device learns it is out, and lets the note go.
      bob.tick();
      await bob.sync.syncNow();
      expect(bob.sharing.teams, isEmpty);
      expect(bob.notes.notes, isEmpty);
      carol.dispose();
    });

    test('removing the only other member ends the space and brings the note home', () async {
      final note = await shareWithBob('Just us');
      final space = alice.sharing.teams.single;
      await alice.sharing.removeMember(space.id, bob.userId);
      alice.tick();
      await alice.sync.syncNow();
      expect(alice.sharing.teams, isEmpty);
      final home = alice.notes.byId(note.id)!;
      expect(home.spaceId, isNull);
      expect(home.body, 'Just us');
    });

    test('a removed member\'s unsynced edit comes home as their own note', () async {
      final note = await shareWithBob('Ours');
      final space = alice.sharing.teams.single;
      bob.tick();
      bob.notes.updateBody(note.id, 'Ours, with my additions');
      await alice.sharing.removeMember(space.id, bob.userId);

      bob.tick();
      await bob.sync.syncNow();
      expect(bob.notes.notes, hasLength(1));
      final kept = bob.notes.notes.single;
      expect(kept.body, 'Ours, with my additions');
      expect(kept.spaceId, isNull);
      expect(kept.id, isNot(note.id), reason: 'its own note, not the shared one');
      // And it went up to his own account in the same pass.
      expect(kept.isDirty, isFalse);
      expect(server.rowsIn(bob.keyring.personal!.id)[kept.id], isNotNull);
    });

    test('a writer that missed the rotation is refused, refreshes, and succeeds', () async {
      final note = await shareWithBob('Race');
      final space = alice.sharing.teams.single;
      // Carol joins so there is somebody else to rotate.
      final carol = Person(server, userId: 'user-3', device: 'carol-ipad');
      await carol.boot();
      await alice.sharing.invite(space.id, carol.email);
      await carol.sharing.acceptInvite(server.outbox.last.token);
      await alice.sync.syncNow();
      await carol.sync.syncNow();
      expect(carol.bodies, ['Race']);

      // Alice removes Bob, and Carol rotates before Alice writes again.
      await alice.sharing.removeMember(space.id, bob.userId);
      carol.tick();
      await carol.sync.syncNow();
      expect(carol.sharing.spaceById(space.id)!.keyGeneration, 2);

      // Alice still holds generation one. Her write is refused once, she
      // refreshes, and the retry lands under generation two.
      alice.tick(2);
      alice.notes.updateBody(note.id, 'Race, edited by Alice');
      await alice.sync.syncNow();
      expect(alice.sync.status, SyncStatus.idle);
      expect(alice.notes.byId(note.id)!.isDirty, isFalse);
      expect(alice.notes.byId(note.id)!.contentKeyGeneration, 2);

      carol.tick(3);
      await carol.sync.syncNow();
      expect(carol.bodies, ['Race, edited by Alice']);
      carol.dispose();
    });
  });

  group('trust on first use', () {
    test('warns when a member\'s public key changes, until acknowledged', () async {
      await shareWithBob('Watch');
      expect(alice.sharing.trust.hasWarnings, isFalse);

      // The server hands Alice a different key for Bob.
      final replaced = await IdentityKeys.generate();
      final bundle = server.user(bob.userId).bundle!;
      server.user(bob.userId).bundle = KeyBundle(
        wrappedMasterKey: bundle.wrappedMasterKey,
        kdf: bundle.kdf,
        identity: await replaced.wrapUnder(bob.vault.masterKeyForKeystore),
      );
      await alice.sharing.refresh();

      expect(alice.sharing.trust.hasWarnings, isTrue);
      final warning = alice.sharing.trust.warnings.single;
      expect(warning.email, bob.email);
      expect(warning.current, replaced.fingerprint);
      expect(warning.previous, isNot(warning.current));

      // Refreshing again does not stack a second warning.
      await alice.sharing.refresh();
      expect(alice.sharing.trust.warnings, hasLength(1));

      alice.sharing.trustNewKey(warning);
      expect(alice.sharing.trust.hasWarnings, isFalse);
      await alice.sharing.refresh();
      expect(alice.sharing.trust.hasWarnings, isFalse);
    });
  });

  group('protocol', () {
    test('a build the server no longer serves stops and says so', () async {
      alice.notes.create(body: 'Held');
      server.minProtocol = 3;
      await alice.sync.syncNow();
      expect(alice.sync.status, SyncStatus.outdated);
      expect(alice.sync.lastError, contains('update'));
      expect(alice.notes.dirtyNotes, hasLength(1), reason: 'nothing is lost');
      // No retry is scheduled and further requests are not made.
      final before = server.calls.length;
      alice.sync.requestSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.calls.length, before);
    });

    test('a wake-up naming a space reaches only its members', () async {
      await shareWithBob('Ping');
      bob.sync.resume();
      await until(() => server.live.containsKey('bob-phone'));
      final carol = Person(server, userId: 'user-3', device: 'carol-ipad');
      await carol.boot();
      carol.sync.resume();
      await until(() => server.live.containsKey('carol-ipad'));
      final carolCalls = server.calls.where((c) => c == 'spaces').length;

      final space = alice.sharing.teams.single;
      alice.tick();
      final fresh = alice.sharing.createNoteIn(space.id);
      alice.notes.updateBody(fresh.id, 'Pong');
      await alice.sync.syncNow();

      await until(() => bob.bodies.contains('Pong'), reason: 'Bob was not woken');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        server.calls.where((c) => c == 'spaces').length,
        carolCalls + 1 + 1,
        reason: 'Bob refreshed once on his wake; Carol did not',
      );
      carol.dispose();
    });
  });

  group('account deletion', () {
    test('is refused while the caller owns a shared space', () async {
      await shareWithBob('Owned');
      expect(
        () => alice.api.deleteAccount(alice.email),
        throwsA(
          isA<SyncRefusedException>().having((e) => e.code, 'code', 'owned-spaces'),
        ),
      );
      // A member, not an owner, may go — and the space marks a rotation.
      await bob.api.deleteAccount(bob.email);
      alice.tick();
      await alice.sync.syncNow();
      expect(alice.sharing.teams, isEmpty, reason: 'alone, it came home');
    });
  });
}
