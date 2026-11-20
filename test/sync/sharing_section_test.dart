import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_api.dart' show SyncTransientException;
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/settings/sharing_section.dart';
import 'package:material_ui/material_ui.dart';

import '../share_dialog_test.dart' show Device;
import 'fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'sharing-section-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

({Account account, NotesStore notes}) build(
  FakeServer server, {
  String userId = 'user-1',
}) {
  final store = MemoryStore();
  final notes = NotesStore(store);
  final state = SyncState(store);
  return (
    account: Account(
      auth: FakeAuth(
        id: userId,
        email: server.user(userId).email,
        name: server.user(userId).name,
        image: server.user(userId).image,
      ),
      syncApi: (_) => FakeApi(server, device: 'device-$userId', userId: userId),
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
    ),
    notes: notes,
  );
}

Widget harness(Widget child) => MaterialApp(
  theme: KapyTheme.dark(),
  debugShowCheckedModeBanner: false,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// The fake people every sharing test and render uses: Sam reads, Priya
/// shares.
void namePeople(FakeServer server) {
  server.user('user-1')
    ..name = 'Sam Rivera'
    ..email = 'sam.rivera@example.com';
  server.user('user-2')
    ..name = 'Priya Nair'
    ..email = 'priya.nair@example.com';
}

void main() {
  late FakeServer server;
  late Device sam;
  late Device priya;

  setUp(() {
    server = FakeServer();
    namePeople(server);
    sam = Device(server, userId: 'user-1', device: 'sam');
    priya = Device(server, userId: 'user-2', device: 'priya');
  });

  tearDown(() {
    sam.dispose();
    priya.dispose();
  });

  Future<void> pump(
    WidgetTester tester,
    Device device, {
    ValueChanged<String>? onOpenNote,
    SharingStart? start,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness(
        SharingSectionBody(
          sharing: device.sharing,
          notes: device.notes,
          start: start,
          onOpenNote: onOpenNote,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  /// Taps something that talks to the server, and lets it answer.
  Future<void> act(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  /// Lets the sync an action asked for go by, so no timer outlives the test.
  Future<void> quiet(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    sam.dispose();
  }

  Future<void> confirm(WidgetTester tester) =>
      act(tester, find.byKey(const ValueKey('sharing-confirm-ok')));

  ValueKey<String> person(Device device) => ValueKey('person-${device.email}');

  /// Priya shares [body] with Sam, and Sam is in, holding the key.
  Future<Note> shareWithSam(WidgetTester tester, String body) async {
    late Note note;
    await tester.runAsync(() async {
      note = priya.notes.create(body: body);
      await priya.sync.syncNow();
      await priya.sharing.shareNoteWith(note.id, email: sam.email);
      await sam.sharing.acceptInvite(server.outbox.last.token);
      await priya.sync.syncNow();
      await sam.sync.syncNow();
    });
    return note;
  }

  testWidgets('a signed-out account is told what sharing needs', (
    tester,
  ) async {
    final app = build(server);
    await app.notes.load();
    await app.account.restore();
    await tester.pumpWidget(
      harness(SharingSection(account: app.account, notes: app.notes)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Sign in, and unlock your notes, to share them with people.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('join-row')), findsNothing);
    expect(find.byKey(const ValueKey('share-with-someone')), findsNothing);
    app.account.dispose();
  });

  testWidgets(
    'an invitation is accepted from the section, and a pasted link that is '
    'not for this account says so',
    (tester) async {
      final owner = build(server, userId: 'user-2');
      late String token;
      await tester.runAsync(() async {
        await owner.notes.load();
        await owner.account.restore();
        await owner.account.signIn(email: 'a@b.co', password: 'x');
        await owner.account.createPassphrase('a good passphrase');
        final note = owner.notes.create(body: 'For Sam');
        await owner.account.sync!.syncNow();
        await owner.account.sharing!.shareNoteWith(
          note.id,
          email: server.user('user-1').email,
          role: SpaceRole.viewer,
        );
        token = server.outbox.single.token;
      });

      final reader = build(server, userId: 'user-1');
      await tester.runAsync(() async {
        await reader.notes.load();
        await reader.account.restore();
        await reader.account.signIn(email: 'b@b.co', password: 'x');
        await reader.account.createPassphrase('another good passphrase');
      });
      await tester.pumpWidget(
        harness(SharingSection(account: reader.account, notes: reader.notes)),
      );
      await tester.pumpAndSettle();

      // The honest sentence about what private means here, in plain words,
      // and the invitation: who it is from by name, with the address that
      // was verified, and never the space's placeholder, which names Sam.
      expect(
        find.textContaining('compare safety codes with them in person'),
        findsOneWidget,
      );
      expect(find.text('Waiting for you'), findsOneWidget);
      expect(
        find.text('Priya Nair invited you to share notes'),
        findsOneWidget,
      );
      expect(find.textContaining('With sam.rivera'), findsNothing);
      expect(find.text('priya.nair@example.com · Can view'), findsOneWidget);
      expect(find.text('No one yet'), findsOneWidget);

      // The owner's device is open beside him: her socket hears the
      // acceptance, she grants the key at once, and his socket brings the
      // note. Nobody presses anything else.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey('accept-$token')));
        await settle(server);
        await until(
          () => reader.notes.notes.isNotEmpty,
          reason: 'the note never arrived',
        );
      });
      await tester.pumpAndSettle();

      expect(find.text('Waiting for you'), findsNothing);
      expect(find.text('Priya Nair'), findsOneWidget);
      expect(find.text('Shares 1 with you'), findsOneWidget);
      expect(reader.notes.notes.single.body, 'For Sam');

      // A pasted link that is not for this account says so, once, inline.
      await tester.tap(find.byKey(const ValueKey('join-row')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('join-code')),
        'https://kapynotes.com/join/not-a-real-token',
      );
      await act(tester, find.byKey(const ValueKey('join-submit')));
      expect(find.textContaining('not for this account'), findsOneWidget);

      owner.account.dispose();
      reader.account.dispose();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets('an invitation is declined, and goes', (tester) async {
    await tester.runAsync(() async {
      await sam.boot();
      await priya.boot();
      final note = priya.notes.create(body: 'Flat 4B bills');
      await priya.sync.syncNow();
      await priya.sharing.shareNoteWith(note.id, email: sam.email);
      await sam.sharing.refresh();
    });
    await pump(tester, sam);

    final token = server.outbox.single.token;
    expect(find.byKey(ValueKey('invite-$token')), findsOneWidget);
    await act(tester, find.byKey(ValueKey('decline-$token')));

    expect(sam.sharing.invites, isEmpty);
    expect(find.text('Waiting for you'), findsNothing);
    expect(sam.notes.notes, isEmpty);
  });

  testWidgets('a person row counts both ways, and opens their page', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await sam.boot();
      await priya.boot();
    });
    await shareWithSam(tester, 'Goa trip budget');
    await tester.runAsync(() async {
      final mine = sam.notes.create(body: 'Groceries this week');
      final also = sam.notes.create(body: "Dad's 60th: plan");
      await sam.sync.syncNow();
      await sam.sharing.shareNoteWith(mine.id, email: priya.email);
      await sam.sharing.shareNoteWith(
        also.id,
        email: priya.email,
        role: SpaceRole.viewer,
      );
    });
    await pump(tester, sam);

    final row = find.byKey(person(priya));
    expect(row, findsOneWidget);
    expect(
      find.text('You share 2 notes · they share 1 with you'),
      findsOneWidget,
    );

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Notes you share with Priya'), findsOneWidget);
    expect(find.text('Notes Priya shares with you'), findsOneWidget);
    expect(find.text('Groceries this week'), findsOneWidget);
    expect(find.text('Goa trip budget'), findsOneWidget);
    expect(find.text('Invited · Can view'), findsOneWidget);
    expect(find.text('Stop sharing with Priya'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sharing-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(person(priya)), findsOneWidget);
    expect(find.text('Notes you share with Priya'), findsNothing);
  });

  testWidgets('it opens on a person, or on Share with someone, when asked', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await sam.boot();
      await priya.boot();
    });
    await shareWithSam(tester, 'Goa trip budget');

    await pump(tester, sam, start: SharingStart.person(priya.email));
    expect(find.text('Notes Priya shares with you'), findsOneWidget);
    expect(find.byKey(person(priya)), findsNothing);

    // A new mount, as Settings opening again is.
    await tester.pumpWidget(const SizedBox());
    await pump(tester, sam, start: const SharingStart.picking());
    expect(find.byKey(const ValueKey('share-picker')), findsOneWidget);
  });

  testWidgets('on the person page, access changes and one note stops', (
    tester,
  ) async {
    late Note mine;
    late Note other;
    await tester.runAsync(() async {
      await sam.boot();
      await priya.boot();
      mine = sam.notes.create(body: 'Rent split, November');
      other = sam.notes.create(body: 'Standup notes');
      await sam.sync.syncNow();
      await sam.sharing.shareNoteWith(mine.id, email: priya.email);
      await sam.sharing.shareNoteWith(
        other.id,
        email: priya.email,
        role: SpaceRole.viewer,
      );
      for (final invite in [...server.outbox]) {
        await priya.sharing.acceptInvite(invite.token);
      }
      await sam.sync.syncNow();
      await sam.sharing.refresh();
    });
    await pump(tester, sam);
    await tester.tap(find.byKey(person(priya)));
    await tester.pumpAndSettle();

    // Can edit becomes Can view. One note in its space, so nothing is asked.
    await tester.tap(find.byKey(ValueKey('access-${mine.id}')));
    await tester.pumpAndSettle();
    await act(tester, find.text('Can view').last);
    final space = sam.sharing.spaceOf(sam.notes.byId(mine.id)!)!;
    expect(space.othersThan(sam.userId).single.role, SpaceRole.viewer);

    // Stop sharing this note asks first, and takes only that one away.
    await tester.tap(find.byKey(ValueKey('access-${other.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop sharing this note'));
    await tester.pumpAndSettle();
    expect(
      find.text('Stop sharing “Standup notes” with Priya?'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Priya stops seeing this note. It stays in your notes, with '
        'everything Priya wrote.',
      ),
      findsOneWidget,
    );
    await confirm(tester);

    expect(sam.notes.byId(other.id)!.isShared, isFalse);
    expect(sam.notes.byId(mine.id)!.isShared, isTrue);
    expect(find.byKey(ValueKey('mine-${other.id}')), findsNothing);
    expect(find.byKey(ValueKey('mine-${mine.id}')), findsOneWidget);
    await quiet(tester);
  });

  testWidgets('stopping sharing with a person keeps the notes, with Undo', (
    tester,
  ) async {
    late Note note;
    await tester.runAsync(() async {
      await sam.boot();
      await priya.boot();
      note = sam.notes.create(body: 'Car service checklist');
      await sam.sync.syncNow();
      await sam.sharing.shareNoteWith(note.id, email: priya.email);
      await priya.sharing.acceptInvite(server.outbox.single.token);
      await sam.sync.syncNow();
      await sam.sharing.refresh();
    });
    await pump(tester, sam);
    await tester.tap(find.byKey(person(priya)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('stop-sharing-with')));
    await tester.pumpAndSettle();
    expect(find.text('Stop sharing with Priya?'), findsOneWidget);
    await confirm(tester);

    expect(sam.notes.byId(note.id)!.isShared, isFalse);
    expect(sam.notes.byId(note.id)!.body, 'Car service checklist');
    expect(sam.sharing.people, isEmpty);
    // Nobody is left to show, so the page is everyone again.
    expect(find.text('No one yet'), findsOneWidget);
    expect(find.text('Stopped sharing with Priya'), findsOneWidget);

    // Undo shares the same note with her again, at the same access.
    await act(tester, find.text('Undo'));
    expect(sam.notes.byId(note.id)!.isShared, isTrue);
    expect(sam.sharing.notesSharedWith(priya.email).single.id, note.id);
  });

  testWidgets('a note shared with you opens, is copied, and is left with a '
      'copy by default', (tester) async {
    String? opened;
    await tester.runAsync(() async {
      await sam.boot();
      await priya.boot();
    });
    final note = await shareWithSam(tester, 'Q4 reading list');
    await pump(tester, sam, onOpenNote: (id) => opened = id);
    await tester.tap(find.byKey(person(priya)));
    await tester.pumpAndSettle();

    final more = find.byKey(ValueKey('received-${note.id}'));
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, note.id);

    await tester.tap(more);
    await tester.pumpAndSettle();
    await act(tester, find.text('Make a private copy'));
    expect(sam.notes.notes.where((n) => !n.isShared), hasLength(1));

    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave this note'));
    await tester.pumpAndSettle();
    final keep = tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(const ValueKey('sharing-confirm-option')),
        matching: find.byType(Checkbox),
      ),
    );
    expect(keep.value, isTrue);
    await confirm(tester);

    // Out of the space, holding the copy that leaving kept beside the one
    // made before; Priya keeps hers.
    expect(sam.sharing.notesSharedFrom(priya.email), isEmpty);
    expect(find.byKey(person(priya)), findsNothing);
    final copies = sam.notes.notes.where((n) => !n.isShared).toList();
    expect(copies, hasLength(2));
    expect(copies.every((n) => n.body == 'Q4 reading list'), isTrue);
    expect(priya.notes.byId(note.id)!.isShared, isTrue);
    await quiet(tester);
  });

  testWidgets('a sent invitation shows its expiry, and is cancelled', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await sam.boot();
      final note = sam.notes.create(body: 'Notes from the call');
      await sam.sync.syncNow();
      await sam.sharing.shareNoteWith(note.id, email: 'tomas.lind@example.org');
    });
    await pump(tester, sam);

    final token = server.outbox.single.token;
    expect(find.text('Invitations you sent'), findsOneWidget);
    expect(
      find.textContaining(
        RegExp(r'^Notes from the call · expires (in \d+ days|tomorrow|today)$'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('copy-$token')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('cancel-$token')));
    await tester.pumpAndSettle();
    expect(
      find.text('Cancel the invitation to tomas.lind@example.org?'),
      findsOneWidget,
    );
    await confirm(tester);

    expect(find.text('Invitations you sent'), findsNothing);
    expect(sam.sharing.teams.expand((space) => space.invites), isEmpty);
  });

  testWidgets('a blocked person is unblocked from the list', (tester) async {
    const wen = 'wen.li@example.com';
    await tester.runAsync(() async {
      await sam.boot();
      await sam.sharing.blockPerson(wen);
    });
    await pump(tester, sam);

    expect(find.text("1 person can't invite you"), findsOneWidget);
    expect(find.byKey(const ValueKey('unblock-$wen')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('blocked-people')));
    await tester.pumpAndSettle();
    await act(tester, find.byKey(const ValueKey('unblock-$wen')));

    expect(sam.sharing.hasBlocked(wen), isFalse);
    expect(find.text('Nobody'), findsOneWidget);
  });

  testWidgets('the picker never lists a Hidden note, and says so', (
    tester,
  ) async {
    late Note open;
    late Note hidden;
    await tester.runAsync(() async {
      await sam.boot();
      await priya.boot();
    });
    final theirs = await shareWithSam(tester, 'Marathon training log');
    await tester.runAsync(() async {
      open = sam.notes.create(body: 'Ideas for the blog');
      hidden = sam.notes.create(body: 'Bank details');
      sam.notes.hide(hidden.id);
      await sam.sync.syncNow();
    });
    await pump(tester, sam);

    await tester.tap(find.byKey(const ValueKey('share-with-someone')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('pick-${open.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('pick-${hidden.id}')), findsNothing);
    expect(find.text('Bank details'), findsNothing);
    // Someone else's note is not this account's to pass on.
    expect(find.byKey(ValueKey('pick-${theirs.id}')), findsNothing);
    expect(
      find.text("Hidden notes can't be shared, so they aren't listed."),
      findsOneWidget,
    );

    // An address is asked for before anything is sent.
    final sent = server.outbox.length;
    await tester.tap(find.byKey(ValueKey('pick-${open.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('picker-share')));
    await tester.pumpAndSettle();
    expect(find.text('Add their email first'), findsOneWidget);
    expect(server.outbox, hasLength(sent));

    await tester.enterText(
      find.byKey(const ValueKey('picker-email')),
      'aoife.byrne@example.com',
    );
    await act(tester, find.byKey(const ValueKey('picker-share')));

    expect(find.byKey(const ValueKey('share-picker')), findsNothing);
    expect(
      find.text('Shared 1 note with aoife.byrne@example.com'),
      findsOneWidget,
    );
    expect(server.outbox.last.to, 'aoife.byrne@example.com');
    expect(sam.notes.byId(open.id)!.isShared, isTrue);
    expect(sam.notes.byId(hidden.id)!.isShared, isFalse);
  });

  testWidgets('offline disables actions and keeps the list, and an error is '
      'said once, inline', (tester) async {
    await tester.runAsync(() async {
      await sam.boot();
      final note = sam.notes.create(body: 'Notes from the call');
      await sam.sync.syncNow();
      await sam.sharing.shareNoteWith(note.id, email: 'tomas.lind@example.org');
    });
    await pump(tester, sam);
    final token = server.outbox.single.token;

    // The server goes away while the section is open: the action fails, and
    // says so once, under its group, with no toast besides.
    server.failNext = const SyncTransientException('offline');
    await tester.tap(find.byKey(ValueKey('cancel-$token')));
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(find.byKey(const ValueKey('sharing-error')), findsOneWidget);
    expect(
      find.text('Couldn’t reach Kapy cloud. Try again in a moment.'),
      findsOneWidget,
    );
    expect(find.text('Sharing failed'), findsNothing);
    expect(find.text('tomas.lind@example.org'), findsOneWidget);

    // Once sync has found it offline, everything that asks the server waits,
    // and what was on screen stays.
    await tester.runAsync(() async {
      server.failNext = const SyncTransientException('offline');
      await sam.sync.syncNow();
    });
    await tester.pumpAndSettle();
    expect(sam.sharing.isOffline, isTrue);
    expect(find.byKey(const ValueKey('sharing-offline')), findsOneWidget);
    expect(find.text('tomas.lind@example.org'), findsOneWidget);
    for (final key in ['cancel-$token', 'share-with-someone']) {
      final button = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull, reason: key);
    }
  });
}
