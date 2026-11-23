import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/checklist_pie.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:material_ui/material_ui.dart';

import 'golden_test.dart' show goldenNotes, pumpForGolden, tapSettings;
import 'test_fonts.dart';

/// Where the running app drifted from the final Paper design (5TS-0, 6EV-0).
void main() {
  setUpAll(loadTestFonts);

  Future<void> pumpWindow(WidgetTester tester, List<String> bodies) async {
    await pumpForGolden(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.dark,
      withNote: false,
    );
    for (final body in bodies) {
      goldenNotes.create(body: body);
    }
    await tester.pumpAndSettle();
  }

  Finder onCard(String title, Finder finder) => find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is NoteCardFace && widget.note.title == title,
    ),
    matching: finder,
  );

  testWidgets('a long title over a checklist keeps clear of its progress', (
    tester,
  ) async {
    const title = 'SnowSEO Issues backlog for the launch';
    await pumpWindow(tester, ['$title\n☑ crawl\n☐ fix titles']);

    // The open card leans, so this measures inside the card, not on screen.
    final card = tester.renderObject<RenderBox>(
      find.byWidgetPredicate(
        (widget) => widget is NoteCardFace && widget.note.title == title,
      ),
    );
    Rect inCard(Finder finder) {
      final box = tester.renderObject<RenderBox>(finder);
      return box.localToGlobal(Offset.zero, ancestor: card) & box.size;
    }

    final heading = inCard(onCard(title, find.text(title)));
    final pie = inCard(onCard(title, find.byType(ChecklistPie)));
    // Every card keeps three fixed lines, so the title takes one.
    expect(heading.height, 18);
    expect(pie.top - heading.bottom, greaterThanOrEqualTo(6));
  });

  testWidgets('an amount on a card is a result: Figtree 12/16 at 600 in the '
      'result green, with tabular figures', (tester) async {
    await pumpWindow(tester, ['land\n₹75,60,000']);

    final style = tester
        .widget<Text>(onCard('land', find.text('₹75,60,000')))
        .style!;
    expect(style.fontFamily, AppFonts.ui);
    expect(style.fontSize, 12);
    expect(style.height, 16 / 12);
    expect(style.fontVariations, AppWeight.variations(AppWeight.page));
    expect(style.color, KapyTheme.darkPalette.resultPillText);
    expect(style.fontFeatures, const [FontFeature.tabularFigures()]);
  });

  testWidgets('View all sits at the end of the Pinned heading', (tester) async {
    await pumpWindow(tester, [for (var i = 0; i < 5; i++) 'Pinned $i']);
    for (final note in goldenNotes.notes) {
      goldenNotes.togglePinned(note.id);
    }
    await tester.pumpAndSettle();

    expect(
      tester
          .getRect(find.byKey(const ValueKey('sidebar-view-all-pinned')))
          .right,
      tester
          .getRect(find.byKey(const ValueKey('sidebar-pinned-heading')))
          .right,
    );
  });

  testWidgets('the settings search keeps a neutral border in focus', (
    tester,
  ) async {
    await pumpWindow(tester, ['Groceries']);
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await tester.pumpAndSettle();

    final decoration = tester
        .widget<TextField>(find.byKey(const ValueKey('settings-search')))
        .decoration!;
    expect(
      decoration.focusedBorder!.borderSide.color,
      KapyTheme.darkPalette.controlBorder,
    );
  });

  testWidgets('the settings search names its "/" key, and the text size '
      'steps with icons', (tester) async {
    await pumpWindow(tester, ['Groceries']);
    await tapSettings(tester);
    await tester.pumpAndSettle();

    final slash = find.descendant(
      of: find.byKey(const ValueKey('settings-search')),
      matching: find.widgetWithText(Keycap, '/'),
    );
    expect(slash, findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'x');
    await tester.pumpAndSettle();
    expect(slash, findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-search-clear')));
    await tester.pumpAndSettle();

    for (final key in const ['stepper-down', 'stepper-up']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(KapyIcon),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('a drawing reads "Edited today", and its tool dock sits as '
      'Paper sets it', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.dark,
      withNote: false,
      withDrawings: true,
    );
    await tester.tap(find.byKey(const ValueKey('rail-drawings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Garden plan').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('Edited today, 15:38 · '), findsOneWidget);
    // One bar: tools, a rule, then the colour, with only the dock's 2 px gap
    // either side of the rule.
    final eraser = tester.getRect(
      find.byKey(const ValueKey('draw-tool-eraser')),
    );
    final colour = tester.getRect(find.byKey(const ValueKey('draw-style')));
    expect(colour.left - eraser.right, closeTo(5, 0.5));
  });
}
