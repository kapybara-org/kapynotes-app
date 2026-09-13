import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_rows.dart';

import '../sync/fake_server.dart';
import 'billing_fakes.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'settings-pro-row-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// Settings on Plan & usage, for an account that signed in with billing
/// already following it — the order `main` wires them in.
Future<Account> pumpSettings(
  WidgetTester tester, {
  required FakePurchaseStore purchases,
  Entitlements Function()? answer,
}) async {
  tester.view.physicalSize = const Size(880, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final server = FakeServer();
  final store = _Store();
  final notes = NotesStore(store);
  final api = FakeBillingApi();
  if (answer != null) api.answer = answer;
  final account = Account(
    auth: FakeAuth(
      id: 'user-1',
      email: server.user('user-1').email,
      name: server.user('user-1').name,
      image: server.user('user-1').image,
    ),
    syncApi: (_) => FakeApi(server, device: 'device-1', userId: 'user-1'),
    keys: KeyStore(InMemorySecureStore()),
    notes: notes,
    state: SyncState(store),
    store: store,
    docStorage: MemoryDocStorage(),
  );
  account.billing = Billing(
    session: account,
    userId: () => account.user?.id,
    token: () => account.token,
    api: (_) => api,
    store: purchases,
    cache: store,
  );
  addTearDown(account.dispose);
  await tester.runAsync(() async {
    await notes.load();
    await account.restore();
    await account.signIn(email: 'a@b.co', password: 'x');
    await account.createPassphrase('a good passphrase');
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: SettingsDialog(
          layoutPrefs: LayoutPrefs(store)..load(),
          shortcuts: ShortcutPrefs(store)..load(),
          rates: RatesRepository(store),
          notes: notes,
          account: account,
          section: SettingsSection.plan,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return account;
}

void main() {
  testWidgets('Plan & usage shows the current plan and opens its details', (
    tester,
  ) async {
    final purchases = FakePurchaseStore();
    await pumpSettings(tester, purchases: purchases);

    expect(find.text('Plan & usage'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-current')), findsOneWidget);
    expect(find.text('Free plan'), findsOneWidget);
    expect(
      find.text('Your current plan and included cloud allowances'),
      findsOneWidget,
    );
    // The store was told whose purchases these will be as soon as the
    // account signed in, not at the moment of buying.
    expect(purchases.log, contains('logIn user-1'));

    await tester.tap(find.byKey(const ValueKey('plan-current')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pro-buy')), findsOneWidget);
  });

  testWidgets('a trial says how long is left, right in the row', (
    tester,
  ) async {
    final account = await pumpSettings(
      tester,
      purchases: FakePurchaseStore(),
      answer: () => trialFor(const Duration(days: 8, hours: 3)),
    );

    expect(find.text('Pro trial'), findsOneWidget);
    expect(find.text('Your Pro trial has 9 days left'), findsOneWidget);

    // Cancel the real trial-end timer before Flutter checks for leaked timers.
    final billing = account.billing;
    account.billing = null;
    billing?.dispose();
  });

  testWidgets(
    'a build with nothing to sell still explains its plan and limits',
    (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpSettings(
        tester,
        purchases: FakePurchaseStore(supported: false),
      );

      expect(find.byKey(const ValueKey('plan-current')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('plan-transcription-usage')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('plan-summary-usage')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-storage-usage')), findsOneWidget);
      // It explains usage without offering a purchase this build cannot make.
      expect(
        tester
            .widget<SettingsRow>(find.byKey(const ValueKey('plan-current')))
            .onTap,
        isNull,
      );
    },
  );

  testWidgets('a desktop build can sell through secure web checkout', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpSettings(tester, purchases: FakePurchaseStore(supported: false));

    expect(find.byKey(const ValueKey('plan-current')), findsOneWidget);
    expect(
      tester
          .widget<SettingsRow>(find.byKey(const ValueKey('plan-current')))
          .onTap,
      isNotNull,
    );
  });
}
