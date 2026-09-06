import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/sharing.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/trust.dart';
import 'package:kapy_notes/ui/share_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'sync/fake_server.dart';

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
  Device(this.server, {required this.userId, required this.device}) {
    server.seedBundle(userId);
    store = MemoryStore();
    notes = NotesStore(store);
    final api = FakeApi(server, device: device, userId: userId);
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
      vault: vault,
      debounce: const Duration(hours: 1),
    );
    sharing = Sharing(
      api: api,
      vault: vault,
      keyring: keyring,
      notes: notes,
      sync: sync,
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
  }
}

Widget harness(Widget child) =>
    MaterialApp(theme: KapyTheme.dark(), home: Scaffold(body: child));

/// Opens the sheet through a button, the way the app reaches it.
Widget opener(Note note, Sharing sharing) => harness(
  Builder(
    builder: (context) => TextButton(
      onPressed: () => showShareDialog(context, note: note, sharing: sharing),
      child: const Text('open'),
    ),
  ),
);

void main() {
  late FakeServer server;
  late Device alice;
  late Device bob;

  setUp(() async {
    server = FakeServer();
    alice = Device(server, userId: 'user-1', device: 'a');
    bob = Device(server, userId: 'user-2', device: 'b');
  });

  tearDown(() {
    alice.dispose();
    bob.dispose();
  });

  testWidgets('a private note is shared with a person by email', (tester) async {
    late Note note;
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      note = alice.notes.create(body: 'Holiday budget');
      await alice.sync.syncNow();
    });

    await tester.pumpWidget(opener(note, alice.sharing));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Share note'), findsOneWidget);
    // The promise, in the sheet: it stays encrypted.
    expect(find.textContaining('stays encrypted'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-email')), findsOneWidget);

    // An address is required.
    await tester.tap(find.byKey(const ValueKey('share-submit-Share')));
    await tester.pumpAndSettle();
    expect(find.text('Enter an email address.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('share-email')), bob.email);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('share-submit-Share')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    // Now a shared note: the sheet shows the space, the invitation, and the
    // ways out.
    expect(find.textContaining('Shared in With user-2'), findsOneWidget);
    expect(find.textContaining('Invitation sent to'), findsOneWidget);
    expect(find.text(bob.email), findsOneWidget);
    expect(find.text('Invited · not yet accepted'), findsOneWidget);
    expect(find.byKey(const ValueKey('unshare-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('stop-sharing')), findsOneWidget);
    expect(alice.notes.byId(note.id)!.isShared, isTrue);
    expect(server.outbox.single.to, bob.email);
  });

  testWidgets('a shared note lists who has access, and can be taken back', (tester) async {
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

    await tester.pumpWidget(opener(note, alice.sharing));
    await tester.tap(find.text('open'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.text('${alice.email} (you)'), findsOneWidget);
    expect(find.text(bob.email), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Waiting for access'), findsNothing);
    // The per-member actions live behind one button, and the owner's menu
    // is the only one with Remove in it.
    expect(find.byKey(ValueKey('member-menu-${bob.userId}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('member-menu-${bob.userId}')));
    await tester.pumpAndSettle();
    expect(find.text('Report…'), findsOneWidget);
    expect(find.text('Block…'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('unshare-note')));
    await tester.pumpAndSettle();
    expect(find.text('Move back to My notes?'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Move it'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.text('Share note'), findsNothing, reason: 'the sheet closed');
    expect(alice.notes.byId(note.id)!.isShared, isFalse);
    expect(server.rowsIn(alice.keyring.personal!.id)[note.id]!.isTombstone, isFalse);
  });

  testWidgets('a member sees the sheet without owner controls, and may leave', (tester) async {
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

    await tester.pumpWidget(opener(theirs, bob.sharing));
    await tester.tap(find.text('open'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stop-sharing')), findsNothing);
    expect(find.byKey(const ValueKey('leave-space')), findsOneWidget);
    expect(find.text('Add someone'), findsNothing);

    // A member can still report and block the owner — those are not
    // privileges — but cannot remove them.
    await tester.tap(find.byKey(ValueKey('member-menu-${alice.userId}')));
    await tester.pumpAndSettle();
    expect(find.text('Report…'), findsOneWidget);
    expect(find.text('Block…'), findsOneWidget);
    expect(find.text('Remove'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('leave-space')));
    await tester.pumpAndSettle();
    // Honest about what leaving does not do.
    expect(find.textContaining('stay with you'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Leave'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(bob.sharing.teams, isEmpty);
    // Leaving asks for a sync soon; the timer must not outlive the test.
    bob.dispose();
  });

  testWidgets('the sidebar groups shared notes under their space', (tester) async {
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
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
            selectedId: null,
            query: '',
            displayTime: (t) => t,
            onQueryChanged: (_) {},
            onSelect: (_) {},
            onCreate: () {},
            onShare: (_) {},
            sharing: alice.sharing,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('My notes'), findsOneWidget);
    expect(find.text('With user-2'), findsOneWidget);
    expect(find.text('Private'), findsOneWidget);
    expect(find.text('Shared'), findsOneWidget);
  });

  testWidgets('without a shared note the sidebar shows no sections', (tester) async {
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
            onQueryChanged: (_) {},
            onSelect: (_) {},
            onCreate: () {},
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
