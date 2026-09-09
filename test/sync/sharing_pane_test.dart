import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/account/sharing_pane.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'sharing-pane-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

({Account account, NotesStore notes}) build(
  FakeServer server, {
  String userId = 'user-1',
}) {
  final store = MemoryStore();
  final notes = NotesStore(store);
  return (
    account: Account(
      auth: FakeAuth(
        id: userId,
        email: server.user(userId).email,
        name: server.user(userId).name,
        image: server.user(userId).image,
      ),
      syncApi: (_) => FakeApi(server, device: 'device-$userId', userId: userId),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: SyncState(store),
      store: store,
      docStorage: MemoryDocStorage(),
    ),
    notes: notes,
  );
}

Widget harness(Account account) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: SingleChildScrollView(child: SharingPane(account: account)),
  ),
);

void main() {
  testWidgets('a signed-out account is told what sharing needs', (
    tester,
  ) async {
    final server = FakeServer();
    final app = build(server);
    await app.notes.load();
    await app.account.restore();
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    expect(find.text('Sharing'), findsOneWidget);
    expect(find.textContaining('Sign in'), findsOneWidget);
    expect(find.byKey(const ValueKey('join-code')), findsNothing);
    app.account.dispose();
  });

  testWidgets(
    'an invitation can be accepted from the pane, and a link pasted',
    (tester) async {
      final server = FakeServer();
      // Alice, on another device, shares a note with Bob.
      final alice = build(server, userId: 'user-1');
      late String token;
      await tester.runAsync(() async {
        await alice.notes.load();
        await alice.account.restore();
        await alice.account.signIn(email: 'a@b.co', password: 'x');
        await alice.account.createPassphrase('a good passphrase');
        final note = alice.notes.create(body: 'For Bob');
        await alice.account.sync!.syncNow();
        await alice.account.sharing!.shareNoteWith(
          note.id,
          email: server.user('user-2').email,
          role: SpaceRole.viewer,
        );
        token = server.outbox.single.token;
      });

      final bob = build(server, userId: 'user-2');
      await tester.runAsync(() async {
        await bob.notes.load();
        await bob.account.restore();
        await bob.account.signIn(email: 'b@b.co', password: 'x');
        await bob.account.createPassphrase('another good passphrase');
      });
      await tester.pumpWidget(harness(bob.account));
      await tester.pumpAndSettle();

      // The honest sentence about what encrypted means here, and the invite.
      expect(
        find.textContaining('only looks, not one that lies'),
        findsOneWidget,
      );
      expect(find.textContaining('invited you to With user-2'), findsOneWidget);
      expect(find.text('View only access'), findsOneWidget);
      expect(
        find.text('None yet. Share a note with someone to start one.'),
        findsOneWidget,
      );

      // Alice's device is open beside him: her socket hears the acceptance,
      // she grants the key at once, and his socket brings the note. Nobody
      // presses anything.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey('accept-$token')));
        await settle(server);
        await until(
          () => bob.notes.notes.isNotEmpty,
          reason: 'the note never arrived',
        );
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('invited you'), findsNothing);
      expect(find.text('With user-2 · shared with you'), findsOneWidget);
      expect(find.text('View only'), findsOneWidget);
      expect(find.text('Waiting for someone to let you in'), findsNothing);
      expect(find.text(server.user('user-1').name), findsOneWidget);
      expect(bob.notes.notes.single.body, 'For Bob');

      // A pasted link that is not for this account says so, plainly.
      await tester.enterText(
        find.byKey(const ValueKey('join-code')),
        'https://kapynotes.com/join/not-a-real-token',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('join-submit')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('not for this account'), findsOneWidget);

      alice.account.dispose();
      bob.account.dispose();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
