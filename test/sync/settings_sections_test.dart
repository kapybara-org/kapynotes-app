import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/billing/billing_api.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/billing/purchase_store.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/cloud_access.dart';
import 'package:kapy_notes/speech/transcriber.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';

import 'fake_server.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'settings-sections-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

class _BillingApi implements BillingApi {
  const _BillingApi(this.answer);

  final Entitlements answer;

  @override
  Future<Entitlements> entitlements() async => answer;

  @override
  Future<AdoptedPurchases> adopt() async => AdoptedPurchases(
    claimed: const [],
    heldByAnother: false,
    entitlements: answer,
  );

  @override
  Future<Uri> webCheckout() async => Uri.parse('https://kapynotes.com/buy');
}

/// A device that can transcribe whatever it is asked to.
class _ReadyDevice implements Transcriber {
  @override
  Future<TranscriberReadiness> readiness() async => TranscriberReadiness.ready;

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async => throw UnimplementedError();
}

/// Settings, opened with an account that has been signed in and unlocked —
/// the only state where both halves of an account have anything to show.
Future<void> pumpSettings(
  WidgetTester tester, {
  required Size size,
  required bool asSheet,
  SettingsSection? section,
  Entitlements? entitlements,
  bool withCloudAccess = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final server = FakeServer();
  final store = _Store();
  final notes = NotesStore(store);
  final syncState = SyncState(store);
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
    state: syncState,
    store: store,
    tags: TagStore(store),
    tasks: TaskLibrary(
      notes: notes,
      store: store,
      state: syncState,
      storage: MemoryDocStorage(),
    ),
  );
  if (entitlements != null) {
    account.billing = Billing(
      session: account,
      userId: () => account.user?.id,
      token: () => account.token,
      api: (_) => _BillingApi(entitlements),
      store: const UnsupportedPurchaseStore(),
      cache: store,
    );
  }
  addTearDown(account.dispose);
  await tester.runAsync(() async {
    await notes.load();
    await account.restore();
    await account.signIn(email: 'a@b.co', password: 'x');
    await account.createPassphrase('a good passphrase');
  });
  final cloudAccess = withCloudAccess
      ? CloudAccess(
          prefs: VoicePrefs(store)..load(),
          device: _ReadyDevice(),
          billing: account.billing,
        )
      : null;
  if (cloudAccess != null) addTearDown(cloudAccess.dispose);

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
          cloudAccess: cloudAccess,
          asSheet: asSheet,
          section: section,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// What the server sends a Free account: 100 MB, fifteen cloud minutes for a
/// language the device cannot transcribe, no cloud summaries, no sync.
const _freePlan = Entitlements(
  plan: 'free',
  storageBytes: 100 * 1024 * 1024,
  storageUsedBytes: 0,
  speechSecondsPerMonth: 15 * 60,
  speechCreditSeconds: 0,
  sync: false,
  sharing: false,
  noteLimit: 20,
);

void main() {
  testWidgets('a free plan shows only the allowance it can use', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      size: const Size(880, 640),
      asSheet: false,
      section: SettingsSection.account,
      entitlements: _freePlan,
      withCloudAccess: true,
    );

    expect(find.text('Free plan'), findsOneWidget);
    expect(
      find.text(
        'Voice notes and summaries run on this device. Cloud transcription '
        'only for languages it has no engine for: 15 min a month. Sync and '
        'shared notes are on Pro.',
      ),
      findsOneWidget,
    );
    // Free runs voice on the device, so its cloud minutes and summaries are
    // nothing it can spend, and are not shown.
    expect(
      find.byKey(const ValueKey('plan-transcription-usage')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('plan-summary-usage')), findsNothing);
    expect(find.text('0 / 100 MB'), findsOneWidget);
  });

  testWidgets('the free line says only what the plan restricts', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      size: const Size(880, 640),
      asSheet: false,
      section: SettingsSection.account,
      entitlements: const Entitlements(
        plan: 'free',
        storageBytes: 100 * 1024 * 1024,
        storageUsedBytes: 0,
        speechSecondsPerMonth: 0,
        speechCreditSeconds: 0,
        sync: true,
        sharing: true,
      ),
    );

    expect(
      find.text('Voice notes and summaries run on this device.'),
      findsOneWidget,
    );
  });

  testWidgets('sharing sits inside Account & sync rather than beside it', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      size: const Size(880, 640),
      asSheet: false,
      section: SettingsSection.account,
    );

    // One account, one category. Sharing stopped being a rail entry of its
    // own: an account is what both halves need, and the pane that asks for
    // one is where the rest of it belongs.
    expect(
      find.byKey(const ValueKey('settings-section-account')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-section-sharing')),
      findsNothing,
    );

    // Both panes are in there, controls and all — not just the heading.
    expect(find.text('Sharing'), findsOneWidget);
    expect(find.byKey(const ValueKey('join-code')), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);

    final delete = find.byKey(const ValueKey('delete-account'));
    expect(delete, findsOneWidget);
    expect(
      tester.getTopLeft(delete).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('join-code'))).dy,
      ),
      reason: 'account deletion belongs at the very bottom of the category',
    );
  });

  testWidgets('searching for a password lands on its row', (tester) async {
    await pumpSettings(
      tester,
      size: const Size(1000, 800),
      asSheet: false,
      section: SettingsSection.account,
    );

    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'password',
    );
    await tester.pumpAndSettle();
    final result = find.byKey(
      const ValueKey('settings-search-result-password-row'),
    );
    expect(result, findsOneWidget);
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('password-row')), findsOneWidget);
  });

  testWidgets('shows the current Pro plan and server usage totals', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      size: const Size(880, 640),
      asSheet: false,
      section: SettingsSection.account,
      entitlements: Entitlements(
        plan: 'pro',
        storageBytes: 1024 * 1024 * 1024,
        storageUsedBytes: 256 * 1024 * 1024,
        speechSecondsPerMonth: 120 * 60,
        speechSecondsUsedThisMonth: 7 * 60 + 30,
        speechCreditSeconds: 10 * 60,
        summaryGenerationsPerMonth: 1000,
        summaryGenerationsUsedThisMonth: 34,
        speechResetsAt: DateTime(2026, 10),
        sync: true,
        sharing: true,
      ),
    );

    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('7.5 / 120 min'), findsOneWidget);
    expect(find.text('Resets on 1 Oct · 10 min extra'), findsOneWidget);
    expect(find.text('34 / 1,000'), findsOneWidget);
    expect(find.text('0.3 / 1 GB'), findsOneWidget);
  });

  testWidgets('the phone list opens sharing through Account & sync', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    await pumpSettings(tester, size: const Size(390, 844), asSheet: true);

    expect(
      find.byKey(const ValueKey('settings-section-sharing')),
      findsNothing,
    );
    expect(find.text('SHARING'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-section-account')));
    await tester.pumpAndSettle();

    expect(find.text('SHARING'), findsOneWidget);
    expect(find.byKey(const ValueKey('join-code')), findsOneWidget);
  });
}
