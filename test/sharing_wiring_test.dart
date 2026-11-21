import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/settings/sharing_section.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'share_dialog_test.dart' show Device;
import 'sync/fake_server.dart';
import 'sync/sharing_section_test.dart' show namePeople;
import 'test_fonts.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'sharing-wiring-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Tripwires for the sharing entry points in the app itself, not in the
/// widgets alone: each fails if a merge drops the wiring between the notes
/// list and Settings → Sharing, even where the widgets still pass on their own.
void main() {
  late FakeServer server;
  late Device priya;
  late _Store store;
  late NotesStore notes;
  late Account account;
  late LayoutPrefs prefs;
  late RatesRepository rates;
  late ShortcutPrefs shortcuts;

  setUpAll(loadTestFonts);

  setUp(() {
    server = FakeServer();
    namePeople(server);
    priya = Device(server, userId: 'user-2', device: 'priya');
    store = _Store();
    notes = NotesStore(store);
    final state = SyncState(store);
    final sam = server.user('user-1');
    account = Account(
      auth: FakeAuth(id: 'user-1', email: sam.email, name: sam.name),
      syncApi: (_) =>
          FakeApi(server, device: 'device-user-1', userId: 'user-1'),
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
    );
    prefs = LayoutPrefs(store);
    rates = RatesRepository(store);
    shortcuts = ShortcutPrefs(store);
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  });

  tearDown(() {
    account.dispose();
    priya.dispose();
  });

  Future<void> signIn(WidgetTester tester) => tester.runAsync(() async {
    await notes.load();
    await account.restore();
    await account.signIn(email: 'sam@kapy34.test', password: 'x');
    await account.createPassphrase('a good passphrase');
  });

  /// Sam shares a note of his own with Priya, and she joins.
  Future<String> shareWithPriya(WidgetTester tester) async {
    late String mine;
    await tester.runAsync(() async {
      await priya.boot();
      mine = notes.create(body: 'Trip budget').id;
      notes.create(body: 'Bank details');
      await account.sync!.syncNow();
      await account.sharing!.shareNoteWith(mine, email: priya.email);
      await priya.sharing.acceptInvite(server.outbox.last.token);
      await priya.sync.syncNow();
      await account.sharing!.refresh();
      await account.sync!.syncNow();
    });
    return mine;
  }

  Future<void> pumpApp(WidgetTester tester, {required bool phone}) async {
    AppPlatform.debugTargetPlatformOverride = phone
        ? TargetPlatform.iOS
        : TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = phone
        ? const Size(390, 844)
        : const Size(1100, 760);
    addTearDown(tester.view.reset);
    prefs.load();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    shortcuts.load();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: rates,
        prefs: prefs,
        shortcuts: shortcuts,
        account: account,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A phone opens on a note's page, with the list under it; beside a
  /// window the list is already there.
  Future<void> showList(WidgetTester tester, {required bool phone}) async {
    final back = find.byKey(const ValueKey('page-back'));
    if (phone && back.evaluate().isNotEmpty) {
      await tester.tap(back);
      await tester.pumpAndSettle();
    }
    expect(find.byType(Sidebar), findsOneWidget);
  }

  /// Beside a window the rail switches between My notes and Shared; on a
  /// phone the bar along the bottom does.
  Future<void> openTab(
    WidgetTester tester,
    SidebarTab tab, {
    required bool phone,
  }) async {
    final key = phone
        ? 'bar-${tab == SidebarTab.mine ? 'notes' : 'shared'}'
        : tab == SidebarTab.mine
        ? 'rail-notes'
        : 'rail-shared';
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  bool listed(WidgetTester tester, String title) => find
      .descendant(of: find.byType(Sidebar), matching: find.text(title))
      .evaluate()
      .isNotEmpty;

  for (final phone in [false, true]) {
    final on = phone ? 'on a phone' : 'beside a window';

    testWidgets('a Shared heading opens that person in Settings → Sharing, '
        '$on', (tester) async {
      await signIn(tester);
      await shareWithPriya(tester);
      await pumpApp(tester, phone: phone);
      await showList(tester, phone: phone);
      await openTab(tester, SidebarTab.shared, phone: phone);

      await tester.tap(
        find.byKey(ValueKey('share-group-sharedWith:${priya.email}')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(find.byType(SharingSection), findsOneWidget);
      expect(find.byKey(const ValueKey('person-header')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('person-header')),
          matching: find.textContaining('Priya'),
        ),
        findsWidgets,
      );
    });

    testWidgets('the empty Shared list starts Share with someone in '
        'Settings → Sharing, $on', (tester) async {
      await signIn(tester);
      await tester.runAsync(() async => notes.create(body: 'Just mine'));
      await pumpApp(tester, phone: phone);
      await showList(tester, phone: phone);
      await openTab(tester, SidebarTab.shared, phone: phone);

      await tester.tap(find.text('Share with someone'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(find.byType(SharingSection), findsOneWidget);
      expect(find.byKey(const ValueKey('picker-email')), findsOneWidget);
    });

    testWidgets('a note of your own that you share is in both tabs, and one '
        'you keep to yourself only in My notes, $on', (tester) async {
      await signIn(tester);
      await shareWithPriya(tester);
      await pumpApp(tester, phone: phone);
      await showList(tester, phone: phone);

      await openTab(tester, SidebarTab.mine, phone: phone);
      expect(listed(tester, 'Trip budget'), isTrue);
      expect(listed(tester, 'Bank details'), isTrue);
      await openTab(tester, SidebarTab.shared, phone: phone);
      expect(listed(tester, 'Trip budget'), isTrue);
      expect(listed(tester, 'Bank details'), isFalse);
    });

    testWidgets('Settings → Sharing is reachable from Settings, $on', (
      tester,
    ) async {
      await signIn(tester);
      await pumpApp(tester, phone: phone);
      await showList(tester, phone: phone);
      await tester.tap(
        find.byKey(ValueKey(phone ? 'bar-settings' : 'rail-settings')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);

      final entry = find.byKey(const ValueKey('settings-section-sharing'));
      await tester.ensureVisible(entry.first);
      await tester.tap(entry.first);
      await tester.pumpAndSettle();
      expect(find.byType(SharingSection), findsOneWidget);
      expect(find.byKey(const ValueKey('share-with-someone')), findsOneWidget);
    });
  }

  testWidgets('on a phone, Shared is a page whose arrow goes back to the '
      'notes', (tester) async {
    await signIn(tester);
    await shareWithPriya(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    expect(find.byKey(const ValueKey('shared-page')), findsNothing);

    await openTab(tester, SidebarTab.shared, phone: true);
    expect(find.byKey(const ValueKey('shared-page')), findsOneWidget);
    expect(find.text('Search shared notes'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('page-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-page')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('phone-list-title'))).data,
      'Notes',
    );
  });
}
