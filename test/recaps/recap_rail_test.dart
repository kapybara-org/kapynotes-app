import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/period_scope.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/ui/recaps/recap_rail.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import '../test_fonts.dart';
import 'recap_maker_fixtures.dart' show GatedEngine;
import 'timeline_app_fixtures.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

/// The rail's list, scrolled down until [target] is on screen.
Future<void> _reach(WidgetTester tester, Finder target) async {
  final list = find
      .ancestor(
        of: find.byType(RecapRailLine).first,
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(target, 120, scrollable: list);
  await tester.pumpAndSettle();
}

/// Makes the window [height] tall, so the whole rail is laid out at once.
Future<void> _tall(WidgetTester tester, double height) async {
  tester.view.physicalSize = Size(tester.view.physicalSize.width, height);
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, String key) => tester.getTopLeft(_key(key)).dy;

void main() {
  setUpAll(loadTestFonts);

  group('the rows', () {
    for (final phone in [true, false]) {
      testWidgets(
        'this week by day, then earlier weeks, months and years folded '
        'under their headings (${phone ? 'phone' : 'desktop'})',
        (tester) async {
          final app = TimelineApp()..sample();
          await app.pump(tester, phone: phone);
          await _tall(tester, 2400);

          final order = [
            'recap-heading-day-2026-11-19',
            'recap-heading-day-2026-11-18',
            'recap-heading-day-2026-11-16',
            'recap-heading-day-2026-11-15',
            'recap-heading-month-2026-11-1',
            'recap-card-week-2026-11-8',
            'recap-card-week-2026-11-1',
            'recap-heading-year-2026-1-1',
            'recap-card-month-2026-10-1',
            'recap-card-month-2026-9-1',
            'recap-heading-years',
            'recap-card-year-2025-1-1',
            'recap-card-year-2024-1-1',
          ];
          final tops = [for (final key in order) _top(tester, key)];
          expect(tops, orderedEquals([...tops]..sort()), reason: '$order');
          expect(_key('recap-heading-day-2026-11-17'), findsNothing);
          expect(find.text('Earlier in November'), findsOneWidget);
          expect(find.text('Earlier in 2026'), findsOneWidget);
          expect(find.text('Earlier years'), findsOneWidget);

          final today = find.descendant(
            of: _key('recap-heading-day-2026-11-19'),
            matching: find.byType(RecapDayTitle),
          );
          expect(tester.widget<RecapDayTitle>(today).label, 'Today');
          expect(find.text('Morning pages'), findsOneWidget);
          expect(find.text('Week note 8'), findsNothing);

          final column = phone ? 24.0 : 20.0;
          final rail = tester.getRect(find.byType(RecapRailLine).first);
          final node = tester.getRect(find.byType(RecapNode).first);
          final title = tester.getTopLeft(find.text('Morning pages'));
          expect(title.dx, greaterThan(node.right));
          expect(
            node.center.dx - rail.left,
            closeTo((phone ? 20 : 16) + column / 2, 1),
          );
        },
      );
    }

    testWidgets('a card opens on a tap to what it holds, and folds again', (
      tester,
    ) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: true);
      final semantics = tester.ensureSemantics();
      final card = _key('recap-card-week-2026-11-8');
      await _reach(tester, card);
      expect(
        tester.getSemantics(card),
        matchesSemantics(
          label: '8–14 November, 14 notes, folded',
          hint: 'Double-tap to open.',
          isButton: true,
          hasTapAction: true,
        ),
      );

      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(card),
        matchesSemantics(
          label: '8–14 November, 14 notes, open',
          hint: 'Double-tap to fold.',
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(_key('recap-heading-day-2026-11-14'), findsOneWidget);
      final under = tester.getTopLeft(_key('recap-heading-day-2026-11-14'));
      expect(under.dy, greaterThan(tester.getBottomLeft(card).dy));

      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(_key('recap-heading-day-2026-11-14'), findsNothing);
      expect(find.text('Week note 14'), findsNothing);
      semantics.dispose();
    });

    testWidgets('the open note is revealed, its cards opened around it', (
      tester,
    ) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: false, opened: 'oct-4');
      final semantics = tester.ensureSemantics();
      final october = _key('recap-card-month-2026-10-1');
      await _reach(tester, october);
      expect(tester.getSemantics(october).label, endsWith(', open'));
      await _reach(tester, find.text('October 4'));
      expect(find.text('October 4'), findsWidgets);
      expect(_key('recap-card-month-2026-9-1'), findsOneWidget);
      expect(
        tester.getSemantics(_key('recap-card-month-2026-9-1')).label,
        endsWith(', folded'),
      );
      semantics.dispose();
    });

    testWidgets('on a phone, the note left is revealed back on Home', (
      tester,
    ) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: true, opened: 'oct-4');
      final semantics = tester.ensureSemantics();
      final october = _key('recap-card-month-2026-10-1');
      await _reach(tester, october);
      expect(tester.getSemantics(october).label, endsWith(', open'));
      semantics.dispose();
    });

    testWidgets('the rail and its nodes say nothing to a screen reader', (
      tester,
    ) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: true);
      for (final node in find.byType(RecapNode).evaluate()) {
        expect(
          find.descendant(
            of: find.byWidget(node.widget),
            matching: find.byType(ExcludeSemantics),
          ),
          findsOneWidget,
        );
      }
      final painted = find.descendant(
        of: find.byType(RecapRailLine).first,
        matching: find.byType(CustomPaint),
      );
      expect(painted, findsWidgets);
    });
  });

  group('the recap icon', () {
    testWidgets('says what it will do in each state', (tester) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: false, made: [TimelineApp.firstWeek]);
      final semantics = tester.ensureSemantics();
      await _tall(tester, 2400);

      String label(String key) => tester.getSemantics(_key(key)).label;
      expect(label('recap-icon-day-2026-11-19'), 'Recap of Thu 19 so far');
      expect(
        find.descendant(
          of: _key('recap-icon-day-2026-11-19'),
          matching: _key('recap-going-pie'),
        ),
        findsOneWidget,
      );
      expect(label('recap-icon-day-2026-11-18'), 'Make a recap of Wed 18');
      expect(
        find.bySemanticsLabel('Too little on Mon 16 for a recap'),
        findsOneWidget,
      );
      expect(label('recap-icon-month-2026-11-1'), 'Recap of November so far');
      expect(
        label('recap-icon-week-2026-11-8'),
        'Make a recap of 8–14 November',
      );
      expect(
        label('recap-icon-week-2026-11-1'),
        'Watch the recap of 1–7 November',
      );
      expect(label('recap-icon-month-2026-10-1'), 'Make a recap of October');
      expect(
        find.bySemanticsLabel('Too little in 2025 for a recap'),
        findsOneWidget,
      );
      expect(
        tester.getSize(_key('recap-icon-day-2026-11-18')),
        const Size(24, 24),
      );
      semantics.dispose();
    });

    for (final phone in [true, false]) {
      testWidgets('a week card and its drawer cover the same days, and a '
          'day\'s drawer offers the rail\'s week '
          '(${phone ? 'phone' : 'desktop'})', (tester) async {
        final app = TimelineApp()..sample();
        await app.pump(tester, phone: phone);
        String weekShown() => tester
            .widget<Text>(
              find.descendant(
                of: _key('recap-period-week'),
                matching: find.byType(Text),
              ),
            )
            .data!;

        await tester.tap(_key('recap-icon-day-2026-11-18'));
        await tester.pumpAndSettle();
        expect(
          weekShown(),
          TimelineApp.week(DateTime(2026, 11, 18)).label,
          reason: 'this week on the rail runs 15–21 Nov',
        );
        await tester.tapAt(Offset.zero);
        await tester.pumpAndSettle();
        if (_key('recap-drawer').evaluate().isNotEmpty) {
          Navigator.of(tester.element(_key('recap-drawer'))).pop();
          await tester.pumpAndSettle();
        }

        final icon = _key('recap-icon-week-2026-11-8');
        await _reach(tester, icon);
        await tester.tap(icon);
        await tester.pumpAndSettle();
        expect(weekShown(), TimelineApp.lastWeek.label);
        expect(
          TimelineApp.makerOf(tester).quote(TimelineApp.lastWeek).plan.period,
          TimelineApp.lastWeek,
        );
      });
    }

    testWidgets('is a 44 pt target on a phone', (tester) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: true);
      expect(
        tester.getSize(_key('recap-icon-day-2026-11-18')),
        const Size(44, 44),
      );
    });

    testWidgets('too little opens the small drawer, where Ask Kapy AI is all '
        'there is', (tester) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: true);
      await tester.tap(_key('recap-icon-day-2026-11-16'));
      await tester.pumpAndSettle();
      expect(_key('recap-drawer'), findsOneWidget);
      expect(find.textContaining('Ask Kapy AI'), findsWidgets);
      expect(find.text('Create recap'), findsNothing);
    });

    testWidgets('fills a pie while a recap is being made, then goes back', (
      tester,
    ) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: false);
      final semantics = tester.ensureSemantics();
      final engine = GatedEngine();
      app.ai.engine = engine;
      final maker = TimelineApp.makerOf(tester);
      final icon = _key('recap-icon-week-2026-11-8');
      await _reach(tester, icon);

      final made = maker.make(maker.quote(TimelineApp.lastWeek));
      await tester.pump();
      final progress = maker.progressOf(TimelineApp.lastWeek)!;
      expect(
        tester.getSemantics(icon).label,
        'Making the recap of 8–14 November, 0 of ${progress.parts} parts done',
      );
      expect(
        find.descendant(of: icon, matching: _key('recap-making-pie')),
        findsOneWidget,
      );

      while (engine.waiting.isNotEmpty) {
        engine.fail(StateError('offline'));
        await tester.pump();
      }
      await made;
      await tester.pumpAndSettle();
      expect(maker.progressOf(TimelineApp.lastWeek), isNull);
      expect(tester.getSemantics(icon).label, 'Make a recap of 8–14 November');
      expect(_key('recap-making-pie'), findsNothing);
      semantics.dispose();
    });

    testWidgets('is not there while Kapy AI is not in the build', (
      tester,
    ) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: true, kapyAi: false);
      expect(_key('recap-heading-day-2026-11-19'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => switch (widget.key) {
            ValueKey<String>(:final value) => value.startsWith('recap-icon-'),
            _ => false,
          },
        ),
        findsNothing,
      );
    });

    testWidgets('is not there while Kapy AI is off', (tester) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: false);
      expect(_key('recap-icon-day-2026-11-18'), findsOneWidget);
      app.ai.enabled = false;
      await tester.pumpAndSettle();
      expect(_key('recap-heading-day-2026-11-18'), findsOneWidget);
      expect(_key('recap-icon-day-2026-11-18'), findsNothing);
    });
  });

  group('the drawer from the icon', () {
    testWidgets('opens as a sheet on a phone, and Ask goes to Kapy AI', (
      tester,
    ) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: true);
      app.ai.periods = (period) => KapyPeriodRead.gather(
        period,
        store: app.notes,
        tasks: TaskBoard.read(
          entries: const [],
          notes: app.notes.notes,
          docOf: (_) => null,
        ),
        tags: TagStore(app.store),
        folders: FolderStore(app.store).tree,
        displayTime: (instant) => instant.toLocal(),
      );
      await tester.tap(_key('recap-icon-day-2026-11-18'));
      await tester.pumpAndSettle();
      expect(_key('recap-drawer'), findsOneWidget);
      expect(
        find.ancestor(
          of: _key('recap-drawer'),
          matching: find.byType(BottomSheet),
        ),
        findsOneWidget,
      );
      expect(find.text('Wed 18 recap'), findsWidgets);

      await tester.tap(_key('recap-ask'));
      await tester.pumpAndSettle();
      expect(_key('recap-drawer'), findsNothing);
      expect(app.ai.calls, contains('newChat'));
      expect(
        TimelineApp.makerOf(tester).hasRecap(
          RecapPeriod.containing(
            DateTime(2026, 11, 18),
            RecapKind.day,
            firstWeekday: DateTime.sunday,
          ),
        ),
        isFalse,
      );
    });

    testWidgets('opens as a popover beside the icon on a desktop', (
      tester,
    ) async {
      final app = TimelineApp()..sample();
      await app.pump(tester, phone: false);
      final icon = tester.getRect(_key('recap-icon-day-2026-11-18'));
      await tester.tap(_key('recap-icon-day-2026-11-18'));
      await tester.pumpAndSettle();
      expect(_key('recap-drawer'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      final drawer = tester.getRect(_key('recap-drawer'));
      final list = tester.getRect(find.byType(Sidebar));
      expect(drawer.left, greaterThanOrEqualTo(icon.right));
      expect(
        drawer.left,
        closeTo(list.right + 8, 1),
        reason: 'beside the list pane, not across its edge',
      );
      expect(drawer.top, icon.top - 24);
      expect(drawer.width, closeTo(372, 1));

      await tester.tap(_key('recap-drawer-close'));
      await tester.pumpAndSettle();
      expect(_key('recap-drawer'), findsNothing);
    });
  });
}
