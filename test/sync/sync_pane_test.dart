import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/file_export.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/text_file_export.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/account/recovery_key_dialog.dart';
import 'package:kapy_notes/ui/account/sync_pane.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_server.dart';
import '../test_fonts.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'sync-pane-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

({Account account, NotesStore notes, FakeServer server}) build({
  FakeAuth? auth,
}) {
  final server = FakeServer();
  final store = MemoryStore();
  final notes = NotesStore(store);
  return (
    account: Account(
      auth: auth ?? FakeAuth(),
      syncApi: (_) => FakeApi(server),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: SyncState(store),
      store: store,
      docStorage: MemoryDocStorage(),
    ),
    notes: notes,
    server: server,
  );
}

Widget harness(Account account, {TextFileSaver? saveTextFile}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: SingleChildScrollView(
      child: SyncPane(account: account, saveTextFile: saveTextFile),
    ),
  ),
);

void main() {
  setUpAll(loadTestFonts);

  testWidgets('a signed-out account is offered a way in', (tester) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    expect(find.text('Email me a code'), findsOneWidget);
    expect(find.text('Use a password'), findsOneWidget);
    app.account.dispose();
  });

  testWidgets('a code is asked for, then exchanged for a session', (
    tester,
  ) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'someone@example.com');
    await tester.tap(find.text('Email me a code'));
    await tester.pumpAndSettle();

    expect(find.textContaining('six-digit code'), findsOneWidget);
    expect(find.text('Send another'), findsOneWidget);

    // "Sign in" is also the panel's title, so aim at the button.
    final signIn = find.widgetWithText(FilledButton, 'Sign in');

    // A wrong code is refused without losing the screen.
    await tester.enterText(find.byType(TextField), '000000');
    await tester.tap(signIn);
    await tester.pumpAndSettle();
    expect(find.textContaining('not right'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(signIn);
    await tester.pumpAndSettle();

    // Signed in, and the app has prepared the passphrase for them.
    expect(find.text('Save your passphrase'), findsOneWidget);
    app.account.dispose();
  });

  testWidgets('a forgotten password is reset with a code, not a link', (
    tester,
  ) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use a password'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'someone@example.com');

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    expect(find.text('Reset your password'), findsOneWidget);
    // The one thing a reset must not be mistaken for.
    expect(find.textContaining('encryption passphrase'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Email me a code'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.enterText(find.byType(TextField).last, 'a new password');
    await tester.tap(find.widgetWithText(FilledButton, 'Set new password'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Password changed'), findsOneWidget);
    app.account.dispose();
  });

  testWidgets('signing in with no key prepares a passphrase', (tester) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    expect(find.text('Save your passphrase'), findsOneWidget);
    expect(find.byKey(const ValueKey('generated-passphrase')), findsOneWidget);
    app.account.dispose();
  });

  testWidgets('a new account must choose its name and can add a photo later', (
    tester,
  ) async {
    final app = build(auth: FakeAuth(name: ''));
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    expect(find.text('What should people call you?'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-avatar')), findsOneWidget);
    expect(find.byKey(const ValueKey('choose-profile-photo')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('profile-name')),
      List.filled(70, 'A').join(),
    );
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('profile-name')),
    );
    expect(field.controller!.text, hasLength(50));

    await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Maya');
    await tester.tap(find.byKey(const ValueKey('save-profile')));
    await tester.pumpAndSettle();

    expect(app.account.user!.name, 'Maya');
    expect(find.text('Save your passphrase'), findsOneWidget);
    app.account.dispose();
  });

  testWidgets('a strong passphrase is ready to save without typing', (
    tester,
  ) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    final value = tester.widget<SelectableText>(
      find.byKey(const ValueKey('generated-passphrase')),
    );
    expect(value.data, isNotEmpty);
    expect(value.data!.length, greaterThan(20));
    expect(find.byKey(const ValueKey('copy-passphrase')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-passphrase')), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, "I've saved my passphrase"),
      findsOneWidget,
    );
    expect(find.text('Set passphrase'), findsNothing);
    expect(find.text('Generate a strong one for me'), findsNothing);
    expect(find.textContaining('no reset link'), findsNothing);

    app.account.dispose();
  });

  testWidgets('generated passphrase desktop golden', (tester) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    tester.view.physicalSize = const Size(520, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: SyncPane(
                account: app.account,
                passphraseGenerator: () => 'HKX2-NSKH-RCRJ-9DMS-YF0Y-BT30-CG',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/passphrase_setup_dark.png'),
    );
    app.account.dispose();
  });

  testWidgets('generated passphrase actions fit a narrow phone', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: SyncPane(
                account: app.account,
                passphraseGenerator: () => 'HKX2-NSKH-RCRJ-9DMS-YF0Y-BT30-CG',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('confirm-passphrase-saved')).hitTestable(),
      findsOneWidget,
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/passphrase_setup_phone_dark.png'),
    );
    app.account.dispose();
  });

  testWidgets('recovery key dialog golden', (tester) async {
    tester.view.physicalSize = const Size(520, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = RecoveryKey(
      Uint8List.fromList(List.generate(32, (index) => index)),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showRecoveryKeyDialog(context, key),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(AlertDialog),
      matchesGoldenFile('goldens/recovery_key_dialog_dark.png'),
    );
  });

  testWidgets('the generated passphrase can be copied in one tap', (
    tester,
  ) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    await tester.pumpWidget(harness(app.account));
    await tester.pumpAndSettle();

    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final passphrase = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('generated-passphrase')),
        )
        .data;
    await tester.tap(find.byKey(const ValueKey('copy-passphrase')));
    await tester.pumpAndSettle();

    expect(clipboard, passphrase);
    expect(find.text('Copied'), findsOneWidget);

    app.account.dispose();
  });

  testWidgets('the generated passphrase downloads as a simple text file', (
    tester,
  ) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    String? savedName;
    String? savedContents;
    await tester.pumpWidget(
      harness(
        app.account,
        saveTextFile:
            ({required String contents, required String suggestedName}) async {
              savedName = suggestedName;
              savedContents = contents;
              return FileExportOutcome.saved;
            },
      ),
    );
    await tester.pumpAndSettle();

    final passphrase = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('generated-passphrase')),
        )
        .data!;
    await tester.tap(find.byKey(const ValueKey('download-passphrase')));
    await tester.pumpAndSettle();

    expect(savedName, 'kapy-notes-passphrase.txt');
    expect(savedContents, '$passphrase\n');
    expect(find.text('Saved'), findsOneWidget);
    app.account.dispose();
  });

  testWidgets('the recovery key cannot be skipped past', (tester) async {
    final app = build();
    await app.notes.load();
    await app.account.restore();
    await app.account.signIn(email: 'a@b.co', password: 'x');
    String? savedName;
    String? savedContents;
    await tester.pumpWidget(
      harness(
        app.account,
        saveTextFile:
            ({required String contents, required String suggestedName}) async {
              savedName = suggestedName;
              savedContents = contents;
              return FileExportOutcome.saved;
            },
      ),
    );
    await tester.pumpAndSettle();

    // Argon2id runs in a real isolate, which the fake clock inside
    // testWidgets cannot advance. runAsync hands back the real one.
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(FilledButton, "I've saved my passphrase"),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    expect(find.text('Save your recovery key'), findsOneWidget);

    final recoveryKey = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('recovery-key-value')),
        )
        .data!;
    await tester.tap(find.byKey(const ValueKey('download-recovery-key')));
    await tester.pumpAndSettle();
    expect(savedName, 'kapy-notes-recovery-key.txt');
    expect(savedContents, '$recoveryKey\n');
    expect(find.text('Saved'), findsOneWidget);

    // Tapping outside must not dismiss it.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Save your recovery key'), findsOneWidget);

    await tester.tap(find.text("I've saved my recovery key"));
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
        store: store,
        docStorage: MemoryDocStorage(),
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

    expect(find.text('Someone'), findsWidgets);
    expect(find.text('Sign out'), findsOneWidget);
    second.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
