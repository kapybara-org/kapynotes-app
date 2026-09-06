import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/safety.dart';
import 'package:kapy_notes/sync/sharing.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/trust.dart';
import 'package:kapy_notes/ui/account/sharing_pane.dart';
import 'package:kapy_notes/ui/share_dialog.dart';
import 'package:material_ui/material_ui.dart';

import 'sync/fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'safety-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

class Device {
  Device(this.server, {required this.userId, required this.device}) {
    server.seedBundle(userId);
    store = MemoryStore();
    notes = NotesStore(store);
    final api = FakeApi(server, device: device, userId: userId);
    final vault = vaultFor(userId);
    keyring = SpaceKeyring(userId: userId, store: store, trust: TrustStore(store));
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
    await sharing.refreshSafety();
  }

  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sharing.dispose();
    sync.dispose();
  }
}

Widget harness(Widget child) =>
    MaterialApp(theme: KapyTheme.dark(), home: Scaffold(body: child));

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

  setUp(() {
    server = FakeServer();
    alice = Device(server, userId: 'user-1', device: 'a');
    bob = Device(server, userId: 'user-2', device: 'b');
  });

  tearDown(() {
    alice.dispose();
    bob.dispose();
  });

  group('the sharing rules', () {
    testWidgets('are shown before a first share, and the share then goes through', (tester) async {
      // An account that has agreed to nothing.
      server.user(alice.userId).termsVersion = 0;
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

      await tester.enterText(find.byKey(const ValueKey('share-email')), bob.email);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-submit-Share')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      // The rules appear rather than an error, and say the two things that
      // matter: what is not allowed, and that we cannot see it ourselves.
      expect(find.text('Before you share'), findsOneWidget);
      expect(find.textContaining('harass'), findsOneWidget);
      expect(find.textContaining('we cannot read them'), findsOneWidget);
      expect(alice.notes.byId(note.id)!.isShared, isFalse);

      // A stray tap outside must not count as agreeing.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Before you share'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('accept-sharing-terms')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      // Accepted, and the share it interrupted completed on its own.
      expect(find.text('Before you share'), findsNothing);
      expect(server.user(alice.userId).termsVersion, sharingTermsVersion);
      expect(alice.notes.byId(note.id)!.isShared, isTrue);
      expect(server.outbox.single.to, bob.email);
    });

    testWidgets('declining leaves the note exactly where it was', (tester) async {
      server.user(alice.userId).termsVersion = 0;
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        note = alice.notes.create(body: 'Mine');
        await alice.sync.syncNow();
      });

      await tester.pumpWidget(opener(note, alice.sharing));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('share-email')), bob.email);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-submit-Share')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(alice.notes.byId(note.id)!.isShared, isFalse);
      expect(server.outbox, isEmpty);
      expect(server.user(alice.userId).termsVersion, 0);
    });
  });

  group('blocking', () {
    testWidgets('from an invitation stops them reaching you again', (tester) async {
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        final note = alice.notes.create(body: 'Unwanted');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(note.id, email: bob.email);
        await bob.sharing.refresh();
      });

      await tester.pumpWidget(harness(
        SingleChildScrollView(child: SharingPaneBody(sharing: bob.sharing)),
      ));
      await tester.pumpAndSettle();

      final token = server.outbox.single.token;
      expect(find.byKey(ValueKey('block-$token')), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey('block-$token')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      // Gone from the list, recorded as blocked, and offered back.
      expect(bob.sharing.hasBlocked(alice.email), isTrue);
      expect(bob.sharing.invites, isEmpty);
      expect(find.byKey(ValueKey('unblock-${alice.email}')), findsOneWidget);

      // And a second invitation never arrives.
      await tester.runAsync(() async {
        server.outbox.clear();
        final another = alice.notes.create(body: 'Again');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(another.id, email: bob.email);
        await bob.sharing.refresh();
      });
      await tester.pumpAndSettle();
      expect(server.outbox, isEmpty, reason: 'nothing was delivered');
      expect(bob.sharing.invites, isEmpty);
    });

    testWidgets('unblocking lets them through again', (tester) async {
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        await bob.sharing.blockPerson(alice.email);
      });

      await tester.pumpWidget(harness(
        SingleChildScrollView(child: SharingPaneBody(sharing: bob.sharing)),
      ));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey('unblock-${alice.email}')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      expect(bob.sharing.hasBlocked(alice.email), isFalse);
    });
  });

  group('reporting', () {
    testWidgets('an invitation needs no note and no consent', (tester) async {
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        final note = alice.notes.create(body: 'Spam');
        await alice.sync.syncNow();
        await alice.sharing.shareNoteWith(note.id, email: bob.email);
        await bob.sharing.refresh();
      });

      await tester.pumpWidget(harness(
        SingleChildScrollView(child: SharingPaneBody(sharing: bob.sharing)),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('report-${server.outbox.single.token}')));
      await tester.pumpAndSettle();

      expect(find.text('Report this invitation'), findsOneWidget);
      // No note is involved, so nothing offers to disclose one.
      expect(find.byKey(const ValueKey('include-note-content')), findsNothing);
      expect(find.textContaining('working days'), findsAtLeastNWidgets(1));

      await tester.tap(find.byKey(const ValueKey('reason-harassment')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('report-details')), 'will not stop');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('file-report')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      final filed = server.reports.single;
      expect(filed.kind, ReportKind.invitation);
      expect(filed.reason, ReportReason.harassment);
      expect(filed.details, 'will not stop');
      expect(filed.content, isNull, reason: 'an invitation has no note in it');
    });

    testWidgets('a note is reported without its text unless that is chosen', (tester) async {
      late Note theirs;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        final note = alice.notes.create(body: 'something horrible');
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

      await tester.tap(find.byKey(const ValueKey('report-note')));
      await tester.pumpAndSettle();

      // The consent is offered, unticked, and says what it does.
      final checkbox = find.byKey(const ValueKey('include-note-content'));
      expect(checkbox, findsOneWidget);
      expect(find.textContaining('unencrypted'), findsOneWidget);
      expect(find.textContaining('still act on who did it'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reason-violence')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('file-report')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      // Left unticked, so the text stayed on the device.
      expect(server.reports.single.content, isNull);
      expect(server.reports.single.noteId, theirs.id);
    });

    testWidgets('ticking the box is what sends the text, and only then', (tester) async {
      late Note theirs;
      await tester.runAsync(() async {
        await alice.boot();
        await bob.boot();
        final note = alice.notes.create(body: 'something horrible');
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
      await tester.tap(find.byKey(const ValueKey('report-note')));
      await tester.pumpAndSettle();

      final consent = find.byKey(const ValueKey('include-note-content'));
      await tester.ensureVisible(consent);
      await tester.pumpAndSettle();
      await tester.tap(consent);
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(consent).value,
        isTrue,
        reason: 'the consent has to be on before the text can travel',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('file-report')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      expect(server.reports.single.content, 'something horrible');
    });
  });
}
