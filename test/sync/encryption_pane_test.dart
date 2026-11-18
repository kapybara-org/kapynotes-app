import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/account/encryption_pane.dart';
import 'package:kapy_notes/ui/account/sync_pane.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_server.dart';
import '../test_fonts.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'encryption-pane-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

Account device(FakeServer server, {String? name = 'Sanjay’s MacBook'}) {
  final store = _Store();
  final notes = NotesStore(store);
  final state = SyncState(store);
  return Account(
    auth: FakeAuth(),
    syncApi: (_) => FakeApi(server)..keyGeneration = () => state.keyGeneration,
    keys: KeyStore(InMemorySecureStore()),
    notes: notes,
    state: state,
    store: store,
    tags: TagStore(store),
    tasks: TaskLibrary(
      notes: notes,
      store: store,
      state: state,
      storage: MemoryDocStorage(),
    ),
  )..deviceName = (_) async => name;
}

/// An account unlocked on this device, made in real time: Argon2id runs in
/// an isolate, which a widget test's clock cannot advance.
Future<Account> unlocked(
  WidgetTester tester,
  FakeServer server, {
  bool withRecoveryKey = true,
}) async {
  final account = device(server);
  await tester.runAsync(() async {
    await account.restore();
    await account.signIn(email: 'a@b.co', password: 'x');
    await account.createPassphrase('first passphrase');
    if (!withRecoveryKey) {
      final user = server.user('user-1');
      final bundle = user.bundle!;
      user.bundle = KeyBundle(
        wrappedMasterKey: bundle.wrappedMasterKey,
        kdf: bundle.kdf,
        identity: bundle.identity,
      );
      await account.signOut();
      await account.signIn(email: 'a@b.co', password: 'x');
      await account.unlock('first passphrase');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  return account;
}

Widget pane(Account account, {bool dark = true}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: dark ? KapyTheme.dark() : KapyTheme.light(),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: SyncPane(
        account: account,
        passphraseGenerator: () => 'HKX2-NSKH-RCRJ-9DMS-YF0Y-BT30-CG',
      ),
    ),
  ),
);

Future<void> size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> openFromSettings(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> enterCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const ValueKey('key-change-code')), code);
  await tester.tap(find.byKey(const ValueKey('key-change-confirm-code')));
  await tester.pumpAndSettle();
}

/// Taps [finder] and lets whatever it starts finish in real time.
Future<void> tapAndFinish(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

Finder byKey(String key) => find.byKey(ValueKey(key));

void main() {
  setUpAll(loadTestFonts);

  testWidgets('changing the passphrase says what changes, checks it is the '
      'owner, and never asks for the old one', (tester) async {
    await size(tester, const Size(640, 900));
    final server = FakeServer();
    final account = await unlocked(tester, server);
    await tester.pumpWidget(pane(account));
    await tester.pumpAndSettle();

    expect(find.text('Encryption'), findsOneWidget);
    await openFromSettings(tester, 'change-passphrase');
    expect(find.text('Change your passphrase'), findsOneWidget);
    expect(
      find.text("To check it's you, we'll email a code to s•••@example.com."),
      findsOneWidget,
    );
    expect(find.textContaining('old passphrase'), findsNothing);

    await tester.tap(byKey('key-change-continue'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the code'), findsOneWidget);

    await enterCode(tester, '000000');
    expect(
      find.text(
        "That code doesn't match. Check the latest email from Kapy Notes.",
      ),
      findsOneWidget,
    );
    await enterCode(tester, '123456');
    expect(find.text('Save your new passphrase'), findsOneWidget);
    expect(find.text('HKX2-NSKH-RCRJ-9DMS-YF0Y-BT30-CG'), findsOneWidget);

    await tapAndFinish(tester, byKey('confirm-new-passphrase'));
    expect(find.text('Save your new passphrase'), findsNothing);
    expect(server.user('user-1').bundle!.version, 2);
    expect(
      find.text('Changed ${changeDate(DateTime.now())} on Sanjay’s MacBook'),
      findsOneWidget,
    );
    account.dispose();
  });

  testWidgets('a new recovery key is shown once and says the old one stops '
      'working', (tester) async {
    await size(tester, const Size(640, 900));
    final server = FakeServer();
    final account = await unlocked(tester, server);
    await tester.pumpWidget(pane(account));
    await tester.pumpAndSettle();

    await openFromSettings(tester, 'recovery-key');
    expect(find.text('Make a new recovery key?'), findsOneWidget);
    expect(
      find.textContaining('Your current recovery key will stop working.'),
      findsOneWidget,
    );
    await tester.tap(byKey('key-change-continue'));
    await tester.pumpAndSettle();
    await tester.enterText(byKey('key-change-code'), '123456');
    await tapAndFinish(tester, byKey('key-change-confirm-code'));

    expect(find.text('Save your new recovery key'), findsOneWidget);
    expect(
      find.textContaining('Your old recovery key no longer works.'),
      findsOneWidget,
    );
    expect(account.recoveryKeyUnsaved, isTrue);
    await tester.tap(byKey('confirm-recovery-key-saved'));
    await tester.pumpAndSettle();
    expect(account.recoveryKeyUnsaved, isFalse);
    expect(server.user('user-1').bundle!.version, 2);
    account.dispose();
  });

  testWidgets(
    'an older account sets up its first recovery key without a code',
    (tester) async {
      await size(tester, const Size(640, 900));
      final server = FakeServer();
      final account = await unlocked(tester, server, withRecoveryKey: false);
      await tester.pumpWidget(pane(account));
      await tester.pumpAndSettle();

      expect(find.text('Not set up yet'), findsOneWidget);
      expect(find.text('Set up…'), findsOneWidget);
      await openFromSettings(tester, 'recovery-key');
      expect(find.text('Set up a recovery key'), findsOneWidget);
      expect(find.textContaining('email a code'), findsNothing);

      await tapAndFinish(tester, byKey('key-change-continue'));
      expect(find.text('Save your new recovery key'), findsOneWidget);
      expect(find.textContaining('no longer works'), findsNothing);
      expect(server.user('user-1').codes, isEmpty);
      await tester.tap(byKey('confirm-recovery-key-saved'));
      await tester.pumpAndSettle();
      expect(find.text('Not set up yet'), findsNothing);
      account.dispose();
    },
  );

  testWidgets('a recovery key made elsewhere a moment before is said calmly', (
    tester,
  ) async {
    await size(tester, const Size(640, 900));
    final server = FakeServer();
    final account = await unlocked(tester, server);
    await tester.pumpWidget(pane(account));
    await tester.pumpAndSettle();

    server.beforeKeyChange = (user) {
      final b = user.bundle!;
      user.bundle = KeyBundle(
        wrappedMasterKey: b.wrappedMasterKey,
        kdf: b.kdf,
        recoveryWrappedMasterKey: b.wrappedMasterKey,
        identity: b.identity,
        version: b.version + 1,
        changes: KeyChanges(
          recoveryKey: KeyChange(at: DateTime.now(), device: 'Sanjay’s iPhone'),
        ),
      );
    };
    await openFromSettings(tester, 'recovery-key');
    await tester.tap(byKey('key-change-continue'));
    await tester.pumpAndSettle();
    await tester.enterText(byKey('key-change-code'), '123456');
    await tapAndFinish(tester, byKey('key-change-confirm-code'));

    expect(
      find.text(
        'A new recovery key was made on Sanjay’s iPhone a moment ago. Keep '
        "that one. Make another here only if you've lost it.",
      ),
      findsOneWidget,
    );
    expect(find.text('Save your new recovery key'), findsNothing);
    account.dispose();
  });

  testWidgets('a locked device says the passphrase changed, and where', (
    tester,
  ) async {
    await size(tester, const Size(640, 700));
    final server = FakeServer();
    final account = await unlocked(tester, server);
    await tester.runAsync(() async {
      final change = await account.preparePassphrase('second passphrase');
      await account.sendKeyCode(KeyProofAction.passphrase);
      final proof = await account.verifyKeyCode(
        KeyProofAction.passphrase,
        '123456',
      );
      await account.commitKeyChange(change!, proof: proof.proof);
    });

    final other = device(server, name: 'Sanjay’s iPhone');
    await tester.runAsync(() async {
      await other.restore();
      await other.signIn(email: 'a@b.co', password: 'x');
    });
    await tester.pumpWidget(pane(other));
    await tester.pumpAndSettle();
    expect(find.text('Unlock your notes'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'first passphrase');
    await tapAndFinish(tester, find.widgetWithText(FilledButton, 'Unlock'));
    expect(
      find.text(
        "That doesn't match. Your passphrase was changed on "
        '${changeDate(DateTime.now())} from Sanjay’s MacBook. Enter the new '
        'one, or use your recovery key.',
      ),
      findsOneWidget,
    );
    account.dispose();
    other.dispose();
  });

  /// Signed in on a device that never unlocked, holding a note of its own.
  Future<Account> locked(WidgetTester tester, FakeServer server) async {
    final other = device(server, name: 'Office iMac');
    await tester.runAsync(() async {
      await other.restore();
      await other.signIn(email: 'a@b.co', password: 'x');
    });
    return other;
  }

  Future<void> resetFrom(WidgetTester tester, Account account) async {
    await tester.runAsync(() async {
      final prepared = await account.prepareReset('new passphrase');
      await account.sendKeyCode(KeyProofAction.reset);
      final proof = await account.verifyKeyCode(KeyProofAction.reset, '123456');
      await account.commitReset(prepared, proof: proof.proof!);
    });
  }

  testWidgets('a locked device resets only after saying what stays, and '
      'shows the new recovery key once', (tester) async {
    await size(tester, const Size(640, 900));
    final server = FakeServer();
    final account = await unlocked(tester, server);
    final other = await locked(tester, server);
    await tester.pumpWidget(pane(other));
    await tester.pumpAndSettle();

    await openFromSettings(tester, 'reset-encryption');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Try these first'), findsOneWidget);
    expect(
      find.textContaining('Resetting is the last resort.'),
      findsOneWidget,
    );
    await tester.tap(byKey('key-change-continue'));
    await tester.pumpAndSettle();
    expect(find.text('What a reset does'), findsOneWidget);
    expect(find.textContaining('every note stays'), findsOneWidget);
    expect(
      find.textContaining('Your account, plan and purchases'),
      findsOneWidget,
    );
    expect(server.user('user-1').bundle!.generation, 1);

    await tester.tap(byKey('key-change-continue'));
    await tester.pumpAndSettle();
    await enterCode(tester, '123456');
    expect(find.text('Reset encryption'), findsOneWidget);
    await tapAndFinish(tester, find.text('Reset encryption'));
    expect(find.text('Save your new recovery key'), findsOneWidget);
    expect(server.user('user-1').bundle!.generation, 2);
    expect(other.state, AccountState.ready);
    account.dispose();
    other.dispose();
  });

  testWidgets('a device left behind by a reset asks once, calmly, and knows '
      'the old passphrase when it sees it', (tester) async {
    await size(tester, const Size(640, 700));
    final server = FakeServer();
    final account = await unlocked(tester, server);
    final other = await locked(tester, server);
    await resetFrom(tester, other);
    await tester.runAsync(() async {
      await account.sync!.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(account.state, AccountState.keysChanged);
    expect(account.syncStatus, SyncStatus.keysChanged);

    await tester.pumpWidget(pane(account));
    await tester.pumpAndSettle();
    expect(find.text('Enter your new passphrase'), findsOneWidget);
    expect(
      find.textContaining(
        'Encryption was reset on ${changeDate(DateTime.now())} from Office iMac.',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'first passphrase');
    await tapAndFinish(tester, find.widgetWithText(FilledButton, 'Unlock'));
    expect(
      find.text(
        "That's your passphrase from before the reset. Enter the one set on "
        '${changeDate(DateTime.now())}.',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'new passphrase');
    await tapAndFinish(tester, find.widgetWithText(FilledButton, 'Unlock'));
    expect(account.state, AccountState.ready);
    account.dispose();
    other.dispose();
  });

  test('a device that has not synced since a reset says what it needs', () {
    final now = DateTime(2026, 11, 18, 12);
    const release = '1.34.0';
    expect(
      resetDeviceLine(
        ResetDevice(
          lastSeenAt: now.subtract(const Duration(hours: 2)),
          protocol: 6,
        ),
        release,
        now: now,
      ),
      'synced 2 hours ago · needs Kapy Notes 1.34.0 to sync after a reset',
    );
    expect(
      resetDeviceLine(
        ResetDevice(
          lastSeenAt: now.subtract(const Duration(days: 3)),
          protocol: 7,
        ),
        release,
        now: now,
      ),
      'synced 3 days ago',
    );
    expect(
      resetDeviceName(ResetDevice(lastSeenAt: now, platform: 'ios')),
      'An iPhone or iPad',
    );
  });

  for (final dark in [false, true]) {
    final theme = dark ? 'dark' : 'light';
    testWidgets('what a reset does golden $theme', (tester) async {
      await size(tester, const Size(560, 760));
      final server = FakeServer();
      final account = await unlocked(tester, server);
      final other = await locked(tester, server);
      await tester.pumpWidget(pane(other, dark: dark));
      await tester.pumpAndSettle();
      await openFromSettings(tester, 'reset-encryption');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      await tester.tap(byKey('key-change-continue'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(AlertDialog),
        matchesGoldenFile('goldens/reset_explain_$theme.png'),
      );
      account.dispose();
      other.dispose();
    });
  }

  for (final dark in [false, true]) {
    final theme = dark ? 'dark' : 'light';
    testWidgets('encryption settings golden $theme', (tester) async {
      await size(tester, const Size(560, 720));
      final server = FakeServer();
      final account = await unlocked(tester, server, withRecoveryKey: false);
      await tester.pumpWidget(pane(account, dark: dark));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(EncryptionGroup),
        matchesGoldenFile('goldens/encryption_settings_$theme.png'),
      );
      account.dispose();
    });

    testWidgets('change passphrase golden $theme', (tester) async {
      await size(tester, const Size(560, 480));
      final server = FakeServer();
      final account = await unlocked(tester, server);
      await tester.pumpWidget(pane(account, dark: dark));
      await tester.pumpAndSettle();
      await openFromSettings(tester, 'change-passphrase');
      await expectLater(
        find.byType(AlertDialog),
        matchesGoldenFile('goldens/change_passphrase_$theme.png'),
      );
      await tester.tap(byKey('key-change-continue'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(AlertDialog),
        matchesGoldenFile('goldens/key_code_$theme.png'),
      );
      account.dispose();
    });
  }

  testWidgets('a new recovery key fits a phone', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await size(tester, const Size(390, 700));
    final server = FakeServer();
    final account = await unlocked(tester, server);
    await tester.pumpWidget(pane(account, dark: false));
    await tester.pumpAndSettle();
    await openFromSettings(tester, 'recovery-key');
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(AlertDialog),
      matchesGoldenFile('goldens/new_recovery_key_phone_light.png'),
    );
    account.dispose();
  });
}
