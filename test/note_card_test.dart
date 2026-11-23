import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/ui/checklist_pie.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:kapy_notes/ui/tag_ui.dart' show TagDot;
import 'package:kapy_notes/ui/tasks/task_marks.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  const palette = KapyTheme.darkPalette;
  const travel = (name: 'Travel', colour: TagColour.sage);
  const money = (name: 'Money', colour: TagColour.rust);

  Note note(String body) => Note(
    id: 'note-1',
    body: body,
    createdAt: DateTime(2026, 11, 1),
    updatedAt: DateTime(2026, 11, 17, 11, 15),
  );

  Future<void> pumpCard(
    WidgetTester tester,
    Note note, {
    List<TagMark> tags = const [],
    bool selected = false,
    bool hovering = false,
    double width = 300,
    ThemeData? theme,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme ?? KapyTheme.dark(),
      home: Material(
        child: TagMarks(
          marksOf: (_) => tags,
          child: Center(
            child: SizedBox(
              width: width,
              height: NoteCardFace.height,
              child: NoteCardFace(
                note: note,
                glance: NoteGlance.of(note, null),
                date: 'Today, 11:15',
                day: 'Today',
                selected: selected,
                hovering: hovering,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  BoxDecoration card(WidgetTester tester) =>
      tester
              .widget<Container>(
                find
                    .descendant(
                      of: find.byType(NoteCardFace),
                      matching: find.byType(Container),
                    )
                    .first,
              )
              .decoration!
          as BoxDecoration;

  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!;

  /// Every fill painted inside the card: its own, and anything nested in it.
  List<Color> fills(WidgetTester tester) => [
    for (final widget in tester.widgetList(
      find.descendant(
        of: find.byType(NoteCardFace),
        matching: find.byWidgetPredicate(
          (widget) => widget is DecoratedBox || widget is ColoredBox,
        ),
      ),
    ))
      switch (widget) {
        DecoratedBox(decoration: BoxDecoration(:final color?)) => color,
        ColoredBox(:final color) => color,
        _ => null,
      },
  ].nonNulls.toList();

  testWidgets('a card paints one opaque fill, so its shadow never shows '
      'through, at rest, under the pointer and open', (tester) async {
    for (final (selected, hovering) in [
      (false, false),
      (false, true),
      (true, false),
    ]) {
      for (final theme in [KapyTheme.dark(), KapyTheme.light()]) {
        await pumpCard(
          tester,
          note('Reading list\nDeep Work, Dune'),
          selected: selected,
          hovering: hovering,
          theme: theme,
        );
        await tester.pumpAndSettle();
        final painted = fills(tester);
        expect(painted, [card(tester).color], reason: '$selected $hovering');
        expect(painted.single.a, 1, reason: '$selected $hovering');
      }
    }
  });

  testWidgets("a card sits on its theme's own card colour, a step up under "
      'the pointer and another when open', (tester) async {
    Future<int> fill(
      ThemeData theme, {
      bool selected = false,
      bool hovering = false,
    }) async {
      await pumpCard(
        tester,
        note('Reading list'),
        selected: selected,
        hovering: hovering,
        theme: theme,
      );
      // A new theme eases in; read the card once it has.
      await tester.pumpAndSettle();
      return card(tester).color!.toARGB32();
    }

    const light = KapyTheme.lightPalette;
    expect(await fill(KapyTheme.light()), light.cardBackground.toARGB32());
    expect(await fill(KapyTheme.light()), 0xFFF6F2E8);
    expect(await fill(KapyTheme.light(), hovering: true), 0xFFEEEAE0);
    expect(await fill(KapyTheme.light(), selected: true), 0xFFEAE6DC);
    // Riverbank dark: the spec's rest card, and its open card (10% over the
    // surface, which is 6% over the card) to within one step of rounding.
    expect(await fill(KapyTheme.dark()), 0xFF24221E);
    expect(await fill(KapyTheme.dark(), hovering: true), 0xFF2C2925);
    expect(await fill(KapyTheme.dark(), selected: true), 0xFF2F2D29);
  });

  testWidgets('a card at rest has no outline, its title in Figtree 13/18 at '
      '500', (tester) async {
    await pumpCard(tester, note('Reading list\nDeep Work, Dune'));

    expect(card(tester).color, palette.cardBackground);
    expect(card(tester).border, isNull);
    expect(find.byType(TagDots), findsNothing);
    final title = styleOf(tester, 'Reading list');
    expect(title.fontFamily, AppFonts.ui);
    expect(title.fontSize, 13);
    expect(title.height, 18 / 13);
    expect(title.fontVariations, AppWeight.variations(AppWeight.button));
    expect(title.color, palette.textPrimary);
    expect(styleOf(tester, 'Today, 11:15').color, palette.textTertiary);
  });

  testWidgets('a tag gives a card its dot and its name, never its colour', (
    tester,
  ) async {
    await pumpCard(
      tester,
      note('Trip budget\n₹28,000'),
      tags: const [travel, money],
    );

    expect(card(tester).color, palette.cardBackground);
    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('Money'), findsNothing);
    expect(styleOf(tester, 'Travel').color, palette.textTertiary);
    expect(tester.getSize(find.byType(TagDots)).width, TagDots.widthFor(2));
  });

  List<Rect> dotRects(WidgetTester tester) => [
    for (final element
        in find
            .descendant(of: find.byType(TagDots), matching: find.byType(TagDot))
            .evaluate())
      tester.getRect(find.byWidget(element.widget)),
  ];

  testWidgets('on the Mac a card draws its tags as 6 px dots, 2 apart, with '
      'no ring', (tester) async {
    await pumpCard(
      tester,
      note('Trip budget\n₹28,000'),
      tags: const [travel, money],
    );

    final dots = dotRects(tester);
    expect(dots.map((dot) => dot.size), [const Size(6, 6), const Size(6, 6)]);
    expect(dots[1].left - dots[0].right, 2);
    expect(TagDots.widthFor(2), 14);
    for (final box in tester.widgetList<Container>(
      find.descendant(
        of: find.byType(TagDots),
        matching: find.byType(Container),
      ),
    )) {
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.boxShadow, isNull);
      expect(decoration.border, isNull);
    }
  });

  testWidgets("a phone's note row titles are 17/24", (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final row = note('Reading list\nDeep Work, Dune');
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: NoteListRowFace(
            note: row,
            glance: NoteGlance.of(row, null),
            date: '11:15',
            selected: false,
            hovering: false,
            touch: true,
          ),
        ),
      ),
    );

    final title = styleOf(tester, 'Reading list');
    expect(title.fontSize, 17);
    expect(title.height, 24 / 17);
  });

  testWidgets('on a phone the dots stay 8 px and 4 apart', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: const Center(child: TagDots(tags: [travel, money])),
      ),
    );

    final dots = dotRects(tester);
    expect(dots.map((dot) => dot.size), [const Size(8, 8), const Size(8, 8)]);
    expect(dots[1].left - dots[0].right, 4);
    expect(TagDots.widthFor(2), 20);
  });

  testWidgets('a phone row with three tags shows two dots, 20 wide', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final row = note('Trip budget');
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: TagMarks(
            marksOf: (_) => const [
              travel,
              money,
              (name: 'Work', colour: TagColour.mustard),
            ],
            child: NoteListRowFace(
              note: row,
              glance: NoteGlance.of(row, null),
              date: '11:15',
              selected: false,
              hovering: false,
              touch: true,
            ),
          ),
        ),
      ),
    );

    expect(dotRects(tester), hasLength(2));
    expect(tester.getSize(find.byType(TagDots)).width, 20);
  });

  testWidgets("a card's preview line is Figtree 12/16 at 400 in T2", (
    tester,
  ) async {
    await pumpCard(tester, note('Reading list\nDeep Work, Dune'));

    final preview = styleOf(tester, 'Deep Work, Dune');
    expect(preview.fontFamily, AppFonts.ui);
    expect(preview.fontSize, 12);
    expect(preview.height, 16 / 12);
    expect(preview.fontVariations, AppWeight.variations(AppWeight.body));
    expect(preview.color, palette.textSecondary);
  });

  testWidgets('the selected card is a step lighter, with no tilt and no '
      'outline, and its meta steps up to T2', (tester) async {
    await pumpCard(
      tester,
      note('Trip budget\n₹28,000'),
      tags: const [travel],
      selected: true,
    );

    expect(
      find.descendant(
        of: find.byType(NoteCardFace),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(
      card(tester).color,
      Color.alphaBlend(palette.fillControl, palette.cardBackground),
    );
    expect(card(tester).border, isNull);
    expect(styleOf(tester, 'Today, 11:15').color, palette.textSecondary);
    expect(styleOf(tester, 'Travel').color, palette.textSecondary);
  });

  testWidgets('a section label is 12/16 at 520 in T3, its count at 400, '
      'with no rule after it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: const Material(
          child: SizedBox(
            width: 300,
            child: NotesGroupHeading(label: 'Yesterday', detail: '2'),
          ),
        ),
      ),
    );

    final label = styleOf(tester, 'Yesterday');
    expect(label.fontSize, 12);
    expect(label.height, 16 / 12);
    expect(label.fontVariations, AppWeight.variations(AppWeight.section));
    expect(label.color, palette.textTertiary);
    final count = styleOf(tester, '2');
    expect(count.fontSize, 12);
    expect(count.fontVariations, AppWeight.variations(AppWeight.body));
    expect(count.color, palette.textTertiary);
    expect(
      find.descendant(
        of: find.byType(NotesGroupHeading),
        matching: find.byType(ColoredBox),
      ),
      findsNothing,
    );
  });

  testWidgets('a card with no text says so in italic', (tester) async {
    await pumpCard(tester, note(''));

    final fallback = tester.widget<Text>(find.text('No text yet'));
    expect(fallback.style?.fontStyle, FontStyle.italic);
  });

  testWidgets('a meta row short of room drops the tag name before the time', (
    tester,
  ) async {
    final seen = <(bool, bool)>{};
    for (var width = 400.0; width >= 90; width -= 4) {
      await pumpCard(
        tester,
        note('SnowSEO Issues\n☑ crawl\n☐ fix titles'),
        tags: const [travel],
        width: width,
      );
      final named = find.text('Travel').evaluate().isNotEmpty;
      final timed = find.text('Today, 11:15').evaluate().isNotEmpty;
      expect(!timed && named, isFalse, reason: 'at $width');
      expect(tester.takeException(), isNull, reason: 'at $width');
      seen.add((named, timed));
    }
    expect(seen, containsAll({(true, true), (false, true), (false, false)}));
  });

  testWidgets('a task\'s note square takes its first tag\'s dot', (
    tester,
  ) async {
    Future<Color?> square(List<TagMark> tags) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: TagMarks(
            marksOf: (_) => tags,
            child: Center(child: NoteSwatch(note: note('Trip budget'))),
          ),
        ),
      );
      return (tester
                  .widget<Container>(
                    find.descendant(
                      of: find.byType(NoteSwatch),
                      matching: find.byType(Container),
                    ),
                  )
                  .decoration!
              as BoxDecoration)
          .color;
    }

    expect(await square(const []), const Color(0xFF3A3530));
    expect(await square(const [travel]), TagColour.sage.dot(palette));
  });

  group('on a desktop', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    Finder chevron(KapyIconData icon) => find.byWidgetPredicate(
      (widget) => widget is KapyIcon && widget.icon == icon,
    );

    Future<void> pumpControls(
      WidgetTester tester, {
      NotesShow show = NotesShow.all,
      bool cards = false,
      ValueChanged<bool>? onCardsChanged,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 304,
              child: NotesListControls(
                show: show,
                onShowChanged: (_) {},
                hiddenListed: true,
                archivedCount: 0,
                onClear: () {},
                media: NoteMedia.values.toSet(),
                today: DateTime(2026, 11, 19),
                cards: cards,
                onCardsChanged: onCardsChanged ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    Container box(WidgetTester tester, String key) =>
        tester.widget<Container>(find.byKey(ValueKey(key)));

    BoxDecoration? fill(WidgetTester tester, String key) =>
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(ValueKey(key)),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as BoxDecoration?;

    testWidgets('"All notes ▾" is plain words and its chevron, with the '
        "filter's 32 pt target and name", (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpControls(tester);
      final filter = find.byKey(const ValueKey('sidebar-notes-filter'));
      final button = tester.widget<Container>(
        find.descendant(of: filter, matching: find.byType(Container)).first,
      );
      expect(button.decoration, isNull);
      expect(tester.getSize(filter).height, 32);
      expect(find.text('All notes'), findsOneWidget);
      expect(
        find.descendant(
          of: filter,
          matching: chevron(KapyIcons.chevronDownRounded),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(filter),
        isSemantics(
          label: 'Notes filter, All notes',
          textDirection: TextDirection.ltr,
          isButton: true,
          hasExpandedState: true,
          hasTapAction: true,
        ),
      );

      await pumpControls(tester, show: NotesShow.hidden);
      expect(
        tester
            .widget<Container>(
              find
                  .descendant(of: filter, matching: find.byType(Container))
                  .first,
            )
            .decoration,
        isNull,
      );
      expect(
        tester.widget<Text>(find.text('Hidden')).style?.color,
        palette.tonalForeground,
      );
      semantics.dispose();
    });

    testWidgets('the view icons stand on their own, only the chosen one on '
        'a fill, each a 28 pt target with its tooltip', (tester) async {
      bool? asked;
      await pumpControls(tester, onCardsChanged: (cards) => asked = cards);
      final framing = box(tester, 'sidebar-view-switch');
      expect(framing.decoration, isNull);
      expect(framing.padding, isNull);
      final chosen = fill(tester, 'sidebar-view-list')!;
      expect(chosen.color, palette.selectedBackground);
      expect(chosen.boxShadow, isNull);
      expect(fill(tester, 'sidebar-view-cards'), isNull);
      for (final key in ['sidebar-view-list', 'sidebar-view-cards']) {
        expect(tester.getSize(find.byKey(ValueKey(key))), const Size(28, 28));
      }
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('sidebar-view-cards'))).dx -
            tester
                .getTopRight(find.byKey(const ValueKey('sidebar-view-list')))
                .dx,
        2,
      );
      expect(find.byTooltip('List view'), findsOneWidget);
      expect(find.byTooltip('Card view'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sidebar-view-cards')));
      expect(asked, isTrue);

      await pumpControls(tester, cards: true);
      expect(fill(tester, 'sidebar-view-list'), isNull);
      expect(
        fill(tester, 'sidebar-view-cards')!.color,
        palette.selectedBackground,
      );
    });

    testWidgets("an iPad's filter row keeps its frames", (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      await pumpControls(tester);
      final filter = find.byKey(const ValueKey('sidebar-notes-filter'));
      final button = tester.widget<Container>(
        find.descendant(of: filter, matching: find.byType(Container)).first,
      );
      expect(
        (button.decoration! as BoxDecoration).border,
        Border.all(color: palette.controlBorder),
      );
      final framing = box(tester, 'sidebar-view-switch');
      expect(framing.padding, const EdgeInsets.all(1));
      expect(
        (framing.decoration! as BoxDecoration).border,
        Border.all(color: palette.controlBorder),
      );
      expect(fill(tester, 'sidebar-view-list')!.boxShadow, hasLength(1));
    });
  });

  group('markdown tasks, read as the header and Tasks read them', () {
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    Future<void> pumpRow(
      WidgetTester tester,
      Note note, {
      bool touch = false,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: TagMarks(
            marksOf: (_) => const [],
            child: Center(
              child: SizedBox(
                width: 360,
                child: NoteListRowFace(
                  note: note,
                  glance: NoteGlance.of(note, null),
                  date: '11:15',
                  selected: false,
                  hovering: false,
                  touch: touch,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    test('every task line counts, ☐ and ☑ with markdown boxes, and a bare '
        'box counts as none', () {
      final glance = NoteGlance.of(
        note(
          'Launch\n☐ Write notes\n- [x] Ship it\n* [ ] Tell Nadia\n'
          '+ [X] Tag it\n☑ Book the room\n- [ ]\n☐ ',
        ),
        null,
      );
      expect((glance.done, glance.boxes), (3, 5));
      expect(glance.line, 'Write notes');
    });

    for (final (box, done) in [
      ('- [ ]', false),
      ('- [x]', true),
      ('* [ ]', false),
      ('+ [X]', true),
    ]) {
      test('a preview drops the "$box" box', () {
        final glance = NoteGlance.of(
          note('Renewal notes\n$box Send the renewal scope'),
          null,
        );
        expect(glance.line, 'Send the renewal scope');
        expect((glance.done, glance.boxes), (done ? 1 : 0, 1));
      });
    }

    testWidgets('a card with markdown tasks carries the ring', (tester) async {
      await pumpCard(
        tester,
        note(
          'Renewal notes\nFor the call with Acme on Friday.\n'
          '- [ ] Send the renewal scope\n- [ ] Read the signed contract',
        ),
      );
      final pie = tester.widget<ChecklistPie>(find.byType(ChecklistPie));
      expect((pie.done, pie.total), (0, 2));
      expect(find.text('For the call with Acme on Friday.'), findsOneWidget);
    });

    testWidgets('a desktop row says "0 of 2 done" of markdown tasks', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      await pumpRow(
        tester,
        note('Renewal notes\n- [ ] Send the renewal scope\n- [ ] Read it'),
      );
      expect(find.text('0 of 2 done · Send the renewal scope'), findsOneWidget);
    });

    testWidgets("a phone row shows markdown tasks as it shows ☐ ones", (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      Future<(int, int, String)> holds(String body) async {
        await pumpRow(tester, note(body), touch: true);
        final hold = find.byKey(const ValueKey('note-row-holds'));
        final pie = tester.widget<ChecklistPie>(
          find.descendant(of: hold, matching: find.byType(ChecklistPie)),
        );
        expect(
          find.descendant(of: hold, matching: find.text('1 of 2')),
          findsOneWidget,
        );
        return (
          pie.done,
          pie.total,
          [
            for (final text in tester.widgetList<RichText>(
              find.byType(RichText),
            ))
              text.text.toPlainText(),
          ].join(' | '),
        );
      }

      expect(
        await holds('Renewal notes\n- [ ] Send the scope\n- [x] Read it'),
        await holds('Renewal notes\n☐ Send the scope\n☑ Read it'),
      );
      expect(
        await holds('Renewal notes\n- [ ] Send the scope\n- [x] Read it'),
        (1, 2, 'Renewal notes | 11:15 | Send the scope | 1 of 2'),
      );
    });
  });
}
