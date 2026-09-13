import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/billing/plan_terms.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/account/sync_pane.dart';
import 'package:kapy_notes/ui/safety_dialogs.dart';
import 'package:material_ui/material_ui.dart';

import '../sync/fake_server.dart';
import 'billing_fakes.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'pro-states-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

class _TermsApi implements PlanTermsApi {
  _TermsApi(this.enforced);
  final bool enforced;
  @override
  Future<PlanTermsAnswer> fetch() async =>
      PlanTermsAnswer(enforced: enforced, trialDays: 14, freeNoteLimit: 5);
}

void main() {
  late FakeServer server;
  late _MemoryStore store;
  late NotesStore notes;
  late Account account;
  late FakeBillingApi billingApi;

  void build({bool enforced = true, bool sells = true}) {
    server = FakeServer();
    store = _MemoryStore();
    notes = NotesStore(store);
    account = Account(
      auth: FakeAuth(),
      syncApi: (_) => FakeApi(server, device: 'device-1'),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: SyncState(store),
      store: store,
      docStorage: MemoryDocStorage(),
    );
    billingApi = FakeBillingApi();
    account.billing = Billing(
      session: account,
      userId: () => account.user?.id,
      token: () => account.token,
      api: (_) => billingApi,
      store: FakePurchaseStore(supported: sells),
    );
    account.planTerms = PlanTerms(store: store, api: _TermsApi(enforced));
  }

  Future<void> pumpPane(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(account.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(child: SyncPane(account: account)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester) => tester.runAsync(() async {
    await notes.load();
    await account.restore();
    await account.signIn(email: 'a@b.co', password: 'x');
    await account.createPassphrase('a good passphrase');
    await account.billing!.refresh();
  });

  testWidgets('a new account hears the trial, what stops, and the price first', (
    tester,
  ) async {
    build();
    await tester.runAsync(() async {
      await notes.load();
      await account.restore();
    });
    await pumpPane(tester);
    await tester.runAsync(() => account.planTerms!.refreshIfStale());
    await tester.pump();

    final notice = find.byKey(const ValueKey('trial-notice'));
    expect(notice, findsOneWidget);
    expect(find.textContaining('14 days of Pro, free'), findsOneWidget);
    expect(find.textContaining('sync and sharing stop'), findsOneWidget);
    expect(find.textContaining(proLifetimeUsPrice), findsOneWidget);
  });

  testWidgets('before launch it promises no trial, because there is none', (
    tester,
  ) async {
    build(enforced: false);
    await tester.runAsync(() async {
      await notes.load();
      await account.restore();
      await account.planTerms!.refreshIfStale();
    });
    await pumpPane(tester);

    expect(find.byKey(const ValueKey('trial-notice')), findsNothing);
  });

  testWidgets('a trial says when it ends and what happens, on any build', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    build(sells: false);
    billingApi.answer = () => trialFor(const Duration(days: 3, hours: 2));
    await signIn(tester);
    await pumpPane(tester);

    expect(find.byKey(const ValueKey('sync-trial')), findsOneWidget);
    expect(find.textContaining('ends in 4 days'), findsOneWidget);
    // Nothing to sell here, so nothing pretends to.
    expect(find.byKey(const ValueKey('sync-get-pro')), findsNothing);
  });

  testWidgets('own notes held back for Pro say so, with the way to it', (
    tester,
  ) async {
    build();
    billingApi.answer = afterTrial;
    await signIn(tester);
    await tester.runAsync(() async {
      server.needsPro.add(server.personal('user-1').id);
      await account.sync!.syncNow();
      await settle(server);
    });
    await pumpPane(tester);

    expect(account.sync!.personalNeedsPro, isTrue);
    expect(find.textContaining('Sync is part of Pro'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-get-pro')), findsOneWidget);
  });

  test('starting to share on Free says what it needs', () {
    expect(
      describeSharingError(
        const SyncRefusedException(402, proRequiredCode, {}),
      ),
      'Sharing is part of Pro.',
    );
  });
}
