import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/ui/day_strip.dart';
import 'package:kapy_notes/ui/notes_grouping.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  // A Thursday.
  final thursday = DateTime(2026, 11, 19);

  Note note(String id, String body, DateTime edited) => Note(
    id: id,
    body: body,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: edited,
  );

  /// Pumps the strip in [room] at most, keeping When as the strip sets it,
  /// and hands back every When it set and every day asked for a page.
  Future<(List<WhenFilter>, List<DateTime>)> pumpStrip(
    WidgetTester tester, {
    DateTime? today,
    List<Note> notes = const [],
    WhenFilter when = NotesWhen.anyTime,
    bool compact = false,
    double room = 1200,
    DateTime? Function(Note note)? ownDay,
    void Function(String noteId, {required bool behind})? onOpenNote,
  }) async {
    final set = <WhenFilter>[];
    final asked = <DateTime>[];
    var current = when;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: room),
              child: StatefulBuilder(
                builder: (context, setState) => DayStrip(
                  today: today ?? thursday,
                  when: current,
                  onWhenChanged: (when) => setState(() {
                    set.add(when);
                    current = when;
                  }),
                  notes: notes,
                  displayTime: (at) => at,
                  firstWeekday: DateTime.monday,
                  ownDay: ownDay,
                  onOpenNote: onOpenNote,
                  onWriteOn: asked.add,
                  compact: compact,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return (set, asked);
  }

  Finder day(int date, {int month = 11}) =>
      find.byKey(ValueKey('day-strip-2026-$month-$date'));
  Finder inMonth(int date, {int month = 11}) =>
      find.byKey(ValueKey('day-month-2026-$month-$date'));
  Finder dotsOf(Finder day) => find.descendant(
    of: day,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).shape == BoxShape.circle,
    ),
  );
  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  test('the week steps down from seven days to five, three and today', () {
    expect(DayStrip.daysIn(540), 7);
    expect(DayStrip.daysIn(539), 5);
    expect(DayStrip.daysIn(400), 5);
    expect(DayStrip.daysIn(399), 3);
    expect(DayStrip.daysIn(260), 3);
    expect(DayStrip.daysIn(259), 1);
    expect(DayStrip.daysIn(120), 1);
    expect(DayStrip.daysIn(119), 0);
    // A finger's arrows take 48 each.
    expect(DayStrip.daysIn(540, arrow: 48), 5);
  });

  testWidgets('seven days with today in the middle, a dot for each note up to '
      'three', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpStrip(
      tester,
      notes: [
        note('standup', 'Standup', DateTime(2026, 11, 17, 10)),
        for (var hour = 9; hour < 14; hour++)
          note('plan $hour', 'Plan', DateTime(2026, 11, 18, hour)),
        note('kickoff', 'Kickoff', DateTime(2026, 11, 2)),
      ],
    );

    for (final date in [16, 17, 18, 19, 20, 21, 22]) {
      expect(day(date), findsOneWidget, reason: '$date November');
    }
    expect(day(15), findsNothing);
    expect(day(23), findsNothing);
    expect(find.text('November'), findsOneWidget);
    expect(find.text('Thu 19'), findsOneWidget);
    expect(dotsOf(day(16)), findsNothing);
    expect(dotsOf(day(17)), findsOneWidget);
    expect(dotsOf(day(18)), findsNWidgets(3));
    expect(
      tester.getSemantics(day(18)),
      isSemantics(
        label: 'Wednesday, 18 November, 5 notes',
        isButton: true,
        isSelected: false,
      ),
    );
    expect(
      tester.getSemantics(day(19)),
      isSemantics(label: 'Today, Thursday, 19 November, No notes'),
    );
    // A day still to come is as writable as any other.
    expect(
      find.descendant(of: day(21), matching: find.byType(TextButton)),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('a note waiting for a later day has its dot there, and none on '
      'the day it was last edited', (tester) async {
    final edited = DateTime(2026, 11, 16, 10);
    await pumpStrip(
      tester,
      notes: [note('renewal', 'Renewal notes', edited)],
      ownDay: (note) => note.id == 'renewal' ? DateTime(2026, 11, 21) : null,
    );
    expect(dotsOf(day(21)), findsOneWidget);
    expect(dotsOf(day(16)), findsNothing);
  });

  testWidgets('a click narrows to the day, and a second lets it go', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final (set, asked) = await pumpStrip(tester);

    await tap(tester, day(17));
    expect(set.single, WhenDay(DateTime(2026, 11, 17), today: thursday));
    expect(set.single.label, 'Tue 17');
    expect(tester.getSemantics(day(17)), isSemantics(isSelected: true));

    await tap(tester, day(17));
    expect(set.last, NotesWhen.anyTime);
    expect(tester.getSemantics(day(17)), isSemantics(isSelected: false));

    // Today is When's own Today.
    await tap(tester, day(19));
    expect(set.last, NotesWhen.today);
    await tap(tester, day(19));
    expect(set.last, NotesWhen.anyTime);
    // None of these days holds a note, so picking each asks for a page, and
    // letting it go asks for none.
    expect(asked, [DateTime(2026, 11, 17), thursday]);
    semantics.dispose();
  });

  testWidgets('a day with no notes opens a page to write it', (tester) async {
    final (set, asked) = await pumpStrip(
      tester,
      notes: [note('standup', 'Standup', DateTime(2026, 11, 17, 10))],
    );
    await tap(tester, day(21));
    expect(asked.single, DateTime(2026, 11, 21));
    expect(set.single, WhenDay(DateTime(2026, 11, 21), today: thursday));

    // A day with notes only narrows.
    await tap(tester, day(17));
    expect(asked, hasLength(1));
    expect(set.last, WhenDay(DateTime(2026, 11, 17), today: thursday));
  });

  testWidgets('‹ and › move a week at a time', (tester) async {
    await pumpStrip(tester);

    await tap(tester, find.byKey(const ValueKey('day-strip-back')));
    for (final date in [9, 10, 11, 12, 13, 14, 15]) {
      expect(day(date), findsOneWidget, reason: '$date November');
    }
    expect(day(16), findsNothing);

    await tap(tester, find.byKey(const ValueKey('day-strip-back')));
    await tap(tester, find.byKey(const ValueKey('day-strip-forward')));
    expect(day(9), findsOneWidget);

    await tap(tester, find.byKey(const ValueKey('day-strip-forward')));
    await tap(tester, find.byKey(const ValueKey('day-strip-forward')));
    for (final date in [23, 24, 25, 26, 27, 28, 29]) {
      expect(day(date), findsOneWidget, reason: '$date November');
    }
    expect(day(22), findsNothing);
  });

  testWidgets('a week across two months names both, in full', (tester) async {
    await pumpStrip(tester, today: DateTime(2026, 12, 2));
    expect(find.text('November–December'), findsOneWidget);
    expect(day(29), findsOneWidget);
    expect(day(3, month: 12), findsOneWidget);
  });

  testWidgets('the month picks a day as a click would, and brings it into '
      'view', (tester) async {
    final (set, asked) = await pumpStrip(
      tester,
      notes: [note('kickoff', 'Kickoff', DateTime(2026, 11, 2, 10))],
    );

    await tap(tester, find.byKey(const ValueKey('day-strip-month')));
    expect(find.text('November 2026'), findsOneWidget);
    // A day still to come can be picked, and so can a later month.
    expect(inMonth(19), findsOneWidget);
    expect(inMonth(28), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.descendant(
              of: find.byKey(const ValueKey('day-month-forward')),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNotNull,
    );

    await tap(tester, find.byKey(const ValueKey('day-month-back')));
    expect(find.text('October 2026'), findsOneWidget);
    expect(inMonth(31, month: 10), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('day-month-forward')));

    await tap(tester, inMonth(2));
    expect(set.single, WhenDay(DateTime(2026, 11, 2), today: thursday));
    expect(day(2), findsOneWidget);
    expect(day(19), findsNothing);
    expect(asked, isEmpty);

    // Picked again, it lets the list go, as a second click does.
    await tap(tester, find.byKey(const ValueKey('day-strip-month')));
    await tap(tester, inMonth(2));
    expect(set.last, NotesWhen.anyTime);
  });

  testWidgets('with no list to narrow, a day lists its notes, and the one '
      'picked opens, behind on ⌘-click', (tester) async {
    final opened = <(String, bool)>[];
    final (set, _) = await pumpStrip(
      tester,
      notes: [
        note('standup', 'Standup notes', DateTime(2026, 11, 18, 10, 5)),
        note('ideas', 'Book ideas', DateTime(2026, 11, 18, 22, 10)),
        note('pricing', 'Pricing ideas', DateTime(2026, 11, 17, 16, 20)),
      ],
      onOpenNote: (id, {required behind}) => opened.add((id, behind)),
    );

    await tap(tester, day(18));
    expect(find.text('Wednesday, 18 November'), findsOneWidget);
    expect(find.text('2 notes'), findsOneWidget);
    expect(find.text('10:05'), findsOneWidget);
    expect(find.text('Pricing ideas'), findsNothing);
    await tap(tester, find.text('Book ideas'));
    expect(opened.single, ('ideas', false));
    expect(set, isEmpty);

    await tap(tester, day(18));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.text('Standup notes'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(opened.last, ('standup', true));

    // A day with nothing in it says so.
    await tap(tester, day(16));
    expect(find.text('No notes'), findsOneWidget);
  });

  testWidgets('narrow, it is one button for the day that opens the month', (
    tester,
  ) async {
    await pumpStrip(tester, compact: true);
    expect(find.text('Today'), findsOneWidget);
    expect(day(19), findsNothing);

    await pumpStrip(
      tester,
      compact: true,
      when: WhenDay(DateTime(2026, 11, 17), today: thursday),
    );
    expect(find.text('Tue 17'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('day-strip-date')));
    expect(find.text('November 2026'), findsOneWidget);
  });

  testWidgets('a narrow page shows fewer days, always around today', (
    tester,
  ) async {
    final month = find.byKey(const ValueKey('day-strip-month'));
    final date = find.byKey(const ValueKey('day-strip-date'));
    int chips() => tester
        .widgetList<Widget>(find.byWidgetPredicate((widget) => true))
        .where(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'day-strip-2026-',
              ),
        )
        .length;

    await pumpStrip(tester);
    expect(chips(), 7);

    await pumpStrip(tester, room: 560);
    expect(day(19), findsOneWidget, reason: 'today never leaves the middle');
    expect(chips(), lessThan(7));

    await pumpStrip(tester, room: 460);
    expect(day(19), findsOneWidget);
    expect(chips(), lessThan(7));

    await pumpStrip(tester, room: 200);
    expect(tester.takeException(), isNull);
    expect(chips(), 0, reason: 'no room for a week');
    expect(month, findsNothing);
    expect(date, findsOneWidget, reason: 'one button for the day instead');
  });
}
