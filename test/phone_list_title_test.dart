import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/writing_streak.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';

void main() {
  const width = 393.0;
  CalcPalette palette() => KapyTheme.dark().extension<CalcPalette>()!;
  final streakMark = find.byKey(const ValueKey('phone-streak'));

  Future<void> pumpTitle(
    WidgetTester tester, {
    String title = 'Notes',
    WritingStreak? streak,
  }) async {
    tester.view.physicalSize = const Size(width, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PhoneListTitle(title: title, count: 37, streak: streak),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Home shows the streak as a clay flame and "1 day" at the end '
      'of the title row, 12 pt clear of the title', (tester) async {
    await pumpTitle(
      tester,
      streak: const WritingStreak(days: 1, wroteToday: true),
    );

    expect(streakMark, findsOneWidget);
    final icon = find.descendant(
      of: streakMark,
      matching: findKapyIcon(KapyIcons.fireOutlined),
    );
    expect(tester.widget<KapyIcon>(icon).color, palette().clay);
    expect(tester.widget<KapyIcon>(icon).size, 16);
    final label = find.descendant(of: streakMark, matching: find.text('1 day'));
    expect(label, findsOneWidget);
    expect(tester.getTopLeft(label).dx - tester.getTopRight(icon).dx, 4);
    expect(find.byTooltip('1-day writing streak'), findsOneWidget);

    // No avatar yet, as when signed out: the streak ends at the row's 20 pt
    // inset, where the avatar's 12 pt gap will start.
    expect(tester.getTopRight(streakMark).dx, width - 20);
    final titleBox = find.ancestor(
      of: find.byKey(const ValueKey('phone-list-title')),
      matching: find.byType(Expanded),
    );
    expect(
      tester.getTopLeft(streakMark).dx - tester.getTopRight(titleBox).dx,
      12,
    );
    expect(tester.getCenter(streakMark).dy, tester.getCenter(titleBox).dy);
  });

  testWidgets('a run of days reads in the plural', (tester) async {
    await pumpTitle(
      tester,
      streak: const WritingStreak(days: 3, wroteToday: true),
    );
    expect(
      find.descendant(of: streakMark, matching: find.text('3 days')),
      findsOneWidget,
    );
  });

  testWidgets('a run waiting on today stays grey and says how to keep it', (
    tester,
  ) async {
    await pumpTitle(
      tester,
      streak: const WritingStreak(days: 3, wroteToday: false),
    );
    final icon = find.descendant(
      of: streakMark,
      matching: findKapyIcon(KapyIcons.fireOutlined),
    );
    expect(tester.widget<KapyIcon>(icon).color, palette().textTertiary);
    expect(
      find.byTooltip('Write today to keep your 3-day streak'),
      findsOneWidget,
    );
  });

  for (final streak in [
    null,
    const WritingStreak(days: 0, wroteToday: false),
  ]) {
    testWidgets('no streak shows nothing, and the title keeps the row '
        '($streak)', (tester) async {
      await pumpTitle(tester, streak: streak);
      expect(streakMark, findsNothing);
      expect(findKapyIcon(KapyIcons.fireOutlined), findsNothing);
      expect(find.byType(Expanded), findsNothing);
    });
  }

  testWidgets('a long title gives way before the streak does', (tester) async {
    await pumpTitle(
      tester,
      title: 'A very long space name that runs past the streak',
      streak: const WritingStreak(days: 12, wroteToday: true),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getTopRight(streakMark).dx, width - 20);
    final title = find.byKey(const ValueKey('phone-list-title'));
    expect(
      tester.getTopLeft(streakMark).dx - tester.getTopRight(title).dx,
      greaterThanOrEqualTo(12),
    );
  });
}
