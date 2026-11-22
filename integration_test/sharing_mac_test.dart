// The owed sharing device checks on the Mac (KAP-256), walked in CI rather
// than by hand: #232's Block and Leave from both dialogs, #255 and #256's
// dialog in S02's layout for the owner and the viewer, and #257's Escape,
// click outside, ⋮ menu and focus order. The Mac workflow (#269) runs every
// integration_test/*_test.dart that isn't a phone's through
// tool/ci/mac_tests.sh, this one included:
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/sharing_mac_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Sam, Priya and Carol are fake devices on the fake sync server from
// test/sync/fake_server.dart, and the dialogs open beside the sidebar's
// Shared list in a bare app, as test/share_dialog_test.dart opens them. So
// nothing signs in to a real account, reads the keychain or reaches the
// network. Off a Mac every test skips.
import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/ui/share_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/sharing_devices.dart' show Device;
import '../test/sync/fake_server.dart' show FakeServer;
import 'sharing_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final mac = AppPlatform.isMacOS;

  late FakeServer server;
  late Device sam;
  late Device priya;
  late Device carol;
  late String bankId;
  late String tripId;
  late String packingId;

  setUp(() {
    server = FakeServer();
    namePeople(server);
    sam = Device(server, userId: 'user-1', device: 'sam');
    priya = Device(server, userId: 'user-2', device: 'priya');
    carol = Device(server, userId: 'user-3', device: 'carol');
  });

  tearDown(() {
    sam.dispose();
    priya.dispose();
    carol.dispose();
  });

  /// Sam shares Trip budget with Priya, who can edit, and Carol, who can
  /// view; Priya shares Packing list with Sam, who can view. Bank details
  /// stays Sam's own.
  Future<void> shareAround(WidgetTester tester) => tester.runAsync(() async {
    for (final device in [sam, priya, carol]) {
      await device.boot();
    }
    bankId = sam.notes.create(body: 'Bank details').id;
    tripId = sam.notes.create(body: 'Trip budget').id;
    await sam.sync.syncNow();
    await sam.sharing.shareNoteWithPeople(tripId, {
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
      email: sam.email,
      role: SpaceRole.viewer,
    );
    await accept(server, sam.sharing, sam.email);
    for (final device in [priya, carol, sam]) {
      await device.sharing.refresh();
      await device.sync.syncNow();
    }
  });

  final dialog = find.byKey(const ValueKey('share-dialog'));
  final shared = find.byType(Sidebar);
  bool listed(String title) => find
      .descendant(of: shared, matching: find.text(title))
      .evaluate()
      .isNotEmpty;

  /// Sam's Shared list, with the note's dialog and its whole share's dialog
  /// a click away.
  Future<void> showSam(WidgetTester tester, String noteId) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 280,
                child: ListenableBuilder(
                  listenable: Listenable.merge([sam.sharing, sam.notes]),
                  builder: (context, _) => Sidebar(
                    notes: [
                      for (final note in sam.notes.notes)
                        if (sidebarTabLists(
                          SidebarTab.shared,
                          note,
                          sam.sharing,
                        ))
                          note,
                    ],
                    selectedId: null,
                    query: '',
                    displayTime: (time) => time,
                    onSearch: () {},
                    onSelect: (_) {},
                    windowBar: const SizedBox(),
                    onShare: (_) {},
                    sharing: sam.sharing,
                    tab: SidebarTab.shared,
                    onTabChanged: (_) {},
                  ),
                ),
              ),
              Expanded(
                child: Builder(
                  builder: (context) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        key: const ValueKey('open-note-dialog'),
                        onPressed: () => unawaited(
                          showShareDialog(
                            context,
                            note: sam.notes.byId(noteId)!,
                            sharing: sam.sharing,
                          ),
                        ),
                        child: const Text('Share note'),
                      ),
                      TextButton(
                        key: const ValueKey('open-share-dialog'),
                        onPressed: () => unawaited(
                          showSpaceDialog(
                            context,
                            spaceId: sam.notes.byId(noteId)!.spaceId!,
                            sharing: sam.sharing,
                          ),
                        ),
                        child: const Text('Share-wide'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String which) async {
    await tester.tap(find.byKey(ValueKey('open-$which-dialog')));
    await settleOnClock(tester);
    expect(dialog, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  }

  /// Which of [keys] holds the keyboard focus, by the nearest keyed widget
  /// around the focused node.
  String? focused(List<String> keys) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    String? found;
    bool look(Element element) {
      final key = element.widget.key;
      if (key is ValueKey<String> && keys.contains(key.value)) {
        found = key.value;
        return false;
      }
      return true;
    }

    if (look(context as Element)) context.visitAncestorElements(look);
    return found;
  }

  Future<void> tab(WidgetTester tester) async {
    if (!await tester.sendKeyEvent(LogicalKeyboardKey.tab)) {
      // Stands in for the Mac text input's insertTab:, which flutter drive doesn't send.
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>()
          ?.performSelector('insertTab:');
    }
    await tester.pumpAndSettle();
  }

  group('#232', () {
    Future<void> blockPriya(WidgetTester tester, String dialogName) async {
      await tester.tap(memberMenu('user-2'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Block…'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Block Priya Nair?'), findsOneWidget);
      expect(
        find.textContaining('Priya loses access to everything you share'),
        findsOneWidget,
      );
      expectNeutral(tester, askOk, 'Block');
      await settledShot(tester, 'mac-sharing-block-ask-$dialogName');
      final blocked = find.text('Blocked Priya Nair');
      await tapUntil(
        tester,
        askOk,
        () =>
            blocked.evaluate().isNotEmpty &&
            memberRow('user-2').evaluate().isEmpty,
      );
      expect(blocked, findsOneWidget);
      expect(sam.sharing.hasBlocked(priya.email), isTrue);
      expect(memberRow('user-2'), findsNothing);
      await settledShot(tester, 'mac-sharing-blocked-$dialogName');
    }

    /// Priya is gone from the note's people, and Carol is still there; and
    /// Packing list, which Block left, is gone from Shared.
    Future<void> expectPriyaGone(WidgetTester tester, String dialogName) async {
      if (dialog.evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const ValueKey('share-done')));
        await tester.pumpAndSettle();
      }
      await tester.runAsync(sam.sync.syncNow);
      await pumpUntil(tester, () => !listed('Packing list'));
      expect(listed('Packing list'), isFalse);
      await open(tester, 'note');
      expect(memberRow('user-2'), findsNothing);
      expect(memberRow('user-3'), findsOneWidget);
      await settledShot(tester, 'mac-sharing-blocked-gone-$dialogName');
    }

    testWidgets('Block from the owner’s note dialog asks by the whole name, '
        'then they are gone from the list', (tester) async {
      await shareAround(tester);
      await showSam(tester, tripId);
      await open(tester, 'note');
      await blockPriya(tester, 'note-dialog');
      await pumpUntil(tester, () => dialog.evaluate().isEmpty);
      expect(dialog, findsNothing);
      await expectPriyaGone(tester, 'note-dialog');
    }, skip: !mac);

    testWidgets('Block from the share’s dialog asks by the whole name, then '
        'they are gone from the list', (tester) async {
      await shareAround(tester);
      await showSam(tester, tripId);
      await open(tester, 'share');
      await blockPriya(tester, 'share-dialog');
      await expectPriyaGone(tester, 'share-dialog');
    }, skip: !mac);

    Future<void> leavePacking(WidgetTester tester, String dialogName) async {
      expect(listed('Packing list'), isTrue);
      await tester.tap(find.byKey(const ValueKey('leave-space')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Leave “Packing list”?'), findsOneWidget);
      expect(find.text('Keep a private copy in my notes'), findsOneWidget);
      expectNeutral(tester, askOk, 'Leave');
      await settledShot(tester, 'mac-sharing-leave-ask-$dialogName');

      await tapAndSettle(tester, askOk);
      // The app syncs soon after a leave; this device waits an hour, so the
      // test syncs it.
      await tester.runAsync(sam.sync.syncNow);
      await pumpUntil(tester, () => !listed('Packing list'));
      if (dialog.evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const ValueKey('share-done')));
        await tester.pumpAndSettle();
      }
      expect(dialog, findsNothing);
      expect(listed('Packing list'), isFalse);
      expect(listed('Trip budget'), isTrue);
      expect(sam.sharing.notesSharedFrom(priya.email), isEmpty);
      expect(
        sam.notes.notes.where((n) => n.body == 'Packing list' && !n.isShared),
        hasLength(1),
      );
      await settledShot(tester, 'mac-sharing-left-$dialogName');
    }

    testWidgets('Leave from the viewer’s note dialog asks, then the note '
        'leaves Shared', (tester) async {
      await shareAround(tester);
      await showSam(tester, packingId);
      await open(tester, 'note');
      expect(find.text('Shared with you'), findsOneWidget);
      await leavePacking(tester, 'note-dialog');
    }, skip: !mac);

    testWidgets('Leave from the share’s dialog asks, then the note leaves '
        'Shared', (tester) async {
      await shareAround(tester);
      await showSam(tester, packingId);
      await open(tester, 'share');
      await leavePacking(tester, 'share-dialog');
    }, skip: !mac);
  });

  group('#255 and #256', () {
    testWidgets(
      'the 480 dialog in S02’s layout, for the owner and the viewer',
      (tester) async {
        await shareAround(tester);
        for (final (noteId, owner) in [(tripId, true), (packingId, false)]) {
          await showSam(tester, noteId);
          await open(tester, 'note');
          final who = owner ? 'owner' : 'viewer';
          expect(tester.getSize(dialog).width, 480, reason: who);
          expect(
            find.descendant(
              of: dialog,
              matching: find.text(owner ? 'Share' : 'Shared with you'),
            ),
            findsWidgets,
            reason: who,
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('share-more'))),
            const Size(28, 28),
            reason: who,
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('share-dialog-close'))),
            const Size(28, 28),
            reason: who,
          );
          final done = find.byKey(const ValueKey('share-done'));
          expect(
            tester.getTopRight(done).dx,
            tester.getTopRight(dialog).dx - 12,
            reason: who,
          );
          if (owner) {
            final email = find.byKey(const ValueKey('share-email'));
            final role = find.byKey(const ValueKey('share-role'));
            expect(tester.getSize(email).height, 32);
            expect(tester.getSize(role).height, 28);
            expect(
              tester.getTopLeft(role).dy - tester.getBottomLeft(email).dy,
              10,
            );
            expect(find.byKey(const ValueKey('stop-sharing')), findsOneWidget);
            expect(memberRow('user-2'), findsOneWidget);
            expect(memberRow('user-3'), findsOneWidget);
          } else {
            expect(find.byKey(const ValueKey('share-email')), findsNothing);
            expect(find.byKey(const ValueKey('copy-note')), findsOneWidget);
            expect(find.byKey(const ValueKey('leave-space')), findsOneWidget);
            expect(find.byKey(const ValueKey('stop-sharing')), findsNothing);
          }
          expect(tester.takeException(), isNull);
          await settledShot(tester, 'mac-sharing-s02-$who');
          await tester.tap(done);
          await tester.pumpAndSettle();
          expect(dialog, findsNothing, reason: who);
        }
      },
      skip: !mac,
    );
  });

  group('#257', () {
    testWidgets('Escape closes the dialog', (tester) async {
      await shareAround(tester);
      await showSam(tester, tripId);
      await open(tester, 'note');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      await settledShot(tester, 'mac-sharing-escape-closed');
    }, skip: !mac);

    testWidgets('a click outside closes the dialog', (tester) async {
      await shareAround(tester);
      await showSam(tester, tripId);
      await open(tester, 'note');
      final box = tester.getRect(dialog);
      await tester.tapAt(
        Offset(box.left / 2, box.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      await settledShot(tester, 'mac-sharing-click-outside-closed');
    }, skip: !mac);

    testWidgets('the header ⋮ opens the menu with Report this note, for the '
        'owner and the viewer', (tester) async {
      await shareAround(tester);
      for (final (noteId, who) in [(tripId, 'owner'), (packingId, 'viewer')]) {
        await showSam(tester, noteId);
        await open(tester, 'note');
        await tester.tap(find.byKey(const ValueKey('share-more')));
        await tester.pumpAndSettle();
        expect(find.text('Report this note'), findsOneWidget, reason: who);
        await settledShot(tester, 'mac-sharing-more-menu-$who');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Report this note'), findsNothing, reason: who);
        expect(dialog, findsOneWidget, reason: who);
        await tester.tap(find.byKey(const ValueKey('share-done')));
        await tester.pumpAndSettle();
      }
    }, skip: !mac);

    testWidgets('Tab walks close, email, each person it suggests, Member, '
        'Viewer, Share and Done, and stays in the dialog', (tester) async {
      await shareAround(tester);
      await showSam(tester, bankId);
      await open(tester, 'note');
      expect(find.byKey(const ValueKey('share-more')), findsNothing);

      final order = [
        'share-dialog-close',
        'share-email',
        'share-suggest-${carol.email}',
        'share-suggest-${priya.email}',
        'share-role-member',
        'share-role-viewer',
        'share-submit-Share',
        'share-done',
      ];
      final reached = <String?>[];
      for (var press = 0; press <= order.length; press++) {
        await tab(tester);
        reached.add(focused(order));
        if (press == 0) await settledShot(tester, 'mac-sharing-first-tab');
      }
      expect(reached, [...order, order.first]);
      expect(dialog, findsOneWidget);
    }, skip: !mac);

    testWidgets('on a shared note the first Tab reaches ⋮, and Enter opens '
        'its menu', (tester) async {
      await shareAround(tester);
      await showSam(tester, tripId);
      await open(tester, 'note');
      await tab(tester);
      expect(focused(['share-more', 'share-dialog-close']), 'share-more');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Report this note'), findsOneWidget);
      await settledShot(tester, 'mac-sharing-more-menu-from-enter');
    }, skip: !mac);
  });
}
