import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
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
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/notes_list.dart' show NoteCardFace;
import 'package:kapy_notes/ui/phone_home_header.dart';
import 'package:kapy_notes/ui/phone_note_header.dart';
import 'package:kapy_notes/ui/settings/sharing_section.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:material_ui/material_ui.dart';

import 'support/sharing_devices.dart' show Device;
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

  Future<void> pumpApp(
    WidgetTester tester, {
    required bool phone,
    NoteDayStore? days,
  }) async {
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
        days: days,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A phone opens on a note's page, with the list under it, which the
  /// phone's own back returns to; beside a window the list is already there.
  Future<void> showList(WidgetTester tester, {required bool phone}) async {
    if (phone && find.byType(PhoneNoteHeader).evaluate().isNotEmpty) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    expect(find.byType(Sidebar), findsOneWidget);
  }

  /// Beside a window the rail switches between My notes and Shared; on a
  /// phone the bar's Notes opens Home, and Folders' Shared tile opens Shared.
  Future<void> openTab(
    WidgetTester tester,
    SidebarTab tab, {
    required bool phone,
  }) async {
    final keys = switch ((phone, tab)) {
      (true, SidebarTab.mine) => ['bar-notes'],
      (true, SidebarTab.shared) => ['bar-folders', 'folders-shared-tile'],
      (false, SidebarTab.mine) => ['rail-notes'],
      (false, SidebarTab.shared) => ['rail-shared'],
    };
    for (final key in keys) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }
  }

  final sharedTile = find.byKey(const ValueKey('folders-shared-tile'));
  final foldersDot = find.byKey(const ValueKey('bar-folders-dot'));
  bool lit(WidgetTester tester, String key) =>
      'bar-${tester.widget<PhoneSpaces>(find.byType(PhoneSpaces)).tab.name}' ==
      key;

  bool listed(WidgetTester tester, String title) => find
      .descendant(of: find.byType(Sidebar), matching: find.text(title))
      .evaluate()
      .isNotEmpty;

  testWidgets("a phone's Shared is rows between hairlines even with cards "
      'chosen on the Mac', (tester) async {
    await signIn(tester);
    await shareWithPriya(tester);
    prefs.noteCards = true;
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    await openTab(tester, SidebarTab.shared, phone: true);

    final rows = tester.widgetList<NoteRow>(
      find.descendant(of: find.byType(Sidebar), matching: find.byType(NoteRow)),
    );
    expect(rows.map((row) => row.note.title), contains('Trip budget'));
    expect(rows.every((row) => row.style == NoteRowStyle.touch), isTrue);
    expect(find.byType(NoteCardFace), findsNothing);
    final width = tester.getSize(find.byType(Sidebar)).width;
    for (final row in rows) {
      expect(tester.getSize(find.byWidget(row)).width, width, reason: 'a row');
    }
    expect(
      find.descendant(of: find.byType(Sidebar), matching: find.byType(Divider)),
      findsAtLeastNWidgets(rows.length - 1),
    );
  });

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
        find.byKey(ValueKey(phone ? 'phone-account' : 'rail-settings')),
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

  /// Priya shares Packing list with Sam, who hasn't answered: one invitation
  /// waits. Returns its token.
  Future<String> priyaInvites(WidgetTester tester) async {
    late String token;
    await tester.runAsync(() async {
      final packing = priya.notes.create(body: 'Packing list');
      await priya.sync.syncNow();
      await priya.sharing.shareNoteWith(
        packing.id,
        email: server.user('user-1').email,
        role: SpaceRole.viewer,
      );
      token = server.outbox.last.token;
      await account.sharing!.refresh();
    });
    return token;
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
    // Someone else stays invited, so taking Priya off asks the server.
    await tester.runAsync(
      () => account.sharing!.addPerson(mine, 'ravi@kapy34.test'),
    );
    account.sharing!.holdRemoval(mine, priya.email, const Duration(hours: 1));
    var asked = false;
    server.onRemoval = () {
      asked = true;
      return Completer<void>().future;
    };

    final watch = Stopwatch()..start();
    await tester.runAsync(
      () => account.signOut().timeout(const Duration(seconds: 10)),
    );
    expect(asked, isTrue);
    expect(account.state, AccountState.signedOut);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  testWidgets('a removal still held when signing out stops waiting stays held, '
      'and goes at the next sign-in', (tester) async {
    await signIn(tester);
    final mine = await shareWithPriya(tester);
    final space = notes.byId(mine)!.spaceId!;
    const ravi = 'ravi@kapy34.test';
    await tester.runAsync(() async {
      await account.sharing!.addPerson(mine, ravi);
      // Someone else stays invited, so the note stays shared.
      await account.sharing!.addPerson(mine, 'mia@kapy34.test');
    });
    bool raviInvited() =>
        server.spaces[space]!.invites.values.any((i) => i.email == ravi);
    account.sharing!.holdRemoval(mine, priya.email, const Duration(hours: 1));
    account.sharing!.holdRemoval(mine, ravi, const Duration(hours: 1));
    await tester.runAsync(() async {
      final answer = Completer<void>();
      server.onRemoval = () {
        server.onRemoval = null;
        return answer.future;
      };
      await account.signOut().timeout(const Duration(seconds: 10));
      answer.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(priyaIn(space), isFalse);
    expect(raviInvited(), isTrue);

    await tester.runAsync(() async {
      await account.signIn(email: 'sam@kapy34.test', password: 'x');
      await account.unlock('a good passphrase');
      for (
        var wait = 0;
        wait < 100 && account.sharing!.isRemovalHeld(mine, ravi);
        wait++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(raviInvited(), isFalse);
    expect(account.sharing!.isRemovalHeld(mine, ravi), isFalse);
  });

  testWidgets('a removal on its way when signing out stops waiting, that then '
      'fails, stays held and goes at the next sign-in', (tester) async {
    await signIn(tester);
    final mine = await shareWithPriya(tester);
    final space = notes.byId(mine)!.spaceId!;
    // Someone else stays invited, so taking Priya off asks the server.
    await tester.runAsync(
      () => account.sharing!.addPerson(mine, 'ravi@kapy34.test'),
    );
    account.sharing!.holdRemoval(mine, priya.email, const Duration(hours: 1));
    List<Object?>? held() =>
        (store.data['sharing.heldRemovals.v1'] as Map?)?['user-1'] as List?;

    await tester.runAsync(() async {
      final answer = Completer<void>();
      server.onRemoval = () {
        server.onRemoval = null;
        return answer.future;
      };
      await account.signOut().timeout(const Duration(seconds: 10));
      answer.completeError(const SyncRefusedException(409, 'conflict', {}));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(priyaIn(space), isTrue);
    expect(held(), [
      {'note': mine, 'email': priya.email},
    ]);

    await tester.runAsync(() async {
      await account.signIn(email: 'sam@kapy34.test', password: 'x');
      await account.unlock('a good passphrase');
      for (var wait = 0; wait < 100 && priyaIn(space); wait++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(priyaIn(space), isFalse);
  });

  testWidgets('on a phone, a toast from the share sheet over Home sits at the '
      'bottom edge, not above the bar the sheet covers', (tester) async {
    await signIn(tester);
    final mine = await shareWithPriya(tester);
    await pumpApp(tester, phone: true);
    // The app restores the account once it is up, with sharing anew.
    await tester.runAsync(() async {
      for (
        var wait = 0;
        wait < 100 && account.sharing?.memberOn(mine, priya.email) == null;
        wait++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    await showList(tester, phone: true);

    await tester.longPress(
      find
          .descendant(
            of: find.byType(Sidebar),
            matching: find.text('Trip budget'),
          )
          .last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sharing'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('member-menu-${priya.userId}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from this note').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    final toast = find.byKey(const ValueKey('toast-surface'));
    expect(
      find.descendant(of: toast, matching: find.textContaining('Removed')),
      findsOneWidget,
    );
    expect(
      tester.getBottomLeft(toast).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('phone-bar'))).dy,
      ),
    );
    await tester.pump(const Duration(seconds: 8));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
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

  testWidgets('on a phone, a shared note opened from outside the list, by '
      'Quick find, moves the bar to Folders, and Back from its page is '
      'Shared', (tester) async {
    await signIn(tester);
    await shareWithPriya(tester);
    await priyaShares(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    expect(lit(tester, 'bar-notes'), isTrue);
    expect(listed(tester, 'Packing list'), isFalse);

    await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('command-menu-field')),
      'Packing',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byKey(const ValueKey('command-menu')),
            matching: find.text('Packing list'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(Sidebar), findsNothing, reason: "the note's page");
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-page')), findsOneWidget);
    expect(lit(tester, 'bar-folders'), isTrue);
    expect(listed(tester, 'Packing list'), isTrue);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('on a phone, Shared opens from its tile on Folders with '
      'Folders chosen in the bar, and Back goes to Folders, then Home', (
    tester,
  ) async {
    await signIn(tester);
    await shareWithPriya(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    await tester.tap(find.byKey(const ValueKey('bar-folders')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: sharedTile, matching: find.text('1')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sharedTile,
        matching: find.text('Trip budget · Today'),
      ),
      findsOneWidget,
    );

    await tester.tap(sharedTile);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-page')), findsOneWidget);
    expect(sharedTile, findsNothing);
    expect(lit(tester, 'bar-folders'), isTrue);
    expect(lit(tester, 'bar-notes'), isFalse);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-page')), findsNothing);
    expect(sharedTile, findsOneWidget);
    expect(lit(tester, 'bar-folders'), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    expect(lit(tester, 'bar-notes'), isTrue);
    expect(listed(tester, 'Bank details'), isTrue);
  });

  testWidgets('on a phone, Notes in the bar leaves Shared for Home', (
    tester,
  ) async {
    await signIn(tester);
    await shareWithPriya(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    await openTab(tester, SidebarTab.shared, phone: true);
    await tester.tap(find.byKey(const ValueKey('bar-notes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-page')), findsNothing);
    expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
  });

  testWidgets("on a phone, Folders in the bar carries a clay dot on every tab "
      'while invitations wait, and loses it once none do', (tester) async {
    final semantics = tester.ensureSemantics();
    await signIn(tester);
    await shareWithPriya(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    expect(foldersDot, findsNothing, reason: 'nothing waits');
    expect(find.bySemanticsLabel('Folders'), findsOneWidget);

    final token = await priyaInvites(tester);
    await tester.pumpAndSettle();
    for (final tab in ['bar-notes', 'bar-folders', 'bar-kapyAi']) {
      if (find.byKey(ValueKey(tab)).evaluate().isEmpty) continue;
      await tester.tap(find.byKey(ValueKey(tab)));
      await tester.pumpAndSettle();
      expect(foldersDot, findsOneWidget, reason: tab);
    }
    expect(
      (tester.widget<Container>(foldersDot).decoration! as BoxDecoration).color,
      tester.element(foldersDot).palette.clay,
    );
    expect(tester.getSize(foldersDot), const Size.square(7));
    expect(find.bySemanticsLabel('Folders, new in Shared'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bar-folders')));
    await tester.pumpAndSettle();
    final badge = find.byKey(const ValueKey('folders-shared-invitations'));
    expect(find.descendant(of: badge, matching: find.text('1')), findsOne);

    await tester.runAsync(() async {
      await account.sharing!.declineInvite(token);
      await account.sharing!.refresh();
    });
    await tester.pumpAndSettle();
    expect(foldersDot, findsNothing);
    expect(badge, findsNothing);
    semantics.dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('on a phone, a view-only note shared with you has Home and '
      'More, no week, and More offers only what a viewer can do', (
    tester,
  ) async {
    await signIn(tester);
    await shareWithPriya(tester);
    await priyaShares(tester);
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

    expect(find.byKey(const ValueKey('page-home')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-day')), findsNothing);
    expect(find.byKey(const ValueKey('page-tasks-line')), findsNothing);
    expect(find.byKey(const ValueKey('view-only-status')), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    Finder item(String value) => find.byKey(ValueKey('page-more-$value'));
    expect(
      find.descendant(of: item('share'), matching: find.text('Sharing')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: item('delete'), matching: find.text('Remove note…')),
      findsOneWidget,
    );
    for (final value in ['day', 'folder', 'tags', 'hide', 'archive']) {
      expect(item(value), findsNothing, reason: value);
    }
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    // Home goes to Home, not back to the Shared list it was opened from.
    await tester.tap(find.byKey(const ValueKey('page-home')));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneNoteHeader), findsNothing);
    expect(find.byKey(const ValueKey('shared-page')), findsNothing);
    expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('beside a window, More leads with Manage sharing on a note you '
      'share, and with Share note on one you keep to yourself', (tester) async {
    await signIn(tester);
    await shareWithPriya(tester);
    await pumpApp(tester, phone: false);
    await openTab(tester, SidebarTab.mine, phone: false);
    for (final (title, label) in [
      ('Trip budget', 'Manage sharing'),
      ('Bank details', 'Share note'),
    ]) {
      await tester.tap(
        find
            .descendant(of: find.byType(Sidebar), matching: find.text(title))
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-share')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('page-more')));
      await tester.pumpAndSettle();
      final first = find
          .byWidgetPredicate((widget) => widget is PopupMenuItem<String>)
          .first;
      expect(tester.widget<PopupMenuItem<String>>(first).value, 'share');
      expect(
        find.descendant(of: first, matching: find.text(label)),
        findsOneWidget,
        reason: title,
      );
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
    }
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('on a phone, a note of your own that you share can be '
      'archived but not moved to Hidden Notes', (tester) async {
    await signIn(tester);
    await shareWithPriya(tester);
    await pumpApp(tester, phone: true);
    await showList(tester, phone: true);
    await openTab(tester, SidebarTab.shared, phone: true);
    await tester.tap(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('Trip budget'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    Finder item(String value) => find.byKey(ValueKey('page-more-$value'));
    expect(item('archive'), findsOneWidget);
    expect(item('hide'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('on an iPhone, a swipe in from the left edge takes Shared '
      'back to Folders', (tester) async {
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
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-page')), findsNothing);
    expect(sharedTile, findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('on a phone, Shared is a page whose arrow goes back to '
      'Folders', (tester) async {
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
    expect(sharedTile, findsOneWidget);
    expect(lit(tester, 'bar-folders'), isTrue);
  });

  for (final phone in [false, true]) {
    testWidgets('${phone ? 'on a phone' : 'beside a window'}, a shared note '
        'for a later day leaves My notes and its count, while Shared lists '
        'and counts it (KAP-352)', (tester) async {
      final days = NoteDayStore(store);
      await days.load();
      await signIn(tester);
      final mine = await shareWithPriya(tester);
      final now = notes.now();
      days.setDay(mine, DateTime(now.year, now.month, now.day + 2));
      await pumpApp(tester, phone: phone, days: days);
      await showList(tester, phone: phone);

      await openTab(tester, SidebarTab.mine, phone: phone);
      expect(listed(tester, 'Trip budget'), isFalse);
      expect(listed(tester, 'Bank details'), isTrue);
      expect(
        phone
            ? tester
                  .widget<PhoneHomeHeader>(find.byType(PhoneHomeHeader))
                  .notesCount
            : tester
                  .widget<SidebarWindowBar>(find.byType(SidebarWindowBar))
                  .count,
        1,
      );

      await openTab(tester, SidebarTab.shared, phone: phone);
      expect(listed(tester, 'Trip budget'), isTrue);
      expect(
        phone
            ? tester.widget<PhoneListTitle>(find.byType(PhoneListTitle)).count
            : tester
                  .widget<SidebarWindowBar>(find.byType(SidebarWindowBar))
                  .count,
        1,
      );
    });
  }

  group("a phone row's swipe in Shared", () {
    /// Priya shares Packing list with Sam, who joins, and Sam shares Trip
    /// budget with her; then Shared opens on Sam's phone.
    Future<void> openShared(WidgetTester tester) async {
      await signIn(tester);
      await tester.runAsync(() async {
        await priya.boot();
        final theirs = priya.notes.create(body: 'Packing list');
        await priya.sync.syncNow();
        await priya.sharing.shareNoteWith(
          theirs.id,
          email: server.user('user-1').email,
        );
        await account.sharing!.acceptInvite(server.outbox.single.token);
        final mine = notes.create(body: 'Trip budget');
        await account.sync!.syncNow();
        await account.sharing!.shareNoteWith(mine.id, email: priya.email);
        await priya.sharing.acceptInvite(server.outbox.last.token);
        await priya.sync.syncNow();
        await account.sharing!.refresh();
        await account.sync!.syncNow();
        for (
          var i = 0;
          i < 200 && !notes.allNotes.any((n) => n.title == 'Packing list');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await pumpApp(tester, phone: true);
      await showList(tester, phone: true);
      await openTab(tester, SidebarTab.shared, phone: true);
    }

    Future<String> openRow(WidgetTester tester, String title) async {
      await tester.drag(
        find.widgetWithText(NoteRow, title),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();
      return notes.allNotes.firstWhere((note) => note.title == title).id;
    }

    testWidgets("an owner's Delete asks first, as the row's menu does", (
      tester,
    ) async {
      await openShared(tester);
      final id = await openRow(tester, 'Trip budget');
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('swipe-delete-$id')));
      await tester.pumpAndSettle();
      expect(find.text('Delete note?'), findsOneWidget);
      expect(
        find.text('Deletes "Trip budget" from every synced device.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Note deleted'), findsOneWidget);
      Toast.debugTimeUp();
      await tester.pumpAndSettle();
      expect(notes.byId(id), isNull);
    });

    testWidgets("a guest's row offers Remove, which only takes the note out "
        'of their notes', (tester) async {
      await openShared(tester);
      final id = await openRow(tester, 'Packing list');
      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
      await tester.tap(find.byKey(ValueKey('swipe-delete-$id')));
      await tester.pumpAndSettle();
      expect(find.text('Remove from your notes?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Removed from your notes'), findsOneWidget);
      Toast.debugTimeUp();
      await tester.pumpAndSettle();
      expect(notes.byId(id), isNull);
    });
  });
}
