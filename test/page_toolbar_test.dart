import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_service.dart' show SyncStatus;
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/page_card.dart';
import 'package:kapy_notes/ui/page_toolbar.dart';
import 'package:kapy_notes/ui/unloaded_pictures_status.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  Widget harness(
    PageToolbar toolbar, {
    double width = 1016,
    Brightness brightness = Brightness.dark,
  }) => MaterialApp(
    theme: brightness == Brightness.dark ? KapyTheme.dark() : KapyTheme.light(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: 300,
          child: PageCard(child: Column(children: [toolbar, const Spacer()])),
        ),
      ),
    ),
  );

  PageToolbar toolbar({
    bool listVisible = true,
    bool noteOpen = true,
    SyncStatus? syncStatus,
    int unloadedPictures = 0,
    String? section = 'Pinned',
    List<SpaceMember> members = const [],
    List<KapyMenuAction> moreActions = const [],
    ValueChanged<String>? onMore,
    VoidCallback? onShowList,
    VoidCallback? onCreate,
  }) => PageToolbar(
    space: 'My notes',
    section: section,
    listVisible: listVisible,
    onShowList: onShowList ?? () {},
    onCreate: onCreate ?? () {},
    showListShortcut: 'Cmd + \\',
    newNoteShortcut: 'Cmd + N',
    noteOpen: noteOpen,
    syncStatus: syncStatus,
    unloadedPictures: unloadedPictures,
    members: members,
    currentUserId: 'me',
    onShare: () {},
    pinned: true,
    onTogglePin: () {},
    moreActions: moreActions,
    onMore: onMore ?? (_) {},
  );

  final showList = find.byKey(const ValueKey('page-show-list'));
  final newNote = find.byKey(const ValueKey('page-new-note'));
  final saved = find.byKey(const ValueKey('page-saved'));

  testWidgets('beside the list it leads with the breadcrumb alone', (
    tester,
  ) async {
    await tester.pumpWidget(harness(toolbar()));

    expect(showList, findsNothing);
    expect(newNote, findsNothing);
    final crumb = find.byKey(const ValueKey('page-breadcrumb'));
    expect(
      find.descendant(of: crumb, matching: find.text('My notes')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: crumb, matching: find.text('Pinned')),
      findsOneWidget,
    );
    // Paper's 24 from the page's edge, inside its 1.5 border.
    expect(tester.getTopLeft(crumb).dx, 25.5);
  });

  testWidgets('with the list hidden it leads with show-list and a new note', (
    tester,
  ) async {
    var shown = 0;
    var created = 0;
    await tester.pumpWidget(
      harness(
        toolbar(
          listVisible: false,
          onShowList: () => shown++,
          onCreate: () => created++,
        ),
      ),
    );

    expect(tester.getSize(showList), const Size.square(30));
    expect(
      find.descendant(
        of: showList,
        matching: find.byTooltip('Show notes  Cmd + \\'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: newNote,
        matching: find.byTooltip('New note  Cmd + N'),
      ),
      findsOneWidget,
    );
    expect(tester.getTopLeft(newNote).dx - tester.getTopRight(showList).dx, 4);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('page-breadcrumb'))).dx,
      greaterThan(tester.getTopRight(newNote).dx + 18),
    );

    await tester.tap(showList);
    await tester.tap(newNote);
    expect((shown, created), (1, 1));
  });

  testWidgets('Saved speaks for the open note, and for sync', (tester) async {
    await tester.pumpWidget(harness(toolbar()));
    expect(
      find.descendant(of: saved, matching: find.text('Saved')),
      findsOneWidget,
    );

    await tester.pumpWidget(harness(toolbar(syncStatus: SyncStatus.syncing)));
    expect(find.text('Syncing'), findsOneWidget);

    await tester.pumpWidget(harness(toolbar(syncStatus: SyncStatus.offline)));
    expect(find.text('Offline'), findsOneWidget);
    expect(
      find.byTooltip(
        'Saved on this device. It syncs once you are back online.',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(harness(toolbar(noteOpen: false)));
    expect(saved, findsNothing);
  });

  testWidgets('a narrow page gives Saved up before anything else', (
    tester,
  ) async {
    await tester.pumpWidget(harness(toolbar(listVisible: false), width: 420));

    expect(saved, findsNothing);
    for (final key in ['page-share', 'page-pin', 'page-more']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets("the count of pictures that didn't load gives way sooner", (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    final count = find.byType(UnloadedPicturesStatus);

    await tester.pumpWidget(harness(toolbar(listVisible: false), width: 560));
    expect(saved, findsOneWidget);

    await tester.pumpWidget(
      harness(toolbar(listVisible: false, unloadedPictures: 123), width: 560),
    );
    expect(count, findsNothing);
    expect(saved, findsNothing);

    await tester.pumpWidget(
      harness(toolbar(listVisible: false, unloadedPictures: 123), width: 632),
    );
    expect(count, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('More lists its actions and hands back the one picked', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      harness(
        toolbar(
          moreActions: const [
            KapyMenuAction(
              value: 'split',
              label: 'Up to three notes side by side',
              icon: KapyIcons.viewColumnOutlined,
              enabled: false,
            ),
            KapyMenuAction(
              value: 'archive',
              label: 'Archive note',
              icon: KapyIcons.archiveOutlined,
              destructive: true,
            ),
          ],
          onMore: (value) => picked = value,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('page-more-split')));
    await tester.pumpAndSettle();
    expect(picked, isNull);

    await tester.tap(find.byKey(const ValueKey('page-more-archive')));
    await tester.pumpAndSettle();
    expect(picked, 'archive');
  });

  testWidgets('More has nothing to open with nothing to offer', (tester) async {
    await tester.pumpWidget(harness(toolbar()));
    final more = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('page-more')),
        matching: find.byType(IconButton),
      ),
    );
    expect(more.onPressed, isNull);
  });

  group('a shared note', () {
    final members = [
      for (final (id, name) in [('me', 'Sanjay'), ('pankaj', 'Pankaj')])
        SpaceMember(
          userId: id,
          email: '$id@example.com',
          name: name,
          role: SpaceRole.member,
          joinedAt: DateTime(2026),
          hasKey: true,
        ),
    ];

    testWidgets('keeps its collaborators with the rest on the right', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      for (final width in [1440.0, 480.0]) {
        tester.view.physicalSize = Size(width, 300);
        await tester.pumpWidget(
          harness(
            toolbar(listVisible: width > 600, members: members),
            width: width,
          ),
        );

        final avatars = find.byKey(const ValueKey('toolbar-members'));
        expect(avatars, findsOneWidget);
        final share = find.byKey(const ValueKey('page-share'));
        // Straight after the breadcrumb's empty stretch, never half way
        // across it: the cluster is one group flush with the right edge.
        expect(
          tester.getTopLeft(share).dx - tester.getTopRight(avatars).dx,
          lessThan(160),
        );
        expect(
          tester.getTopRight(find.byKey(const ValueKey('page-more'))).dx,
          closeTo(width - 1.5 - 16, 0.01),
        );
        expect(tester.getTopLeft(avatars).dx, greaterThan(width * 0.5));
        expect(tester.takeException(), isNull);
      }
    });

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final (label, width) in [('wide', 1440.0), ('narrow', 480.0)]) {
        testWidgets('header, $label, ${brightness.name}', (tester) async {
          tester.view.physicalSize = Size(width, 300);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            harness(
              toolbar(listVisible: width > 600, members: members),
              width: width,
              brightness: brightness,
            ),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(PageCard),
            matchesGoldenFile(
              'goldens/page_toolbar_shared_${label}_${brightness.name}.png',
            ),
          );
        });
      }
    }
  });
}
