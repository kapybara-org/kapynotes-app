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

  /// Pumps the strip in [room] at most, with its month over its week, keeping
  /// When as the strip sets it, and hands back every When it set.
  Future<List<WhenFilter>> pumpStrip(
    WidgetTester tester, {
    DateTime? today,
    List<Note> notes = const [],
    WhenFilter when = NotesWhen.anyTime,
    bool compact = false,
    double room = double.infinity,
    void Function(String noteId, {required bool behind})? onOpenNote,
  }) async {
    final set = <WhenFilter>[];
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
                  place: (month, week) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [month, ?week],
                  ),
                  today: today ?? thursday,
                  when: current,
                  onWhenChanged: (when) => setState(() {
                    set.add(when);
                    current = when;
                  }),
                  notes: notes,
                  displayTime: (at) => at,
                  firstWeekday: DateTime.monday,
                  onOpenNote: onOpenNote,
                  compact: compact,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return set;
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
  VoidCallback? onPressed(WidgetTester tester, String key) => tester
      .widget<IconButton>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(IconButton),
        ),
      )
      .onPressed;
  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('shows three days before today, today and tomorrow, with a dot '
      'for each note up to three', (tester) async {
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

    for (final date in [16, 17, 18, 19, 20]) {
      expect(day(date), findsOneWidget, reason: '$date November');
    }
    expect(day(15), findsNothing);
    // The month in full, as the header names it.
    expect(find.text('November'), findsOneWidget);
    // Today goes by its weekday, never "Today".
    expect(find.text('Thu'), findsOneWidget);
    expect(find.text('Today'), findsNothing);
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
    // Tomorrow is greyed out, with nothing to press.
    expect(
      find.descendant(of: day(20), matching: find.byType(TextButton)),
      findsNothing,
    );
    expect(onPressed(tester, 'day-strip-forward'), isNull);
    semantics.dispose();
  });

  testWidgets('a click narrows to the day, and a second lets it go', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final set = await pumpStrip(tester);

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

    await tester.tap(day(20), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(set, hasLength(4));
    semantics.dispose();
  });

  testWidgets('‹ pages back five days, and Today pages back to them', (
    tester,
  ) async {
    await pumpStrip(tester);
    final today = find.byKey(const ValueKey('day-strip-today'));
    expect(today, findsNothing);

    await tap(tester, find.byKey(const ValueKey('day-strip-back')));
    for (final date in [11, 12, 13, 14, 15]) {
      expect(day(date), findsOneWidget, reason: '$date November');
    }
    expect(day(16), findsNothing);
    expect(onPressed(tester, 'day-strip-forward'), isNotNull);
    expect(today, findsOneWidget);

    await tap(tester, find.byKey(const ValueKey('day-strip-back')));
    await tap(tester, find.byKey(const ValueKey('day-strip-forward')));
    expect(day(11), findsOneWidget);

    await tap(tester, today);
    expect(day(19), findsOneWidget);
    expect(today, findsNothing);
  });

  testWidgets('five days across two months name both', (tester) async {
    await pumpStrip(tester, today: DateTime(2026, 12, 2));
    expect(find.text('November–December'), findsOneWidget);
    expect(day(29), findsOneWidget);
    expect(day(3, month: 12), findsOneWidget);
  });

  testWidgets('the month picks a day as a click would, and brings it into '
      'view', (tester) async {
    final set = await pumpStrip(
      tester,
      notes: [note('kickoff', 'Kickoff', DateTime(2026, 11, 2, 10))],
    );

    await tap(tester, find.byKey(const ValueKey('day-strip-month')));
    expect(find.text('November 2026'), findsOneWidget);
    // Days still to come take no click, and no later month opens.
    expect(inMonth(19), findsOneWidget);
    expect(inMonth(20), findsNothing);
    expect(find.text('20'), findsNWidgets(2));
    expect(onPressed(tester, 'day-month-forward'), isNull);

    await tap(tester, find.byKey(const ValueKey('day-month-back')));
    expect(find.text('October 2026'), findsOneWidget);
    expect(inMonth(31, month: 10), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('day-month-forward')));

    await tap(tester, inMonth(2));
    expect(find.byKey(const ValueKey('day-month')), findsNothing);
    expect(set.single, WhenDay(DateTime(2026, 11, 2), today: thursday));
    expect(day(2), findsOneWidget);
    expect(day(19), findsNothing);
    expect(find.byKey(const ValueKey('day-strip-today')), findsOneWidget);

    // Picked again, it lets the list go, as a second click does.
    await tap(tester, find.byKey(const ValueKey('day-strip-month')));
    await tap(tester, inMonth(2));
    expect(set.last, NotesWhen.anyTime);
  });

  testWidgets('with no list to narrow, a day lists its notes, and the one '
      'picked opens, behind on ⌘-click', (tester) async {
    final opened = <(String, bool)>[];
    final set = await pumpStrip(
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

  testWidgets('short of room the week gives way and the month stays, and '
      'short of room for the month or its one button, they give way too', (
    tester,
  ) async {
    final month = find.byKey(const ValueKey('day-strip-month'));
    final date = find.byKey(const ValueKey('day-strip-date'));
    final back = find.byKey(const ValueKey('day-strip-back'));
    // A page back, with its Today button, the week is as wide as it gets.
    await pumpStrip(tester);
    await tap(tester, back);
    final week = tester
        .getSize(find.ancestor(of: back, matching: find.byType(Row)).first)
        .width;
    final label = tester.getSize(month).width;
    await pumpStrip(tester, compact: true);
    final button = tester.getSize(date).width;

    for (final (room, compact, shown, weekShown) in [
      (week + 0.5, false, month, true),
      (week - 0.5, false, month, false),
      (label + 0.5, false, month, false),
      (label - 0.5, false, null, false),
      (button + 0.5, true, date, false),
      (button - 0.5, true, null, false),
    ]) {
      await pumpStrip(tester, room: room, compact: compact);
      final reason = 'in $room, compact $compact';
      expect(tester.takeException(), isNull, reason: reason);
      for (final form in [month, date]) {
        expect(
          form,
          form == shown ? findsOneWidget : findsNothing,
          reason: reason,
        );
      }
      expect(back, weekShown ? findsOneWidget : findsNothing, reason: reason);
    }
    expect(find.byType(TextButton), findsNothing);
  });
}
