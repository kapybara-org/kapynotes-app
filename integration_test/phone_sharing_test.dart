// The owed sharing device checks on a phone (KAP-256), walked in CI rather
// than by hand: #232's Block and Leave from both sheets, and #245, #255 and
// #256's Shared page, owner's sheet, share-wide and viewer's sheets, Remove
// and Stop sharing with Undo, the neutral asks and the invitation card. The
// Phones workflow runs it on an iOS 27.2 iPhone and an Android emulator
// through tool/ci/phone_screenshots.sh:
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_sharing_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The app is signed in as Sam on the fake sync server, through a fake
// sign-in and an in-memory key store, and Priya and Carol are fake devices on
// that server. The rates fetch gets a client that answers every request with
// an error. So nothing signs in to a real account or reaches the network.
// Off a phone every test skips.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
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
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/join/joining_ui.dart';
import 'package:kapy_notes/ui/share_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/sharing_devices.dart'
    show Device, FakeSend, joiningOver, opener;
import '../test/sync/fake_server.dart' show FakeApi, FakeAuth, FakeServer;
import 'sharing_support.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'phone-sharing-integration.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final phone = AppPlatform.isMobile;

  late FakeServer server;
  late Device priya;
  late Device carol;
  late _Store store;
  late NotesStore notes;
  late Account account;
  late LayoutPrefs prefs;
  late RatesRepository rates;
  late ShortcutPrefs shortcuts;
  late String samEmail;
  late String tripId;
  late String packingId;

  setUp(() {
    server = FakeServer();
    namePeople(server);
    priya = Device(server, userId: 'user-2', device: 'priya');
    carol = Device(server, userId: 'user-3', device: 'carol');
    store = _Store();
    notes = NotesStore(store);
    final state = SyncState(store);
    final sam = server.user('user-1');
    samEmail = sam.email;
    account = Account(
      auth: FakeAuth(id: 'user-1', email: sam.email, name: sam.name),
      syncApi: (_) => FakeApi(server, device: 'sam-phone', userId: 'user-1'),
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
    rates = RatesRepository(
      store,
      client: MockClient((_) async => http.Response('', 503)),
    );
    shortcuts = ShortcutPrefs(store);
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  });

  tearDown(() {
    account.dispose();
    priya.dispose();
    carol.dispose();
  });

  /// Sam signs in and shares Trip budget with Priya, who can edit, and
  /// Carol, who can view; Priya shares Packing list with Sam, who can view.
  /// Bank details stays Sam's own.
  Future<void> shareAround(WidgetTester tester) => tester.runAsync(() async {
    await notes.load();
    await account.restore();
    await account.signIn(email: samEmail, password: 'x');
    await account.createPassphrase('a good passphrase');
    final sharing = account.sharing!;
    final sync = account.sync!;
    await priya.boot();
    await carol.boot();
    notes.create(body: 'Bank details');
    tripId = notes.create(body: 'Trip budget').id;
    await sync.syncNow();
    await sharing.shareNoteWithPeople(tripId, {
      priya.email: SpaceRole.member,
      carol.email: SpaceRole.viewer,
    });
    await accept(server, priya.sharing, priya.email);
    await accept(server, carol.sharing, carol.email);
    final packing = priya.notes.create(body: 'Packing list');
    packingId = packing.id;
    await priya.sync.syncNow();
    await priya.sharing.shareNoteWith(
      packing.id,
      email: samEmail,
      role: SpaceRole.viewer,
    );
    await accept(server, sharing, samEmail);
    for (final device in [priya, carol]) {
      await device.sharing.refresh();
      await device.sync.syncNow();
    }
    await sharing.refresh();
    await sync.syncNow();
  });

  final sharedPage = find.byKey(const ValueKey('shared-page'));
  final sheet = find.byType(BottomSheet);
  final close = find.byKey(const ValueKey('share-dialog-close'));
  final done = find.byKey(const ValueKey('share-done'));

  Finder row(String title) => find.descendant(
    of: sharedPage,
    matching: find.widgetWithText(NoteRow, title),
  );
  bool listed(String title) => row(title).evaluate().isNotEmpty;
  Finder menuAction(String label) => find.descendant(
    of: find.byType(KapyMenuActionRow),
    matching: find.text(label),
  );

  /// The app as it launches, then Home's Shared card, which opens Shared as
  /// a page.
  ///
  /// Launching, the app restores the account itself, which swaps in a
  /// sharing of its own that hears about the spaces a moment later. Until it
  /// has, Trip budget counts as somebody else's note, and the page it opens
  /// on goes back to Shared rather than Home. So this waits for that sharing
  /// to know Trip budget's space, then goes back until Home's card is there.
  Future<void> openSharedPage(WidgetTester tester) async {
    prefs.load();
    shortcuts.load();
    final restored = account.sharing;
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
    await pumpUntil(tester, () {
      final sharing = account.sharing;
      return sharing != null &&
          !identical(sharing, restored) &&
          sharing.spaceOf(notes.byId(tripId)!) != null;
    });
    await tester.pumpAndSettle();
    final home = find.byKey(const ValueKey('page-home'));
    final card = find.byKey(const ValueKey('home-shared-card'));
    for (
      var taps = 0;
      taps < 3 && card.evaluate().isEmpty && home.evaluate().isNotEmpty;
      taps++
    ) {
      await tester.tap(home);
      await tester.pumpAndSettle();
    }
    expect(card, findsOneWidget, reason: 'Home, with its Shared card');
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(sharedPage, findsOneWidget);
  }

  /// Opens [title] from its Shared row and comes back to Shared, so it is
  /// the note selected behind the list, as after a person has read it.
  Future<void> openAndComeBack(WidgetTester tester, String title) async {
    await tester.tap(row(title));
    await tester.pumpAndSettle();
    expect(sharedPage, findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(sharedPage, findsOneWidget);
  }

  /// Holds [title]'s row until its menu opens. The menu opens while the
  /// press is still held, and without passing pointer events through, the
  /// live binding drops the pointer cancel that opening sends (KAPY-45). The
  /// binding has to have it off again by the end of the test.
  Future<void> longPressRow(WidgetTester tester, String title) async {
    binding.shouldPropagateDevicePointerEvents = true;
    try {
      await tester.longPress(row(title));
      await tester.pumpAndSettle();
    } finally {
      binding.shouldPropagateDevicePointerEvents = false;
    }
  }

  /// A note's sheet, the way a person reaches it: its row's menu on the
  /// Shared page, then Sharing.
  Future<void> openSheetFor(WidgetTester tester, String title) async {
    await longPressRow(tester, title);
    await tester.tap(menuAction('Sharing'));
    await settleOnClock(tester);
    expect(sheet, findsOneWidget);
  }

  /// The sheet for the whole share [noteId] is in.
  Future<void> openShareWideSheet(WidgetTester tester, String noteId) async {
    unawaited(
      showSpaceDialog(
        tester.element(sharedPage),
        spaceId: notes.byId(noteId)!.spaceId!,
        sharing: account.sharing!,
      ),
    );
    await settleOnClock(tester);
    expect(sheet, findsOneWidget);
  }

  /// Closes the sheet without settling, so a toast it left stays up.
  Future<void> closeSheetIfOpen(WidgetTester tester) async {
    if (close.evaluate().isNotEmpty) await tester.tap(close);
    await pumpUntil(tester, () => sheet.evaluate().isEmpty);
  }

  group('#245, #255 and #256', () {
    testWidgets('the Shared page lists what is shared, and a row’s menu '
        'offers Sharing', (tester) async {
      await shareAround(tester);
      await openSharedPage(tester);

      expect(find.text('Search shared notes'), findsOneWidget);
      expect(find.byKey(const ValueKey('page-back')), findsOneWidget);
      expect(listed('Trip budget'), isTrue);
      expect(listed('Packing list'), isTrue);
      expect(listed('Bank details'), isFalse);
      await settledShot(tester, 'phone-sharing-shared-page');

      await longPressRow(tester, 'Trip budget');
      expect(menuAction('Sharing'), findsOneWidget);
      await settledShot(tester, 'phone-sharing-shared-row-menu');

      await tester.tap(menuAction('Sharing'));
      await settleOnClock(tester);
      expect(sheet, findsOneWidget);
      expect(memberRow('user-2'), findsOneWidget);
      expect(memberRow('user-3'), findsOneWidget);
      await settledShot(tester, 'phone-sharing-owner-sheet-from-shared-page');
    }, skip: !phone);

    // The app builds its invite link service only over the real server, so
    // this sheet opens over a fake one, as test/share_dialog_test.dart does.
    testWidgets('the owner’s sheet in P09’s layout: the email field, the '
        'access segments, Share and the invite link row', (tester) async {
      final sam = Device(server, userId: 'user-1', device: 'sam');
      addTearDown(sam.dispose);
      late Note note;
      await tester.runAsync(() async {
        await sam.boot();
        await priya.boot();
        note = sam.notes.create(body: 'Trip budget');
        await sam.sync.syncNow();
        await sam.sharing.shareNoteWith(note.id, email: priya.email);
        await accept(server, priya.sharing, priya.email);
        await sam.sync.syncNow();
      });
      final joining = joiningOver(FakeSend());
      addTearDown(joining.dispose);
      await tester.pumpWidget(
        JoiningScope.value(
          joining: joining,
          child: opener(sam.notes.byId(note.id)!, sam.sharing),
        ),
      );
      await tester.tap(find.text('open'));
      await settleOnClock(tester);

      Finder segment(String label) => find.descendant(
        of: find.byKey(const ValueKey('share-role')),
        matching: find.text(label),
      );
      expect(sheet, findsOneWidget);
      expect(find.byKey(const ValueKey('share-dialog')), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('share-email'))).height,
        44,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('share-role'))).height,
        36,
      );
      expect(segment('Can edit'), findsOneWidget);
      expect(segment('Can view'), findsOneWidget);
      expect(find.byKey(const ValueKey('share-submit-Share')), findsOneWidget);
      expect(find.byKey(const ValueKey('share-link')), findsOneWidget);
      expect(find.textContaining('Off · Turn on'), findsOneWidget);
      expect(memberRow('user-2'), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-sharing')), findsOneWidget);
      await settledShot(tester, 'phone-sharing-owner-sheet');

      await tester.tap(segment('Can view'));
      await tester.pumpAndSettle();
      final viewer = tester.widget<TextButton>(
        find.byKey(const ValueKey('share-role-viewer')),
      );
      expect(viewer.style!.backgroundColor?.resolve({}), isNotNull);
      await settledShot(tester, 'phone-sharing-owner-sheet-can-view');
    }, skip: !phone);

    testWidgets('the viewer’s sheet, and the sheet for a whole share', (
      tester,
    ) async {
      await shareAround(tester);
      await openSharedPage(tester);

      await openSheetFor(tester, 'Packing list');
      expect(find.text('Shared with you'), findsOneWidget);
      expect(memberRow('user-2'), findsOneWidget);
      expect(find.byKey(const ValueKey('copy-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('leave-space')), findsOneWidget);
      expect(find.byKey(const ValueKey('share-email')), findsNothing);
      expect(find.byKey(const ValueKey('stop-sharing')), findsNothing);
      await settledShot(tester, 'phone-sharing-viewer-sheet');
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);

      await openShareWideSheet(tester, tripId);
      expect(memberRow('user-2'), findsOneWidget);
      expect(memberRow('user-3'), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-sharing')), findsOneWidget);
      expect(find.byKey(const ValueKey('leave-space')), findsNothing);
      await settledShot(tester, 'phone-sharing-share-wide-sheet');
    }, skip: !phone);

    testWidgets('Remove a person, then Undo after the sheet has closed '
        'invites them again', (tester) async {
      await shareAround(tester);
      await openSharedPage(tester);
      await openSheetFor(tester, 'Trip budget');

      await tester.tap(memberMenu('user-3'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Remove from this note'));
      await tester.pumpAndSettle();
      expect(find.textContaining('stops seeing this note'), findsOneWidget);
      expectNeutral(tester, askOk, 'Remove');
      await settledShot(tester, 'phone-sharing-remove-ask');

      final removed = find.textContaining('Removed Carol');
      await tapUntil(
        tester,
        askOk,
        () =>
            removed.evaluate().isNotEmpty &&
            memberRow('user-3').evaluate().isEmpty,
      );
      expect(removed, findsOneWidget);
      expect(memberRow('user-3'), findsNothing);
      await closeSheetIfOpen(tester);
      expect(sheet, findsNothing);
      expect(removed, findsOneWidget);
      await settledShot(tester, 'phone-sharing-removed-toast');

      await tester.tap(find.text('Undo'));
      final sent = find.text(
        'Invited Carol again. They can see the note once they accept.',
      );
      await pumpUntil(tester, () => sent.evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
      expect(sent, findsOneWidget);
      final space = account.sharing!.spaceOf(notes.byId(tripId)!)!;
      expect(
        {for (final invite in space.invites) invite.email: invite.role},
        {carol.email: SpaceRole.viewer},
      );
      await settledShot(tester, 'phone-sharing-remove-undone');
    }, skip: !phone);

    testWidgets('Stop sharing, then Undo after the sheet has closed shares '
        'the note again', (tester) async {
      await shareAround(tester);
      await openSharedPage(tester);
      await openSheetFor(tester, 'Trip budget');
      final who = account.sharing!
          .spaceOf(notes.byId(tripId)!)!
          .peoplePhrase(account.sharing!.userId);

      await tester.tap(find.byKey(const ValueKey('stop-sharing')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('stays in your notes, with every change'),
        findsOneWidget,
      );
      expectNeutral(tester, askOk, 'Stop sharing');
      await settledShot(tester, 'phone-sharing-stop-ask');

      final stopped = find.textContaining('Stopped sharing');
      await tapUntil(
        tester,
        askOk,
        () => stopped.evaluate().isNotEmpty && !notes.byId(tripId)!.isShared,
      );
      expect(notes.byId(tripId)!.isShared, isFalse);
      expect(stopped, findsOneWidget);
      await closeSheetIfOpen(tester);
      expect(sheet, findsNothing);
      await pumpUntil(tester, () => !listed('Trip budget'));
      expect(listed('Trip budget'), isFalse);
      expect(stopped, findsOneWidget);
      await settledShot(tester, 'phone-sharing-stopped-toast');

      await tester.tap(find.text('Undo'));
      final again = find.text('$who can see this note again');
      await pumpUntil(
        tester,
        () => again.evaluate().isNotEmpty && listed('Trip budget'),
      );
      expect(tester.takeException(), isNull);
      expect(again, findsOneWidget);
      expect(notes.byId(tripId)!.isShared, isTrue);
      expect(listed('Trip budget'), isTrue);
      final space = account.sharing!.spaceOf(notes.byId(tripId)!)!;
      expect(space.invites, isEmpty);
      await settledShot(tester, 'phone-sharing-stop-undone');
    }, skip: !phone);

    testWidgets('the asks and the sheets stay out of the warning colour, '
        'and Remove note… is the one red item', (tester) async {
      await shareAround(tester);
      await openSharedPage(tester);

      await openSheetFor(tester, 'Trip budget');
      expectNeutral(
        tester,
        find.byKey(const ValueKey('stop-sharing')),
        'Stop sharing',
      );
      await tester.tap(memberMenu('user-2'));
      await tester.pumpAndSettle();
      expectNeutral(tester, menuItem('Remove from this note'), 'Remove');
      expectNeutral(tester, menuItem('Block…'), 'Block…');
      await settledShot(tester, 'phone-sharing-member-menu');
      await tester.tap(menuItem('Block…'));
      await tester.pumpAndSettle();
      expectNeutral(tester, askOk, 'Block');
      await tester.tap(askCancel);
      await tester.pumpAndSettle();
      await tester.tap(done);
      await tester.pumpAndSettle();

      await openSheetFor(tester, 'Packing list');
      expectNeutral(tester, find.byKey(const ValueKey('leave-space')), 'Leave');
      expectNeutral(tester, find.byKey(const ValueKey('copy-note')), 'Copy');
      await tester.tap(find.byKey(const ValueKey('leave-space')));
      await tester.pumpAndSettle();
      expectNeutral(tester, askOk, 'Leave');
      await tester.tap(askCancel);
      await tester.pumpAndSettle();
      await tester.tap(done);
      await tester.pumpAndSettle();

      await tester.tap(row('Packing list'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-more')));
      await tester.pumpAndSettle();
      final items = find.byType(KapyMenuActionRow);
      final warning = warningColour(tester, items);
      final red = [
        for (final item in items.evaluate())
          if (inkOf(tester, find.byWidget(item.widget)) == warning)
            (item.widget as KapyMenuActionRow).action.label,
      ];
      expect(red, ['Remove note…']);
      await settledShot(tester, 'phone-sharing-viewer-page-menu');
    }, skip: !phone);

    testWidgets('an invitation waits on the Shared page as a card, and its '
        'Block asks first by the whole name', (tester) async {
      await shareAround(tester);
      late String token;
      await tester.runAsync(() async {
        final gift = carol.notes.create(body: 'Gift ideas');
        await carol.sync.syncNow();
        await carol.sharing.shareNoteWith(gift.id, email: samEmail);
        token = tokenFor(server, samEmail);
        await account.sharing!.refresh();
      });
      await openSharedPage(tester);

      final card = find.byKey(ValueKey('sidebar-invite-$token'));
      expect(card, findsOneWidget);
      expect(
        find.byKey(ValueKey('sidebar-invite-accept-$token')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('sidebar-invite-decline-$token')),
        findsOneWidget,
      );
      await settledShot(tester, 'phone-sharing-invitation-card');

      await tester.tap(find.byKey(ValueKey('sidebar-invite-more-$token')));
      await tester.pumpAndSettle();
      await settledShot(tester, 'phone-sharing-invitation-menu');
      await tester.tap(find.byKey(ValueKey('invite-block-$token')));
      await tester.pumpAndSettle();
      expect(find.text('Block Carol Diaz?'), findsOneWidget);
      expect(
        find.text(
          'They can’t invite you again, and this invitation goes away. You '
          'can unblock them in Settings, under Blocked people.',
        ),
        findsOneWidget,
      );
      expectNeutral(tester, askOk, 'Block');
      await settledShot(tester, 'phone-sharing-invitation-block-ask');

      await tapAndSettle(tester, askOk);
      await pumpUntil(tester, () => card.evaluate().isEmpty);
      expect(card, findsNothing);
      expect(account.sharing!.hasBlocked(carol.email), isTrue);
      await settledShot(tester, 'phone-sharing-invitation-blocked');
    }, skip: !phone);
  });

  group('#232', () {
    Future<void> blockPriya(WidgetTester tester, String sheetName) async {
      await tester.tap(memberMenu('user-2'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Block…'));
      await tester.pumpAndSettle();
      expect(find.text('Block Priya Nair?'), findsOneWidget);
      expect(
        find.textContaining('Priya loses access to everything you share'),
        findsOneWidget,
      );
      expectNeutral(tester, askOk, 'Block');
      await settledShot(tester, 'phone-sharing-block-ask-$sheetName');
      final blocked = find.text('Blocked Priya Nair');
      await tapUntil(
        tester,
        askOk,
        () =>
            blocked.evaluate().isNotEmpty &&
            memberRow('user-2').evaluate().isEmpty,
      );
      expect(blocked, findsOneWidget);
      expect(account.sharing!.hasBlocked(priya.email), isTrue);
      expect(memberRow('user-2'), findsNothing);
      expect(sharedPage, findsOneWidget, reason: 'Shared stays');
      await settledShot(tester, 'phone-sharing-blocked-$sheetName');
    }

    /// Priya is gone from the note's people, and Carol is still there.
    Future<void> expectPriyaGone(WidgetTester tester, String sheetName) async {
      await closeSheetIfOpen(tester);
      await openSheetFor(tester, 'Trip budget');
      expect(memberRow('user-2'), findsNothing);
      expect(memberRow('user-3'), findsOneWidget);
      await settledShot(tester, 'phone-sharing-blocked-gone-$sheetName');
    }

    testWidgets('Block from the owner’s note sheet asks by the whole name, '
        'then they are gone from the list', (tester) async {
      await shareAround(tester);
      await openSharedPage(tester);
      await openAndComeBack(tester, 'Packing list');
      await openSheetFor(tester, 'Trip budget');
      await blockPriya(tester, 'note-sheet');
      await pumpUntil(tester, () => sheet.evaluate().isEmpty);
      expect(sheet, findsNothing);
      await expectPriyaGone(tester, 'note-sheet');
    }, skip: !phone);

    testWidgets('Block from the share’s sheet asks by the whole name, then '
        'they are gone from the list', (tester) async {
      await shareAround(tester);
      await openSharedPage(tester);
      await openAndComeBack(tester, 'Packing list');
      await openShareWideSheet(tester, tripId);
      await blockPriya(tester, 'share-sheet');
      await expectPriyaGone(tester, 'share-sheet');
    }, skip: !phone);

    Future<void> leavePacking(WidgetTester tester, String sheetName) async {
      await tester.tap(find.byKey(const ValueKey('leave-space')));
      await tester.pumpAndSettle();
      expect(find.text('Leave “Packing list”?'), findsOneWidget);
      expect(find.text('Keep a private copy in my notes'), findsOneWidget);
      expectNeutral(tester, askOk, 'Leave');
      await settledShot(tester, 'phone-sharing-leave-ask-$sheetName');

      await tapAndSettle(tester, askOk);
      await pumpUntil(tester, () => !listed('Packing list'));
      await closeSheetIfOpen(tester);
      expect(sheet, findsNothing);
      expect(sharedPage, findsOneWidget, reason: 'Shared stays');
      expect(listed('Packing list'), isFalse);
      expect(listed('Trip budget'), isTrue);
      expect(account.sharing!.notesSharedFrom(priya.email), isEmpty);
      expect(
        notes.notes.where((n) => n.body == 'Packing list' && !n.isShared),
        hasLength(1),
      );
      await settledShot(tester, 'phone-sharing-left-$sheetName');
    }

    testWidgets('Leave from the viewer’s note sheet asks, then the note '
        'leaves the Shared page', (tester) async {
      await shareAround(tester);
      await openSharedPage(tester);
      await openAndComeBack(tester, 'Packing list');
      await openSheetFor(tester, 'Packing list');
      expect(find.text('Shared with you'), findsOneWidget);
      await leavePacking(tester, 'note-sheet');
    }, skip: !phone);

    testWidgets('Leave from the share’s sheet asks, then the note leaves the '
        'Shared page', (tester) async {
      await shareAround(tester);
      await openSharedPage(tester);
      await openAndComeBack(tester, 'Packing list');
      await openShareWideSheet(tester, packingId);
      await leavePacking(tester, 'share-sheet');
    }, skip: !phone);
  });
}
