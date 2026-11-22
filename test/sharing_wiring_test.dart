import 'dart:async';

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
import 'package:kapy_notes/sync/spaces.dart';
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

  /// Whether Priya is still in [space] on the server.
  bool priyaIn(String space) =>
      server.spaces[space]?.members.containsKey(priya.userId) ?? false;

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
  /// phone the bar's Notes opens Home, and Home's Shared card opens Shared.
  Future<void> openTab(
    WidgetTester tester,
    SidebarTab tab, {
    required bool phone,
  }) async {
    final key = switch ((phone, tab)) {
      (true, SidebarTab.mine) => 'bar-notes',
      (true, SidebarTab.shared) => 'home-shared-card',
      (false, SidebarTab.mine) => 'rail-notes',
      (false, SidebarTab.shared) => 'rail-shared',
    };
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

  /// Priya shares Packing list with Sam, who can view it.
  Future<String> priyaShares(WidgetTester tester) async {
    late String spaceId;
    await tester.runAsync(() async {
      final packing = priya.notes.create(body: 'Packing list');
      await priya.sync.syncNow();
      final space = await priya.sharing.shareNoteWith(
        packing.id,
        email: server.user('user-1').email,
        role: SpaceRole.viewer,
      );
      spaceId = space.id;
      await account.sharing!.acceptInvite(server.outbox.last.token);
      await priya.sharing.refresh();
      await priya.sync.syncNow();
      await account.sharing!.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await account.sync!.syncNow();
    });
    return spaceId;
  }

  /// Opens Packing list from Shared and comes back to the list, so it is
  /// the note selected behind it.
  Future<void> openPackingAndBack(
    WidgetTester tester, {
    required bool phone,
  }) async {
    await tester.tap(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('Packing list'),
      ),
    );
    await tester.pumpAndSettle();
    await showList(tester, phone: phone);
  }

  for (final block in [false, true]) {
    final what = block ? 'Block' : 'Leave';
    testWidgets('on a phone, Shared stays when $what takes away the note '
        'selected behind it', (tester) async {
      await signIn(tester);
      await shareWithPriya(tester);
      final space = await priyaShares(tester);
      await pumpApp(tester, phone: true);
      await showList(tester, phone: true);
      await openTab(tester, SidebarTab.shared, phone: true);
      await openPackingAndBack(tester, phone: true);
      expect(find.byKey(const ValueKey('shared-page')), findsOneWidget);

      await tester.runAsync(
        () => block
            ? account.sharing!.blockEverywhere(priya.email)
            : account.sharing!.leave(space),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shared-page')), findsOneWidget);
      expect(listed(tester, 'Packing list'), isFalse);
      expect(listed(tester, 'Trip budget'), !block);
      await tester.pump(const Duration(seconds: 2));
    });
  }

  /// Opens Packing list from Shared on a phone, so its page is on screen.
  Future<String> openPackingPage(WidgetTester tester) async {
    await signIn(tester);
    await shareWithPriya(tester);
    final space = await priyaShares(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    await openTab(tester, SidebarTab.shared, phone: true);
    await tester.tap(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('Packing list'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Sidebar), findsNothing);
    return space;
  }

  testWidgets('leaving the app sends a removal still held for Undo', (
    tester,
  ) async {
    await signIn(tester);
    final mine = await shareWithPriya(tester);
    final space = notes.byId(mine)!.spaceId!;
    await pumpApp(tester, phone: true);
    account.sharing!.holdRemoval(mine, priya.email, const Duration(hours: 1));

    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      for (var wait = 0; wait < 100 && priyaIn(space); wait++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(priyaIn(space), isFalse);
    expect(account.sharing!.cancelRemoval(mine, priya.email), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('signing out sends a removal still held for Undo first', (
    tester,
  ) async {
    await signIn(tester);
    final mine = await shareWithPriya(tester);
    final space = notes.byId(mine)!.spaceId!;
    // Someone else stays invited, so the note stays shared.
    await tester.runAsync(
      () => account.sharing!.addPerson(mine, 'ravi@kapy34.test'),
    );
    account.sharing!.holdRemoval(mine, priya.email, const Duration(hours: 1));

    await tester.runAsync(account.signOut);
    expect(account.state, AccountState.signedOut);
    expect(priyaIn(space), isFalse);
  });

  testWidgets('a removal the server never answers does not hold signing out '
      'up', (tester) async {
    await signIn(tester);
    final mine = await shareWithPriya(tester);
    account.sharing!.holdRemoval(mine, priya.email, const Duration(hours: 1));
    server.onRemoval = () => Completer<void>().future;

    final watch = Stopwatch()..start();
    await tester.runAsync(account.signOut);
    expect(account.state, AccountState.signedOut);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  testWidgets('on a phone, Leave without a copy from the open page goes back '
      'to Shared', (tester) async {
    final space = await openPackingPage(tester);

    await tester.runAsync(
      () => account.sharing!.leave(space, keepCopies: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-page')), findsOneWidget);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(listed(tester, 'Packing list'), isFalse);
    // Past the presence HomePage writes for the shared note now selected.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('on a phone, Leave keeping a copy from the open page stays on '
      'the page, showing the copy', (tester) async {
    final space = await openPackingPage(tester);

    await tester.runAsync(() => account.sharing!.leave(space));
    await tester.pumpAndSettle();
    expect(find.byType(Sidebar), findsNothing);
    final shown = notes.byId(prefs.lastOpenedNoteId);
    expect(shown?.body, 'Packing list');
    expect(shown?.isShared, isFalse);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('beside a window, the list follows the selection to My notes '
      'when Leave takes away the shared note it was on', (tester) async {
    await signIn(tester);
    await shareWithPriya(tester);
    final space = await priyaShares(tester);
    await pumpApp(tester, phone: false);
    await openTab(tester, SidebarTab.shared, phone: false);
    await openPackingAndBack(tester, phone: false);
    expect(listed(tester, 'Bank details'), isFalse);

    await tester.runAsync(() => account.sharing!.leave(space));
    await tester.pumpAndSettle();
    expect(listed(tester, 'Bank details'), isTrue);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("Back from Shared comes home to Notes, with Home's cards and "
      'Notes chosen in the bar, on a phone', (tester) async {
    await signIn(tester);
    await shareWithPriya(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    await openTab(tester, SidebarTab.shared, phone: true);
    expect(find.byKey(const ValueKey('home-shared-card')), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-pinned-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-shared-card')), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('bar-notes'))),
      isSemantics(isSelected: true),
    );
    expect(listed(tester, 'Bank details'), isTrue);
  });

  testWidgets('on an iPhone, a swipe in from the left edge takes Shared '
      'back to Home', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await signIn(tester);
    await shareWithPriya(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    await openTab(tester, SidebarTab.shared, phone: true);
    expect(find.byKey(const ValueKey('shared-page')), findsOneWidget);

    await tester.dragFrom(
      Offset(2, tester.getCenter(find.byType(NoteRow).first).dy),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-page')), findsNothing);
    expect(find.byKey(const ValueKey('home-shared-card')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

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
    expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-shared-card')), findsOneWidget);
  });
}
