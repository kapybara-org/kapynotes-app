import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kMiddleMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_service.dart' show SyncStatus;
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/day_strip.dart';
import 'package:kapy_notes/ui/notes_grouping.dart';
import 'package:kapy_notes/ui/page_card.dart';
import 'package:kapy_notes/ui/page_toolbar.dart';
import 'package:kapy_notes/ui/unloaded_pictures_status.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  // The page card's border, on each side of the bar.
  const border = 1.5;

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

  const clients = PagePath(
    icon: KapyIcons.noteOutlined,
    root: 'My notes',
    levels: [
      (name: 'Work', folderId: 'work'),
      (name: 'Clients', folderId: 'clients'),
    ],
  );

  PageToolbar toolbar({
    PagePath path = clients,
    bool listVisible = true,
    bool noteOpen = true,
    SyncStatus? syncStatus,
    int unloadedPictures = 0,
    List<SpaceMember> members = const [],
    List<KapyMenuAction> moreActions = const [],
    ValueChanged<String>? onMore,
    VoidCallback? onShowList,
    void Function(String folderId, {required bool behind})? onOpenFolder,
    Widget? assistant,
    Widget Function(bool compact)? days,
  }) => PageToolbar(
    path: path,
    days: days,
    listVisible: listVisible,
    onShowList: onShowList ?? () {},
    showListShortcut: 'Cmd + \\',
    onOpenFolder: onOpenFolder ?? (_, {required behind}) {},
    noteOpen: noteOpen,
    syncStatus: syncStatus,
    unloadedPictures: unloadedPictures,
    members: members,
    currentUserId: 'me',
    onShare: () {},
    assistant: assistant,
    moreActions: moreActions,
    onMore: onMore ?? (_) {},
  );

  final bar = find.byKey(const ValueKey('page-toolbar'));
  final showList = find.byKey(const ValueKey('page-show-list'));
  final saved = find.byKey(const ValueKey('page-saved'));
  final share = find.byKey(const ValueKey('page-share'));
  final more = find.byKey(const ValueKey('page-more'));
  final path = find.byKey(const ValueKey('page-path'));
  final fold = find.byKey(const ValueKey('page-path-fold'));
  const ai = ValueKey('ai');
  Finder onPath(String text) =>
      find.descendant(of: path, matching: find.text(text));

  testWidgets('is 72 tall, with the path 16 in and every control centred 40 '
      'down', (tester) async {
    await tester.pumpWidget(
      harness(
        toolbar(assistant: const SizedBox(key: ai, width: 49, height: 32)),
      ),
    );

    final rect = tester.getRect(bar);
    expect(rect.height, 72);
    expect(showList, findsNothing);
    expect(find.byKey(const ValueKey('page-new-note')), findsNothing);
    expect(tester.getTopLeft(path).dx, rect.left + 16);
    for (final control in [path, saved, share, more, find.byKey(ai)]) {
      expect(tester.getCenter(control).dy, rect.top + 40);
    }
    expect(tester.getSize(share).height, 32);
    expect(tester.getSize(more), const Size.square(32));
    // Saved, Share and More 8 apart, and Kapy AI last at the bar's end.
    expect(tester.getTopLeft(share).dx - tester.getTopRight(saved).dx, 8);
    expect(tester.getTopLeft(more).dx - tester.getTopRight(share).dx, 8);
    expect(tester.getTopRight(find.byKey(ai)).dx, rect.right - 16);
  });

  testWidgets('the days sit between the path and the actions with as much '
      'room on either side, and give way to one button below 720', (
    tester,
  ) async {
    final compact = <bool>[];
    Widget days(bool narrow) {
      compact.add(narrow);
      return SizedBox(
        key: const ValueKey('days'),
        width: narrow ? 96 : 316,
        height: 64,
      );
    }

    await tester.pumpWidget(harness(toolbar(days: days)));
    final strip = find.byKey(const ValueKey('days'));
    final before = tester.getTopLeft(strip).dx - tester.getTopRight(path).dx;
    expect(before, greaterThan(16));
    expect(tester.getTopLeft(saved).dx - tester.getTopRight(strip).dx, before);
    // The days' column starts 8 down, as every control's centre is 40 down.
    expect(tester.getTopLeft(strip).dy, tester.getTopLeft(bar).dy + 8);
    expect(compact.last, isFalse);

    await tester.pumpWidget(
      harness(toolbar(days: days), width: 719 + 2 * border),
    );
    expect(compact.last, isTrue);
    await tester.pumpWidget(
      harness(toolbar(days: days), width: 720 + 2 * border),
    );
    expect(compact.last, isFalse);
  });

  testWidgets('with the list hidden it leads with the way back to it', (
    tester,
  ) async {
    var shown = 0;
    await tester.pumpWidget(
      harness(toolbar(listVisible: false, onShowList: () => shown++)),
    );

    expect(tester.getSize(showList), const Size.square(32));
    expect(tester.getTopLeft(showList).dx, tester.getRect(bar).left + 8);
    expect(tester.getTopLeft(path).dx - tester.getTopRight(showList).dx, 8);
    expect(
      find.descendant(
        of: showList,
        matching: find.byTooltip('Show notes  Cmd + \\'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('page-new-note')), findsNothing);

    await tester.tap(showList);
    expect(shown, 1);
  });

  testWidgets('the path names each level, with only where the page is in '
      'primary', (tester) async {
    await tester.pumpWidget(harness(toolbar()));

    TextStyle style(String text) => tester.widget<Text>(onPath(text)).style!;
    for (final text in ['My notes', 'Work']) {
      expect(style(text).fontWeight, FontWeight.w400);
      expect(style(text).color, KapyTheme.darkPalette.textTertiary);
    }
    expect(style('Clients').fontWeight, FontWeight.w500);
    expect(style('Clients').color, KapyTheme.darkPalette.textPrimary);
    expect(fold, findsNothing);
    // All of it shows, so hovering has nothing to add.
    expect(find.byTooltip('My notes › Work › Clients'), findsNothing);
  });

  testWidgets('a folder on the path opens in this tab on a click, and behind '
      'it on ⌘-click or a middle click', (tester) async {
    final opened = <(String, bool)>[];
    await tester.pumpWidget(
      harness(
        toolbar(
          onOpenFolder: (folderId, {required behind}) =>
              opened.add((folderId, behind)),
        ),
      ),
    );

    await tester.tap(onPath('Work'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(onPath('Clients'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(
      onPath('Work'),
      buttons: kMiddleMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    // My notes is a place on the rail, not a folder.
    await tester.tap(onPath('My notes'));
    expect(opened, [('work', false), ('clients', true), ('work', true)]);
  });

  testWidgets('a path deeper than two levels folds the middle into "…", '
      'whose menu opens the folder picked', (tester) async {
    final opened = <(String, bool)>[];
    await tester.pumpWidget(
      harness(
        toolbar(
          path: const PagePath(
            icon: KapyIcons.noteOutlined,
            root: 'My notes',
            levels: [
              (name: 'Work', folderId: 'work'),
              (name: 'Clients', folderId: 'clients'),
              (name: 'Acme', folderId: 'acme'),
              (name: '2026', folderId: 'y2026'),
            ],
          ),
          onOpenFolder: (folderId, {required behind}) =>
              opened.add((folderId, behind)),
        ),
      ),
    );

    for (final text in ['My notes', 'Acme', '2026']) {
      expect(onPath(text), findsOneWidget, reason: text);
    }
    expect(onPath('Work'), findsNothing);
    expect(onPath('Clients'), findsNothing);
    expect(
      find.byTooltip('My notes › Work › Clients › Acme › 2026'),
      findsOneWidget,
    );

    await tester.tap(fold);
    await tester.pumpAndSettle();
    Finder line(String folderId, String name) => find.descendant(
      of: find.byKey(ValueKey('page-path-$folderId')),
      matching: find.text(name),
    );
    // Each level sits 12 further in than the one it is inside.
    expect(
      tester.getTopLeft(line('clients', 'Clients')).dx -
          tester.getTopLeft(line('work', 'Work')).dx,
      12,
    );
    await tester.tap(line('clients', 'Clients'));
    await tester.pumpAndSettle();
    expect(opened, [('clients', false)]);
  });

  testWidgets('a narrower page keeps the last level, after a fold, then on '
      'its own, and hovering shows the whole path', (tester) async {
    await tester.pumpWidget(
      harness(toolbar(listVisible: false), width: 640 + 2 * border),
    );
    expect(onPath('Clients'), findsOneWidget);
    expect(onPath('My notes'), findsNothing);
    expect(fold, findsOneWidget);
    expect(find.byTooltip('My notes › Work › Clients'), findsOneWidget);

    await tester.pumpWidget(
      harness(toolbar(listVisible: false), width: 520 + 2 * border),
    );
    expect(onPath('Clients'), findsOneWidget);
    expect(onPath('My notes'), findsNothing);
    expect(fold, findsNothing);
    expect(find.byTooltip('My notes › Work › Clients'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long name stops at 200 and leaves the other names whole', (
    tester,
  ) async {
    const long = 'Quarterly planning for the regional offices and partners';
    await tester.pumpWidget(
      harness(
        toolbar(
          path: const PagePath(
            icon: KapyIcons.noteOutlined,
            root: 'My notes',
            levels: [(name: long, folderId: 'plans')],
          ),
        ),
      ),
    );

    expect(tester.getSize(onPath(long)).width, lessThanOrEqualTo(200));
    expect(tester.getSize(onPath('My notes')).width, greaterThan(40));
    expect(find.byTooltip('My notes › $long'), findsOneWidget);
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

  testWidgets('below a 560 page Saved leaves the bar, and Share, More and '
      'Kapy AI stay', (tester) async {
    Widget at(double width) => harness(
      toolbar(
        listVisible: false,
        assistant: const SizedBox(key: ai, width: 49, height: 32),
      ),
      width: width + 2 * border,
    );

    await tester.pumpWidget(at(560));
    expect(saved, findsOneWidget);

    await tester.pumpWidget(at(559));
    expect(saved, findsNothing);
    expect(
      find.descendant(of: share, matching: find.text('Share')),
      findsOneWidget,
    );
    expect(more, findsOneWidget);
    expect(find.byKey(ai), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("the count of pictures that didn't load gives way sooner", (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    final count = find.byType(UnloadedPicturesStatus);
    Widget at(double width, {int unloaded = 0}) => harness(
      toolbar(listVisible: false, unloadedPictures: unloaded),
      width: width + 2 * border,
    );

    await tester.pumpWidget(at(600));
    expect(saved, findsOneWidget);

    await tester.pumpWidget(at(600, unloaded: 123));
    expect(count, findsNothing);
    expect(saved, findsNothing);

    await tester.pumpWidget(at(685, unloaded: 123));
    expect(count, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('Saved goes to the date line wherever neither it nor the count of '
      "pictures that didn't load fits the bar", () {
    expect(PageToolbar.savedFits(560, unloadedPictures: 0), isTrue);
    expect(PageToolbar.savedFits(559, unloadedPictures: 0), isFalse);
    expect(PageToolbar.savedFits(684, unloadedPictures: 123), isFalse);
    expect(PageToolbar.savedFits(685, unloadedPictures: 123), isTrue);
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

    await tester.tap(more);
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
    final button = tester.widget<IconButton>(
      find.descendant(of: more, matching: find.byType(IconButton)),
    );
    expect(button.onPressed, isNull);
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

    // The days as My notes shows them, with notes on three of them.
    Widget week(bool compact) => DayStrip(
      compact: compact,
      today: DateTime(2026, 11, 19),
      when: NotesWhen.anyTime,
      onWhenChanged: (_) {},
      notes: [
        for (final (index, edited) in [
          DateTime(2026, 11, 17, 9),
          DateTime(2026, 11, 18, 10),
          DateTime(2026, 11, 18, 17),
          DateTime(2026, 11, 19, 8),
        ].indexed)
          Note(
            id: '$index',
            body: 'Note $index',
            createdAt: edited,
            updatedAt: edited,
          ),
      ],
      displayTime: (at) => at,
      firstWeekday: DateTime.monday,
    );

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
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('give way, and the days with them, before More leaves the '
        'bar', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      final crowd = [
        ...members,
        for (final id in ['a', 'b', 'c'])
          SpaceMember(
            userId: id,
            email: '$id@example.com',
            name: id,
            role: SpaceRole.member,
            joinedAt: DateTime(2026),
            hasKey: true,
          ),
      ];
      for (final (width, listVisible) in [(260.0, true), (420.0, false)]) {
        tester.view.physicalSize = Size(width, 300);
        await tester.pumpWidget(
          harness(
            toolbar(
              listVisible: listVisible,
              members: crowd,
              assistant: const SizedBox(width: 38, height: 32),
              days: week,
            ),
            width: width,
          ),
        );

        expect(tester.takeException(), isNull, reason: 'at $width');
        expect(
          tester.getTopRight(find.byKey(const ValueKey('page-more'))).dx,
          lessThanOrEqualTo(width),
          reason: 'More left the bar at $width',
        );
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
              toolbar(listVisible: width > 600, members: members, days: week),
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
