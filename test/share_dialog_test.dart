import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/identity.dart';
import 'package:kapy_notes/sync/image_sync.dart';
import 'package:kapy_notes/sync/joining.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/presence.dart';
import 'package:kapy_notes/sync/sharing.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_api.dart'
    show SyncProtocolException, SyncRefusedException, SyncTransientException;
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/trust.dart';
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/home_page.dart' show forgottenMessage;
import 'package:kapy_notes/ui/note_picks.dart';
import 'package:kapy_notes/ui/share_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/join/joining_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'billing/billing_fakes.dart';
import 'kapy_icon_finder.dart';
import 'sync/fake_server.dart';
import 'test_fonts.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'share-dialog-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// One unlocked account against the fake server, with everything the share
/// sheet talks to.
class Device {
  Device(
    this.server, {
    required this.userId,
    required this.device,
    Directory? media,
  }) {
    server.seedBundle(userId);
    store = MemoryStore();
    notes = media == null
        ? NotesStore(store)
        : NotesStore(store, blobs: BlobStore(directory: media));
    final api = FakeApi(server, device: device, userId: userId);
    images = media == null
        ? null
        : ImageSync(api: api, store: notes.blobs, notes: notes);
    final vault = vaultFor(userId);
    keyring = SpaceKeyring(
      userId: userId,
      store: store,
      trust: TrustStore(store),
    );
    sync = SyncService(
      notes: notes,
      state: SyncState(store),
      api: api,
      keyring: keyring,
      docs: DocStore(MemoryDocStorage(), replica: device),
      images: images,
      vault: vault,
      sendDelay: const Duration(hours: 1),
    );
    sharing = Sharing(
      api: api,
      vault: vault,
      keyring: keyring,
      notes: notes,
      sync: sync,
      images: images,
    );
  }

  final FakeServer server;
  final String userId;
  final String device;
  late final MemoryStore store;
  late final NotesStore notes;
  late final SpaceKeyring keyring;
  late final SyncService sync;
  late final Sharing sharing;
  late final ImageSync? images;

  String get email => server.user(userId).email;

  Future<void> boot() async {
    await notes.load();
    await sync.syncNow();
  }

  bool _disposed = false;

  /// Idempotent: a test that has to tear a device down before the framework
  /// checks for stray timers disposes it early, and tearDown does it again.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sharing.dispose();
    sync.dispose();
    images?.dispose();
  }
}

Widget harness(Widget child) => MaterialApp(
  theme: KapyTheme.dark(),
  debugShowCheckedModeBanner: false,
  home: Scaffold(body: child),
);

/// Opens the sheet through a button, the way the app reaches it.
Widget opener(Note note, Sharing sharing, {Billing? billing}) => harness(
  Builder(
    builder: (context) => TextButton(
      onPressed: () => showShareDialog(
        context,
        note: note,
        sharing: sharing,
        billing: billing,
      ),
      child: const Text('open'),
    ),
  ),
);

/// The joining endpoints the fake server does not know.
class FakeSend {
  final calls = <(String, String, Map<String, Object?>?)>[];

  bool sawPath(String method, String path) =>
      calls.any((call) => call.$1 == method && call.$2 == path);

  Object? Function(String method, String path, Map<String, Object?>? payload)?
  fallback;

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Map<String, Object?>? payload,
  }) async {
    calls.add((method, path, payload));
    final answer = fallback?.call(method, path, payload);
    if (answer != null) {
      if (answer is Exception) throw answer;
      return (answer as Map<String, Object?>?) ?? const {};
    }
    if (path.endsWith('/link')) {
      if (method == 'PUT') {
        return {
          'token': 'tok-1',
          'url': 'https://kapynotes.com/space/tok-1',
          'role': payload?['role'],
          'approval': payload?['approval'],
          'expiresAt': null,
        };
      }
      return {'link': null};
    }
    return const {};
  }
}

Joining joiningOver(FakeSend send) =>
    Joining(send: send.call, refreshSpaces: () async {}, requestSync: () {});

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

    testWidgets('Undo after the sheet has closed still puts them back, and '
        'says so', (tester) async {
      await sharedWithBob(tester);
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Remove from this note'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(alice.notes.byId(note.id)!.isShared, isFalse);

      await tester.tap(find.byKey(const ValueKey('share-dialog-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-dialog-close')), findsNothing);

      await tester.tap(find.text('Undo'));
      await until(tester, () => alice.notes.byId(note.id)!.isShared);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(server.outbox.last.to, bob.email);
      expect(find.text('Invitation sent to ${bob.email}'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('Undo that has to invite them again says so, not that they '
        'can see the note', (tester) async {
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
        await carol.sharing.acceptInvite(server.outbox.last.token);
        await alice.sync.syncNow();
      });
      await openSheet(tester, alice.notes.byId(note.id)!, alice);
      await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Remove from this note'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      await tester.tap(find.text('Undo'));
      final sent = find.text('Invitation sent to ${bob.email}');
      await until(tester, () => sent.evaluate().isNotEmpty);
      expect(sent, findsOneWidget);
      expect(find.textContaining('can see this note again'), findsNothing);
      expect(find.textContaining('waiting to join'), findsOneWidget);
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

    /// The notes [device] holds of its own, by body.
    List<String> ownNotes(Device device) => [
      for (final note in device.notes.notes)
        if (!note.isShared) note.body,
    ]..sort();

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

  testWidgets('Stop sharing brings the note home and Undo shares it again', (
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
      await bob.sync.syncNow();
    });

    await openSheet(tester, alice.notes.byId(note.id)!, alice);
    await tester.tap(find.byKey(const ValueKey('stop-sharing')));
    await tester.pumpAndSettle();
    expect(find.textContaining('loses access'), findsOneWidget);
    expect(
      find.textContaining('stays in your notes, with every change'),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sharing-ask-ok')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));

    expect(alice.notes.byId(note.id)!.isShared, isFalse);
    expect(find.textContaining('Stopped sharing'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await until(
      tester,
      () => alice.sharing.notesSharedWith(bob.email).isNotEmpty,
    );
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
    final again = find.textContaining('Shared again with');
    await until(tester, () => again.evaluate().isNotEmpty);
    expect(tester.takeException(), isNull);
    expect(again, findsOneWidget);
    expect(alice.notes.byId(note.id)!.isShared, isTrue);
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
    final again = find.textContaining('Shared again with');
    await until(tester, () => again.evaluate().isNotEmpty);
    expect(again, findsOneWidget);
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
      // title bar, where it acts on the note that is open rather than whichever
      // row happens to be under the pointer.
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

  test('the toast after a mixed delete says which notes are gone for good', () {
    expect(forgottenMessage(deleted: 1, removed: 0), 'Note deleted');
    expect(forgottenMessage(deleted: 3, removed: 0), '3 notes deleted');
    expect(forgottenMessage(deleted: 0, removed: 2), 'Removed from your notes');
    expect(
      forgottenMessage(deleted: 1, removed: 2),
      'Note deleted, and 2 removed from your notes',
    );
    expect(
      forgottenMessage(deleted: 2, removed: 1),
      '2 notes deleted, and 1 removed from your notes',
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
