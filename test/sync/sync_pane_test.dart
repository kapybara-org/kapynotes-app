import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/account/sync_pane.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'sync-pane-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

({Account account, NotesStore notes, FakeServer server}) build() {
  final server = FakeServer();
  final store = MemoryStore();
  final notes = NotesStore(store);
  return (
    account: Account(
      auth: FakeAuth(),
      syncApi: (_) => FakeApi(server),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: SyncState(store),
    ),
    notes: notes,
    server: server,
  );
}

Widget harness(Account account) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: SingleChildScrollView(child: SyncPane(account: account)),
  ),
);

void main() {
  testWidgets('a signed-out account is offered a way in', (tester) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('Create an account'), findsOneWidget);
    app.account.dispose();
  });

  testWidgets('signing in with no key asks for a passphrase', (tester) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    expect(find.text('Choose an encryption passphrase'), findsOneWidget);
    // The promise the screen has to make, in the place it has to make it.
    expect(find.textContaining('nobody'), findsOneWidget);
    app.account.dispose();
  });

  testWidgets('the recovery key cannot be skipped past', (tester) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'a good passphrase');
    await tester.enterText(find.byType(TextField).last, 'a good passphrase');

    // Argon2id runs in a real isolate, which the fake clock inside
    // testWidgets cannot advance. runAsync hands back the real one.
    await tester.runAsync(() async {
      await tester.tap(find.text('Set passphrase'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    expect(find.text('Save your recovery key'), findsOneWidget);

    // Done stays dead until the box is ticked.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
          .onPressed,
      isNull,
      reason: 'not until they say they have saved it',
    );

    // And tapping outside must not dismiss it either.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Save your recovery key'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Save your recovery key'), findsNothing);
    app.account.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a locked device offers both ways back in', (tester) async {
    final first = build();
    late Account second;
    late NotesStore notes;

    await tester.runAsync(() async {
      await first.notes.load();
      await first.account.restore();
      await first.account.signIn(email: 'a@b.co', password: 'x');
      await first.account.createPassphrase('a good passphrase');
      first.account.dispose();

      // A second device against the same server: bundle published, key absent.
      final store = MemoryStore();
      notes = NotesStore(store);
      await notes.load();
      second = Account(
        auth: FakeAuth(),
        syncApi: (_) => FakeApi(first.server),
        keys: KeyStore(InMemorySecureStore()),
        notes: notes,
        state: SyncState(store),
      );
      await second.restore();
      await second.signIn(email: 'a@b.co', password: 'x');
    });

    await tester.pumpWidget(harness(second));
    await tester.pumpAndSettle();

    expect(find.text('Unlock your notes'), findsOneWidget);
    expect(find.text('Use my recovery key'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.runAsync(() async {
      await tester.tap(find.text('Unlock'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('does not open'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'a good passphrase');
    await tester.runAsync(() async {
      await tester.tap(find.text('Unlock'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    expect(find.text('someone@example.com'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    second.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
