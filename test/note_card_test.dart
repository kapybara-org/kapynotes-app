import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
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
    double width = 300,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
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
                hovering: false,
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

  testWidgets('a card at rest is the quiet 4% fill with no outline, its '
      'title in Figtree 13/18 at 500', (tester) async {
    await pumpCard(tester, note('Reading list\nDeep Work, Dune'));

    expect(card(tester).color, palette.fillRest);
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

    expect(card(tester).color, palette.fillRest);
    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('Money'), findsNothing);
    expect(styleOf(tester, 'Travel').color, palette.textTertiary);
    expect(tester.getSize(find.byType(TagDots)).width, TagDots.widthFor(2));
  });

  testWidgets('the selected card is the 10% fill, with no tilt and no '
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
    expect(card(tester).color, palette.fillSelectedCard);
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
            child: NotesGroupHeading(label: 'Upcoming', detail: '2'),
          ),
        ),
      ),
    );

    final label = styleOf(tester, 'Upcoming');
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
}
