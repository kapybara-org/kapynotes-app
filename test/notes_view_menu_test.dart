import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/notes_grouping.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:kapy_notes/ui/tag_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

/// B's calm list (KAP-408): one View menu beside the search, one chip for
/// what narrows the list, the checklist as a pie and media marks on hover.
void main() {
  setUpAll(loadTestFonts);

  void desktop(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    AppPlatform.debugTargetPlatformOverride = platform;
  }

  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  Future<void> pumpView(
    WidgetTester tester, {
    NotesShow show = NotesShow.all,
    Set<NoteMedia>? media = const {
      NoteMedia.voice,
      NoteMedia.video,
      NoteMedia.image,
    },
    ValueChanged<NotesShow>? onShowChanged,
    NotesGrouping grouping = NotesGrouping.byDate,
    ValueChanged<NotesGrouping>? onGroupingChanged,
    bool cards = false,
    ValueChanged<bool>? onCardsChanged,
    ValueChanged<NotesWhen>? onWhenChanged,
    Size window = const Size(1200, 800),
    double listWidth = 336,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: listWidth,
              child: Align(
                alignment: Alignment.topRight,
                child: NotesListControls(
                  show: show,
                  onShowChanged: onShowChanged ?? (_) {},
                  hiddenListed: true,
                  archivedCount: 12,
                  media: media,
                  onMediaChanged: (_) {},
                  today: DateTime(2026, 11, 26),
                  when: NotesWhen.anyTime,
                  onWhenChanged: onWhenChanged ?? (_) {},
                  grouping: grouping,
                  onGroupingChanged: onGroupingChanged ?? (_) {},
                  cards: cards,
                  onCardsChanged: onCardsChanged ?? (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  final view = find.byKey(const ValueKey('notes-view'));
  final menu = find.byKey(const ValueKey('notes-filter-menu'));

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('${platform.name}: the View icon is a 32 pt sliders button '
        "named View, and its menu holds Show with When, Media, Group by and "
        'Layout, in that order', (tester) async {
      desktop(platform);
      await pumpView(tester);
      expect(tester.getSize(view), const Size(32, 32));
      expect(find.byTooltip('View'), findsOneWidget);
      expect(find.text('All notes'), findsNothing);

      await tester.tap(view);
      await tester.pump();
      expect(menu, findsOneWidget);
      double top(String text) => tester
          .getTopLeft(find.descendant(of: menu, matching: find.text(text)))
          .dy;
      final order = [
        'Show',
        'All notes',
        'Hidden',
        'Archive',
        'When',
        'Media',
        'All media',
        'Voice',
        'Video',
        'Image',
        'Group by',
        'By date',
        'By tag',
        'A–Z',
        'Layout',
        'List',
        'Grid',
      ];
      for (var i = 1; i < order.length; i++) {
        expect(
          top(order[i]),
          greaterThan(top(order[i - 1])),
          reason: '${order[i]} after ${order[i - 1]}',
        );
      }
      expect(find.descendant(of: menu, matching: find.text('12')), findsOne);
      // Right-aligned under the icon, inside the list.
      expect(tester.getRect(menu).right, tester.getRect(view).right);
      expect(tester.getRect(menu).left, greaterThanOrEqualTo(0));
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Grid and By tag are ticked choices that close the menu', (
    tester,
  ) async {
    desktop(TargetPlatform.macOS);
    bool? cards;
    NotesGrouping? grouping;
    await pumpView(
      tester,
      onCardsChanged: (value) => cards = value,
      onGroupingChanged: (value) => grouping = value,
    );
    await tester.tap(view);
    await tester.pump();
    Finder tick(String key) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byWidgetPredicate(
        (widget) => widget is KapyIcon && widget.icon == KapyIcons.checkRounded,
      ),
    );
    expect(tick('notes-layout-list'), findsOneWidget);
    expect(tick('notes-layout-grid'), findsNothing);
    expect(tick('notes-grouping-byDate'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notes-layout-grid')));
    await tester.pump();
    expect(cards, isTrue);
    expect(menu, findsNothing);

    await tester.tap(view);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-grouping-byTag')));
    await tester.pump();
    expect(grouping, NotesGrouping.byTag);
    expect(menu, findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("Drawings' View menu has no Media group", (tester) async {
    desktop(TargetPlatform.macOS);
    await pumpView(tester, media: null);
    await tester.tap(view);
    await tester.pump();
    expect(find.text('All drawings'), findsOneWidget);
    expect(find.text('Media'), findsNothing);
    expect(find.text('All media'), findsNothing);
    expect(find.text('Group by'), findsOneWidget);
    expect(find.text('Layout'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the keyboard reaches every row: Tab to the icon, Enter opens '
      'the menu, the arrows walk it, Enter chooses and Escape closes', (
    tester,
  ) async {
    desktop(TargetPlatform.macOS);
    NotesShow? shown;
    bool? cards;
    await pumpView(
      tester,
      onShowChanged: (show) => shown = show,
      onCardsChanged: (value) => cards = value,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(menu, findsOneWidget);

    // All notes, then Hidden.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(shown, NotesShow.hidden);
    expect(menu, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(menu, findsOneWidget, reason: 'focus came back to the icon');
    // Up from the top wraps round to the last row, Grid.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(cards, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(menu, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(menu, findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('When opens beside the menu where there is room, and in its '
      'place with a row back to it in a 400 px window', (tester) async {
    desktop(TargetPlatform.macOS);
    NotesWhen? when;
    final whenMenu = find.byKey(const ValueKey('notes-when-menu'));
    final back = find.byKey(const ValueKey('notes-view-back'));

    await pumpView(tester, onWhenChanged: (value) => when = value);
    await tester.tap(view);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-filter-when')));
    await tester.pump();
    expect(menu, findsOneWidget);
    expect(whenMenu, findsOneWidget);
    expect(back, findsNothing);
    expect(
      tester.getRect(whenMenu).left,
      greaterThan(tester.getRect(menu).right),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    await pumpView(
      tester,
      onWhenChanged: (value) => when = value,
      window: const Size(400, 720),
      listWidth: 400,
    );
    await tester.tap(view);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-filter-when')));
    await tester.pump();
    expect(menu, findsNothing);
    expect(whenMenu, findsOneWidget);
    expect(back, findsOneWidget);
    expect(tester.getRect(whenMenu).right, lessThanOrEqualTo(400));
    expect(tester.getRect(whenMenu).left, greaterThanOrEqualTo(0));

    await tester.tap(back);
    await tester.pump();
    expect(menu, findsOneWidget);
    expect(whenMenu, findsNothing);

    await tester.tap(find.byKey(const ValueKey('notes-filter-when')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-filter-when-thisWeek')));
    await tester.pump();
    expect(when, NotesWhen.thisWeek);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('in a 400 px window the keyboard goes into When in the '
      "menu's place and back out of it", (tester) async {
    desktop(TargetPlatform.macOS);
    final back = find.byKey(const ValueKey('notes-view-back'));
    final whenRow = find.byKey(const ValueKey('notes-filter-when'));
    bool focused(Finder finder) {
      final at = FocusManager.instance.primaryFocus?.context;
      if (at is! Element) return false;
      final target = tester.element(finder);
      var inside = identical(at, target);
      at.visitAncestorElements((element) {
        inside = inside || identical(element, target);
        return !inside;
      });
      return inside;
    }

    await pumpView(tester, window: const Size(400, 720), listWidth: 400);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 20 && !focused(whenRow); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(back, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      focused(back),
      isTrue,
      reason: 'the submenu starts at its first row',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(menu, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      focused(find.byKey(const ValueKey('notes-filter-all'))),
      isTrue,
      reason: 'the menu starts again at its first row',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(menu, findsNothing);
    expect(focused(view), isTrue, reason: 'focus goes back to the View icon');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('in a short window the menu scrolls, and its last row is still '
      'reached', (tester) async {
    desktop(TargetPlatform.macOS);
    bool? cards;
    await pumpView(
      tester,
      window: const Size(1200, 360),
      onCardsChanged: (value) => cards = value,
    );
    await tester.tap(view);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(menu).bottom,
      lessThanOrEqualTo(360 - 12),
      reason: 'the menu ends inside the window',
    );
    final grid = find.byKey(const ValueKey('notes-layout-grid'));
    await tester.ensureVisible(grid);
    await tester.pump();
    await tester.tap(grid);
    expect(cards, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('in a short window a row the keyboard reaches by wrapping '
      'round is scrolled into sight', (tester) async {
    desktop(TargetPlatform.macOS);
    await pumpView(tester, window: const Size(1200, 360));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    final box = tester.getRect(menu);
    bool inSight(String key) {
      final row = tester.getRect(find.byKey(ValueKey(key)));
      return row.top >= box.top && row.bottom <= box.bottom;
    }

    // Up from the top wraps round to Grid, at the foot.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(inSight('notes-layout-grid'), isTrue);

    // Down from Grid wraps round to All notes, at the top.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(inSight('notes-filter-all'), isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("an iPad's View icon opens the touch popover, which adds "
      'Group by and Layout', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    bool? cards;
    NotesGrouping? grouping;
    await pumpView(
      tester,
      onCardsChanged: (value) => cards = value,
      onGroupingChanged: (value) => grouping = value,
    );
    await tester.tap(view);
    await tester.pumpAndSettle();
    expect(find.text('Group by'), findsOneWidget);
    expect(find.text('Layout'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notes-grouping-aToZ')));
    await tester.pumpAndSettle();
    expect(grouping, NotesGrouping.aToZ);

    await tester.tap(view);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-layout-grid')));
    await tester.pumpAndSettle();
    expect(cards, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("a phone's filter row has no Group by or Layout", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: NotesListControls(
            show: NotesShow.all,
            onShowChanged: (_) {},
            hiddenListed: true,
            archivedCount: 0,
            media: NoteMedia.values.toSet(),
            onMediaChanged: (_) {},
            today: DateTime(2026, 11, 26),
            grouping: NotesGrouping.byDate,
            onGroupingChanged: (_) {},
            phone: true,
          ),
        ),
      ),
    );
    expect(view, findsNothing);
    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    expect(find.text('Media'), findsOneWidget);
    expect(find.text('Group by'), findsNothing);
    expect(find.text('Layout'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  group('the chip', () {
    final chip = find.byKey(const ValueKey('notes-filter-chip'));

    Future<void> pumpChip(
      WidgetTester tester, {
      double width = 300,
      VoidCallback? onClear,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Align(
                alignment: Alignment.centerLeft,
                child: NotesFilterChip(
                  show: NotesShow.hidden,
                  media: const {NoteMedia.voice, NoteMedia.image},
                  tags: null,
                  when: NotesWhen.thisWeek,
                  onClear: onClear ?? () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    test('shows only while something narrows the list', () {
      final every = NoteMedia.values.toSet();
      expect(
        NotesFilterChip.shows(
          show: NotesShow.all,
          media: every,
          tags: null,
          when: NotesWhen.anyTime,
        ),
        isFalse,
      );
      for (final (show, media, span) in [
        (NotesShow.archive, every, NotesWhen.anyTime),
        (NotesShow.all, {NoteMedia.voice}, NotesWhen.anyTime),
        (NotesShow.all, every, NotesWhen.today),
      ]) {
        expect(
          NotesFilterChip.shows(
            show: show,
            media: media,
            tags: null,
            when: span,
          ),
          isTrue,
        );
      }
    });

    testWidgets('names every filter in menu order, with the whole in its '
        'tooltip and a ✕', (tester) async {
      desktop(TargetPlatform.macOS);
      final semantics = tester.ensureSemantics();
      await pumpChip(tester);
      const label = 'Hidden · Voice, Image · This week';
      expect(find.text(label), findsOneWidget);
      expect(find.byTooltip(label), findsOneWidget);
      expect(
        find.descendant(
          of: chip,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KapyIcon && widget.icon == KapyIcons.closeRounded,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('$label, back to All notes'),
        findsOneWidget,
      );
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets("in Drawings it names No tag and goes back to All drawings", (
      tester,
    ) async {
      desktop(TargetPlatform.macOS);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.light(),
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: NotesFilterChip(
                show: NotesShow.all,
                media: null,
                tags: const TagFilter(none: true),
                when: NotesWhen.anyTime,
                onClear: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('No tag'), findsOneWidget);
      expect(
        find.bySemanticsLabel('No tag, back to All drawings'),
        findsOneWidget,
      );
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('runs out of room in "…" before its ✕', (tester) async {
      desktop(TargetPlatform.macOS);
      await pumpChip(tester, width: 120);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(chip).width, lessThanOrEqualTo(120));
      final words = tester.renderObject<RenderParagraph>(
        find.descendant(of: chip, matching: find.byType(RichText)),
      );
      expect(words.didExceedMaxLines, isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a click or Enter goes back to everything', (tester) async {
      desktop(TargetPlatform.macOS);
      var cleared = 0;
      await pumpChip(tester, onClear: () => cleared++);
      await tester.tap(chip);
      expect(cleared, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(cleared, 2);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('a row', () {
    Note withPicture(String body) => Note(
      id: 'note-1',
      body: '$body\n${NoteAttachmentRef.placeholder}',
      createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 17, 11, 15),
      attachments: [
        NoteImageRef(
          offset: body.length + 1,
          hash: 'pic',
          key: Uint8List(32),
          mime: 'image/png',
          width: 4,
          height: 3,
          bytes: 12,
        ),
      ],
    );

    Future<void> pumpRow(
      WidgetTester tester,
      Note note, {
      bool hovering = false,
      bool selected = false,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: TagMarks(
            marksOf: (_) => const [],
            child: Center(
              child: SizedBox(
                width: 320,
                child: NoteListRowFace(
                  note: note,
                  glance: NoteGlance.of(note, null),
                  date: '11:15',
                  selected: selected,
                  hovering: hovering,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final picture = find.byWidgetPredicate(
      (widget) => widget is KapyIcon && widget.icon == NoteMedia.image.icon,
    );

    testWidgets('shows what the note holds only while hovered or open', (
      tester,
    ) async {
      desktop(TargetPlatform.macOS);
      final note = withPicture('Moodboard\nWarm light, linen');
      await pumpRow(tester, note);
      expect(picture, findsNothing);
      expect(find.text('Warm light, linen'), findsOneWidget);
      await pumpRow(tester, note, hovering: true);
      expect(picture, findsOneWidget);
      await pumpRow(tester, note, selected: true);
      expect(picture, findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('keeps the lock in sight at rest', (tester) async {
      desktop(TargetPlatform.macOS);
      final note = withPicture('Moodboard\nWarm light, linen');
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Material(
            child: TagMarks(
              marksOf: (_) => const [],
              child: SizedBox(
                width: 320,
                child: NoteListRowFace(
                  note: note,
                  glance: NoteGlance.of(note, null),
                  date: '11:15',
                  selected: false,
                  hovering: false,
                  locked: true,
                ),
              ),
            ),
          ),
        ),
      );
      expect(picture, findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is KapyIcon && widget.icon == KapyIcons.lockRounded,
        ),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets("Pinned's count waits in its tooltip", (tester) async {
    desktop(TargetPlatform.macOS);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: const Material(
          child: NotesListHeading(label: 'Pinned', count: 4),
        ),
      ),
    );
    expect(find.text('4'), findsNothing);
    expect(find.byTooltip('4 notes'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
