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

import 'kapy_icon_finder.dart';
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
    bool underList = false,
    bool noteOpen = true,
    SyncStatus? syncStatus,
    int unloadedPictures = 0,
    List<SpaceMember> members = const [],
    List<KapyMenuAction> moreActions = const [],
    void Function(String value, Offset at)? onMore,
    VoidCallback? onShowList,
    VoidCallback? onNew,
    void Function(String folderId, {required bool behind})? onOpenFolder,
    Widget? assistant,
    List<Widget>? actions,
    Widget Function(bool compact, PlaceDays place)? days,
    ({String to, VoidCallback onPressed})? back,
  }) => PageToolbar(
    path: path,
    days: days,
    back: back,
    actions: actions,
    listVisible: listVisible,
    underList: underList,
    onShowList: onShowList ?? () {},
    showListShortcut: 'Cmd + \\',
    create: onNew == null
        ? null
        : (label: 'New note', tooltip: 'New note  Cmd + N', onPressed: onNew),
    onOpenFolder: onOpenFolder ?? (_, {required behind}) {},
    noteOpen: noteOpen,
    syncStatus: syncStatus,
    unloadedPictures: unloadedPictures,
    members: members,
    currentUserId: 'me',
    onShare: () {},
    assistant: assistant,
    moreActions: moreActions,
    onMore: onMore ?? (_, _) {},
  );

  final bar = find.byKey(const ValueKey('page-toolbar'));
  final showList = find.byKey(const ValueKey('page-show-list'));
  final newButton = find.byKey(const ValueKey('page-new'));
  final saved = find.byKey(const ValueKey('page-saved'));
  final share = find.byKey(const ValueKey('page-share'));
  final more = find.byKey(const ValueKey('page-more'));
  final path = find.byKey(const ValueKey('page-path'));
  final fold = find.byKey(const ValueKey('page-path-fold'));
  const ai = ValueKey('ai');
  Finder onPath(String text) =>
      find.descendant(of: path, matching: find.text(text));

  testWidgets('Share is quiet: grey words on no fill until the pointer is '
      'on it, and greyer still when it cannot be used', (tester) async {
    await tester.pumpWidget(harness(toolbar()));

    final palette = tester.element(share).palette;
    final style = tester
        .widget<FilledButton>(
          find.descendant(of: share, matching: find.byType(FilledButton)),
        )
        .style!;
    expect(style.backgroundColor!.resolve({}), Colors.transparent);
    expect(style.foregroundColor!.resolve({}), palette.textSecondary);
    expect(
      style.backgroundColor!.resolve({WidgetState.hovered}),
      palette.textPrimary.withValues(alpha: 0.07),
    );
    expect(
      style.backgroundColor!.resolve({WidgetState.disabled}),
      Colors.transparent,
    );
    expect(
      style.foregroundColor!.resolve({WidgetState.disabled}),
      palette.textTertiary,
    );
    expect(style.side!.resolve({}), BorderSide.none);
    expect(
      style.side!.resolve({WidgetState.focused}),
      BorderSide(color: palette.selectedBorder, width: 1),
    );
  });

  testWidgets('the band has a hairline along its bottom, but none under the '
      'list or on a phone', (tester) async {
    BoxDecoration? hairline() =>
        tester.widget<Container>(bar).foregroundDecoration as BoxDecoration?;

    await tester.pumpWidget(harness(toolbar()));
    expect(
      hairline()?.border,
      Border(bottom: BorderSide(color: KapyTheme.darkPalette.railBorder)),
    );

    await tester.pumpWidget(
      harness(toolbar(listVisible: false, underList: true)),
    );
    expect(hairline(), isNull);

    await tester.pumpWidget(
      harness(toolbar(back: (to: 'Notes', onPressed: () {}))),
    );
    expect(hairline(), isNull);
  });

  testWidgets(
    'is a 52 band from the page\'s top, with the path 18 in, every '
    'control centred down it, and More last, after Kapy AI, 12 from the end',
    (tester) async {
      await tester.pumpWidget(
        harness(
          toolbar(assistant: const SizedBox(key: ai, width: 49, height: 32)),
        ),
      );

      final rect = tester.getRect(bar);
      final card = tester.getRect(find.byType(PageCard));
      expect(rect.top, card.top + border);
      expect(rect.bottom, card.top + 52);
      expect(showList, findsNothing);
      expect(find.byKey(const ValueKey('page-new-note')), findsNothing);
      expect(tester.getTopLeft(path).dx, rect.left + 18);
      for (final control in [path, saved, share, more, find.byKey(ai)]) {
        expect(tester.getCenter(control).dy, rect.center.dy);
      }
      expect(tester.getSize(share).height, 32);
      expect(tester.getSize(more), const Size.square(32));
      // Saved and Share 8 apart, Kapy AI straight after Share behind its own
      // hairline, and More 4 after it at the bar's end.
      expect(tester.getTopLeft(share).dx - tester.getTopRight(saved).dx, 8);
      expect(
        tester.getTopLeft(find.byKey(ai)).dx,
        tester.getTopRight(share).dx,
      );
      expect(
        tester.getTopLeft(more).dx - tester.getTopRight(find.byKey(ai)).dx,
        4,
      );
      expect(tester.getTopRight(more).dx, rect.right - 12);
      expect(
        find.descendant(
          of: more,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KapyIcon &&
                widget.icon == KapyIcons.moreVerticalRounded,
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('the days put their month at the top left in place of the '
      'path, and the week centred on the page between two 208 slots, 12 '
      'clear of each; below 720 one button stands in for both', (tester) async {
    final compact = <bool>[];
    const month = ValueKey('month');
    const week = ValueKey('week');
    Widget days(bool narrow, PlaceDays place) {
      compact.add(narrow);
      return place(
        SizedBox(key: month, width: narrow ? 96 : 90, height: 32),
        narrow
            ? null
            : const SizedBox(key: week, width: double.infinity, height: 44),
      );
    }

    await tester.pumpWidget(harness(toolbar(days: days)));
    final rect = tester.getRect(bar);
    expect(path, findsNothing);
    // The month's button starts 8 before its words, which start 18 in.
    expect(tester.getTopLeft(find.byKey(month)).dx, rect.left + 10);
    final middle = tester.getRect(find.byKey(week));
    expect(middle.width, rect.width - 2 * (PageToolbar.slot + 12));
    expect(middle.center.dx, rect.center.dx);
    for (final part in [month, week]) {
      expect(tester.getCenter(find.byKey(part)).dy, rect.center.dy);
    }
    expect(compact.last, isFalse);

    await tester.pumpWidget(
      harness(toolbar(days: days), width: 719 + 2 * border),
    );
    expect(compact.last, isTrue);
    expect(find.byKey(week), findsNothing);
    expect(tester.getTopLeft(find.byKey(month)).dx, rect.left + 10);
    await tester.pumpWidget(
      harness(toolbar(days: days), width: 720 + 2 * border),
    );
    expect(compact.last, isFalse);
  });

  testWidgets('actions wider than their slot widen both slots, so the week '
      'stays centred', (tester) async {
    const week = ValueKey('week');
    await tester.pumpWidget(
      harness(
        toolbar(
          assistant: const SizedBox(key: ai, width: 120, height: 32),
          days: (_, place) => place(
            const SizedBox(width: 90, height: 32),
            const SizedBox(key: week, width: double.infinity, height: 44),
          ),
        ),
      ),
    );

    final rect = tester.getRect(bar);
    final middle = tester.getRect(find.byKey(week));
    final actions = rect.right - tester.getTopLeft(saved).dx;
    expect(actions, greaterThan(PageToolbar.slot));
    expect(middle.width, rect.width - 2 * (actions + 12));
    expect(middle.center.dx, rect.center.dx);
  });

  testWidgets('a folder page has only Kapy AI and More on its right', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        toolbar(
          actions: const [],
          assistant: const SizedBox(key: ai, width: 49, height: 32),
        ),
      ),
    );

    expect(saved, findsNothing);
    expect(share, findsNothing);
    expect(
      tester.getTopLeft(more).dx - tester.getTopRight(find.byKey(ai)).dx,
      4,
    );
    expect(tester.getTopRight(more).dx, tester.getRect(bar).right - 12);
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
    expect(newButton, findsNothing);

    await tester.tap(showList);
    expect(shown, 1);
  });

  group('New beside the way back to the list', () {
    testWidgets('its plus is the sage that marks the main action', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(toolbar(listVisible: false, onNew: () {})),
      );

      final plus = tester.widget<KapyIcon>(
        find.descendant(of: newButton, matching: find.byType(KapyIcon)),
      );
      expect(plus.color, tester.element(newButton).palette.accentText);
    });

    testWidgets('sits 4 after it, the same quiet button, and makes what the '
        'list\'s New makes', (tester) async {
      var made = 0;
      await tester.pumpWidget(
        harness(toolbar(listVisible: false, onNew: () => made++)),
      );

      expect(tester.getSize(newButton), tester.getSize(showList));
      expect(
        tester.getTopLeft(newButton).dx - tester.getTopRight(showList).dx,
        4,
      );
      expect(tester.getCenter(newButton).dy, tester.getCenter(showList).dy);
      expect(tester.getTopLeft(path).dx - tester.getTopRight(newButton).dx, 8);
      expect(
        find.descendant(
          of: newButton,
          matching: findKapyIcon(KapyIcons.addRounded),
        ),
        findsOneWidget,
      );
      KapyIcon glyph(Finder button, KapyIconData data) =>
          tester.widget<KapyIcon>(
            find.descendant(of: button, matching: findKapyIcon(data)),
          );
      expect(
        glyph(newButton, KapyIcons.addRounded).size,
        glyph(showList, KapyIcons.menuOpenRounded).size,
      );
      expect(
        IconTheme.of(
          tester.element(
            find.descendant(
              of: newButton,
              matching: findKapyIcon(KapyIcons.addRounded),
            ),
          ),
        ).color,
        IconTheme.of(
          tester.element(
            find.descendant(
              of: showList,
              matching: findKapyIcon(KapyIcons.menuOpenRounded),
            ),
          ),
        ).color,
      );

      await tester.tap(newButton);
      expect(made, 1);
    });

    testWidgets('is left out while the list shows, beside the page or over '
        'it', (tester) async {
      await tester.pumpWidget(harness(toolbar(onNew: () {})));
      expect(newButton, findsNothing);
      await tester.pumpWidget(
        harness(toolbar(listVisible: false, underList: true, onNew: () {})),
      );
      expect(newButton, findsNothing);
    });

    testWidgets('names what it makes and its chord, and the keyboard reaches '
        'and presses it', (tester) async {
      final semantics = tester.ensureSemantics();
      var made = 0;
      await tester.pumpWidget(
        harness(toolbar(listVisible: false, onNew: () => made++)),
      );
      expect(
        find.descendant(
          of: newButton,
          matching: find.byTooltip('New note  Cmd + N'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(newButton),
        isSemantics(
          label: 'New note',
          tooltip: 'New note  Cmd + N',
          isButton: true,
          hasTapAction: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );

      bool focused() => Focus.of(
        tester.element(
          find.descendant(
            of: newButton,
            matching: findKapyIcon(KapyIcons.addRounded),
          ),
        ),
      ).hasPrimaryFocus;
      var tabs = 0;
      while (!focused() && tabs < 10) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        tabs++;
      }
      expect(focused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(made, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(made, 2);
      semantics.dispose();
    });

    testWidgets('takes its room before the path, the days and Saved decide '
        'what fits', (tester) async {
      // Its button and the 4 before it.
      const room = 32.0 + 4;
      final compact = <bool>[];
      Widget days(bool narrow, PlaceDays place) {
        compact.add(narrow);
        return place(
          const SizedBox(width: 96, height: 32),
          narrow ? null : const SizedBox(width: double.infinity, height: 44),
        );
      }

      Widget at(double width, {bool withNew = true, bool withDays = false}) =>
          harness(
            toolbar(
              listVisible: false,
              onNew: withNew ? () {} : null,
              days: withDays ? days : null,
              assistant: const SizedBox(key: ai, width: 49, height: 32),
            ),
            width: width + 2 * border,
          );

      await tester.pumpWidget(at(720 + room - 1, withDays: true));
      expect(compact.last, isTrue);
      await tester.pumpWidget(at(720 + room, withDays: true));
      expect(compact.last, isFalse);
      await tester.pumpWidget(
        at(720 + room - 1, withNew: false, withDays: true),
      );
      expect(compact.last, isFalse);

      await tester.pumpWidget(at(720 + room - 1));
      expect(fold, findsOneWidget);
      await tester.pumpWidget(at(720 + room));
      expect(fold, findsNothing);
      await tester.pumpWidget(at(560 + room - 1));
      expect(fold, findsNothing);
      expect(onPath('Clients'), findsOneWidget);

      await tester.pumpWidget(at(560 + room));
      expect(saved, findsOneWidget);
      await tester.pumpWidget(at(560 + room - 1));
      expect(saved, findsNothing);
      expect(
        PageToolbar.savedFits(
          560 + room - 1,
          unloadedPictures: 0,
          withNew: true,
        ),
        isFalse,
      );
      expect(
        PageToolbar.savedFits(560 + room, unloadedPictures: 0, withNew: true),
        isTrue,
      );
      expect(
        PageToolbar.savedFits(560 + room - 1, unloadedPictures: 0),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
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

  group('the line above a note\'s title', () {
    final line = find.byKey(const ValueKey('note-path'));
    Finder onLine(String text) =>
        find.descendant(of: line, matching: find.text(text));
    Widget pathLine(
      List<PagePlace> folders, {
      void Function(String folderId, {required bool behind})? onOpenFolder,
    }) => MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 680,
            child: NotePathLine(
              folders: folders,
              onOpenFolder: onOpenFolder ?? (_, {required behind}) {},
            ),
          ),
        ),
      ),
    );

    testWidgets('names the folders alone, and opens one in this tab on a '
        'click, behind it on ⌘-click or a middle click', (tester) async {
      final opened = <(String, bool)>[];
      await tester.pumpWidget(
        pathLine(
          [
            (name: 'Work', folderId: 'work'),
            (name: 'Clients', folderId: 'clients'),
            (name: 'Acme', folderId: 'acme'),
          ],
          onOpenFolder: (folderId, {required behind}) {
            opened.add((folderId, behind));
          },
        ),
      );

      expect(tester.getSize(line).height, 16);
      for (final name in ['Work', 'Clients', 'Acme']) {
        expect(onLine(name), findsOneWidget, reason: name);
      }
      expect(find.byKey(const ValueKey('note-path-fold')), findsNothing);
      expect(find.byTooltip('Work › Clients › Acme'), findsNothing);

      await tester.tap(onLine('Acme'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(onLine('Clients'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(
        onLine('Work'),
        buttons: kMiddleMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      expect(opened, [('acme', false), ('clients', true), ('work', true)]);
    });

    testWidgets('a name too long is cut at 200, and hovering shows the whole '
        'line', (tester) async {
      const long = 'Quarterly planning for the regional offices and partners';
      await tester.pumpWidget(
        pathLine([
          (name: 'Work', folderId: 'work'),
          (name: long, folderId: 'plans'),
        ]),
      );

      expect(tester.getSize(onLine(long)).width, lessThanOrEqualTo(200));
      expect(find.byTooltip('Work › $long'), findsOneWidget);
    });
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

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('a ${platform.name} note header draws Back as an arrow and '
        'More as ⋮, both at 20', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      await tester.pumpWidget(
        harness(
          toolbar(
            listVisible: false,
            back: (to: 'Notes', onPressed: () {}),
            moreActions: const [
              KapyMenuAction(
                value: 'pin',
                label: 'Pin note',
                icon: KapyIcons.pinOutlined,
              ),
            ],
          ),
          width: 393,
        ),
      );

      final back = find.byKey(const ValueKey('page-back'));
      final arrow = find.descendant(
        of: back,
        matching: findKapyIcon(KapyIcons.arrowBackRounded),
      );
      expect(arrow, findsOneWidget);
      expect(tester.widget<KapyIcon>(arrow).size, 20);
      expect(findKapyIcon(KapyIcons.chevronLeftRounded), findsNothing);

      final dots = find.descendant(
        of: more,
        matching: findKapyIcon(KapyIcons.moreVerticalRounded),
      );
      expect(dots, findsOneWidget);
      expect(tester.widget<KapyIcon>(dots).size, 20);
    });
  }

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
          onMore: (value, _) => picked = value,
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
    Widget week(bool compact, PlaceDays place) => DayStrip(
      place: place,
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
          closeTo(width - 1.5 - 12, 0.01),
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
              onNew: () {},
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
