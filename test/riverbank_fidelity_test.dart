import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/checklist_pie.dart';
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

    // The cards lean, so this measures inside the card rather than on screen.
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
    expect(heading.height, 18, reason: 'one line');
    expect(pie.top - heading.bottom, greaterThanOrEqualTo(6));
  });

  testWidgets('an amount on a card is set in Geist Mono', (tester) async {
    await pumpWindow(tester, ['land\n₹75,60,000']);

    final amount = tester.widget<Text>(onCard('land', find.text('₹75,60,000')));
    expect(amount.style?.fontFamily, AppFonts.mono);
  });

  testWidgets('See all sits at the end of the Pinned heading', (tester) async {
    await pumpWindow(tester, [for (var i = 0; i < 5; i++) 'Pinned $i']);
    for (final note in goldenNotes.notes) {
      goldenNotes.togglePinned(note.id);
    }
    await tester.pumpAndSettle();

    expect(
      tester
          .getRect(find.byKey(const ValueKey('sidebar-see-all-pinned')))
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
}
