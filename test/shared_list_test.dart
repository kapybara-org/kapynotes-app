import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/sync/sharing.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'share_dialog_test.dart' show Device, harness;
import 'sync/fake_server.dart';
import 'test_fonts.dart';

/// The Shared list, grouped by person: "With Priya", "With Aoife and Kwame",
/// "From Wen", "Waiting for tomas.lind".
void main() {
  late FakeServer server;
  late Device sam;
  late Device priya;
  late Device aoife;
  late Device kwame;
  late Device wen;
  const tomas = 'tomas.lind@example.org';

  setUpAll(loadTestFonts);

  setUp(() {
    server = FakeServer();
    for (final (id, name) in [
      ('user-1', 'Sam Rivera'),
      ('user-2', 'Priya Nair'),
      ('user-3', 'Aoife Byrne'),
      ('user-4', 'Kwame Mensah'),
      ('user-5', 'Wen Li'),
    ]) {
      server.user(id)
        ..name = name
        ..email = '${name.toLowerCase().replaceAll(' ', '.')}@example.com';
    }
    sam = Device(server, userId: 'user-1', device: 'sam');
    priya = Device(server, userId: 'user-2', device: 'priya');
    aoife = Device(server, userId: 'user-3', device: 'aoife');
    kwame = Device(server, userId: 'user-4', device: 'kwame');
    wen = Device(server, userId: 'user-5', device: 'wen');
  });

  tearDown(() {
    for (final device in [sam, priya, aoife, kwame, wen]) {
      device.dispose();
    }
  });

  String tokenFor(Device device) =>
      server.outbox.lastWhere((sent) => sent.to == device.email).token;

  Future<void> join(Device device) async {
    await device.sharing.acceptInvite(tokenFor(device));
    await device.sync.syncNow();
  }

  /// Sam's Shared list, rebuilt as his notes and spaces change, as the app
  /// does.
  Future<void> pumpShared(
    WidgetTester tester, {
    ValueChanged<String>? onOpenPerson,
  }) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness(
        ListenableBuilder(
          listenable: Listenable.merge([sam.sharing, sam.notes]),
          builder: (context, _) => Sidebar(
            notes: [
              for (final note in sam.notes.notes)
                if (sidebarTabLists(SidebarTab.shared, note, sam.sharing)) note,
            ],
            selectedId: null,
            query: '',
            displayTime: (t) => t,
            onSearch: () {},
            onSelect: (_) {},
            sharing: sam.sharing,
            tab: SidebarTab.shared,
            onTabChanged: (_) {},
            onOpenPerson: onOpenPerson,
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
  }

  /// Whether [title]'s row sits under [heading] and above anything below
  /// it in the list.
  void expectUnder(WidgetTester tester, String title, String heading) {
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top(heading), lessThan(top(title)));
    final headings = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          RegExp(r'^(With|From|Waiting for) ').hasMatch(widget.data ?? ''),
    );
    for (final element in headings.evaluate()) {
      final dy = tester.getTopLeft(find.byWidget(element.widget)).dy;
      if (dy > top(heading)) expect(dy, greaterThan(top(title)));
    }
  }

  testWidgets('one person shared with at two accesses is one group', (
    tester,
  ) async {
    late Note goa;
    late Note dad;
    await tester.runAsync(() async {
      for (final device in [sam, priya]) {
        await device.boot();
      }
      goa = sam.notes.create(body: 'Goa trip budget');
      dad = sam.notes.create(body: "Dad's 60th: plan");
      sam.notes.create(body: 'Bank details');
      await sam.sync.syncNow();
      await sam.sharing.shareNoteWith(goa.id, email: priya.email);
      await join(priya);
      await sam.sharing.shareNoteWith(
        dad.id,
        email: priya.email,
        role: SpaceRole.viewer,
      );
      await join(priya);
      await sam.sharing.refresh();
      await sam.sync.syncNow();
    });

    // Two spaces, one for each access, and one heading over both.
    Note now(Note note) => sam.notes.byId(note.id)!;
    expect(
      sam.sharing.spaceOf(now(goa))!.id,
      isNot(sam.sharing.spaceOf(now(dad))!.id),
    );
    expect(
      sam.sharing.groupOf(now(goa))!.key,
      sam.sharing.groupOf(now(dad))!.key,
    );

    String? opened;
    await pumpShared(tester, onOpenPerson: (email) => opened = email);
    expect(find.text('With Priya'), findsOneWidget);
    expectUnder(tester, 'Goa trip budget', 'With Priya');
    expectUnder(tester, "Dad's 60th: plan", 'With Priya');
    // Notes nobody else can see stay out of Shared.
    expect(find.text('Bank details'), findsNothing);

    await tester.tap(find.text('With Priya'));
    expect(opened, priya.email);
  });

  testWidgets('groups for several people, from an owner, and for invitees', (
    tester,
  ) async {
    late Note flat;
    await tester.runAsync(() async {
      for (final device in [sam, aoife, kwame, wen]) {
        await device.boot();
      }
      flat = sam.notes.create(body: 'Flat 4B bills');
      final call = sam.notes.create(
        body: 'Notes from the call with the contractor',
      );
      final marathon = wen.notes.create(body: 'Marathon training log');
      await sam.sync.syncNow();
      await wen.sync.syncNow();
      await sam.sharing.shareNoteWith(flat.id, email: aoife.email);
      await sam.sharing.addPerson(flat.id, kwame.email);
      await join(aoife);
      await sam.sharing.shareNoteWith(call.id, email: tomas);
      await wen.sharing.shareNoteWith(marathon.id, email: sam.email);
      await join(sam);
      // The note reaches Sam once Wen has synced him in.
      await wen.sync.syncNow();
      await sam.sharing.refresh();
      await sam.sync.syncNow();
    });

    String? opened;
    await pumpShared(tester, onOpenPerson: (email) => opened = email);

    // Aoife has joined and Kwame not yet: the group is still theirs, with
    // Kwame named by his address until he joins and says who he is.
    expect(find.text('With Aoife, waiting for kwame.mensah'), findsOneWidget);
    expectUnder(
      tester,
      'Flat 4B bills',
      'With Aoife, waiting for kwame.mensah',
    );
    expect(find.text('From Wen'), findsOneWidget);
    expectUnder(tester, 'Marathon training log', 'From Wen');
    expect(find.text('Waiting for tomas.lind'), findsOneWidget);
    expectUnder(
      tester,
      'Notes from the call with the contractor',
      'Waiting for tomas.lind',
    );

    // A group opens the first person it names.
    await tester.tap(find.text('With Aoife, waiting for kwame.mensah'));
    expect(opened, aoife.email);
    await tester.tap(find.text('From Wen'));
    expect(opened, wen.email);
    expect(
      sam.sharing.groupOf(sam.notes.byId(flat.id)!)!.kind,
      ShareGroupKind.sharedWith,
    );
  });

  testWidgets('a note moves between groups as its people change', (
    tester,
  ) async {
    late Note groceries;
    late Note blog;
    await tester.runAsync(() async {
      for (final device in [sam, priya, aoife, kwame]) {
        await device.boot();
      }
      groceries = sam.notes.create(body: 'Groceries this week');
      blog = sam.notes.create(body: 'Ideas for the blog');
      await sam.sync.syncNow();
      await sam.sharing.shareNoteWith(groceries.id, email: priya.email);
      await join(priya);
      await sam.sharing.shareNoteWith(blog.id, email: kwame.email);
      await sam.sharing.refresh();
      await sam.sync.syncNow();
    });

    await pumpShared(tester);
    expectUnder(tester, 'Groceries this week', 'With Priya');
    expectUnder(tester, 'Ideas for the blog', 'Waiting for kwame.mensah');

    await tester.runAsync(() async {
      await sam.sharing.addPerson(groceries.id, aoife.email);
      await join(aoife);
      await join(kwame);
      await sam.sharing.refresh();
      await sam.sync.syncNow();
    });
    await tester.pumpAndSettle();

    // Aoife is in it now too, and Kwame has joined.
    expect(find.text('With Priya'), findsNothing);
    expectUnder(tester, 'Groceries this week', 'With Aoife and Priya');
    expect(find.text('Waiting for kwame.mensah'), findsNothing);
    expectUnder(tester, 'Ideas for the blog', 'With Kwame');
  });

  test('a heading names everyone, and full names only where first ones '
      'clash', () {
    SharePerson person(String name) => SharePerson(
      email: '${name.toLowerCase().replaceAll(' ', '.')}@example.com',
      name: name,
      userId: name,
    );
    final aoife = person('Aoife Byrne');
    final kwame = person('Kwame Mensah');
    final wen = person('Wen Li');
    final priya = person('Priya Nair');
    expect(
      ShareGroup(ShareGroupKind.sharedWith, [aoife, kwame, wen]).title,
      'With Aoife, Kwame and Wen',
    );
    expect(
      ShareGroup(ShareGroupKind.sharedWith, [aoife, kwame, priya, wen]).title,
      'With Aoife, Kwame and 2 others',
    );
    expect(
      ShareGroup(ShareGroupKind.sharedWith, [
        person('Priya Nair'),
        person('Priya Shah'),
      ]).title,
      'With Priya Nair and Priya Shah',
    );
    expect(
      ShareGroup(ShareGroupKind.waiting, [
        const SharePerson(email: 'tomas.lind@example.org', name: 'tomas.lind'),
      ]).title,
      'Waiting for tomas.lind',
    );
    expect(ShareGroup(ShareGroupKind.from, [wen]).title, 'From Wen');
  });

  test('a heading keeps people who have not joined apart, and does not '
      'shorten a name to an initial', () {
    const invited = SharePerson(
      email: 'tomas.lind@example.org',
      name: 'tomas.lind',
    );
    const priya = SharePerson(
      email: 'priya.nair@example.com',
      name: 'Priya Nair',
      userId: 'user-2',
    );
    const initial = SharePerson(
      email: 'j.okafor@example.com',
      name: 'J. Okafor',
      userId: 'user-6',
    );
    expect(
      ShareGroup(ShareGroupKind.sharedWith, [priya, invited]).title,
      'With Priya, waiting for tomas.lind',
    );
    expect(
      ShareGroup(ShareGroupKind.sharedWith, [initial]).title,
      'With J. Okafor',
    );
    expect(initial.firstName, 'J. Okafor');
    expect(priya.firstName, 'Priya');
  });
}
