import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/writing_streak.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/streak_badge.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

final _at = DateTime(2026, 9, 11, 9, 30);

List<Note> notesTitled(List<String> titles) => [
  for (final (index, title) in titles.indexed)
    Note(
      id: 'note-$index',
      body: '$title\nMore below',
      createdAt: _at,
      updatedAt: _at.subtract(Duration(hours: index * 5)),
    ),
];

Sidebar sidebar(
  List<Note> notes, {
  WritingStreak? streak,
  String query = '',
  bool archiveMode = false,
  Set<String> pinned = const {},
}) => Sidebar(
  notes: notes,
  pinnedNoteIds: pinned,
  selectedId: null,
  query: query,
  displayTime: (t) => t,
  onQueryChanged: (_) {},
  onSelect: (_) {},
  onCreate: () {},
  archiveMode: archiveMode,
  streak: streak,
  showHeader: false,
);

Widget harness(
  List<Widget> sidebars, {
  bool light = false,
  double width = 260,
  double height = 220,
  bool reduceMotion = false,
}) => MaterialApp(
  theme: light ? KapyTheme.light() : KapyTheme.dark(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: Material(
        child: RepaintBoundary(
          key: const ValueKey('streak-golden'),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final sidebar in sidebars)
                SizedBox(width: width, height: height, child: sidebar),
            ],
          ),
        ),
      ),
    ),
  ),
);

const _lit = WritingStreak(days: 12, wroteToday: true);
const _waiting = WritingStreak(days: 12, wroteToday: false);

/// How far the flame is scaled up at this moment: 1 at rest.
double flameScale(WidgetTester tester) => tester
    .widget<Transform>(
      find.descendant(
        of: find.byType(StreakBadge),
        matching: find.byType(Transform),
      ),
    )
    .transform
    .getMaxScaleOnAxis();

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  final three = notesTitled(['Groceries', 'Standup notes', 'Trip budget']);

  testWidgets('the heading over your notes counts them and shows the streak', (
    tester,
  ) async {
    await tester.pumpWidget(harness([sidebar(three, streak: _lit)]));

    expect(find.text('Notes'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-note-count')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-streak')),
        matching: find.text('12'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('3 notes'), findsOneWidget);
    expect(find.byTooltip('12-day writing streak'), findsOneWidget);
    // The heading leads the list.
    expect(
      tester.getTopLeft(find.text('Notes')).dy,
      lessThan(tester.getTopLeft(find.text('Groceries')).dy),
    );
  });

  testWidgets('a run waiting on today asks for today', (tester) async {
    await tester.pumpWidget(harness([sidebar(three, streak: _waiting)]));

    expect(
      find.byTooltip('Write today to keep your 12-day streak'),
      findsOneWidget,
    );
  });

  testWidgets('says what the numbers are to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(harness([sidebar(three, streak: _lit)]));

    // "Notes, 3 notes" rather than "Notes, 3": the figure itself is left out.
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sidebar-note-count'))),
      isSemantics(label: 'Notes', tooltip: '3 notes'),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sidebar-streak'))),
      isSemantics(tooltip: '12-day writing streak'),
    );
    semantics.dispose();
  });

  testWidgets('with no run to show there is no flame, only the count', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness([
        sidebar(three, streak: const WritingStreak(days: 0, wroteToday: false)),
      ]),
    );

    expect(find.byType(StreakBadge), findsNothing);
    expect(find.byTooltip('3 notes'), findsOneWidget);
  });

  testWidgets('one note is one note', (tester) async {
    await tester.pumpWidget(
      harness([
        sidebar(notesTitled(['Only']), streak: _lit),
      ]),
    );
    expect(find.byTooltip('1 note'), findsOneWidget);
  });

  testWidgets('a search result is not the library: no count, no streak', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness([sidebar(three, streak: _lit, query: 'trip')]),
    );

    expect(find.text('Notes'), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-note-count')), findsNothing);
    expect(find.byType(StreakBadge), findsNothing);
  });

  testWidgets('the archive has neither', (tester) async {
    await tester.pumpWidget(
      harness([sidebar(three, streak: _lit, archiveMode: true)]),
    );

    expect(find.byKey(const ValueKey('sidebar-note-count')), findsNothing);
    expect(find.byType(StreakBadge), findsNothing);
  });

  testWidgets('pinned notes are still yours, and counted', (tester) async {
    await tester.pumpWidget(
      harness([
        sidebar(three, streak: _lit, pinned: {three.last.id}),
      ]),
    );

    expect(find.text('Pinned'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-note-count')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('with every note pinned the heading stays, with nothing under '
      'it', (tester) async {
    await tester.pumpWidget(
      harness([
        sidebar(
          three,
          streak: _lit,
          pinned: {for (final note in three) note.id},
        ),
      ], height: 400),
    );

    expect(find.byTooltip('3 notes'), findsOneWidget);
    expect(find.byType(StreakBadge), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Notes')).dy,
      greaterThan(tester.getTopLeft(find.text('Trip budget')).dy),
    );
  });

  testWidgets('the flame flares when the first thing of the day is written', (
    tester,
  ) async {
    await tester.pumpWidget(harness([sidebar(three, streak: _waiting)]));
    expect(flameScale(tester), 1);

    await tester.pumpWidget(
      harness([
        sidebar(three, streak: const WritingStreak(days: 13, wroteToday: true)),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(flameScale(tester), greaterThan(1.2));

    await tester.pumpAndSettle();
    expect(flameScale(tester), 1);
  });

  testWidgets('and simply lights when less motion is asked for', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness([sidebar(three, streak: _waiting)], reduceMotion: true),
    );
    await tester.pumpWidget(
      harness([
        sidebar(three, streak: const WritingStreak(days: 13, wroteToday: true)),
      ], reduceMotion: true),
    );
    await tester.pump();

    expect(flameScale(tester), 1);
    // Already the lit red, one frame in.
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byType(StreakBadge),
              matching: find.text('13'),
            ),
          )
          .style!
          .color,
      const Color(0xFFFF7A5C),
    );
  });

  testWidgets('at its narrowest the name gives way, not the numbers', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness([
        sidebar(
          three,
          streak: const WritingStreak(days: 365, wroteToday: true),
        ),
      ], width: 150),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('365'), findsOneWidget);
  });

  group('golden', () {
    Future<void> pumpGolden(WidgetTester tester, {required bool light}) async {
      tester.view.physicalSize = const Size(540, 220);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        harness([
          sidebar(three, streak: _lit),
          sidebar(three, streak: _waiting),
        ], light: light),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('dark: lit, and waiting on today', (tester) async {
      await pumpGolden(tester, light: false);
      await expectLater(
        find.byKey(const ValueKey('streak-golden')),
        matchesGoldenFile('goldens/sidebar_streak_dark.png'),
      );
    });

    testWidgets('light: lit, and waiting on today', (tester) async {
      await pumpGolden(tester, light: true);
      await expectLater(
        find.byKey(const ValueKey('streak-golden')),
        matchesGoldenFile('goldens/sidebar_streak_light.png'),
      );
    });

    testWidgets('phone', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.physicalSize = const Size(340, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        harness([sidebar(three, streak: _lit)], width: 340),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('streak-golden')),
        matchesGoldenFile('goldens/sidebar_streak_phone.png'),
      );
    });
  });
}
