import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/core/phone_keyboard.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/sync/identity.dart';
import 'package:kapy_notes/sync/joining.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/presence.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_api.dart'
    show SyncProtocolException, SyncRefusedException, SyncTransientException;
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/control_surface.dart';
import 'package:kapy_notes/ui/home_page.dart' show forgottenMessage;
import 'package:kapy_notes/ui/note_picks.dart';
import 'package:kapy_notes/ui/profile_avatar.dart';
import 'package:kapy_notes/ui/share_dialog.dart';
import 'package:kapy_notes/ui/sharing_sheet.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/join/joining_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'billing/billing_fakes.dart';
import 'kapy_icon_finder.dart';
import 'support/sharing_devices.dart';
import 'sync/fake_server.dart';
import 'test_fonts.dart';

List<String> captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

void main() {
  late FakeServer server;
  late Device alice;
  late Device bob;
  late Device carol;

  setUpAll(loadTestFonts);

  setUp(() async {
    server = FakeServer();
    alice = Device(server, userId: 'user-1', device: 'a');
    bob = Device(server, userId: 'user-2', device: 'b');
    carol = Device(server, userId: 'user-3', device: 'c');
  });

  tearDown(() {
    alice.dispose();
    bob.dispose();
    carol.dispose();
  });

  Future<void> openSheet(
    WidgetTester tester,
    Note note,
    Device device, {
    Billing? billing,
    Joining? joining,
  }) async {
    final page = opener(note, device.sharing, billing: billing);
    await tester.pumpWidget(
      joining == null
          ? page
          : JoiningScope.value(joining: joining, child: page),
    );
    await tester.tap(find.text('open'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  /// The access chosen for somebody new, in the sheet's one segmented control.
  Finder segment(String label) => find.descendant(
    of: find.byKey(const ValueKey('share-role')),
    matching: find.text(label),
  );

  /// An item of one of the sheet's menus.
  Finder menuItem(String label) => find.descendant(
    of: find.byType(PopupMenuItem<String>),
    matching: find.text(label),
  );

  /// Lets work the sheet started finish on the real clock, until [done].
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var pass = 0; pass < 40 && !done(); pass++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  /// The sheet's own Share, passed through the real clock the sharing work
  /// needs.
  Future<void> share(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('share-submit-Share')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('a private note is shared with someone by email', (tester) async {
    late Note note;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      note = alice.notes.create(body: 'Holiday budget');
      await alice.sync.syncNow();
    });

    await openSheet(tester, note, alice);

    // Nothing has ever been shared from this account, so the three promises
    // are shown, and the access is chosen before an address is typed.
    expect(find.byKey(const ValueKey('share-first-use')), findsOneWidget);
    expect(find.textContaining('Not even Kapy can'), findsOneWidget);
    expect(segment('Can edit'), findsOneWidget);
    expect(segment('Can view'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-email')), findsOneWidget);
    // A private note is nobody else's yet.
    expect(find.text('People with access'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('share-submit-Share')));
    await tester.pumpAndSettle();
    expect(find.text("Add someone's email first."), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('share-email')),
      bob.email,
    );
    await tester.tap(segment('Can view'));
    await tester.pumpAndSettle();
    await share(tester);

    expect(alice.notes.byId(note.id)!.isShared, isTrue);
    expect(server.outbox.single.to, bob.email);
    expect(
      server.spaces.values
          .singleWhere((space) => space.kind == SpaceKind.team)
          .invites
          .values
          .single
          .role,
      SpaceRole.viewer,
    );
    // Now a shared note: who is on it, and the invitation still waiting.
    expect(find.text('Owner'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-first-use')), findsNothing);
    expect(
      find.byKey(ValueKey('invite-row-${server.outbox.single.token}')),
      findsOneWidget,
    );
    expect(find.text('Can view · waiting to join'), findsOneWidget);
    expect(find.byKey(const ValueKey('stop-sharing')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-dialog-close')), findsOneWidget);
  });

  testWidgets('the people already shared with are offered as suggestions', (
    tester,
  ) async {
    late Note note;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      final other = alice.notes.create(body: 'Trip');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(other.id, email: bob.email);
      note = alice.notes.create(body: 'Holiday budget');
      await alice.sync.syncNow();
    });

    await openSheet(tester, note, alice);
    await tester.tap(find.byKey(const ValueKey('share-email')));
    await tester.pumpAndSettle();

    final suggestion = find.byKey(ValueKey('share-suggest-${bob.email}'));
    expect(suggestion, findsOneWidget);
    await tester.tap(suggestion);
    await tester.pumpAndSettle();

    // Choosing somebody fills the address in, ready to be given access.
    expect(find.byKey(ValueKey('share-chip-${bob.email}')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('share-email')))
          .controller!
          .text,
      isEmpty,
    );
  });

  for (final (platform, kind) in [
    (TargetPlatform.iOS, PointerDeviceKind.touch),
    (TargetPlatform.android, PointerDeviceKind.touch),
    (TargetPlatform.macOS, PointerDeviceKind.mouse),
  ]) {
    testWidgets('on ${platform.name}, a press held on a suggestion picks it, '
        'though a press anywhere else takes the empty field’s focus', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        final other = alice.notes.create(body: 'Trip');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(other.id, email: bob.email);
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
      });

      // The app's own rule for a press outside a text field.
      await tester.pumpWidget(
        Actions(
          actions: {EditableTextTapOutsideIntent: TouchUnfocusAction()},
          child: opener(note, alice.sharing),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-email')), kind: kind);
      await tester.pumpAndSettle();

      final suggestion = find.byKey(ValueKey('share-suggest-${bob.email}'));
      final press = await tester.startGesture(
        tester.getCenter(suggestion),
        kind: kind,
      );
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(suggestion, findsOneWidget, reason: 'still under the press');
      await press.up();
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('share-chip-${bob.email}')), findsOneWidget);
    });
  }

  group('a note already shared with other notes', () {
    late Note first;
    late Note second;
    late String pairId;

    Future<void> shareTwoNotes(WidgetTester tester) =>
        tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          await carol.boot();
          first = alice.notes.create(body: 'Goa trip budget');
          second = alice.notes.create(body: 'Groceries this week');
          await alice.sync.syncNow();
          final space = await alice.sharing.shareNoteWith(
            first.id,
            email: bob.email,
          );
          pairId = space.id;
          await alice.sharing.shareNote(second.id, spaceId: pairId);
        });

    testWidgets('asks before an invitation opens the others, and only this '
        'note takes the note else where', (tester) async {
      await shareTwoNotes(tester);
      await openSheet(tester, alice.notes.byId(first.id)!, alice);

      await tester.enterText(
        find.byKey(const ValueKey('share-email')),
        carol.email,
      );
      await tester.pumpAndSettle();

      // The question only appears once somebody is being added.
      expect(find.byKey(const ValueKey('share-scope')), findsOneWidget);
      expect(find.text('Only this note'), findsOneWidget);
      expect(find.text('Both notes'), findsOneWidget);
      // The question names the note, the people it is shared with, and the
      // other note the person would otherwise join.
      expect(
        find.textContaining('Goa trip budget is shared with'),
        findsOneWidget,
      );
      expect(
        find.textContaining('together with Groceries this week'),
        findsOneWidget,
      );
      expect(find.textContaining('Give ${carol.email}'), findsOneWidget);

      await share(tester);

      // Only this note: it moves to a space of its own with Carol, and Bob is
      // invited there rather than Carol being let into the pair space.
      final moved = alice.notes.byId(first.id)!;
      expect(moved.spaceId, isNot(pairId));
      expect(alice.notes.byId(second.id)!.spaceId, pairId);
      final ownSpace = server.spaces[moved.spaceId]!;
      expect(
        ownSpace.invites.values.map((invite) => invite.email),
        containsAll([bob.email, carol.email]),
      );
      expect(
        server.spaces[pairId]!.invites.values.map((i) => i.email),
        isNot(contains(carol.email)),
      );
    });

    testWidgets('all the notes puts them in the space that already exists', (
      tester,
    ) async {
      await shareTwoNotes(tester);
      await openSheet(tester, alice.notes.byId(first.id)!, alice);

      await tester.enterText(
        find.byKey(const ValueKey('share-email')),
        carol.email,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-scope-all')));
      await tester.pumpAndSettle();
      await share(tester);

      expect(alice.notes.byId(first.id)!.spaceId, pairId);
      expect(alice.notes.byId(second.id)!.spaceId, pairId);
      expect(
        server.spaces[pairId]!.invites.values.map((i) => i.email),
        contains(carol.email),
      );
    });

    testWidgets('nothing is asked when the note is the only one', (
      tester,
    ) async {
      late Note alone;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        alone = alice.notes.create(body: 'Just this');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(alone.id, email: bob.email);
      });
      await openSheet(tester, alice.notes.byId(alone.id)!, alice);

      await tester.enterText(
        find.byKey(const ValueKey('share-email')),
        carol.email,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-scope')), findsNothing);
    });
  });

  group('people with access', () {
    late Note note;

    Future<void> sharedWithBob(WidgetTester tester) =>
        tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          note = alice.notes.create(body: 'Ours');
          await alice.sync.syncNow();
          await alice.sharing.shareNoteWith(note.id, email: bob.email);
          await bob.sharing.acceptInvite(server.outbox.single.token);
          await alice.sync.syncNow();
          await bob.sync.syncNow();
        });

    testWidgets('a changed safety code is said in plain words, and trusted '
        'from the banner', (tester) async {
      await sharedWithBob(tester);
      await tester.runAsync(() async {
        final replaced = await IdentityKeys.generate();
        final bundle = server.user(bob.userId).bundle!;
        server.user(bob.userId).bundle = KeyBundle(
          wrappedMasterKey: bundle.wrappedMasterKey,
          kdf: bundle.kdf,
          identity: await replaced.wrapUnder(
            vaultFor(bob.userId).masterKeyForKeystore,
          ),
        );
        await alice.sharing.refresh();
      });
      expect(alice.sharing.trust.hasWarnings, isTrue);

      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      expect(
        find.textContaining(
          'safety code changed. If they set up a new account, compare this '
          'safety code with them',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('fingerprint'), findsNothing);
      expect(find.textContaining('key changed'), findsNothing);

      await tester.ensureVisible(find.text('Trust this safety code'));
      await tester.tap(find.text('Trust this safety code'));
      await tester.pumpAndSettle();
      expect(alice.sharing.trust.hasWarnings, isFalse);
      expect(find.text('Trust this safety code'), findsNothing);
    });

    testWidgets('changing access changes what they may do', (tester) async {
      await sharedWithBob(tester);
      await openSheet(tester, alice.notes.byId(note.id)!, alice);

      expect(find.text('You'), findsOneWidget);
      expect(find.text(server.user(bob.userId).name), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
      await tester.pumpAndSettle();
      expect(menuItem('Can edit'), findsOneWidget);
      expect(menuItem('Can view'), findsOneWidget);
      expect(menuItem('Remove from this note'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(menuItem('Can view'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      final spaceId = alice.notes.byId(note.id)!.spaceId!;
      expect(server.spaces[spaceId]!.members[bob.userId], SpaceRole.viewer);
      expect(find.textContaining('can view now'), findsOneWidget);
    });

    testWidgets('changing access that reaches another note asks first, and '
        'names it', (tester) async {
      await sharedWithBob(tester);
      final spaceId = alice.notes.byId(note.id)!.spaceId!;
      await tester.runAsync(() async {
        await alice.sharing.shareNote(
          alice.notes.create(body: 'Renewal notes').id,
          spaceId: spaceId,
        );
      });
      await openSheet(tester, alice.notes.byId(note.id)!, alice);

      final bobName = server.user(bob.userId).name.split(' ').first;
      for (final answer in ['sharing-ask-cancel', 'sharing-ask-ok']) {
        await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
        await tester.pumpAndSettle();
        await tester.tap(menuItem('Can view'));
        await tester.pumpAndSettle();
        expect(find.text('Let $bobName only view?'), findsOneWidget);
        expect(
          find.text(
            '$bobName sees this note together with “Renewal notes”, so the '
            'change is for both.',
          ),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(ValueKey(answer)));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(
          server.spaces[spaceId]!.members[bob.userId],
          answer == 'sharing-ask-ok' ? SpaceRole.viewer : SpaceRole.member,
        );
      }
    });

    /// Alice's note with Bob and Carol, both joined, so taking one off
    /// leaves the note shared.
    Future<void> sharedWithBobAndCarol(WidgetTester tester) =>
        tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          await carol.boot();
          note = alice.notes.create(body: 'Ours');
          await alice.sync.syncNow();
          await alice.sharing.shareNoteWith(note.id, email: bob.email);
          await bob.sharing.acceptInvite(server.outbox.last.token);
          await alice.sync.syncNow();
          await alice.sharing.addPerson(note.id, carol.email, allNotes: true);
          await carol.sharing.acceptInvite(server.outbox.last.token);
          await alice.sync.syncNow();
        });

    bool bobOnServer() => server
        .spaces[alice.notes.byId(note.id)!.spaceId]!
        .members
        .containsKey(bob.userId);

    /// Lets work started on the test's clock that waits on the real one
    /// finish, without moving the test's clock on.
    Future<void> settleHere(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    /// Remove from this note on Bob's row, and yes to the ask.
    Future<void> removeBob(WidgetTester tester) async {
      await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Remove from this note'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
      await settleHere(tester);
    }

    testWidgets('Undo inside the toast’s time sends nothing, and the ask, the '
        'toast and Undo agree', (tester) async {
      await sharedWithBobAndCarol(tester);
      final invitations = server.outbox.length;
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      final bobName = server.user(bob.userId).name.split(' ').first;

      await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Remove from this note'));
      await tester.pumpAndSettle();
      expect(find.text('Remove $bobName from this note?'), findsOneWidget);
      expect(
        find.textContaining('$bobName stops seeing this note'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
      await settleHere(tester);

      expect(find.text('Removed $bobName from this note'), findsOneWidget);
      expect(find.byKey(ValueKey('member-row-${bob.userId}')), findsNothing);
      expect(bobOnServer(), isTrue);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('$bobName can see this note again'), findsOneWidget);
      expect(find.byKey(ValueKey('member-row-${bob.userId}')), findsOneWidget);

      await tester.pump(const Duration(seconds: 8));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      expect(bobOnServer(), isTrue);
      expect(server.outbox.length, invitations);
      expect(alice.sharing.memberOn(note.id, bob.email), isNotNull);
    });

    for (final (platform, icon) in [
      (TargetPlatform.iOS, KapyIcons.checkCircleRounded),
      (TargetPlatform.macOS, KapyIcons.checkRounded),
    ]) {
      testWidgets(
        'on ${platform.name}, the removal’s notice shows '
        '${icon == KapyIcons.checkRounded ? 'the tick it always has' : 'a check in a circle'}',
        (tester) async {
          AppPlatform.debugTargetPlatformOverride = platform;
          addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
          await sharedWithBobAndCarol(tester);
          await openSheet(tester, alice.notes.byId(note.id)!, alice);
          await removeBob(tester);

          expect(
            tester
                .widget<KapyIcon>(
                  find.byKey(const ValueKey('toast-status-icon')),
                )
                .icon,
            icon,
          );
          await tester.tap(find.text('Undo'));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 8));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
        },
      );
    }

    group('while a notice shows', () {
      final surface = find.byKey(const ValueKey('toast-surface'));

      Future<void> drain(WidgetTester tester) async {
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 8));
        await until(
          tester,
          () => !alice.sharing.isRemovalHeld(note.id, bob.email),
        );
        await tester.runAsync(alice.sync.syncNow);
      }

      /// Whether [finder]'s box and the notice's card share any point.
      bool underCard(WidgetTester tester, Finder finder) =>
          tester.getRect(finder).overlaps(tester.getRect(surface));

      for (final (platform, size, inset) in [
        (TargetPlatform.iOS, const Size(390, 844), 34.0),
        (TargetPlatform.macOS, const Size(800, 600), 0.0),
        (TargetPlatform.macOS, const Size(1280, 800), 0.0),
      ]) {
        group('on ${platform.name} at ${size.width.round()}×'
            '${size.height.round()}', () {
          /// The sheet or dialog, with [invite] invited too when given.
          Future<void> openAt(WidgetTester tester, {String? invite}) async {
            AppPlatform.debugTargetPlatformOverride = platform;
            addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = size;
            tester.view.padding = FakeViewPadding(bottom: inset);
            addTearDown(tester.view.reset);
            await sharedWithBobAndCarol(tester);
            if (invite != null) {
              await tester.runAsync(() async {
                await alice.sharing.addPerson(
                  note.id,
                  invite,
                  role: SpaceRole.viewer,
                );
                await alice.sync.syncNow();
              });
            }
            await openSheet(tester, alice.notes.byId(note.id)!, alice);
          }

          final done = find.byKey(const ValueKey('share-done'));
          final frame = platform == TargetPlatform.iOS
              ? find.byType(SharingSheetFrame).first
              : find.byKey(const ValueKey('share-dialog'));

          /// The space under Done to the sheet's foot, which a room adds to.
          double foot(WidgetTester tester) =>
              tester.getRect(frame).bottom - tester.getRect(done).bottom;
          Finder carolMenu() =>
              find.byKey(ValueKey('member-menu-${carol.userId}'));

          if (size.width == 1280) {
            testWidgets('a row’s ⋯ menu opens under its button when there is '
                'room', (tester) async {
              await openAt(tester);
              final button = find.byKey(ValueKey('member-menu-${bob.userId}'));
              await tester.tap(button);
              await tester.pumpAndSettle();
              final menu = find.byWidgetPredicate(
                (widget) =>
                    widget.runtimeType.toString().startsWith('_PopupMenu<'),
              );
              expect(tester.getRect(menu).top, tester.getRect(button).bottom);
              await tester.tapAt(const Offset(4, 4));
              await tester.pumpAndSettle();
            });
          }

          testWidgets('Done and Stop sharing stay clear of it and reachable', (
            tester,
          ) async {
            await openAt(tester);
            await removeBob(tester);

            expect(find.text('Undo'), findsOneWidget);
            final done = find.byKey(const ValueKey('share-done'));
            final stop = find.text('Stop sharing');
            expect(underCard(tester, done), isFalse);
            expect(underCard(tester, stop), isFalse);
            await tester.tap(stop);
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('sharing-ask')), findsOneWidget);
            await tester.tap(find.byKey(const ValueKey('sharing-ask-cancel')));
            await tester.pumpAndSettle();
            await tester.tap(done);
            await tester.pumpAndSettle();
            expect(done, findsNothing, reason: 'Done closed the sheet');
            await drain(tester);
          });

          testWidgets("a person's ⋯ menu hides the notice, and the Remove "
              'confirmation keeps clear of it and is reachable', (
            tester,
          ) async {
            await openAt(tester);
            await removeBob(tester);
            expect(find.text('Undo'), findsOneWidget);

            await tester.tap(
              find.byKey(ValueKey('member-menu-${carol.userId}')),
            );
            await tester.pumpAndSettle();
            expect(menuItem('Remove from this note'), findsOneWidget);
            expect(surface, findsNothing, reason: 'out of sight');
            await tester.tap(menuItem('Remove from this note'));
            await tester.pumpAndSettle();

            final ok = find.byKey(const ValueKey('sharing-ask-ok'));
            final cancel = find.byKey(const ValueKey('sharing-ask-cancel'));
            expect(ok, findsOneWidget);
            expect(find.text('Undo'), findsOneWidget, reason: 'back');
            expect(underCard(tester, ok), isFalse);
            expect(underCard(tester, cancel), isFalse);
            await tester.tap(cancel);
            await tester.pumpAndSettle();
            expect(ok, findsNothing, reason: 'Cancel closed the ask');
            expect(
              find.byKey(ValueKey('member-row-${carol.userId}')),
              findsOneWidget,
            );
            await drain(tester);
          });

          testWidgets('a row menu pauses the notice’s time, and it comes back '
              'with what it had left when the menu closes', (tester) async {
            Toast.debugAnimateLifetimeInTests = true;
            addTearDown(() => Toast.debugAnimateLifetimeInTests = false);
            await openAt(tester);
            Toast.show(
              tester.element(find.byKey(const ValueKey('share-done'))),
              'Removed Bob from this note',
              action: 'Undo',
              onAction: () {},
            );
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));

            await tester.tap(
              find.byKey(ValueKey('member-menu-${carol.userId}')),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(menuItem('Remove from this note'), findsOneWidget);
            final held = find.byKey(
              const ValueKey('toast-surface'),
              skipOffstage: false,
            );
            expect(surface, findsNothing);
            expect(held, findsOneWidget);
            await tester.pump(const Duration(seconds: 10));
            expect(held, findsOneWidget, reason: 'its time is paused');

            await tester.tapAt(const Offset(4, 4));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(menuItem('Remove from this note'), findsNothing);
            expect(surface, findsOneWidget);
            await tester.pump(const Duration(milliseconds: 2400));
            expect(surface, findsOneWidget, reason: 'about 3 s were left');
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump();
            expect(surface, findsNothing, reason: 'and no more');
          });

          testWidgets('a notice from a row menu’s own action replaces the one '
              'it hid', (tester) async {
            await openAt(tester);
            await removeBob(tester);
            final bobName = server.user(bob.userId).name.split(' ').first;
            final carolName = server.user(carol.userId).name.split(' ').first;
            expect(
              find.text('Removed $bobName from this note'),
              findsOneWidget,
            );

            await tester.tap(
              find.byKey(ValueKey('member-menu-${carol.userId}')),
            );
            await tester.pumpAndSettle();
            await tester.tap(menuItem('Can view'));
            await settleHere(tester);
            await until(
              tester,
              () => find.text('$carolName can view now').evaluate().isNotEmpty,
            );

            expect(find.text('$carolName can view now'), findsOneWidget);
            expect(
              find.text('Removed $bobName from this note', skipOffstage: false),
              findsNothing,
            );
            await drain(tester);
            await tester.pump(const Duration(seconds: 1));
          });

          testWidgets('a row that goes while its ⋯ menu is open still brings '
              'the notice back when the menu closes, and it ends on time', (
            tester,
          ) async {
            Toast.debugAnimateLifetimeInTests = true;
            addTearDown(() => Toast.debugAnimateLifetimeInTests = false);
            await openAt(tester);
            final shut = foot(tester);
            Toast.show(
              tester.element(done),
              'Removed Bob from this note',
              action: 'Undo',
              onAction: () {},
            );
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            await tester.tap(carolMenu());
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));

            await tester.runAsync(() async {
              await carol.sharing.leave(alice.notes.byId(note.id)!.spaceId!);
              await alice.sync.syncNow();
            });
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            expect(carolMenu(), findsNothing, reason: 'Carol left');
            expect(menuItem('Remove from this note'), findsOneWidget);

            await tester.tap(menuItem('Remove from this note'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(menuItem('Remove from this note'), findsNothing);
            expect(
              find.byKey(const ValueKey('sharing-ask-ok')),
              findsNothing,
              reason: 'the stale menu asks nothing',
            );
            expect(surface, findsOneWidget, reason: 'back');
            await tester.pump(const Duration(milliseconds: 2400));
            expect(surface, findsOneWidget, reason: 'about 3 s were left');
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump();
            expect(surface, findsNothing, reason: 'and no more');
            await tester.pumpAndSettle();
            expect(foot(tester), shut, reason: 'its room shut');
            await drain(tester);
            await tester.pump(const Duration(seconds: 1));
          });

          testWidgets('as a row menu closes, the card shows only in its room', (
            tester,
          ) async {
            await openAt(tester);
            await removeBob(tester);
            final room = tester.getRect(surface);

            await tester.tap(carolMenu());
            await tester.pumpAndSettle();
            expect(surface, findsNothing);
            await tester.tapAt(const Offset(4, 4));
            for (var frame = 0; frame < 30; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              if (surface.evaluate().isEmpty) continue;
              expect(tester.getRect(surface), room, reason: 'frame $frame');
            }
            expect(surface, findsOneWidget);
            await drain(tester);
          });

          testWidgets('a notice that comes while the Remove confirmation is up '
              'leaves the sheet under it where it is until it closes', (
            tester,
          ) async {
            await openAt(tester);
            final top = tester.getRect(frame).top;
            await tester.tap(carolMenu());
            await tester.pumpAndSettle();
            await tester.tap(menuItem('Remove from this note'));
            await tester.pumpAndSettle();

            Toast.show(tester.element(done), 'Copied');
            await tester.pumpAndSettle();
            expect(surface, findsOneWidget);
            expect(tester.getRect(frame).top, top);
            await tester.tap(find.byKey(const ValueKey('sharing-ask-cancel')));
            await tester.pumpAndSettle();
            expect(tester.getRect(frame).top, lessThan(top), reason: 'room');
            await drain(tester);
          });

          testWidgets('a notice that ends while the Remove confirmation is up '
              'leaves the sheet under it where it is until it closes', (
            tester,
          ) async {
            await openAt(tester);
            final shut = foot(tester);
            await removeBob(tester);
            final top = tester.getRect(frame).top;
            expect(foot(tester), greaterThan(shut), reason: 'room');
            await tester.tap(carolMenu());
            await tester.pumpAndSettle();
            await tester.tap(menuItem('Remove from this note'));
            await tester.pumpAndSettle();

            Toast.showProgress(tester.element(done), 'Saving…').dismiss();
            await tester.pumpAndSettle();
            expect(surface, findsNothing);
            expect(tester.getRect(frame).top, top);
            await tester.tap(find.byKey(const ValueKey('sharing-ask-cancel')));
            await tester.pumpAndSettle();
            expect(foot(tester), shut);
            await drain(tester);
          });

          testWidgets('a new notice while a row menu hides one shows at once', (
            tester,
          ) async {
            await openAt(tester);
            await removeBob(tester);
            await tester.tap(carolMenu());
            await tester.pumpAndSettle();
            expect(surface, findsNothing);

            Toast.show(tester.element(done), 'Link copied');
            await tester.pump();
            expect(find.text('Link copied'), findsOneWidget);
            expect(surface, findsOneWidget);
            await tester.tapAt(const Offset(4, 4));
            await drain(tester);
          });

          testWidgets("an invitation's ⋯ menu hides the notice and brings it "
              'back', (tester) async {
            await openAt(tester, invite: 'guest@example.com');
            await removeBob(tester);
            expect(surface, findsOneWidget);

            await tester.tap(
              find.byWidgetPredicate(
                (widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key! as ValueKey<String>).value.startsWith(
                      'invite-menu-',
                    ),
              ),
            );
            await tester.pumpAndSettle();
            expect(menuItem('Copy link'), findsOneWidget);
            expect(surface, findsNothing);
            await tester.tapAt(const Offset(4, 4));
            await tester.pumpAndSettle();
            expect(menuItem('Copy link'), findsNothing);
            expect(surface, findsOneWidget);
            expect(find.text('Undo'), findsOneWidget);
            await drain(tester);
          });

          if (platform == TargetPlatform.macOS) {
            testWidgets('closing the dialog hands an Undo notice back to the '
                'window’s foot, and Undo still works', (tester) async {
              await openAt(tester);
              await removeBob(tester);
              final bobName = server.user(bob.userId).name.split(' ').first;

              await tester.tap(find.byKey(const ValueKey('share-done')));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 16));
              expect(
                find.byKey(const ValueKey('share-dialog')),
                findsOneWidget,
                reason: 'still closing',
              );
              expect(
                tester.getRect(surface).bottom,
                size.height - 24,
                reason: 'the notice leaves as the dialog does',
              );
              await tester.pumpAndSettle();
              expect(find.byKey(const ValueKey('share-done')), findsNothing);
              expect(find.text('Undo'), findsOneWidget);
              expect(tester.getRect(surface).bottom, size.height - 24);

              final invitations = server.outbox.length;
              await tester.tap(find.text('Undo'));
              final again = find.text(
                'Invited $bobName again. They can see the note once they '
                'accept.',
              );
              await until(tester, () => again.evaluate().isNotEmpty);
              expect(again, findsOneWidget, reason: 'the removal went out');
              expect(server.outbox.length, invitations + 1);
              await drain(tester);
              await tester.pump(const Duration(seconds: 1));
            });
          }
        });
      }
    });

    group('on a phone, a notice at the sheet’s foot', () {
      const long =
          'Removed Christopher Montgomery-Whitfield from this note and from '
          'every other note in the share';
      final surface = find.byKey(const ValueKey('toast-surface'));
      final done = find.byKey(const ValueKey('share-done'));

      /// The sheet, with [invites] people invited too, enough to make it
      /// scroll at its tallest.
      Future<void> phoneSheet(
        WidgetTester tester, {
        double inset = 0,
        int invites = 0,
      }) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.padding = FakeViewPadding(bottom: inset);
        addTearDown(tester.view.reset);
        await sharedWithBobAndCarol(tester);
        await tester.runAsync(() async {
          for (var i = 1; i <= invites; i++) {
            await alice.sharing.addPerson(
              note.id,
              'guest$i@example.com',
              role: SpaceRole.viewer,
            );
          }
          await alice.sync.syncNow();
        });
        await openSheet(tester, alice.notes.byId(note.id)!, alice);
      }

      Future<void> drain(WidgetTester tester) async {
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 8));
        await until(
          tester,
          () => !alice.sharing.isRemovalHeld(note.id, bob.email),
        );
        await tester.runAsync(alice.sync.syncNow);
      }

      testWidgets('back-to-back notices keep the room open between them', (
        tester,
      ) async {
        await phoneSheet(tester, inset: 34);
        Toast.show(tester.element(done), 'Copied');
        await tester.pumpAndSettle();
        final open = tester.getRect(done).top;

        Toast.show(tester.element(done), 'Link copied');
        for (var frame = 0; frame < 15; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(done).top, open, reason: 'frame $frame');
        }
        await drain(tester);
      });

      for (final turn in ['first', 'second']) {
        testWidgets('opens its room in the $turn of two tests that both end '
            'with the same notice up', (tester) async {
          await phoneSheet(tester, inset: 34);
          Toast.show(tester.element(done), 'Copied');
          await tester.pumpAndSettle();
          expect(tester.getRect(surface).top - tester.getRect(done).bottom, 8);
        });
      }

      testWidgets('opens its room over 160 ms and shuts it the same way', (
        tester,
      ) async {
        await phoneSheet(tester, inset: 34);
        final shut = tester.getRect(done).top;
        Toast.show(tester.element(done), 'Copied');
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final opening = tester.getRect(done).top;
        await tester.pump(const Duration(milliseconds: 100));
        final open = tester.getRect(done).top;
        expect(shut - open, 52 + 1.5 + 16);
        expect(opening, lessThan(shut));
        expect(opening, greaterThan(open));

        Toast.showProgress(tester.element(done), 'Saving…').dismiss();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final shutting = tester.getRect(done).top;
        await tester.pump(const Duration(milliseconds: 100));
        expect(shutting, greaterThan(open));
        expect(shutting, lessThan(shut));
        expect(tester.getRect(done).top, shut);
        await drain(tester);
      });

      testWidgets('at its tallest, the sheet keeps its top and takes the room '
          'from the list, Done and Stop sharing still reachable', (
        tester,
      ) async {
        await phoneSheet(tester, inset: 34, invites: 12);
        final frame = find.byType(SharingSheetFrame);
        final top = tester.getRect(frame).top;
        final list = find
            .descendant(
              of: find.byType(SingleChildScrollView).first,
              matching: find.byType(Scrollable),
            )
            .first;
        final scroll = tester.state<ScrollableState>(list).position;
        expect(scroll.maxScrollExtent, greaterThan(0), reason: 'it scrolls');
        final view = scroll.viewportDimension;
        await removeBob(tester);

        expect(tester.getRect(frame).top, top);
        expect(
          tester.state<ScrollableState>(list).position.viewportDimension,
          view - (52 + 1.5 + 16),
        );
        expect(tester.getRect(surface).top - tester.getRect(done).bottom, 8);
        await tester.tap(find.text('Stop sharing'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('sharing-ask')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('sharing-ask-cancel')));
        await tester.pumpAndSettle();
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(done, findsNothing, reason: 'Done closed the sheet');
        await drain(tester);
      });

      testWidgets('sits 8 under the footer at its own height, and the sheet '
          'gives the room back after', (tester) async {
        await phoneSheet(tester, inset: 34);
        final before = tester.getRect(done);
        await removeBob(tester);

        final card = tester.getRect(surface);
        expect(card.height, 52 + 1.5, reason: 'its own height');
        expect(card.top - tester.getRect(done).bottom, 8);
        expect(card.bottom, 844 - 34 - 8);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        Toast.showProgress(tester.element(done), 'Saving…').dismiss();
        await drain(tester);
        expect(surface, findsNothing);
        expect(tester.getRect(done), before);
      });

      testWidgets('keeps clear of Done even on two lines', (tester) async {
        await phoneSheet(tester, inset: 34);
        Toast.show(tester.element(done), long);
        await tester.pumpAndSettle();

        final card = tester.getRect(surface);
        expect(card.height, greaterThan(60), reason: 'two lines');
        expect(card.top - tester.getRect(done).bottom, 8);
        expect(card.bottom, 844 - 34 - 8);
        await drain(tester);
      });

      testWidgets('stays on screen with no bottom inset', (tester) async {
        await phoneSheet(tester);
        Toast.show(tester.element(done), long);
        await tester.pumpAndSettle();

        expect(tester.getRect(surface).bottom, 844 - 8 - 8);
        await drain(tester);
      });

      testWidgets('lets go of the sheet as it starts to close', (tester) async {
        await phoneSheet(tester, inset: 34);
        await removeBob(tester);
        final over = tester.getRect(surface);

        await tester.tapAt(const Offset(195, 40));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          done,
          findsOneWidget,
          reason: 'the sheet is still on its way down',
        );
        final card = tester.getRect(surface);
        expect(card.bottom, 844 - 34 - 16);
        expect(card.bottom, isNot(over.bottom));
        await drain(tester);
      });
    });

    testWidgets('without Undo, the removal reaches the server once the '
        'toast’s time is up', (tester) async {
      await sharedWithBobAndCarol(tester);
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await removeBob(tester);
      expect(bobOnServer(), isTrue);

      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      expect(bobOnServer(), isTrue);

      await tester.pump(const Duration(seconds: 2));
      await until(tester, () => !bobOnServer());
      expect(bobOnServer(), isFalse);
      expect(find.byKey(ValueKey('member-row-${bob.userId}')), findsNothing);
      expect(
        find.byKey(ValueKey('member-row-${carol.userId}')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('closing the sheet sends a held removal at once', (
      tester,
    ) async {
      await sharedWithBobAndCarol(tester);
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await removeBob(tester);

      await tester.tap(find.byKey(const ValueKey('share-dialog-close')));
      await tester.pumpAndSettle();
      await until(tester, () => !bobOnServer());
      expect(bobOnServer(), isFalse);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a removal the server refuses once the toast’s time is up '
        'puts them back, saying why', (tester) async {
      await sharedWithBobAndCarol(tester);
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await removeBob(tester);
      server.onRemoval = () async {
        server.onRemoval = null;
        throw const SyncRefusedException(403, 'view-only', {});
      };

      await tester.pump(const Duration(seconds: 5));
      final row = find.byKey(ValueKey('member-row-${bob.userId}'));
      await until(tester, () => row.evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
      expect(row, findsOneWidget);
      expect(
        find.text('You have View only access to this space.'),
        findsOneWidget,
      );
      expect(bobOnServer(), isTrue);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a removal put off by a lost connection shows them being '
        'removed until it goes', (tester) async {
      await sharedWithBobAndCarol(tester);
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await removeBob(tester);
      server.onRemoval = () async {
        server.onRemoval = null;
        throw const SyncTransientException('offline');
      };

      await tester.pump(const Duration(seconds: 5));
      final row = find.byKey(ValueKey('member-row-${bob.userId}'));
      await until(tester, () => row.evaluate().isNotEmpty);
      expect(
        find.descendant(of: row, matching: find.text('Removing…')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('member-menu-${bob.userId}')), findsNothing);
      expect(bobOnServer(), isTrue);

      await tester.runAsync(alice.sync.syncNow);
      await until(tester, () => row.evaluate().isEmpty);
      expect(bobOnServer(), isFalse);
      expect(row, findsNothing);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('Undo after the sheet has closed invites them again, and '
        'says so', (tester) async {
      await sharedWithBob(tester);
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await removeBob(tester);
      expect(alice.notes.byId(note.id)!.isShared, isTrue);

      await tester.tap(find.byKey(const ValueKey('share-dialog-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-dialog-close')), findsNothing);
      await until(tester, () => !alice.notes.byId(note.id)!.isShared);
      expect(alice.notes.byId(note.id)!.isShared, isFalse);

      await tester.tap(find.text('Undo'));
      await until(tester, () => alice.notes.byId(note.id)!.isShared);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(server.outbox.last.to, bob.email);
      final bobName = server.user(bob.userId).name.split(' ').first;
      expect(
        find.text(
          'Invited $bobName again. They can see the note once they accept.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('can see this note again'), findsNothing);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('removing somebody says who loses what, and Undo brings them '
        'back', (tester) async {
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        await carol.boot();
        note = alice.notes.create(body: 'Ours');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(note.id, email: bob.email);
        await bob.sharing.acceptInvite(server.outbox.last.token);
        await alice.sync.syncNow();
        await alice.sharing.addPerson(note.id, carol.email, allNotes: true);
      });

      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Remove from this note'));
      await tester.pumpAndSettle();

      final body = find.textContaining('stops seeing this note');
      expect(body, findsOneWidget);
      expect(
        find.textContaining('stays in your notes, with everything'),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('Removed'), findsOneWidget);
      expect(find.byKey(ValueKey('member-menu-${bob.userId}')), findsNothing);

      await tester.tap(find.text('Undo'));
      await until(
        tester,
        () => alice.sharing.notesSharedWith(bob.email).isNotEmpty,
      );
      expect(
        alice.sharing.notesSharedWith(bob.email).map((note) => note.body),
        contains('Ours'),
      );
      // The toast holds the offer for four seconds; nothing may outlive the
      // test.
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets(
      'a pending invitation can be copied, sent again, or cancelled',
      (tester) async {
        late Note pending;
        await tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          pending = alice.notes.create(body: 'Ours');
          await alice.sync.syncNow();
          await alice.sharing.shareNoteWith(pending.id, email: bob.email);
        });
        final copied = captureClipboard(tester);
        await openSheet(tester, alice.notes.byId(pending.id)!, alice);

        final token = server.outbox.single.token;
        final menu = find.byKey(ValueKey('invite-menu-$token'));
        expect(menu, findsOneWidget);

        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy link'));
        await tester.pumpAndSettle();
        expect(copied.single, contains('join/$token'));

        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('Send again'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(find.text('Sent again to ${bob.email}'), findsOneWidget);

        await tester.tap(
          find.byKey(
            ValueKey(
              'invite-menu-${server.spaces.values.last.invites.keys.single}',
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel invitation…'));
        await tester.pumpAndSettle();
        expect(find.textContaining('stop working'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Invitation to ${bob.email} cancelled'),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets('the owner gets Stop sharing, a member gets a copy and Leave', (
    tester,
  ) async {
    late Note theirs;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      final note = alice.notes.create(body: 'Ours');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(note.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.single.token);
      await alice.sync.syncNow();
      await bob.sync.syncNow();
      theirs = bob.notes.notes.single;
    });

    await openSheet(tester, theirs, bob);
    // Never Move to my notes: that would take the note from its owner.
    expect(find.byKey(const ValueKey('unshare-note')), findsNothing);
    expect(find.text('Move to my notes'), findsNothing);
    expect(find.byKey(const ValueKey('copy-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('leave-space')), findsOneWidget);
    expect(find.byKey(const ValueKey('stop-sharing')), findsNothing);
    // A member may not change access, so the person beside them has no menu.
    expect(find.byKey(ValueKey('member-menu-${alice.userId}')), findsNothing);
    expect(find.byKey(const ValueKey('share-email')), findsNothing);
    expect(
      find.textContaining('can add people or change access'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('leave-space')));
    await tester.pumpAndSettle();
    expect(find.text('Keep a private copy in my notes'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    expect(bob.sharing.teams, isEmpty);
    expect(bob.notes.notes.where((n) => !n.isShared), hasLength(1));
    bob.dispose();
  });

  group('Block and Leave in the sheet', () {
    /// [owner] shares a new note with [people] at once, and they are all in
    /// and hold the key.
    Future<Note> shareFrom(
      Device owner,
      String body,
      List<Device> people,
    ) async {
      final note = owner.notes.create(body: body);
      await owner.sync.syncNow();
      await owner.sharing.shareNoteWithPeople(note.id, {
        for (final person in people) person.email: SpaceRole.member,
      });
      for (final person in people) {
        await person.sharing.acceptInvite(
          server.outbox.lastWhere((sent) => sent.to == person.email).token,
        );
      }
      await owner.sync.syncNow();
      for (final person in people) {
        await person.sync.syncNow();
      }
      return owner.notes.byId(note.id)!;
    }

    /// The sheet for [note], or with [whole] the sheet for its whole share,
    /// the one a joined link opens.
    Future<void> open(
      WidgetTester tester,
      Note note,
      Device device, {
      required bool whole,
    }) async {
      if (!whole) return openSheet(tester, note, device);
      await tester.pumpWidget(
        harness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showSpaceDialog(
                context,
                spaceId: note.spaceId!,
                sharing: device.sharing,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    String from(bool whole) =>
        whole ? "from the share's sheet" : "from the note's sheet";

    for (final whole in [false, true]) {
      testWidgets('your own row reads You and shows your own initial, '
          '${from(whole)}', (tester) async {
        server.user(alice.userId).name = 'Alice Moreau';
        server.user(bob.userId).name = 'Bob Stone';
        late Note ours;
        await tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          ours = await shareFrom(alice, 'Ours', [bob]);
        });
        for (final (device, initial) in [(alice, 'A'), (bob, 'B')]) {
          await open(tester, device.notes.byId(ours.id)!, device, whole: whole);
          final row = find.byKey(ValueKey('member-row-${device.userId}'));
          expect(
            find.descendant(of: row, matching: find.text('You')),
            findsWidgets,
          );
          final face = find.descendant(
            of: row,
            matching: find.byType(ProfileAvatar),
          );
          expect(
            find.descendant(of: face, matching: find.text(initial)),
            findsOneWidget,
            reason: device.userId,
          );
          expect(
            find.descendant(of: face, matching: find.text('Y')),
            findsNothing,
          );
          await tester.pumpWidget(const SizedBox());
        }
      });
    }

    /// The notes [device] holds of its own, by body.
    List<String> ownNotes(Device device) => [
      for (final note in device.notes.notes)
        if (!note.isShared) note.body,
    ]..sort();

    testWidgets("the share's sheet keeps the owner body's gap under its email "
        'field: 12 on phones and 10 on the Mac', (tester) async {
      late Note ours;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        ours = await shareFrom(alice, 'Ours', [bob]);
      });
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      for (final (platform, size, gap) in [
        (TargetPlatform.iOS, const Size(393, 852), 12.0),
        (TargetPlatform.macOS, const Size(1100, 720), 10.0),
      ]) {
        AppPlatform.debugTargetPlatformOverride = platform;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await open(tester, alice.notes.byId(ours.id)!, alice, whole: true);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('share-role'))).dy -
              tester
                  .getBottomLeft(find.byKey(const ValueKey('share-email')))
                  .dy,
          gap,
          reason: '$platform',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets("an access change from the share's sheet asks first when it "
        'covers more than one note, and its notice is announced', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      late Note ours;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        ours = await shareFrom(alice, 'Ours', [bob]);
        await alice.sharing.shareNote(
          alice.notes.create(body: 'Renewal notes').id,
          spaceId: ours.spaceId!,
        );
      });
      await open(tester, alice.notes.byId(ours.id)!, alice, whole: true);

      final bobName = server.user(bob.userId).name.split(' ').first;
      for (final answer in ['sharing-ask-cancel', 'sharing-ask-ok']) {
        await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
        await tester.pumpAndSettle();
        await tester.tap(menuItem('Can view'));
        await tester.pumpAndSettle();
        expect(find.text('Let $bobName only view?'), findsOneWidget);
        expect(
          find.text(
            '$bobName sees 2 notes you share together, and the change is for '
            'all of them.',
          ),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(ValueKey(answer)));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(
          server.spaces[ours.spaceId]!.members[bob.userId],
          answer == 'sharing-ask-ok' ? SpaceRole.viewer : SpaceRole.member,
        );
      }
      expect(
        tester.getSemantics(find.text('Access changed')),
        isSemantics(isLiveRegion: true),
      );
      semantics.dispose();
      await tester.pump(const Duration(seconds: 6));
    });

    /// Alice shares two notes in one share with Bob, who can edit, and Carol,
    /// who can only view, and both are in.
    Future<Note> twoWithBobAndCarol(WidgetTester tester) async {
      late Note ours;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        await carol.boot();
        ours = alice.notes.create(body: 'Ours');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWithPeople(ours.id, {
          bob.email: SpaceRole.member,
          carol.email: SpaceRole.viewer,
        });
        for (final person in [bob, carol]) {
          await person.sharing.acceptInvite(
            server.outbox.lastWhere((sent) => sent.to == person.email).token,
          );
        }
        await alice.sync.syncNow();
        await alice.sharing.shareNote(
          alice.notes.create(body: 'Renewal notes').id,
          spaceId: alice.notes.byId(ours.id)!.spaceId!,
        );
      });
      return alice.notes.byId(ours.id)!;
    }

    testWidgets("after Block, the share's sheet is titled by the people "
        'still in it', (tester) async {
      final ours = await twoWithBobAndCarol(tester);
      final space = alice.sharing.spaceById(ours.spaceId)!;
      final placeholder = space.name!;
      final carolName = space.member(carol.userId)!.firstName;
      expect(placeholder, startsWith('With '));
      await open(tester, ours, alice, whole: true);

      await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Block…'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await until(
        tester,
        () => !alice.sharing
            .spaceById(ours.spaceId)!
            .members
            .any((member) => member.userId == bob.userId),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('member-row-${carol.userId}')),
        findsOneWidget,
      );
      expect(find.text('Shared with $carolName'), findsOneWidget);
      expect(find.text(placeholder), findsNothing);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets("Remove from the share's sheet asks first and says these "
        'notes, and Undo after the sheet has closed invites them again, '
        'still only able to view', (tester) async {
      final ours = await twoWithBobAndCarol(tester);
      final spaceId = ours.spaceId!;
      final name = alice.sharing
          .spaceById(spaceId)!
          .member(carol.userId)!
          .firstName;
      await open(tester, ours, alice, whole: true);
      for (final answer in ['sharing-ask-cancel', 'sharing-ask-ok']) {
        await tester.tap(find.byKey(ValueKey('member-menu-${carol.userId}')));
        await tester.pumpAndSettle();
        await tester.tap(menuItem('Remove from these notes'));
        await tester.pumpAndSettle();
        expect(find.text('Remove $name from these notes?'), findsOneWidget);
        expect(
          find.text(
            '$name stops seeing these notes, and they leave $name’s devices. '
            'They stay in your notes, with everything $name wrote.',
          ),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(ValueKey(answer)));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(
          server.spaces[spaceId]!.members.containsKey(carol.userId),
          answer == 'sharing-ask-cancel',
        );
      }
      expect(find.text('Removed $name from these notes'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('share-dialog-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-dialog-close')), findsNothing);
      final sentBefore = server.outbox.length;
      await tester.tap(find.text('Undo'));
      final sent = find.text('Invitation sent to ${carol.email}');
      await until(tester, () => sent.evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
      expect(sent, findsOneWidget);
      expect(server.outbox, hasLength(sentBefore + 1));
      expect(server.outbox.last.to, carol.email);
      expect(
        alice.sharing.spaceById(spaceId)!.invites.single.role,
        SpaceRole.viewer,
      );
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets("Stop sharing from the share's sheet asks first, and Undo "
        'after the sheet has closed invites everyone again at their access', (
      tester,
    ) async {
      final ours = await twoWithBobAndCarol(tester);
      final other = alice.notes.notes.singleWhere(
        (note) => note.body == 'Renewal notes',
      );
      await open(tester, ours, alice, whole: true);
      for (final answer in ['sharing-ask-cancel', 'sharing-ask-ok']) {
        await tester.tap(find.byKey(const ValueKey('stop-sharing')));
        await tester.pumpAndSettle();
        expect(find.text('Stop sharing 2 notes?'), findsOneWidget);
        expect(
          find.textContaining(
            'access. The notes stay in your notes, with every change.',
          ),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(ValueKey(answer)));
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        await tester.pumpAndSettle();
        if (answer == 'sharing-ask-ok') {
          await until(tester, () => !alice.notes.byId(ours.id)!.isShared);
        }
        expect(
          alice.notes.byId(ours.id)!.isShared,
          answer == 'sharing-ask-cancel',
        );
      }
      expect(alice.notes.byId(other.id)!.isShared, isFalse);
      final close = find.byKey(const ValueKey('share-dialog-close'));
      await until(tester, () => close.evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(close, findsNothing);
      expect(find.text('Stopped sharing 2 notes'), findsOneWidget);

      final sentBefore = server.outbox.length;
      await tester.tap(find.text('Undo'));
      final again = find.textContaining('Invitations sent to');
      await until(tester, () => again.evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
      expect(again, findsOneWidget);
      expect(find.textContaining('Shared again'), findsNothing);
      final spaceId = alice.notes.byId(ours.id)!.spaceId;
      expect(spaceId, isNotNull);
      expect(alice.notes.byId(other.id)!.spaceId, spaceId);
      expect(
        {for (final sent in server.outbox.skip(sentBefore)) sent.to},
        {bob.email, carol.email},
      );
      expect(
        {
          for (final invite in alice.sharing.spaceById(spaceId!)!.invites)
            invite.email: invite.role,
        },
        {bob.email: SpaceRole.member, carol.email: SpaceRole.viewer},
      );
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets("Stop sharing from the share's sheet, when every note left "
        'in it is Hidden, asks without a count and says so after', (
      tester,
    ) async {
      late Note ours;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        ours = await shareFrom(alice, 'Ours', [bob]);
      });
      alice.notes.applyDoc(
        alice.notes.byId(ours.id)!.copyWith(hiddenAt: DateTime.now()),
      );
      await open(tester, alice.notes.byId(ours.id)!, alice, whole: true);
      await tester.tap(find.byKey(const ValueKey('stop-sharing')));
      await tester.pumpAndSettle();
      expect(find.text('Stop sharing?'), findsOneWidget);
      expect(find.textContaining('0 notes'), findsNothing);
      expect(
        find.textContaining(
          'access. Everything here stays in your notes, with every change.',
        ),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      await until(tester, () => !alice.notes.byId(ours.id)!.isShared);
      final close = find.byKey(const ValueKey('share-dialog-close'));
      await until(tester, () => close.evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Stopped sharing'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets("Undo after Stop sharing in the share's sheet says shared "
        'again when the people are still in another share with Alice', (
      tester,
    ) async {
      late Note ours;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        ours = await shareFrom(alice, 'Ours', [bob]);
        final other = await alice.sharing.createSpace('Other');
        await alice.sharing.invite(other.id, bob.email, role: SpaceRole.member);
        await bob.sharing.acceptInvite(server.outbox.last.token);
        await alice.sync.syncNow();
        await alice.sharing.shareNote(
          alice.notes.create(body: 'Elsewhere').id,
          spaceId: other.id,
        );
      });
      await open(tester, alice.notes.byId(ours.id)!, alice, whole: true);
      await tester.tap(find.byKey(const ValueKey('stop-sharing')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      final close = find.byKey(const ValueKey('share-dialog-close'));
      await until(tester, () => close.evaluate().isEmpty);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Undo'));
      final again = find.textContaining('Shared again with');
      await until(tester, () => again.evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
      expect(again, findsOneWidget);
      expect(find.textContaining('sent to'), findsNothing);
      expect(
        alice.sharing.memberOn(ours.id, bob.email)?.role,
        SpaceRole.member,
      );
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets("Undo after Stop sharing in the share's sheet shares the "
        'visible notes again and leaves a Hidden one private', (tester) async {
      late Note ours;
      late Note hidden;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        ours = await shareFrom(alice, 'Ours', [bob]);
        hidden = alice.notes.create(body: 'Kept to myself');
        await alice.sharing.shareNote(
          hidden.id,
          spaceId: alice.notes.byId(ours.id)!.spaceId!,
        );
      });
      alice.notes.applyDoc(
        alice.notes.byId(hidden.id)!.copyWith(hiddenAt: DateTime.now()),
      );
      await open(tester, alice.notes.byId(ours.id)!, alice, whole: true);
      await tester.tap(find.byKey(const ValueKey('stop-sharing')));
      await tester.pumpAndSettle();
      expect(find.text('Stop sharing “Ours”?'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      final close = find.byKey(const ValueKey('share-dialog-close'));
      await until(tester, () => close.evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(alice.notes.byId(hidden.id)!.isShared, isFalse);

      await tester.tap(find.text('Undo'));
      final sent = find.textContaining('Invitation sent to');
      await until(tester, () => sent.evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Hidden'), findsNothing);
      expect(alice.notes.byId(ours.id)!.isShared, isTrue);
      expect(alice.notes.byId(hidden.id)!.isShared, isFalse);
      expect(alice.notes.byId(hidden.id)!.isHidden, isTrue);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('Block asks by the whole name, then says who is blocked', (
      tester,
    ) async {
      server.user(bob.userId).name = 'Bob Stone';
      late Note ours;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        ours = await shareFrom(alice, 'Ours', [bob]);
      });
      await open(tester, alice.notes.byId(ours.id)!, alice, whole: false);
      await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Block…'));
      await tester.pumpAndSettle();
      expect(find.text('Block Bob Stone?'), findsOneWidget);
      expect(
        find.textContaining('Bob loses access to everything you share'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final blocked = find.text('Blocked Bob Stone');
      await until(tester, () => blocked.evaluate().isNotEmpty);
      expect(blocked, findsOneWidget);
      expect(alice.sharing.hasBlocked(bob.email), isTrue);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('no sharing action takes the warning colour', (tester) async {
      late Note ours;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        ours = await shareFrom(alice, 'Ours', [bob]);
      });
      Color? colourOf(String key) => tester
          .widget<TextButton>(find.byKey(ValueKey(key)))
          .style
          ?.foregroundColor
          ?.resolve({});
      Color warning() => Theme.of(
        tester.element(find.byKey(const ValueKey('share-done'))),
      ).colorScheme.error;

      for (final whole in [false, true]) {
        await open(tester, alice.notes.byId(ours.id)!, alice, whole: whole);
        expect(colourOf('stop-sharing'), isNot(warning()), reason: from(whole));
        await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
        await tester.pumpAndSettle();
        final remove = find.descendant(
          of: find.byType(PopupMenuItem<String>),
          matching: find.textContaining('Remove from'),
        );
        expect(
          tester.widget<Text>(remove).style?.color,
          isNot(warning()),
          reason: from(whole),
        );
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('share-done')));
        await tester.pumpAndSettle();

        await open(tester, bob.notes.byId(ours.id)!, bob, whole: whole);
        expect(colourOf('leave-space'), isNot(warning()), reason: from(whole));
        await tester.tap(find.byKey(const ValueKey('share-done')));
        await tester.pumpAndSettle();
      }
      await tester.pump(const Duration(seconds: 6));
    });

    for (final whole in [false, true]) {
      testWidgets('Block ${from(whole)} asks first, then ends the shares '
          'Alice owns with them and leaves the one Bob owns, keeping copies '
          'of his notes', (tester) async {
        late Note mine;
        late Note withCarol;
        late Note theirs;
        await tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          await carol.boot();
          mine = await shareFrom(alice, 'Ours', [bob]);
          withCarol = await shareFrom(alice, 'All three', [bob, carol]);
          theirs = await shareFrom(bob, 'From Bob', [alice]);
          await alice.sync.syncNow();
        });
        expect(alice.sharing.teams, hasLength(3));

        await open(tester, alice.notes.byId(mine.id)!, alice, whole: whole);
        await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
        await tester.pumpAndSettle();
        await tester.tap(menuItem('Block…'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            'loses access to everything you share, you leave what',
          ),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await until(
          tester,
          () => alice.sharing.teams.every((space) => space.isOwner),
        );
        await tester.pumpAndSettle();

        expect(alice.sharing.hasBlocked(bob.email), isTrue);
        // Bob is in none of Alice's shares, and Carol keeps hers.
        expect(alice.sharing.notesSharedWith(bob.email), isEmpty);
        expect(alice.notes.byId(mine.id)!.isShared, isFalse);
        final kept = alice.sharing.spaceOf(alice.notes.byId(withCarol.id)!)!;
        expect(alice.sharing.audienceOf(kept).keys, [carol.email]);
        // Alice is out of Bob's share, with a copy of its note.
        expect(alice.sharing.notesSharedFrom(bob.email), isEmpty);
        expect(alice.sharing.teams.map((space) => space.id), [kept.id]);
        expect(
          server.spaces[theirs.spaceId]!.members,
          isNot(contains(alice.userId)),
        );
        expect(ownNotes(alice), ['From Bob', 'Ours']);
        await tester.pump(const Duration(seconds: 6));
      });
    }

    testWidgets(
      'the Block question keeps its button out of the warning colour',
      (tester) async {
        late Note mine;
        await tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          mine = await shareFrom(alice, 'Ours', [bob]);
        });

        await open(tester, alice.notes.byId(mine.id)!, alice, whole: false);
        await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
        await tester.pumpAndSettle();
        await tester.tap(menuItem('Block…'));
        await tester.pumpAndSettle();
        final ok = find.byKey(const ValueKey('sharing-ask-ok'));
        expect(
          tester.widget<TextButton>(ok).style?.foregroundColor?.resolve({}),
          isNot(Theme.of(tester.element(ok)).colorScheme.error),
        );
        await tester.tap(find.byKey(const ValueKey('sharing-ask-cancel')));
        await tester.pumpAndSettle();
        expect(alice.sharing.hasBlocked(bob.email), isFalse);
      },
    );

    Future<Note> threeFromAlice(WidgetTester tester) async {
      late Note first;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        first = alice.notes.create(body: 'Flights');
        final others = [
          alice.notes.create(body: 'Hotels'),
          alice.notes.create(body: 'Packing'),
        ];
        await alice.sync.syncNow();
        for (final note in [first, ...others]) {
          await alice.sharing.shareNoteWith(note.id, email: bob.email);
        }
        await bob.sharing.acceptInvite(server.outbox.single.token);
        await alice.sync.syncNow();
        await bob.sync.syncNow();
      });
      expect(bob.sharing.notesSharedFrom(alice.email), hasLength(3));
      return bob.notes.byId(first.id)!;
    }

    Future<void> askToLeave(
      WidgetTester tester,
      Note note, {
      required bool whole,
    }) async {
      await open(tester, note, bob, whole: whole);
      await tester.tap(find.byKey(const ValueKey('leave-space')));
      await tester.pumpAndSettle();
      final question = find.byKey(const ValueKey('sharing-ask'));
      Finder within(String text) =>
          find.descendant(of: question, matching: find.textContaining(text));
      expect(within('Leave 3 notes from '), findsOneWidget);
      expect(
        within('” together with 2 more, so you leave all of them.'),
        findsOneWidget,
      );
      if (!whole) expect(within('“Flights” together with'), findsOneWidget);
      expect(within('keeps the notes.'), findsOneWidget);
      expect(within('Keep private copies'), findsOneWidget);
      expect(within('Keep a private copy'), findsNothing);
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(bob.sync.syncNow);
    }

    for (final whole in [false, true]) {
      testWidgets('Leave ${from(whole)} with three notes in the share says '
          'so, and keeps copies of all three', (tester) async {
        final note = await threeFromAlice(tester);
        await askToLeave(tester, note, whole: whole);
        await leave(tester);

        expect(bob.sharing.teams, isEmpty);
        expect(bob.notes.notes.where((n) => n.isShared), isEmpty);
        expect(ownNotes(bob), ['Flights', 'Hotels', 'Packing']);
        bob.dispose();
      });

      testWidgets('Leave ${from(whole)} with three notes in the share, '
          'without copies, leaves all three', (tester) async {
        final note = await threeFromAlice(tester);
        await askToLeave(tester, note, whole: whole);
        await tester.tap(find.byKey(const ValueKey('sharing-ask-option')));
        await tester.pumpAndSettle();
        await leave(tester);

        expect(bob.sharing.teams, isEmpty);
        expect(bob.notes.notes, isEmpty);
        expect(alice.notes.notes.where((n) => n.isShared), hasLength(3));
        bob.dispose();
      });
    }
  });

  testWidgets('a member makes a private copy and the shared note stays put', (
    tester,
  ) async {
    late Note theirs;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      final note = alice.notes.create(body: 'Trip budget');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(note.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.single.token);
      await alice.sync.syncNow();
      await bob.sync.syncNow();
      theirs = bob.notes.notes.single;
    });

    await openSheet(tester, theirs, bob);
    await tester.tap(find.byKey(const ValueKey('copy-note')));
    await tester.pumpAndSettle();

    final copies = bob.notes.notes.where((n) => !n.isShared).toList();
    expect(copies, hasLength(1));
    expect(copies.single.body, 'Trip budget');
    expect(copies.single.id, isNot(theirs.id));
    await tester.runAsync(() async {
      await bob.sync.syncNow();
      await alice.sync.syncNow();
    });
    expect(bob.notes.byId(theirs.id)!.isShared, isTrue);
    expect(alice.notes.notes.single.isShared, isTrue);
    expect(find.text('Copied to my notes'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    bob.dispose();
  });

  test('a private copy is only made of a shared note', () async {
    await alice.boot();
    final mine = alice.notes.create(body: 'Mine');
    await expectLater(
      alice.sharing.makePrivateCopy(mine.id),
      throwsA(isA<SyncProtocolException>()),
    );
    await expectLater(
      alice.sharing.makePrivateCopy('missing'),
      throwsA(anything),
    );
    expect(alice.notes.notes, hasLength(1));
  });

  test(
    'a private copy keeps its attachments after leaving the space',
    () async {
      final root = await Directory.systemTemp.createTemp('kapy-copy-');
      addTearDown(() => root.delete(recursive: true));
      Device on(String user, String name) {
        final device = Device(
          server,
          userId: user,
          device: name,
          media: Directory('${root.path}/$name')..createSync(),
        );
        addTearDown(device.dispose);
        return device;
      }

      Future<void> settle(Device device) async {
        for (var pass = 0; pass < 5; pass++) {
          await device.sync.syncNow();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      final owner = on('user-4', 'owner');
      final laptop = on('user-5', 'laptop');
      await owner.boot();
      await laptop.boot();
      final bytes = Uint8List.fromList(List.generate(4096, (i) => i % 251));
      final hash = await owner.notes.blobs.put(bytes, extension: '.pdf');
      final note = owner.notes.create(body: 'Plan');
      owner.notes.updateDocument(
        note.id,
        'Plan\n${NoteAttachmentRef.placeholder}',
        const [],
        [
          NoteFileRef(
            offset: 5,
            hash: hash,
            key: Uint8List(32)..fillRange(0, 32, 7),
            mime: 'application/pdf',
            bytes: bytes.length,
            name: 'plan.pdf',
          ),
        ],
      );
      await settle(owner);
      await owner.sharing.shareNoteWith(note.id, email: laptop.email);
      await laptop.sharing.acceptInvite(server.outbox.single.token);
      await settle(owner);
      await settle(laptop);
      final theirs = laptop.notes.notes.single;
      expect(theirs.attachments.single.isUploaded, isTrue);

      await laptop.sharing.leave(theirs.spaceId!);
      await settle(laptop);

      final phone = on('user-5', 'phone');
      await phone.boot();
      await settle(phone);
      final copy = phone.notes.notes.single;
      expect(copy.isShared, isFalse);
      expect(copy.attachments.single.isUploaded, isTrue);
      expect(await phone.images!.fetch(hash), bytes);
      expect(owner.notes.byId(note.id)!.attachments.single.isUploaded, isTrue);
    },
  );

  testWidgets('Stop sharing brings the note home and Undo shares it again, '
      'and the ask, the toast and Undo agree', (tester) async {
    late Note note;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      note = alice.notes.create(body: 'Ours');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(note.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.single.token);
      await alice.sync.syncNow();
      await bob.sync.syncNow();
    });

    await openSheet(tester, alice.notes.byId(note.id)!, alice);
    final bobName = alice.sharing
        .spaceOf(alice.notes.byId(note.id)!)!
        .shortNameOf(bob.userId);
    await tester.tap(find.byKey(const ValueKey('stop-sharing')));
    await tester.pumpAndSettle();
    expect(find.text('Stop sharing “Ours”?'), findsOneWidget);
    expect(
      find.text(
        '$bobName loses access. The note stays in your notes, with every '
        'change.',
      ),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));

    expect(alice.notes.byId(note.id)!.isShared, isFalse);
    expect(find.text('Stopped sharing “Ours”'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    final again = find.text('$bobName can see this note again');
    await until(tester, () => again.evaluate().isNotEmpty);
    expect(again, findsOneWidget);
    expect(alice.sharing.memberOn(note.id, bob.email), isNotNull);
    expect(
      alice.sharing.notesSharedWith(bob.email).map((note) => note.body),
      contains('Ours'),
    );
    expect(server.outbox.last.to, bob.email);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Undo after the sheet has closed still shares the note again', (
    tester,
  ) async {
    late Note note;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      note = alice.notes.create(body: 'Ours');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(note.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.single.token);
      await alice.sync.syncNow();
    });

    await openSheet(tester, alice.notes.byId(note.id)!, alice);
    await tester.tap(find.byKey(const ValueKey('stop-sharing')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-dialog-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('share-dialog-close')), findsNothing);

    await tester.tap(find.text('Undo'));
    final again = find.textContaining('can see this note again');
    await until(tester, () => again.evaluate().isNotEmpty);
    expect(tester.takeException(), isNull);
    expect(again, findsOneWidget);
    expect(alice.notes.byId(note.id)!.isShared, isTrue);
    expect(alice.sharing.memberOn(note.id, bob.email), isNotNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Undo after Stop sharing puts a note back with exactly its '
      'people, and nobody gets notes meant for someone else', (tester) async {
    const dana = 'dana@example.com';
    Future<void> accept(Device device, String token) async {
      try {
        await device.sharing.acceptInvite(token);
      } on SyncRefusedException {
        return;
      }
    }

    late Note forBob;
    late Note forCarol;
    late Note ours;
    await tester.runAsync(() async {
      for (final device in [alice, bob, carol]) {
        await device.boot();
      }
      forBob = alice.notes.create(body: 'Only for Bob');
      forCarol = alice.notes.create(body: 'Only for Carol');
      ours = alice.notes.create(body: 'For all of us');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(forBob.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.last.token);
      await alice.sharing.shareNoteWith(forCarol.id, email: carol.email);
      await carol.sharing.acceptInvite(server.outbox.last.token);
      await alice.sharing.shareNoteWithPeople(ours.id, {
        bob.email: SpaceRole.member,
        carol.email: SpaceRole.viewer,
        dana: SpaceRole.member,
      });
      for (final invite in [...server.outbox]) {
        if (invite.to == bob.email) await accept(bob, invite.token);
        if (invite.to == carol.email) await accept(carol, invite.token);
      }
      for (final device in [alice, bob, carol, alice]) {
        await device.sharing.refresh();
        await device.sync.syncNow();
      }
    });
    final home = alice.notes.byId(ours.id)!.spaceId!;
    final people = alice.sharing.audienceOf(alice.sharing.spaceById(home)!);
    expect(people, {
      bob.email: SpaceRole.member,
      carol.email: SpaceRole.viewer,
      dana: SpaceRole.member,
    });

    await openSheet(tester, alice.notes.byId(ours.id)!, alice);
    await tester.tap(find.byKey(const ValueKey('stop-sharing')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(alice.notes.byId(ours.id)!.isShared, isFalse);

    await tester.tap(find.text('Undo'));
    // Bob and Carol are back as members; dana only ever had an invitation.
    final again = find.text(
      'Invited dana again. They can see the note once they accept.',
    );
    await until(tester, () => again.evaluate().isNotEmpty);
    expect(again, findsOneWidget);
    expect(find.textContaining('Shared again'), findsNothing);
    await tester.runAsync(() async {
      for (final invite in [...server.outbox]) {
        if (invite.to == bob.email) await accept(bob, invite.token);
        if (invite.to == carol.email) await accept(carol, invite.token);
      }
      for (final device in [bob, carol, bob, carol]) {
        await device.sharing.refresh();
        await device.sync.syncNow();
      }
    });

    expect(alice.notes.byId(ours.id)!.spaceId, home);
    expect(alice.sharing.audienceOf(alice.sharing.spaceById(home)!), people);
    expect(bob.notes.byId(ours.id)?.body, 'For all of us');
    expect(carol.notes.byId(ours.id)?.body, 'For all of us');
    expect(bob.notes.byId(forCarol.id), isNull);
    expect(carol.notes.byId(forBob.id), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  group('the invite link', () {
    late Note note;
    late String spaceId;

    Future<void> sharedWithBob(WidgetTester tester) =>
        tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          note = alice.notes.create(body: 'Trip plan');
          await alice.sync.syncNow();
          final space = await alice.sharing.shareNoteWith(
            note.id,
            email: bob.email,
          );
          spaceId = space.id;
        });

    testWidgets('is one switch, and copies the link it turns on', (
      tester,
    ) async {
      await sharedWithBob(tester);
      final copied = captureClipboard(tester);
      final send = FakeSend();
      final joining = joiningOver(send);
      addTearDown(joining.dispose);

      await openSheet(
        tester,
        alice.notes.byId(note.id)!,
        alice,
        joining: joining,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Off · Turn on'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-link-switch')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();

      final made = send.calls.singleWhere((call) => call.$1 == 'PUT');
      expect(made.$3, {'role': 'viewer', 'approval': false});
      expect(copied.single, 'https://kapynotes.com/space/tok-1');
      expect(find.textContaining('Link copied'), findsOneWidget);
      expect(find.byKey(const ValueKey('share-link-copy')), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-link-switch')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();
      expect(send.sawPath('DELETE', 'spaces/$spaceId/link'), isTrue);
      expect(find.textContaining('The link is off'), findsOneWidget);
    });

    testWidgets('says when it opens more than this note', (tester) async {
      await sharedWithBob(tester);
      await tester.runAsync(() async {
        await alice.sharing.shareNote(
          alice.notes.create(body: 'Also this').id,
          spaceId: spaceId,
        );
      });
      final copied = captureClipboard(tester);
      final joining = joiningOver(FakeSend());
      addTearDown(joining.dispose);
      await openSheet(
        tester,
        alice.notes.byId(note.id)!,
        alice,
        joining: joining,
      );
      await tester.pumpAndSettle();

      // Before the switch is touched, since turning it on copies the link.
      expect(find.textContaining('Off · Turn on'), findsOneWidget);
      expect(copied, isEmpty);
      expect(
        find.textContaining('The link opens both notes here'),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-link-switch')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();

      expect(
        find.textContaining('The link opens both notes here'),
        findsOneWidget,
      );
    });
  });

  group('the states', () {
    testWidgets('a Hidden note says why it stays private', (tester) async {
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        final at = DateTime.utc(2026, 11, 1);
        alice.notes.importNotes([
          Note(
            id: 'hidden-1',
            body: 'Secret plans',
            createdAt: at,
            updatedAt: at,
            hiddenAt: at,
          ),
        ]);
        await alice.sync.syncNow();
        note = alice.notes.byId('hidden-1')!;
      });

      await openSheet(tester, note, alice);
      expect(find.byKey(const ValueKey('share-hidden')), findsOneWidget);
      expect(find.text('Hidden notes stay private'), findsOneWidget);
      expect(find.byKey(const ValueKey('share-email')), findsNothing);
      expect(find.byKey(const ValueKey('share-done')), findsOneWidget);
    });

    testWidgets('a Free account is told sharing is part of Pro, before it '
        'types', (tester) async {
      final session = FakeSession()..signIn(alice.userId);
      final billing = billingFor(
        session,
        FakeBillingApi()..answer = () => entitlementsFor(sync: false),
      );
      addTearDown(billing.dispose);
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
        await billing.refresh();
      });

      await openSheet(tester, note, alice, billing: billing);
      expect(find.byKey(const ValueKey('share-free')), findsOneWidget);
      expect(find.text('Sharing is part of Pro'), findsOneWidget);
      expect(find.textContaining('don’t need Pro'), findsOneWidget);
      expect(find.byKey(const ValueKey('share-email')), findsNothing);
      expect(find.text('See Pro'), findsOneWidget);
    });

    testWidgets('a Free account the server lets share is not stopped', (
      tester,
    ) async {
      final session = FakeSession()..signIn(alice.userId);
      final billing = billingFor(session, FakeBillingApi());
      addTearDown(billing.dispose);
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
        await billing.refresh();
      });
      expect(billing.hasPro, isFalse);
      expect(billing.entitlements!.sharing, isTrue);

      await openSheet(tester, note, alice, billing: billing);
      expect(find.byKey(const ValueKey('share-free')), findsNothing);
      expect(find.byKey(const ValueKey('share-email')), findsOneWidget);
    });

    testWidgets('offline disables the actions and says the note is safe', (
      tester,
    ) async {
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
        server.failNext = const SyncTransientException('no network');
        await alice.sync.syncNow();
      });
      expect(alice.sync.status, SyncStatus.offline);

      await openSheet(tester, note, alice);
      expect(find.byKey(const ValueKey('share-offline')), findsOneWidget);
      expect(find.textContaining('Your note is safe'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('share-email')),
        bob.email,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('share-submit-Share')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('a failure is said in the sheet, keeping what was typed and '
        'showing no toast', (tester) async {
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
      });

      await openSheet(tester, note, alice);
      await tester.enterText(
        find.byKey(const ValueKey('share-email')),
        bob.email,
      );
      await tester.pumpAndSettle();

      server.failNext = const SyncRefusedException(409, 'the space is full', {
        'error': 'the space is full',
      });
      await share(tester);

      expect(find.byKey(const ValueKey('share-error')), findsOneWidget);
      expect(find.text('Sharing failed'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('share-email')))
            .controller!
            .text,
        bob.email,
      );
      expect(alice.notes.byId(note.id)!.isShared, isFalse);
    });
  });

  group('the sheet on a phone', () {
    setUp(() {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    });

    testWidgets('is a bottom sheet rather than a dialog', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
      });

      await openSheet(tester, note, alice);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('share-email')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a private share sheet leaves the phone keyboard closed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
      });

      await tester.pumpWidget(
        harness(
          Builder(
            builder: (context) => Column(
              children: [
                const TextField(
                  key: ValueKey('focused-note-field'),
                  autofocus: true,
                ),
                TextButton(
                  onPressed: () => showShareDialog(
                    context,
                    note: note,
                    sharing: alice.sharing,
                  ),
                  child: const Text('open'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('share-email')),
      );
      expect(field.autofocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('takes the phone sheet measurements: a 17 pt header, '
        'people in 56 pt rows with no card, and a footer of words with Done '
        'at the right', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWithPeople(note.id, {
          bob.email: SpaceRole.member,
        });
        await bob.sharing.acceptInvite(server.outbox.single.token);
        await alice.sync.syncNow();
        await bob.sync.syncNow();
      });

      for (final (device, actions) in [
        (alice, ['stop-sharing']),
        (bob, ['copy-note', 'leave-space']),
      ]) {
        await openSheet(tester, device.notes.byId(note.id)!, device);
        final palette = tester.element(find.byType(BottomSheet)).palette;
        expect(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(SharingSheetFrame),
          ),
          findsOneWidget,
        );
        final title = tester
            .widgetList<Text>(
              find.text(device == alice ? 'Share' : 'Shared with you'),
            )
            .first;
        expect(title.style!.fontSize, 17);
        expect(
          title.style!.fontVariations,
          contains(const FontVariation('wght', 600)),
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('share-dialog-close'))),
          const Size(44, 44),
        );

        final label = tester.widget<Text>(find.text('People with access'));
        expect(label.style!.fontSize, 13);
        expect(label.style!.color, palette.textTertiary);
        final row = find.byKey(ValueKey('member-row-${alice.userId}'));
        expect(tester.getSize(row).height, greaterThanOrEqualTo(56));
        expect(
          tester
              .widget<ProfileAvatar>(
                find.descendant(of: row, matching: find.byType(ProfileAvatar)),
              )
              .extent,
          32,
        );
        expect(
          find.ancestor(of: row, matching: find.byType(KapyControlSurface)),
          findsNothing,
        );

        final done = find.byKey(const ValueKey('share-done'));
        // ignore: avoid_print
        print(
          'DBG done=${tester.getRect(done)} frame=${tester.getRect(find.byType(SharingSheetFrame))} sheet=${tester.getRect(find.byType(BottomSheet))} view=${tester.view.physicalSize}',
        );
        for (final key in actions) {
          final action = find.byKey(ValueKey(key));
          expect(
            find.descendant(of: action, matching: find.byType(KapyIcon)),
            findsNothing,
          );
          expect(
            tester.getRect(action).right,
            lessThanOrEqualTo(tester.getRect(done).left),
          );
          expect(
            tester
                .widget<TextButton>(action)
                .style!
                .foregroundColor!
                .resolve({}),
            palette.textSecondary,
          );
        }
        expect(
          tester.widget<TextButton>(done).style!.foregroundColor!.resolve({}),
          palette.textPrimary,
        );
        for (final key in [...actions, 'share-done']) {
          expect(
            tester
                .widget<TextButton>(find.byKey(ValueKey(key)))
                .style!
                .textStyle!
                .resolve({})!
                .fontFamily,
            AppFonts.ui,
            reason: '$key keeps the app’s face',
          );
        }
        expect(
          tester.getTopRight(done).dx,
          tester.getTopRight(find.byType(SharingSheetFrame)).dx - 12,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(done);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('the ask that slides up keeps the app’s face on its buttons', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(note.id, email: bob.email);
        await bob.sharing.acceptInvite(server.outbox.single.token);
        await alice.sync.syncNow();
      });
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await tester.tap(find.byKey(const ValueKey('stop-sharing')));
      await tester.pumpAndSettle();
      for (final key in ['sharing-ask-cancel', 'sharing-ask-ok']) {
        expect(
          tester
              .widget<TextButton>(find.byKey(ValueKey(key)))
              .style!
              .textStyle!
              .resolve({})!
              .fontFamily,
          AppFonts.ui,
          reason: '$key keeps the app’s face',
        );
      }
      await tester.tap(find.byKey(const ValueKey('sharing-ask-cancel')));
      await tester.pumpAndSettle();
      expect(alice.notes.byId(note.id)!.isShared, isTrue);
    });

    testWidgets('P09’s controls: a quiet field, a quietly lifted access, a '
        'sage-tinted Share, and an Invite link row under a hairline rather '
        'than a card', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
      });
      await openSheet(tester, note, alice, joining: joiningOver(FakeSend()));
      final palette = tester.element(find.byType(BottomSheet)).palette;

      final field = find.byKey(const ValueKey('share-email'));
      final decoration = tester.widget<TextField>(field).decoration!;
      expect(tester.getSize(field).height, 44);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('share-role'))).dy -
            tester.getBottomLeft(field).dy,
        12,
      );
      expect(decoration.fillColor, palette.textPrimary.withValues(alpha: 0.04));
      expect(decoration.enabledBorder!.borderSide, BorderSide.none);

      Color? fill(String key) => tester
          .widget<TextButton>(find.byKey(ValueKey(key)))
          .style!
          .backgroundColor
          ?.resolve({});
      expect(
        tester.getSize(find.byKey(const ValueKey('share-role'))).height,
        36,
      );
      expect(
        fill('share-role-member'),
        palette.textPrimary.withValues(alpha: 0.07),
      );
      expect(fill('share-role-viewer'), isNull);
      await tester.tap(segment('Can view'));
      await tester.pumpAndSettle();
      expect(
        fill('share-role-viewer'),
        palette.textPrimary.withValues(alpha: 0.07),
      );
      expect(fill('share-role-member'), isNull);

      final share = tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('share-submit-Share')),
          )
          .style!;
      expect(
        share.backgroundColor!.resolve({}),
        palette.accentText.withValues(alpha: 0.16),
      );
      expect(share.foregroundColor!.resolve({}), palette.accentText);

      final link = find.byKey(const ValueKey('share-link'));
      expect(
        find.ancestor(of: link, matching: find.byType(KapyControlSurface)),
        findsNothing,
      );
      expect(
        find.descendant(of: link, matching: find.byType(KapyControlSurface)),
        findsNothing,
      );
      expect(tester.getSize(link).height, greaterThanOrEqualTo(52));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('on a Mac the same controls take S02’s sizes: a 32 field, a 28 '
      'access track and Share in the sage tint, with the link as a row', (
    tester,
  ) async {
    late Note note;
    await tester.runAsync(() async {
      await alice.boot();
      note = alice.notes.create(body: 'Holiday budget');
      await alice.sync.syncNow();
    });
    await openSheet(tester, note, alice, joining: joiningOver(FakeSend()));
    final palette = tester
        .element(find.byKey(const ValueKey('share-dialog')))
        .palette;
    expect(
      tester.getSize(find.byKey(const ValueKey('share-email'))).height,
      32,
    );
    expect(tester.getSize(find.byKey(const ValueKey('share-role'))).height, 28);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('share-submit-Share')),
          )
          .style!
          .backgroundColor!
          .resolve({}),
      palette.accentText.withValues(alpha: 0.16),
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('share-link')),
        matching: find.byType(KapyControlSurface),
      ),
      findsNothing,
    );
  });

  testWidgets('on Windows the dialog names its route with its own title, '
      'for the owner and for a viewer', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final semantics = tester.ensureSemantics();
    late Note note;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      note = alice.notes.create(body: 'Holiday budget');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(
        note.id,
        email: bob.email,
        role: SpaceRole.viewer,
      );
      await bob.sharing.acceptInvite(server.outbox.single.token);
      await alice.sync.syncNow();
      await bob.sync.syncNow();
    });
    for (final (device, title) in [
      (alice, 'Share'),
      (bob, 'Shared with you'),
    ]) {
      await openSheet(tester, device.notes.byId(note.id)!, device);
      final route = find.ancestor(
        of: find.byKey(const ValueKey('share-dialog')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.namesRoute == true,
        ),
      );
      expect(route, findsOneWidget);
      expect(
        tester.getSemantics(route),
        isSemantics(label: title, scopesRoute: true, namesRoute: true),
      );
      await tester.tap(find.byKey(const ValueKey('share-done')));
      await tester.pumpAndSettle();
    }
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  group('Tab on a Mac', () {
    /// The keyed control holding the keyboard focus.
    String? focused() {
      String? key;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        element,
      ) {
        final found = element.widget.key;
        if (found is! ValueKey<String> || !found.value.startsWith('share-')) {
          return true;
        }
        key = found.value;
        return false;
      });
      return key;
    }

    /// Presses Tab, or Shift+Tab when [back], and says where each press
    /// lands.
    Future<List<String?>> tab(
      WidgetTester tester,
      int presses, {
      bool back = false,
    }) async {
      final reached = <String?>[];
      for (var press = 0; press < presses; press++) {
        if (back) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        if (back) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        reached.add(focused());
      }
      return reached;
    }

    /// A new note of Alice's, after she has shared another with Bob and
    /// Carol, so both are suggested.
    Future<Note> afterSharingWithBobAndCarol(WidgetTester tester) async {
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        await carol.boot();
        final trip = alice.notes.create(body: 'Trip budget');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWithPeople(trip.id, {
          bob.email: SpaceRole.member,
          carol.email: SpaceRole.viewer,
        });
        for (final device in [bob, carol]) {
          await device.sharing.acceptInvite(
            server.outbox.lastWhere((sent) => sent.to == device.email).token,
          );
        }
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
        await alice.sharing.refresh();
      });
      return note;
    }

    testWidgets('walks from the email field through the people it suggests '
        'to the rest of the dialog', (tester) async {
      await openSheet(tester, await afterSharingWithBobAndCarol(tester), alice);
      expect(await tab(tester, 9), [
        'share-dialog-close',
        'share-email',
        'share-suggest-${bob.email}',
        'share-suggest-${carol.email}',
        'share-role-member',
        'share-role-viewer',
        'share-submit-Share',
        'share-done',
        'share-dialog-close',
      ]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('on an account that has never shared walks the dialog as '
        'before', (tester) async {
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
      });
      await openSheet(tester, note, alice);
      expect(await tab(tester, 7), [
        'share-dialog-close',
        'share-email',
        'share-role-member',
        'share-role-viewer',
        'share-submit-Share',
        'share-done',
        'share-dialog-close',
      ]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('with Shift walks back through the suggestions and the '
        'dialog', (tester) async {
      await openSheet(tester, await afterSharingWithBobAndCarol(tester), alice);
      await tab(tester, 4);
      expect(focused(), 'share-suggest-${carol.email}');
      expect(await tab(tester, 8, back: true), [
        'share-suggest-${bob.email}',
        'share-email',
        'share-dialog-close',
        'share-done',
        'share-submit-Share',
        'share-role-viewer',
        'share-role-member',
        'share-email',
      ]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('keeps the suggestions while one has focus, and drops them '
        'once focus leaves them and the empty field', (tester) async {
      await openSheet(tester, await afterSharingWithBobAndCarol(tester), alice);
      final bobRow = find.byKey(ValueKey('share-suggest-${bob.email}'));
      final carolRow = find.byKey(ValueKey('share-suggest-${carol.email}'));
      expect(bobRow, findsNothing);
      for (final reached in [
        'share-email',
        'share-suggest-${bob.email}',
        'share-suggest-${carol.email}',
      ]) {
        await tab(tester, reached == 'share-email' ? 2 : 1);
        expect(focused(), reached);
        expect(bobRow, findsOneWidget);
        expect(carolRow, findsOneWidget);
      }
      await tab(tester, 1);
      expect(focused(), 'share-role-member');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('share-email')))
            .controller!
            .text,
        isEmpty,
      );
      expect(bobRow, findsNothing);
      expect(carolRow, findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  for (final (platform, size) in const [
    (TargetPlatform.iOS, Size(390, 844)),
    (TargetPlatform.macOS, Size(1100, 720)),
  ]) {
    testWidgets('on ${platform.name} the header’s ⋮ is for whoever the note is '
        'shared with: Report this note there, and none for its owner', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        note = alice.notes.create(body: 'Holiday budget');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(note.id, email: bob.email);
        await bob.sharing.acceptInvite(server.outbox.single.token);
        await alice.sync.syncNow();
        await bob.sync.syncNow();
      });
      final more = find.byKey(const ValueKey('share-more'));

      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      expect(find.byKey(const ValueKey('share-email')), findsOneWidget);
      expect(more, findsNothing);
      expect(find.text('Report this note'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('share-dialog-close')));
      await tester.pumpAndSettle();

      await openSheet(tester, bob.notes.byId(note.id)!, bob);
      expect(find.text('Shared with you'), findsOneWidget);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('Report this note'), findsOneWidget);
    });
  }

  testWidgets('the Mac dialog is S02’s: 480 wide, a clear ⋮ at 16 in a 28 box, '
      'plain rows, a quiet subtitle and label, and a footer of words with Done '
      'at the right', (tester) async {
    tester.view.physicalSize = const Size(1100, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Note note;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      note = alice.notes.create(body: 'Holiday budget');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(note.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.single.token);
      await alice.sharing.addPerson(
        note.id,
        'luca@example.com',
        role: SpaceRole.viewer,
      );
      await alice.sync.syncNow();
      await bob.sync.syncNow();
    });

    for (final (device, actions) in [
      (alice, ['stop-sharing']),
      (bob, ['copy-note', 'leave-space']),
    ]) {
      await openSheet(tester, device.notes.byId(note.id)!, device);
      final dialog = find.byKey(const ValueKey('share-dialog'));
      final palette = tester.element(dialog).palette;
      expect(tester.getSize(dialog).width, 480);
      if (device == alice) {
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('share-role'))).dy -
              tester
                  .getBottomLeft(find.byKey(const ValueKey('share-email')))
                  .dy,
          10,
        );
      }

      final more = find.byKey(const ValueKey('share-more'));
      if (device == alice) {
        expect(more, findsNothing);
      } else {
        expect(tester.getSize(more), const Size(28, 28));
        expect(
          tester.getSize(
            find.descendant(of: more, matching: find.byType(KapyIcon)),
          ),
          const Size(16, 16),
        );
      }

      final subtitle = tester.widget<Text>(
        find.byKey(const ValueKey('share-subtitle')),
      );
      expect(subtitle.style!.fontSize, 12);
      expect(subtitle.style!.color, palette.textSecondary);
      expect(
        subtitle.style!.fontVariations,
        contains(const FontVariation('wght', 400)),
      );
      final label = tester.widget<Text>(find.text('People with access'));
      expect(label.style!.fontSize, 12);
      expect(label.style!.color, palette.textTertiary);
      expect(
        label.style!.fontVariations,
        contains(const FontVariation('wght', 400)),
      );

      final row = find.byKey(ValueKey('member-row-${alice.userId}'));
      expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
      expect(
        tester
            .widget<ProfileAvatar>(
              find.descendant(of: row, matching: find.byType(ProfileAvatar)),
            )
            .extent,
        28,
      );
      expect(
        find.ancestor(of: row, matching: find.byType(KapyControlSurface)),
        findsNothing,
      );
      expect(
        find.descendant(of: dialog, matching: find.byType(Divider)),
        findsNothing,
      );
      if (device == alice) {
        final face = find.byKey(const ValueKey('invite-face'));
        expect(tester.getSize(face), const Size(28, 28));
        expect(
          tester.getSize(
            find.descendant(of: face, matching: find.byType(KapyIcon)),
          ),
          const Size(14, 14),
        );
      }

      final done = find.byKey(const ValueKey('share-done'));
      expect(tester.getTopRight(done).dx, tester.getTopRight(dialog).dx - 12);
      var left = tester.getTopLeft(dialog).dx + 12;
      for (final key in actions) {
        final action = find.byKey(ValueKey(key));
        expect(tester.getTopLeft(action).dx, left);
        expect(tester.getCenter(action).dy, tester.getCenter(done).dy);
        left = tester.getTopRight(action).dx;
        expect(
          find.descendant(of: action, matching: find.byType(KapyIcon)),
          findsNothing,
        );
        expect(
          tester.widget<TextButton>(action).style!.foregroundColor!.resolve({}),
          palette.textSecondary,
        );
      }
      expect(
        tester.widget<TextButton>(done).style!.foregroundColor!.resolve({}),
        palette.textPrimary,
      );
      expect(
        tester
            .widget<TextButton>(done)
            .style!
            .textStyle!
            .resolve({})!
            .fontFamily,
        AppFonts.ui,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(done);
      await tester.pumpAndSettle();
    }
  });

  // The server lets only a team space's owner move a note out of it. 1.32.0
  // offered "Move to my notes" to any editor; how that build took the
  // refusal was proven at 7377085 (#75). Since #78 a refused note waits for
  // its next edit, and the failure stays shown until then.
  test('an editor\'s refused move out keeps everything', () async {
    await alice.boot();
    await bob.boot();
    final note = alice.notes.create(body: 'Trip budget');
    await alice.sync.syncNow();
    await alice.sharing.shareNoteWith(note.id, email: bob.email);
    await bob.sharing.acceptInvite(server.outbox.single.token);
    await alice.sync.syncNow();
    await bob.sync.syncNow();
    final theirs = bob.notes.notes.single;
    final spaceId = theirs.spaceId!;

    // What 1.32.0's unshareNote let any editor do.
    bob.notes.moveToSpace(theirs.id, spaceId: null, contentKey: null);
    await bob.sync.syncNow();
    final refused = server.refusals.where((c) => c == 'owner-only').length;
    expect(refused, greaterThan(0));
    final other = bob.notes.create(body: 'Groceries');
    for (var pass = 0; pass < 3; pass++) {
      await bob.sync.syncNow();
      expect(bob.sync.status, SyncStatus.failed);
      expect(bob.sync.lastError, contains('owner-only'));
    }
    await alice.sync.syncNow();

    expect(server.refusals.where((c) => c == 'owner-only'), hasLength(refused));
    final kept = bob.notes.byId(theirs.id)!;
    expect(kept.spaceId, isNull);
    expect(kept.body, 'Trip budget');
    expect(server.rows.containsKey(other.id), isTrue);
    expect(server.rowsIn(spaceId).containsKey(note.id), isTrue);
    final ours = alice.notes.byId(note.id)!;
    expect(ours.spaceId, spaceId);
    expect(ours.body, 'Trip budget');
  });

  /// Any sharing heading: one per person or space the shared notes are open
  /// to.
  final sharedHeading = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('share-group-'),
  );

  testWidgets('the sidebar groups shared notes under who they are for', (
    tester,
  ) async {
    late Note pinned;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      pinned = alice.notes.create(body: 'Kept at hand');
      alice.notes.create(body: 'Private');
      final shared = alice.notes.create(body: 'Shared');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(shared.id, email: bob.email);
    });

    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 260,
          child: Sidebar(
            notes: alice.notes.notes,
            pinnedNoteIds: {pinned.id},
            selectedId: null,
            query: '',
            displayTime: (t) => t,
            onSearch: () {},
            onSelect: (_) {},
            windowBar: const SizedBox(),
            onShare: (_) {},
            sharing: alice.sharing,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final today = find.byKey(const ValueKey('sidebar-group-Today'));
    expect(today, findsOneWidget);
    // Bob has not joined yet.
    expect(find.text('Waiting for user-2'), findsOneWidget);
    expect(find.text('Private'), findsOneWidget);
    expect(find.text('Shared'), findsOneWidget);

    // Pinned, then the shared groups, then your own under their days. Shared
    // notes lead because they are the ones that change while you are not
    // looking; your own are where you left them.
    double top(String label) => tester.getTopLeft(find.text(label)).dy;
    final ownDay = tester.getTopLeft(today).dy;
    expect(top('Pinned'), lessThan(top('Waiting for user-2')));
    expect(top('Waiting for user-2'), lessThan(ownDay));

    // And a pinned note is lifted out of the section it came from rather
    // than repeated in it.
    expect(find.text('Kept at hand'), findsOneWidget);
    expect(top('Kept at hand'), lessThan(top('Waiting for user-2')));

    // Your own day holds your own note, and the shared one stays in its group.
    expect(top('Shared'), lessThan(ownDay));
    expect(top('Private'), greaterThan(ownDay));
  });

  testWidgets('a shared group is headed by its people and their faces, says '
      'who is in a note, and opens their page from its heading', (
    tester,
  ) async {
    late Note shared;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      shared = alice.notes.create(body: 'Shared');
      alice.notes.create(body: 'Private');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(shared.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.single.token);
      await alice.sync.syncNow();
    });

    String? opened;
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 280,
          child: Sidebar(
            notes: alice.notes.notes,
            selectedId: null,
            query: '',
            displayTime: (t) => t,
            onSearch: () {},
            onSelect: (_) {},
            windowBar: const SizedBox(),
            onShare: (_) {},
            sharing: alice.sharing,
            collaborators: {
              shared.id: [
                Collaborator(
                  userId: bob.userId,
                  name: 'User',
                  fullName: server.user(bob.userId).name,
                ),
              ],
            },
            onOpenPerson: (email) => opened = email,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final group = alice.sharing.groupOf(alice.notes.byId(shared.id)!)!;
    // Bob by his name, not by the address the note was first shared with.
    expect(find.text('With User'), findsOneWidget);
    expect(find.textContaining('user-2'), findsNothing);
    expect(
      find.byKey(ValueKey('share-group-avatar-${group.key}-${bob.userId}')),
      findsOneWidget,
    );
    // Only the other people: this account is not its own company.
    expect(
      find.byKey(ValueKey('share-group-avatar-${group.key}-${alice.userId}')),
      findsNothing,
    );
    // The row with somebody in it says who, where its time would be, and the
    // heading says it too.
    expect(find.text('User is here'), findsOneWidget);
    expect(find.bySemanticsLabel('With User. User is here'), findsOneWidget);

    await tester.tap(find.text('With User'));
    expect(opened, bob.email);
  });

  testWidgets('a recipient sees who shared the note', (tester) async {
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      final note = alice.notes.create(body: 'Shared');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(note.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.single.token);
      await alice.sync.syncNow();
      await bob.sync.syncNow();
    });

    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 280,
          child: Sidebar(
            notes: bob.notes.notes,
            selectedId: null,
            query: '',
            displayTime: (t) => t,
            onSearch: () {},
            onSelect: (_) {},
            windowBar: const SizedBox(),
            onShare: (_) {},
            sharing: bob.sharing,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('From Someone'), findsOneWidget);
    expect(find.text('With Someone'), findsNothing);
  });

  testWidgets(
    'a note row leaves sharing to the title bar, but keeps the menu',
    (tester) async {
      late Note shared;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        shared = alice.notes.create(body: 'Shared');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(shared.id, email: bob.email);
      });

      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 260,
            child: Sidebar(
              notes: alice.notes.notes,
              selectedId: shared.id,
              query: '',
              displayTime: (t) => t,
              onSearch: () {},
              onSelect: (_) {},
              windowBar: const SizedBox(),
              onShare: (_) {},
              onArchive: (_) {},
              sharing: alice.sharing,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The row keeps one menu affordance. Sharing itself still lives in the
      // page's More, where it acts on the note that is open rather than
      // whichever row happens to be under the pointer.
      expect(find.byKey(ValueKey('share-note-${shared.id}')), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.text('Shared')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('note-actions-${shared.id}')), findsOneWidget);

      // Right-click still reaches it without opening the note first.
      await tester.tap(find.text('Shared'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Manage sharing'), findsOneWidget);

      // Share's one icon, as everywhere else, rather than the Shared mark.
      final line = find.ancestor(
        of: find.text('Manage sharing'),
        matching: find.byType(KapyMenuActionRow),
      );
      expect(
        find.descendant(
          of: line,
          matching: findKapyIcon(KapyIcons.shareRounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: line,
          matching: findKapyIcon(KapyIcons.groupOutlined),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('a note somebody shares with you is removed from your notes, '
      'and only an editor of it may', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    late Note shared;
    late Note viewed;
    late Note own;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      shared = alice.notes.create(body: 'Edited together');
      viewed = alice.notes.create(body: 'Read only');
      own = bob.notes.create(body: 'Bob alone');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(shared.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.last.token);
      await alice.sharing.shareNoteWith(
        viewed.id,
        email: bob.email,
        role: SpaceRole.viewer,
      );
      await bob.sharing.acceptInvite(server.outbox.last.token);
      await alice.sync.syncNow();
      await bob.sync.syncNow();
    });

    Future<void> pumpBob({required bool asks}) async {
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 280,
            child: Sidebar(
              notes: bob.notes.notes,
              selectedId: null,
              query: '',
              displayTime: (t) => t,
              onSearch: () {},
              onSelect: (_) {},
              onArchive: (_) {},
              onDelete: (_) {},
              asksBeforeDeleting: asks,
              sharing: bob.sharing,
              windowBar: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<String?> deleteLabel(Note note) async {
      await tester.tap(find.text(note.title), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      final item = find.byKey(ValueKey('delete-note-${note.id}'));
      final label = item.evaluate().isEmpty
          ? null
          : tester
                .widget<KapyMenuActionRow>(
                  find.descendant(
                    of: item,
                    matching: find.byType(KapyMenuActionRow),
                  ),
                )
                .action
                .label;
      if (label != null) {
        final text = find.descendant(of: item, matching: find.text(label));
        expect(
          tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
          isFalse,
          reason: '$label fits the menu',
        );
      }
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      return label;
    }

    await pumpBob(asks: true);
    expect(bob.notes.byId(shared.id), isNotNull);
    expect(await deleteLabel(shared), 'Remove note…');
    expect(await deleteLabel(own), 'Delete note…');
    // A viewer takes it out of their own notes the same way. Before, Leave
    // was their only way out, and it left the whole space.
    expect(await deleteLabel(viewed), 'Remove note…');

    await pumpBob(asks: false);
    expect(await deleteLabel(shared), 'Remove note');
  });

  testWidgets('picked notes somebody shares with you are acted on only where '
      'their row would let you', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    late Note shared;
    late Note viewed;
    late Note own;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      shared = alice.notes.create(body: 'Edited together');
      viewed = alice.notes.create(body: 'Read only');
      own = bob.notes.create(body: 'Bob alone');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(shared.id, email: bob.email);
      await bob.sharing.acceptInvite(server.outbox.last.token);
      await alice.sharing.shareNoteWith(
        viewed.id,
        email: bob.email,
        role: SpaceRole.viewer,
      );
      await bob.sharing.acceptInvite(server.outbox.last.token);
      await alice.sync.syncNow();
      await bob.sync.syncNow();
    });

    final picks = NotePicks();
    addTearDown(picks.dispose);
    final done = <(PickedAction, List<String>)>[];
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 280,
          child: ListenableBuilder(
            listenable: picks,
            builder: (context, _) => Sidebar(
              notes: bob.notes.notes,
              selectedId: null,
              query: '',
              displayTime: (t) => t,
              onSearch: () {},
              onSelect: (_) {},
              onArchive: (_) {},
              onHide: (_) {},
              onTogglePin: (_) {},
              onDelete: (_) {},
              sharing: bob.sharing,
              picks: picks,
              onPicked: (action, ids) => done.add((action, ids)),
              windowBar: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    picks.all([for (final note in bob.notes.notes) note.id]);
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);

    Future<String?> label(String action) async {
      await tester.tap(find.text(own.title), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      final item = find.byKey(ValueKey('picked-$action-note-${own.id}'));
      final label = item.evaluate().isEmpty
          ? null
          : tester
                .widget<KapyMenuActionRow>(
                  find.descendant(
                    of: item,
                    matching: find.byType(KapyMenuActionRow),
                  ),
                )
                .action
                .label;
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      return label;
    }

    // Pins are the reader's own, so every note takes one.
    expect(await label('pin'), 'Pin');
    // Hidden Notes are only ever the reader's own notes.
    expect(await label('hide'), 'Move 1 note to Hidden Notes');
    // A viewer changes nothing, so the note they may only read is left out of
    // Archive; but it leaves their notes with the rest, as its row's does.
    expect(await label('archive'), 'Archive 2 notes');
    expect(await label('delete'), 'Delete 3 notes…');

    await tester.tap(find.byKey(const ValueKey('picked-delete')));
    await tester.pumpAndSettle();
    expect(done.single.$1, PickedAction.delete);
    expect(done.single.$2, unorderedEquals([shared.id, viewed.id, own.id]));

    // Both of these only leave Bob's notes, whatever he may do in them.
    picks
      ..clear()
      ..toggle(shared.id)
      ..toggle(viewed.id);
    await tester.pumpAndSettle();
    await tester.tap(find.text(shared.title), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    final remove = find.byKey(ValueKey('picked-delete-note-${shared.id}'));
    expect(
      tester
          .widget<KapyMenuActionRow>(
            find.descendant(
              of: remove,
              matching: find.byType(KapyMenuActionRow),
            ),
          )
          .action
          .label,
      'Remove 2 notes…',
    );
  });

  test('the toast after a mixed delete says where each note went', () {
    expect(
      forgottenMessage(deleted: 1, removed: 0),
      'Moved to Recently deleted',
    );
    expect(
      forgottenMessage(deleted: 3, removed: 0),
      'Moved 3 notes to Recently deleted',
    );
    expect(forgottenMessage(deleted: 0, removed: 2), 'Removed from your notes');
    expect(
      forgottenMessage(deleted: 1, removed: 2),
      'Moved to Recently deleted, and 2 removed from your notes',
    );
    expect(
      forgottenMessage(deleted: 2, removed: 1),
      'Moved 2 notes to Recently deleted, and 1 removed from your notes',
    );
  });

  group('a viewer removes a note from their own notes', () {
    late Note viewed;

    /// Alice shares a note with Bob, who may only read it, and with Carol,
    /// who may edit it.
    Future<void> sharedToRead(WidgetTester tester) => tester.runAsync(() async {
      for (final device in [alice, bob, carol]) {
        await device.boot();
      }
      viewed = alice.notes.create(body: 'Read only\nfor Bob');
      await alice.sync.syncNow();
      await alice.sharing.shareNoteWith(
        viewed.id,
        email: bob.email,
        role: SpaceRole.viewer,
      );
      await bob.sharing.acceptInvite(server.outbox.last.token);
      await alice.sharing.addPerson(viewed.id, carol.email);
      await carol.sharing.acceptInvite(server.outbox.last.token);
      for (final device in [alice, bob, carol]) {
        await device.sync.syncNow();
      }
    });

    /// Takes [ids] out of Bob's notes as the app does once he confirms, then
    /// lets everyone sync.
    Future<void> removeForBob(WidgetTester tester, List<String> ids) =>
        tester.runAsync(() async {
          bob.notes.deleteAll(ids);
          for (final device in [bob, alice, carol, bob]) {
            await device.sync.syncNow();
          }
        });

    Widget bobsList({
      required ValueChanged<String> onDelete,
      NotePicks? picks,
      void Function(PickedAction, List<String>)? onPicked,
    }) => harness(
      SizedBox(
        width: 280,
        child: Sidebar(
          windowBar: const SizedBox(),
          notes: bob.notes.notes,
          selectedId: null,
          query: '',
          displayTime: (t) => t,
          onSearch: () {},
          onSelect: (_) {},
          onArchive: (_) {},
          onDelete: onDelete,
          sharing: bob.sharing,
          picks: picks,
          onPicked: onPicked,
        ),
      ),
    );

    testWidgets('from its row, and the others keep it', (tester) async {
      await sharedToRead(tester);
      expect(bob.sharing.canEdit(bob.notes.byId(viewed.id)!), isFalse);
      String? removed;
      await tester.pumpWidget(bobsList(onDelete: (id) => removed = id));
      await tester.pumpAndSettle();

      await tester.tap(find.text(viewed.title), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('archive-note-${viewed.id}')), findsNothing);
      await tester.tap(find.byKey(ValueKey('delete-note-${viewed.id}')));
      await tester.pumpAndSettle();
      expect(removed, viewed.id);

      await removeForBob(tester, [viewed.id]);
      expect(bob.notes.byId(viewed.id), isNull);
      expect(alice.notes.byId(viewed.id)?.body, 'Read only\nfor Bob');
      expect(carol.notes.byId(viewed.id)?.body, 'Read only\nfor Bob');
      expect(server.rows[viewed.id]!.isTombstone, isFalse);
      expect(bob.notes.dirtyTombstones, isEmpty);
    });

    testWidgets('picked with an edited note and his own, and only his own is '
        'gone for everyone', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await sharedToRead(tester);
      late Note edited;
      late Note own;
      await tester.runAsync(() async {
        edited = alice.notes.create(body: 'Edited together');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(edited.id, email: bob.email);
        await bob.sharing.acceptInvite(server.outbox.last.token);
        own = bob.notes.create(body: 'Bob alone');
        for (final device in [alice, bob]) {
          await device.sync.syncNow();
        }
      });

      final picks = NotePicks();
      addTearDown(picks.dispose);
      final done = <(PickedAction, List<String>)>[];
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: picks,
          builder: (context, _) => bobsList(
            onDelete: (_) {},
            picks: picks,
            onPicked: (action, ids) => done.add((action, ids)),
          ),
        ),
      );
      picks.all([viewed.id, edited.id, own.id]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('picked-delete')));
      await tester.pumpAndSettle();
      expect(done.single.$1, PickedAction.delete);
      expect(done.single.$2, unorderedEquals([viewed.id, edited.id, own.id]));

      await removeForBob(tester, done.single.$2);
      for (final id in [viewed.id, edited.id, own.id]) {
        expect(bob.notes.byId(id), isNull);
      }
      expect(alice.notes.byId(viewed.id)?.body, 'Read only\nfor Bob');
      expect(carol.notes.byId(viewed.id)?.body, 'Read only\nfor Bob');
      expect(alice.notes.byId(edited.id)?.body, 'Edited together');
      expect(server.rows[own.id]!.isTombstone, isTrue);
      expect(server.rows[viewed.id]!.isTombstone, isFalse);
      expect(server.rows[edited.id]!.isTombstone, isFalse);
      expect(bob.notes.dirtyTombstones, isEmpty);
    });
  });

  group('sidebar tabs', () {
    Widget tabbed(
      Device device, {
      required SidebarTab tab,
      ValueChanged<SidebarTab>? onTabChanged,
      bool phone = false,
    }) => harness(
      // The app rebuilds the sidebar whenever the account changes, sharing
      // included; this stands in for that.
      ListenableBuilder(
        listenable: device.sharing,
        builder: (context, _) => SizedBox(
          width: phone ? 393 : 280,
          child: Sidebar(
            phone: phone,
            notes: [
              for (final note in device.notes.notes)
                if (sidebarTabLists(tab, note, device.sharing)) note,
            ],
            selectedId: null,
            query: '',
            displayTime: (t) => t,
            onSearch: () {},
            onSelect: (_) {},
            windowBar: const SizedBox(),
            onShare: (_) {},
            sharing: device.sharing,
            tab: tab,
            onTabChanged: onTabChanged ?? (_) {},
          ),
        ),
      ),
    );

    testWidgets("a phone's row shows who a note is open to, with an envelope "
        'for an invitation still waiting, and Shared leaves them off', (
      tester,
    ) async {
      late Note shared;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        alice.notes.create(body: 'Private');
        shared = alice.notes.create(body: 'Ours');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(shared.id, email: bob.email);
        await bob.sharing.acceptInvite(server.outbox.single.token);
        await alice.sharing.addPerson(shared.id, carol.email);
        await alice.sync.syncNow();
        await alice.sharing.refresh();
      });
      final group = alice.sharing.groupOf(alice.notes.byId(shared.id)!)!;
      expect(group.people.map((person) => person.isInvited), [false, true]);

      await tester.pumpWidget(tabbed(alice, tab: SidebarTab.mine, phone: true));
      await tester.pumpAndSettle();
      final row = find.widgetWithText(NoteRow, 'Ours');
      expect(
        find.descendant(
          of: row,
          matching: find.bySemanticsLabel(
            RegExp('\n${RegExp.escape(group.title)}\$'),
          ),
        ),
        findsOneWidget,
      );
      final initial = group.people.first.name.trim()[0].toUpperCase();
      expect(
        find.descendant(of: row, matching: find.text(initial)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KapyIcon && widget.icon == KapyIcons.mailOutlined,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(NoteRow, 'Private'),
          matching: find.bySemanticsLabel(RegExp('\nWith ')),
        ),
        findsNothing,
      );

      await tester.pumpWidget(
        tabbed(alice, tab: SidebarTab.shared, phone: true),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.widgetWithText(NoteRow, 'Ours'),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KapyIcon && widget.icon == KapyIcons.mailOutlined,
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('your own shared note stays in the notes list, and is in '
        'Shared under the person it is open to', (tester) async {
      late Note shared;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        alice.notes.create(body: 'Private');
        shared = alice.notes.create(body: 'Ours');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(shared.id, email: bob.email);
        await bob.sharing.acceptInvite(server.outbox.single.token);
        await alice.sync.syncNow();
        await bob.sync.syncNow();
        await alice.sharing.refresh();
      });

      await tester.pumpWidget(tabbed(alice, tab: SidebarTab.mine));
      await tester.pumpAndSettle();

      // An ordinary row, not a section of its own: her own list has no
      // sharing heading over it.
      expect(find.text('Private'), findsOneWidget);
      expect(find.text('Ours'), findsOneWidget);
      expect(sharedHeading, findsNothing);

      // Shared lists it under Bob, whose faces the heading shows, and leaves
      // her private note out.
      await tester.pumpWidget(tabbed(alice, tab: SidebarTab.shared));
      await tester.pumpAndSettle();
      expect(sharedHeading, findsWidgets);
      expect(find.text('Ours'), findsOneWidget);
      expect(find.text('Private'), findsNothing);
    });

    testWidgets('an empty Shared says how to share, and starts from Settings', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await alice.boot();
        alice.notes.create(body: 'Private');
      });
      var started = 0;
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 280,
            child: Sidebar(
              notes: const [],
              selectedId: null,
              query: '',
              displayTime: (t) => t,
              onSearch: () {},
              onSelect: (_) {},
              sharing: alice.sharing,
              tab: SidebarTab.shared,
              onTabChanged: (_) {},
              onStartSharing: () => started++,
              windowBar: SidebarWindowBar(
                title: 'Notes',
                count: 0,
                onCreate: () {},
                onHide: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Nothing shared yet'), findsOneWidget);
      expect(
        find.text(
          'Pick notes and someone to share them with. Only the people you add, or anyone with a link you turn on, can see them.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('sidebar-empty-share')));
      expect(started, 1);
    });

    testWidgets("someone else's note is under Shared only", (tester) async {
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        final note = alice.notes.create(body: 'From Alice');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(note.id, email: bob.email);
        await bob.sharing.acceptInvite(server.outbox.single.token);
        await alice.sync.syncNow();
        await bob.sync.syncNow();
        bob.notes.create(body: 'Bob own');
      });

      await tester.pumpWidget(tabbed(bob, tab: SidebarTab.mine));
      await tester.pumpAndSettle();
      expect(find.text('Bob own'), findsOneWidget);
      expect(find.text('From Alice'), findsNothing);

      await tester.pumpWidget(tabbed(bob, tab: SidebarTab.shared));
      await tester.pumpAndSettle();
      expect(find.text('From Alice'), findsOneWidget);
      expect(find.text('Bob own'), findsNothing);
      // Grouped under who shared it, whose faces that heading already shows,
      // so the row does not repeat them.
      expect(find.text('From Someone'), findsOneWidget);
      expect(find.byKey(const ValueKey('note-row-people')), findsNothing);
    });

    testWidgets('on a phone, Block… on an invitation asks first by the whole '
        'name; on a Mac it blocks at once, so it has no ellipsis', (
      tester,
    ) async {
      server.user(alice.userId).name = 'Alice Moreau';
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        final note = alice.notes.create(body: 'Plans');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(note.id, email: bob.email);
        await bob.sharing.refresh();
      });
      final token = server.outbox.single.token;
      Future<void> block(String label) async {
        await tester.tap(find.byKey(ValueKey('sidebar-invite-more-$token')));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(ValueKey('invite-report-$token')),
            matching: find.text('Report…'),
          ),
          findsOneWidget,
        );
        final item = find.byKey(ValueKey('invite-block-$token'));
        expect(
          find.descendant(of: item, matching: find.text(label)),
          findsOneWidget,
        );
        await tester.tap(item);
        await tester.pumpAndSettle();
      }

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await tester.pumpWidget(tabbed(bob, tab: SidebarTab.shared));
      await tester.pumpAndSettle();
      await block('Block…');
      expect(find.text('Block Alice Moreau?'), findsOneWidget);
      expect(
        find.text(
          'They can’t invite you again, and this invitation goes away. You '
          'can unblock them in Settings, under Blocked people.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('sharing-ask-cancel')));
      await tester.pumpAndSettle();
      expect(bob.sharing.hasBlocked(alice.email), isFalse);

      AppPlatform.debugTargetPlatformOverride = null;
      await tester.pumpWidget(tabbed(bob, tab: SidebarTab.shared));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await block('Block Alice Moreau');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sharing-ask')), findsNothing);
      expect(bob.sharing.hasBlocked(alice.email), isTrue);
      bob.dispose();
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('an invitation waits under the search field until answered', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        final note = alice.notes.create(body: 'Plans');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(note.id, email: bob.email);
        await bob.sharing.refresh();
      });
      final token = server.outbox.single.token;
      SidebarTab? switchedTo;

      await tester.pumpWidget(
        tabbed(
          bob,
          tab: SidebarTab.shared,
          onTabChanged: (t) => switchedTo = t,
        ),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(ValueKey('sidebar-invite-$token'));
      expect(card, findsOneWidget);
      double top(Finder finder) => tester.getTopLeft(finder).dy;
      expect(
        top(card),
        greaterThan(top(find.byKey(const ValueKey('sidebar-search-field')))),
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey('sidebar-invite-accept-$token')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      expect(bob.sharing.invites, isEmpty);
      expect(bob.sharing.teams, hasLength(1));
      expect(switchedTo, SidebarTab.shared);
      expect(card, findsNothing);
      // Joining asks for a sync soon; the timer must not outlive the test.
      bob.dispose();
      await tester.pump(const Duration(seconds: 3));
    });
  });

  testWidgets('without a shared note the sidebar shows no sections', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await alice.boot();
      alice.notes.create(body: 'Only mine');
    });
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 260,
          child: Sidebar(
            notes: alice.notes.notes,
            selectedId: null,
            query: '',
            displayTime: (t) => t,
            onSearch: () {},
            onSelect: (_) {},
            windowBar: const SizedBox(),
            onShare: (_) {},
            sharing: alice.sharing,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('My notes'), findsNothing);
    expect(find.text('Only mine'), findsOneWidget);
  });
}
