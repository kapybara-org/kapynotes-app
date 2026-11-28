import 'dart:io';

import 'package:flutter/rendering.dart';
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
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/control_surface.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:kapy_notes/ui/settings_search.dart';

import '../support/store_updates.dart';
import '../test_fonts.dart';
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
/// the only state where both halves of an account have anything to show —
/// and invited into a space by each of [invitedBy].
Future<void> pumpSettings(
  WidgetTester tester, {
  required Size size,
  required bool asSheet,
  SettingsSection? section,
  Entitlements? entitlements,
  bool withCloudAccess = false,
  List<String> invitedBy = const [],
  bool increaseContrast = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final server = FakeServer();
  for (final name in invitedBy) {
    final owner = server.user('user-$name')..name = name;
    server.spaces['space-$name'] =
        FakeSpace(
            id: 'space-$name',
            kind: SpaceKind.team,
            name: '$name’s notes',
            ownerId: owner.id,
          )
          ..members[owner.id] = SpaceRole.owner
          ..invites['invite-$name'] = (
            email: server.user('user-1').email,
            role: SpaceRole.member,
          );
  }
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
    if (invitedBy.isNotEmpty) await account.sharing!.refresh();
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
      theme: KapyTheme.dark(increaseContrast: increaseContrast),
      home: Scaffold(
        body: SettingsDialog(
          layoutPrefs: LayoutPrefs(store)..load(),
          shortcuts: ShortcutPrefs(store)..load(),
          rates: RatesRepository(store),
          notes: notes,
          account: account,
          storeUpdates: AppPlatform.isMobile ? fakeStoreUpdates(store) : null,
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

  testWidgets('sharing is its own category, after Account & sync', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      size: const Size(1000, 800),
      asSheet: false,
      section: SettingsSection.account,
    );

    final account = find.byKey(const ValueKey('settings-section-account'));
    final sharing = find.byKey(const ValueKey('settings-section-sharing'));
    final about = find.byKey(const ValueKey('settings-section-about'));
    expect(account, findsOneWidget);
    expect(sharing, findsOneWidget);
    expect(
      tester.getTopLeft(sharing).dy,
      greaterThan(tester.getTopLeft(account).dy),
    );
    if (about.evaluate().isNotEmpty) {
      expect(
        tester.getTopLeft(about).dy,
        greaterThan(tester.getTopLeft(sharing).dy),
      );
    }

    // Account & sync keeps the account, and nothing of sharing.
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.byKey(const ValueKey('join-row')), findsNothing);
    expect(find.byKey(const ValueKey('sharing-people')), findsNothing);

    await tester.tap(sharing);
    await tester.pumpAndSettle();
    expect(find.text('Sharing'), findsWidgets);
    expect(find.byKey(const ValueKey('sharing-people')), findsOneWidget);
    expect(find.byKey(const ValueKey('join-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('blocked-people')), findsOneWidget);
  });

  testWidgets('a search for a sharing row lands in Sharing', (tester) async {
    await pumpSettings(
      tester,
      size: const Size(1000, 800),
      asSheet: false,
      section: SettingsSection.account,
    );

    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'unblock',
    );
    await tester.pumpAndSettle();
    final result = find.byKey(
      const ValueKey('settings-search-result-blocked-people'),
    );
    expect(result, findsOneWidget);
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('blocked-people')), findsOneWidget);
    expect(find.byKey(const ValueKey('sharing-people')), findsOneWidget);
  });

  testWidgets('Free is told sharing needs Pro before typing anything', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      size: const Size(1000, 800),
      asSheet: false,
      section: SettingsSection.sharing,
      entitlements: _freePlan,
    );

    expect(find.text('Sharing is part of Pro'), findsOneWidget);
    final share = tester.widget<TextButton>(
      find.descendant(
        of: find.byKey(const ValueKey('share-with-someone')),
        matching: find.byType(TextButton),
      ),
    );
    expect(share.onPressed, isNull);
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

  testWidgets('the phone list opens Sharing on its own', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    await pumpSettings(tester, size: const Size(390, 844), asSheet: true);

    final sharing = find.byKey(const ValueKey('settings-section-sharing'));
    expect(sharing, findsOneWidget);
    expect(
      tester.getTopLeft(sharing).dy,
      greaterThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('settings-section-account')))
            .dy,
      ),
    );

    await tester.tap(sharing);
    await tester.pumpAndSettle();

    expect(find.text('People'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-with-someone')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('join-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('join-code')), findsOneWidget);
  });

  // The crisp boards draw Settings' filled cards, search field and segment
  // tracks with no edge. Increase contrast gives each its border back, and
  // rings the chosen theme card in the accent.
  for (final increaseContrast in const [false, true]) {
    testWidgets('Appearance with Increase contrast '
        '${increaseContrast ? 'on' : 'off'}', (tester) async {
      await pumpSettings(
        tester,
        size: const Size(1440, 900),
        asSheet: false,
        section: SettingsSection.appearance,
        increaseContrast: increaseContrast,
      );
      final palette = tester.element(find.byType(SettingsDialog)).palette;
      final edge = increaseContrast
          ? palette.controlBorder
          : const Color(0x00000000);

      final groups = tester.widgetList<KapyControlSurface>(
        find.descendant(
          of: find.byType(SettingsGroup),
          matching: find.byType(KapyControlSurface),
        ),
      );
      expect(groups, isNotEmpty);
      expect(groups.map((group) => group.borderColor), everyElement(edge));

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(SettingsSearchField),
          matching: find.byType(TextField),
        ),
      );
      expect(field.decoration!.enabledBorder!.borderSide.color, edge);

      final track = tester.widget<Container>(
        find
            .descendant(
              of: find.byWidgetPredicate((w) => w is SettingsSegmented).first,
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (track.decoration! as BoxDecoration).border,
        increaseContrast ? Border.all(color: edge) : isNull,
      );

      BoxDecoration ring(String theme) {
        final mark = tester.widget<Container>(
          find
              .descendant(
                of: find.byKey(ValueKey('theme-$theme')),
                matching: find.byType(Container),
              )
              .first,
        );
        return mark.decoration! as BoxDecoration;
      }

      expect(ring('riverbank').border!.top.color, palette.accent);
      expect(ring('graphite').border!.top.color, Colors.transparent);
    });
  }

  group('in the app\'s own fonts', () {
    setUpAll(loadTestFonts);

    // iOS's accessibility sizes, at twice the text and past it: the phone's
    // list grows rather than clipping, every name stays whole (at 2.35×
    // About & updates takes two lines), and a value too wide to sit beside
    // its name drops under it, inside its own row, and wraps when it is
    // wider than the row.
    for (final scale in const [2.0, 2.35]) {
      testWidgets('the phone list grows with text at ${scale}x', (
        tester,
      ) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await pumpSettings(
          tester,
          size: const Size(390, 844),
          asSheet: true,
          invitedBy: const ['Priya', 'Arjun'],
        );

        expect(tester.takeException(), isNull);
        for (final name in [
          'Sharing',
          'Notes',
          'Appearance',
          'Voice & AI',
          'About & updates',
        ]) {
          final label = tester.renderObject<RenderParagraph>(find.text(name));
          expect(
            label.didExceedMaxLines,
            isFalse,
            reason: '$name is cut short',
          );
          expect(
            label.size.width,
            greaterThanOrEqualTo(label.getMinIntrinsicWidth(double.infinity)),
            reason: '$name breaks inside a word',
          );
        }
        final sharing = find.byKey(const ValueKey('settings-section-sharing'));
        final waiting = find.descendant(
          of: sharing,
          matching: find.text('2 invitations waiting'),
        );
        expect(waiting, findsOneWidget);
        expect(
          tester.getTopLeft(waiting).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(find.text('Sharing')).dy),
        );
        expect(
          tester.getBottomLeft(waiting).dy,
          lessThanOrEqualTo(tester.getBottomLeft(sharing).dy),
        );
        expect(tester.getSize(sharing).height, greaterThan(48));
        expect(
          tester
              .getSize(find.byKey(const ValueKey('settings-section-account')))
              .height,
          greaterThan(64),
        );
      });
    }

    // Android's Large text and iOS's largest on a 360 pt phone: the longest
    // titles take a second line, and the bar grows to hold it.
    for (final scale in const [1.3, 2.35]) {
      testWidgets("a category's title stays whole at ${scale}x on a narrow "
          'phone', (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpSettings(tester, size: const Size(360, 780), asSheet: true);

        for (final section in [
          SettingsSection.about,
          SettingsSection.account,
        ]) {
          await tester.tap(
            find.byKey(ValueKey('settings-section-${section.name}')),
          );
          await tester.pumpAndSettle();
          final title = tester.renderObject<RenderParagraph>(
            find.text(section.label),
          );
          expect(title.didExceedMaxLines, isFalse, reason: section.label);
          expect(
            title.size.height,
            greaterThanOrEqualTo(title.textSize.height),
            reason: '${section.label} is clipped by its bar',
          );
          await tester.tap(find.byKey(const ValueKey('settings-sheet-back')));
          await tester.pumpAndSettle();
        }
      });
    }
  });
}
