import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/ui/day_strip.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  // A Thursday.
  final thursday = DateTime(2026, 11, 19);

  Note note(String id, String body, DateTime edited, {DateTime? written}) =>
      Note(id: id, body: body, createdAt: written ?? edited, updatedAt: edited);

  /// Pumps the strip in [room] at most, with its month over its week, keeping
  /// the day it picks filled, and hands back every day it picked with the
  /// ids of the notes on it.
  Future<List<(DateTime, List<String>)>> pumpStrip(
    WidgetTester tester, {
    DateTime? today,
    List<Note> notes = const [],
    DateTime? picked,
    bool compact = false,
    double room = 1200,
    DateTime? Function(Note note)? ownDay,
    bool phone = false,
    bool opensTabs = false,
  }) async {
    final picks = <(DateTime, List<String>)>[];
    var current = picked;
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
                  place: (month, week) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [month, ?week],
                  ),
                  today: today ?? thursday,
                  picked: current,
                  onPick: (day, notes) => setState(() {
                    picks.add((day, [for (final note in notes) note.id]));
                    current = day;
                  }),
                  notes: notes,
                  displayTime: (at) => at,
                  firstWeekday: DateTime.monday,
                  ownDay: ownDay,
                  compact: compact,
                  phone: phone,
                  opensTabs: opensTabs,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // The month names the days that fit, a frame after they are laid out.
    await tester.pump();
    return picks;
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

  testWidgets('a click picks the day, with its notes the earliest written '
      'first, and fills it', (tester) async {
    final semantics = tester.ensureSemantics();
    final picks = await pumpStrip(
      tester,
      notes: [
        note('standup', 'Standup', DateTime(2026, 11, 17, 10)),
        note('agenda', 'Agenda', DateTime(2026, 11, 17, 10)),
        note(
          'pricing',
          'Pricing ideas',
          DateTime(2026, 11, 17, 16),
          written: DateTime(2026, 11, 17, 8),
        ),
        note('renewal', 'Renewal notes', DateTime(2026, 11, 16, 9)),
      ],
      ownDay: (note) => note.id == 'renewal' ? DateTime(2026, 11, 21) : null,
    );

    await tap(tester, day(17));
    expect(picks.single.$1, DateTime(2026, 11, 17));
    expect(picks.single.$2, ['pricing', 'agenda', 'standup']);
    expect(tester.getSemantics(day(17)), isSemantics(isSelected: true));

    await tap(tester, day(21));
    expect(picks.last.$1, DateTime(2026, 11, 21));
    expect(picks.last.$2, ['renewal']);
    expect(tester.getSemantics(day(17)), isSemantics(isSelected: false));
    expect(tester.getSemantics(day(21)), isSemantics(isSelected: true));

    // A day with nothing on it is picked with no notes, for a page to
    // write it.
    await tap(tester, day(20));
    expect(picks.last.$1, DateTime(2026, 11, 20));
    expect(picks.last.$2, isEmpty);
    semantics.dispose();
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
    final picks = await pumpStrip(
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
    expect(picks.single.$1, DateTime(2026, 11, 2));
    expect(picks.single.$2, ['kickoff']);
    expect(day(2), findsOneWidget);
    expect(day(19), findsNothing);
  });

  testWidgets('a day says it opens its notes as tabs, and once picked that '
      'it brings the tabs back', (tester) async {
    final semantics = tester.ensureSemantics();
    final picks = await pumpStrip(
      tester,
      opensTabs: true,
      notes: [
        note('standup', 'Standup notes', DateTime(2026, 11, 18, 10, 5)),
        note('ideas', 'Book ideas', DateTime(2026, 11, 18, 22, 10)),
        note('pricing', 'Pricing ideas', DateTime(2026, 11, 17, 16, 20)),
      ],
    );
    expect(
      tester.getSemantics(day(18)),
      isSemantics(hint: 'Opens its notes as tabs'),
    );
    expect(tester.getSemantics(day(17)), isSemantics(hint: 'Opens its note'));
    expect(
      tester.getSemantics(day(16)),
      isSemantics(hint: 'Opens a page to write on it'),
    );
    expect(find.byTooltip('Back to your tabs'), findsNothing);

    // A click picks the day with all its notes, and lists none of them.
    await tap(tester, day(18));
    expect(picks.single.$1, DateTime(2026, 11, 18));
    expect(picks.single.$2, ['standup', 'ideas']);
    expect(find.text('Wednesday, 18 November'), findsNothing);
    expect(
      tester.getSemantics(day(18)),
      isSemantics(isSelected: true, hint: 'Back to your tabs'),
    );
    expect(
      find.descendant(
        of: day(18),
        matching: find.byTooltip('Back to your tabs'),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('narrow, it is one button for the day that opens the month', (
    tester,
  ) async {
    await pumpStrip(tester, compact: true);
    expect(find.text('Today'), findsOneWidget);
    expect(day(19), findsNothing);

    // A day picked goes by its date, so the name stays true past midnight.
    for (final (date, label) in [
      (18, 'Wed 18'),
      (17, 'Tue 17'),
      (12, 'Thu 12 Nov'),
    ]) {
      await pumpStrip(tester, compact: true, picked: DateTime(2026, 11, date));
      expect(find.text(label), findsOneWidget);
    }
    await tap(tester, find.byKey(const ValueKey('day-strip-date')));
    expect(find.text('November 2026'), findsOneWidget);
  });

  testWidgets('a narrow page shows fewer days, always around today, and the '
      'month stays when the week gives way', (tester) async {
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

    await pumpStrip(tester, room: 500);
    expect(day(19), findsOneWidget, reason: 'today never leaves the middle');
    expect(chips(), 5);

    await pumpStrip(tester, room: 300);
    expect(day(19), findsOneWidget);
    expect(chips(), 3);

    await pumpStrip(tester, room: 110);
    expect(tester.takeException(), isNull);
    expect(chips(), 0, reason: 'no room for a week');
    expect(month, findsOneWidget, reason: 'the month still picks a day');

    await pumpStrip(tester, room: 110, compact: true);
    expect(month, findsNothing);
    expect(date, findsOneWidget, reason: 'one button for the day instead');
  });

  testWidgets('at every width it fits, with › or a button that picks a day', (
    tester,
  ) async {
    final forward = find.byKey(const ValueKey('day-strip-forward'));
    final month = find.byKey(const ValueKey('day-strip-month'));
    final date = find.byKey(const ValueKey('day-strip-date'));
    // Seven days from Sun 29 November say "November–December", and fewer
    // around Wed 2 December only "December".
    for (var room = 200.0; room <= 760; room += 12) {
      for (final compact in [false, true]) {
        await pumpStrip(
          tester,
          today: DateTime(2026, 12, 2),
          room: room,
          compact: compact,
        );
        expect(tester.takeException(), isNull, reason: 'at $room');
        expect(
          (compact ? date : month),
          findsOneWidget,
          reason: 'a day can be picked at $room',
        );
        if (!compact && room >= 120) {
          expect(forward, findsOneWidget, reason: 'the next week at $room');
        }
      }
    }
  });
}
