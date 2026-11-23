import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/sync/presence.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';
import 'support/sharing_devices.dart' show Device;
import 'sync/fake_server.dart';
import 'test_fonts.dart';

/// A phone's Shared page as 16RO-0 draws it: each group headed by its
/// people's faces, whose notes they are in the serif and a › that opens that
/// person, over rows that give the preview, who is typing and the tasks,
/// with no shared mark.
void main() {
  late FakeServer server;
  late Device sam;
  late Device priya;
  late Device wen;
  late Device kwame;
  const luca = 'luca@example.com';
  const nadia = 'nadia@example.com';
  final now = DateTime(2026, 11, 23, 9, 41);
  late Map<String, DateTime> edited;
  late String callId;

  setUpAll(loadTestFonts);

  setUp(() {
    server = FakeServer();
    for (final (id, name) in [
      ('user-1', 'Sam Rivera'),
      ('user-2', 'Priya Nair'),
      ('user-3', 'Wen Zhou'),
      ('user-4', 'Kwame Mensah'),
    ]) {
      server.user(id)
        ..name = name
        ..email = '${name.split(' ').first.toLowerCase()}@example.com';
    }
    sam = Device(server, userId: 'user-1', device: 'sam');
    priya = Device(server, userId: 'user-2', device: 'priya');
    wen = Device(server, userId: 'user-3', device: 'wen');
    kwame = Device(server, userId: 'user-4', device: 'kwame');
  });

  tearDown(() {
    for (final device in [sam, priya, wen, kwame]) {
      device.dispose();
    }
  });

  String tokenFor(String email) =>
      server.outbox.lastWhere((sent) => sent.to == email).token;

  /// Sam shares Call with Arjun and Renewal notes with Priya, who joins, and
  /// luca, who hasn't yet, and Spare keys with nadia alone; Wen shares Book
  /// club picks with Sam, who can only view it. With [invitation], Kwame's
  /// invitation to Offsite plan waits for Sam's answer.
  Future<void> shareAround(WidgetTester tester, {bool invitation = false}) =>
      tester.runAsync(() async {
        for (final device in [sam, priya, wen, kwame]) {
          await device.boot();
        }
        final call = sam.notes.create(
          body: 'Call with Arjun\nPricing page by Friday\n☐ Send the deck',
        );
        final renewal = sam.notes.create(
          body:
              'Renewal notes\nFor the call with Acme on Friday.\n'
              '☐ Pull the numbers\n☐ Book the room',
        );
        final keys = sam.notes.create(
          body: 'Spare keys\nWith the neighbour at 4B',
        );
        final book = wen.notes.create(
          body: 'Book club picks\nThe Overstory first, then Piranesi',
        );
        callId = call.id;
        edited = {
          call.id: DateTime(2026, 11, 23, 8, 55),
          book.id: DateTime(2026, 11, 23, 7, 50),
          renewal.id: DateTime(2026, 11, 20, 16, 5),
          keys.id: DateTime(2026, 11, 18, 12),
        };
        await sam.sync.syncNow();
        await wen.sync.syncNow();
        for (final note in [call, renewal]) {
          final sent = server.outbox.length;
          await sam.sharing.shareNoteWithPeople(note.id, {
            priya.email: SpaceRole.member,
            luca: SpaceRole.member,
          });
          if (server.outbox.skip(sent).any((mail) => mail.to == priya.email)) {
            await priya.sharing.acceptInvite(tokenFor(priya.email));
            await priya.sync.syncNow();
          }
        }
        await sam.sharing.shareNoteWith(keys.id, email: nadia);
        await wen.sharing.shareNoteWith(
          book.id,
          email: sam.email,
          role: SpaceRole.viewer,
        );
        await sam.sharing.acceptInvite(tokenFor(sam.email));
        await wen.sync.syncNow();
        if (invitation) {
          final offsite = kwame.notes.create(body: 'Offsite plan');
          await kwame.sync.syncNow();
          await kwame.sharing.shareNoteWith(offsite.id, email: sam.email);
        }
        await sam.sharing.refresh();
        await sam.sync.syncNow();
      });

  /// The page on an iPhone 15, with Priya typing in Call with Arjun.
  Future<void> pumpPage(
    WidgetTester tester, {
    ValueChanged<String>? onOpenPerson,
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final notes = [
      for (final note in sam.notes.notes)
        if (sidebarTabLists(SidebarTab.shared, note, sam.sharing))
          note.copyWith(updatedAt: edited[note.id]),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? KapyTheme.dark()
            : KapyTheme.light(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Sidebar(
            phone: true,
            notes: notes,
            selectedId: null,
            query: '',
            displayTime: (time) => time,
            now: () => now,
            onSearch: () {},
            onSelect: (_) {},
            sharing: sam.sharing,
            tab: SidebarTab.shared,
            onTabChanged: (_) {},
            onOpenPerson: onOpenPerson,
            collaborators: {
              callId: const [
                Collaborator(
                  userId: 'user-2',
                  name: 'Priya',
                  fullName: 'Priya Nair',
                  typing: true,
                ),
              ],
            },
            searchPlaceholder: 'Search shared notes',
            windowBar: PhoneListTitle(
              title: 'Shared',
              count: notes.length,
              onBack: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder heading(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byWidgetPredicate(
      (widget) => switch (widget.key) {
        ValueKey<String>(:final value) => value.startsWith('share-group-'),
        _ => false,
      },
    ),
  );

  Finder row(String title) => find.widgetWithText(NoteRow, title);

  for (final (title, people, opens) in [
    ('From Wen', ['wen@example.com'], 'wen@example.com'),
    (
      'With Priya, waiting for luca',
      ['priya@example.com', luca],
      'priya@example.com',
    ),
    ('Waiting for nadia', [nadia], nadia),
  ]) {
    testWidgets('"$title" leads with its faces, is set in the serif, and '
        'its › opens that person', (tester) async {
      await shareAround(tester);
      String? opened;
      await pumpPage(tester, onOpenPerson: (email) => opened = email);
      final palette = KapyTheme.darkPalette;
      final group = heading(title);
      expect(group, findsOne);

      final words = tester.widget<Text>(find.text(title));
      expect(words.style?.fontFamily, AppFonts.title);
      expect(words.style?.fontSize, 19);
      expect(words.style?.height, 24 / 19);
      expect(words.style?.color, palette.textPrimary);
      expect(words.maxLines, 1);

      final titleRect = tester.getRect(find.text(title));
      for (final email in people) {
        final face = find.descendant(
          of: group,
          matching: find.byKey(ValueKey('share-face-$email')),
        );
        expect(face, findsOne);
        expect(tester.getSize(face), const Size(24, 24));
        expect(tester.getRect(face).right, lessThan(titleRect.left));
      }
      expect(
        find.descendant(
          of: group,
          matching: findKapyIcon(KapyIcons.mailOutlined),
        ),
        people.contains(luca) || people.contains(nadia)
            ? findsOne
            : findsNothing,
        reason: 'someone who hasn’t joined has the mail face',
      );

      final chevron = find.descendant(
        of: group,
        matching: findKapyIcon(KapyIcons.chevronRightRounded),
      );
      expect(chevron, findsOne);
      expect(tester.getSize(chevron), const Size(14, 14));
      expect(tester.getRect(chevron).left - titleRect.right, 8);
      expect(tester.widget<KapyIcon>(chevron).color, palette.textTertiary);

      await tester.tap(chevron);
      expect(opened, opens);
    });
  }

  testWidgets('a heading takes the 19 above it, sits right on its first row, '
      'and marks whoever is in one of its notes with a sage dot', (
    tester,
  ) async {
    await shareAround(tester);
    await pumpPage(tester, onOpenPerson: (_) {});
    final palette = KapyTheme.darkPalette;
    final group = heading('With Priya, waiting for luca');
    expect(tester.getSize(group).height, 19 + 24);
    final first = row('Call with Arjun');
    expect(tester.getRect(first).top, tester.getRect(group).bottom);
    expect(
      tester.getRect(find.text('Call with Arjun')).top -
          tester.getRect(first).top,
      12,
    );

    final here = find.descendant(
      of: group,
      matching: find.byKey(const ValueKey('share-face-here')),
    );
    expect(here, findsOne);
    expect(tester.getSize(here), const Size(10, 10));
    expect(
      (tester.widget<Container>(here).decoration! as BoxDecoration).color,
      palette.accentText,
    );
    final priyaFace = tester.getRect(
      find.descendant(
        of: group,
        matching: find.byKey(const ValueKey('share-face-priya@example.com')),
      ),
    );
    expect(
      tester.getRect(here).bottomRight,
      priyaFace.bottomRight + const Offset(3, 3),
    );
    expect(
      find.descendant(
        of: heading('From Wen'),
        matching: find.byKey(const ValueKey('share-face-here')),
      ),
      findsNothing,
    );
  });

  testWidgets('without a way to open people, a heading has no ›', (
    tester,
  ) async {
    await shareAround(tester);
    await pumpPage(tester);
    expect(find.text('From Wen'), findsOne);
    expect(findKapyIcon(KapyIcons.chevronRightRounded), findsNothing);
  });

  testWidgets('rows give the preview, who is typing and the tasks, keep '
      'their time, and carry no shared mark', (tester) async {
    await shareAround(tester);
    await pumpPage(tester, onOpenPerson: (_) {});
    final holds = find.byKey(const ValueKey('note-row-holds'));

    final call = row('Call with Arjun');
    expect(
      find.descendant(of: call, matching: find.text('Pricing page by Friday')),
      findsOne,
    );
    final callHolds = find.descendant(of: call, matching: holds);
    expect(
      find.descendant(of: callHolds, matching: find.text('Priya is typing...')),
      findsOne,
    );
    expect(
      find.descendant(of: callHolds, matching: find.text('0 of 1')),
      findsOne,
    );
    expect(
      find.descendant(of: call, matching: find.text('8:55')),
      findsOne,
      reason: 'the time stays where it is while someone types',
    );

    final renewal = row('Renewal notes');
    expect(
      find.descendant(
        of: renewal,
        matching: find.text('For the call with Acme on Friday.'),
      ),
      findsOne,
    );
    expect(
      find.descendant(of: renewal, matching: find.text('0 of 2')),
      findsOne,
    );
    expect(
      find.descendant(
        of: renewal,
        matching: find.byKey(const ValueKey('note-row-live')),
      ),
      findsNothing,
    );

    final book = row('Book club picks');
    expect(
      find.descendant(
        of: find.descendant(of: book, matching: holds),
        matching: find.text('View only'),
      ),
      findsOne,
    );

    expect(
      find.descendant(of: row('Spare keys'), matching: holds),
      findsNothing,
    );
    expect(findKapyIcon(KapyIcons.groupOutlined), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the phone Shared page, ${brightness.name}', (tester) async {
      await shareAround(tester, invitation: true);
      await pumpPage(tester, onOpenPerson: (_) {}, brightness: brightness);
      expect(find.textContaining('Kwame Mensah'), findsWidgets);
      await expectLater(
        find.byType(Sidebar),
        matchesGoldenFile(
          'goldens/phone_shared_page_iphone_${brightness.name}.png',
        ),
      );
    });
  }
}
