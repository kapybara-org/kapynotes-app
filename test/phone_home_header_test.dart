import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/writing_streak.dart';
import 'package:kapy_notes/sync/auth_api.dart';
import 'package:kapy_notes/ui/editor/note_header.dart';
import 'package:kapy_notes/ui/phone_home_header.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  const user = AccountUser(
    id: 'user-1',
    email: 'sanjay@example.com',
    emailVerified: true,
    name: 'Sanjay',
  );
  final notesTitle = find.byKey(const ValueKey('home-title-notes'));
  final tasksTitle = find.byKey(const ValueKey('home-title-tasks'));
  final streakMark = find.byKey(const ValueKey('phone-streak'));
  final avatar = find.byKey(const ValueKey('phone-account'));
  final circle = find.descendant(
    of: avatar,
    matching: find.byKey(const ValueKey('account-circle')),
  );
  CalcPalette palette() => KapyTheme.dark().extension<CalcPalette>()!;

  Future<List<String>> pumpHeader(
    WidgetTester tester, {
    bool tasks = false,
    int notesCount = 37,
    int tasksCount = 6,
    bool withTasks = true,
    WritingStreak? streak = const WritingStreak(days: 1, wroteToday: true),
    AccountUser? signedIn = user,
    double width = 393,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final taps = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PhoneHomeHeader(
              tasks: tasks,
              notesCount: notesCount,
              tasksCount: tasksCount,
              onNotes: () => taps.add('notes'),
              onTasks: withTasks ? () => taps.add('tasks') : null,
              streak: streak,
              user: signedIn,
              onSettings: () => taps.add('settings'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return taps;
  }

  Color? ink(WidgetTester tester, Finder title, String label) => tester
      .widget<Text>(find.descendant(of: title, matching: find.text(label)))
      .style
      ?.color;

  for (final notesCount in [1, 37, 999]) {
    testWidgets('Notes $notesCount starts at the 20 pt inset and Tasks sits '
        '12 pt after its count, as M01 draws it', (tester) async {
      await pumpHeader(tester, notesCount: notesCount, width: 375);

      final notes = tester.getRect(notesTitle);
      final count = tester.getRect(
        find.descendant(of: notesTitle, matching: find.text('$notesCount')),
      );
      expect(notes.left, 20);
      expect(count.right, notes.right);
      expect(tester.getRect(tasksTitle).left - count.right, 12);
      expect(tester.getSize(find.byType(PhoneHomeHeader)).height, 48);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the title on screen is in ink with its count and the clay '
      'underline; the other waits in grey', (tester) async {
    await pumpHeader(tester);

    expect(ink(tester, notesTitle, 'Notes'), palette().textPrimary);
    expect(
      find.descendant(of: notesTitle, matching: find.text('37')),
      findsOne,
    );
    expect(
      find.descendant(
        of: notesTitle,
        matching: find.byType(NoteTitleUnderline),
      ),
      findsOneWidget,
    );
    expect(ink(tester, tasksTitle, 'Tasks'), palette().textTertiary);
    expect(
      find.descendant(
        of: tasksTitle,
        matching: find.byType(NoteTitleUnderline),
      ),
      findsNothing,
    );

    final tasksLeft = tester.getRect(tasksTitle).left;
    await pumpHeader(tester, tasks: true);
    expect(ink(tester, tasksTitle, 'Tasks'), palette().textPrimary);
    expect(find.descendant(of: tasksTitle, matching: find.text('6')), findsOne);
    expect(
      find.descendant(
        of: tasksTitle,
        matching: find.byType(NoteTitleUnderline),
      ),
      findsOneWidget,
    );
    expect(ink(tester, notesTitle, 'Notes'), palette().textTertiary);
    expect(
      find.descendant(of: notesTitle, matching: find.text('6')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: notesTitle,
        matching: find.byType(NoteTitleUnderline),
      ),
      findsNothing,
    );
    expect(
      tester
          .widget<Visibility>(
            find.ancestor(
              of: find.descendant(of: notesTitle, matching: find.text('37')),
              matching: find.byType(Visibility),
            ),
          )
          .visible,
      isFalse,
      reason: "Notes keeps its count's room unseen",
    );
    expect(
      tester.getRect(tasksTitle).left,
      tasksLeft,
      reason: 'Tasks stays put',
    );
  });

  testWidgets('each title is at least 44 pt tall to tap', (tester) async {
    await pumpHeader(tester);
    expect(tester.getSize(notesTitle).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(tasksTitle).height, greaterThanOrEqualTo(44));
  });

  testWidgets('a tap on either title asks for it', (tester) async {
    final taps = await pumpHeader(tester);
    await tester.tap(tasksTitle);
    await tester.tap(notesTitle);
    expect(taps, ['tasks', 'notes']);
  });

  testWidgets('without Tasks there is only Notes', (tester) async {
    await pumpHeader(tester, withTasks: false);
    expect(notesTitle, findsOneWidget);
    expect(tasksTitle, findsNothing);
  });

  testWidgets('S ends the row at the 20 pt inset, opens Settings, and the '
      'streak sits 12 pt before it', (tester) async {
    final taps = await pumpHeader(tester);

    expect(tester.getSize(circle), const Size(32, 32));
    expect(tester.getTopRight(circle).dx, 393 - 20);
    expect(find.descendant(of: avatar, matching: find.text('S')), findsOne);
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);

    final flame = find.descendant(
      of: streakMark,
      matching: findKapyIcon(KapyIcons.fireOutlined),
    );
    expect(tester.widget<KapyIcon>(flame).color, palette().clay);
    expect(
      find.descendant(of: streakMark, matching: find.text('1 day')),
      findsOne,
    );
    expect(
      tester.getTopLeft(circle).dx - tester.getTopRight(streakMark).dx,
      12,
    );
    expect(tester.getCenter(streakMark).dy, tester.getCenter(circle).dy);

    await tester.tap(avatar);
    expect(taps, ['settings']);
  });

  testWidgets('S takes a tap anywhere in 44 pt round its 32 pt circle, '
      'without moving it', (tester) async {
    final taps = await pumpHeader(tester);
    final target = tester.getRect(avatar);
    expect(target.size, const Size(44, 44));
    expect(target.center, tester.getCenter(circle));
    expect(target.right, 393 - 14);

    await tester.tapAt(target.topLeft + const Offset(1, 1));
    await tester.tapAt(target.bottomRight - const Offset(1, 1));
    expect(taps, ['settings', 'settings']);
  });

  testWidgets('signed out, S is the quiet account mark and still opens '
      'Settings', (tester) async {
    final taps = await pumpHeader(tester, signedIn: null);

    expect(
      find.descendant(
        of: avatar,
        matching: findKapyIcon(KapyIcons.accountCircleOutlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: avatar, matching: find.byType(Text)),
      findsNothing,
    );
    expect(find.byTooltip('Settings'), findsOneWidget);
    await tester.tap(avatar);
    expect(taps, ['settings']);
  });

  testWidgets('a run of days reads in the plural, and one waiting on today '
      'stays grey', (tester) async {
    await pumpHeader(
      tester,
      streak: const WritingStreak(days: 3, wroteToday: false),
    );
    final flame = find.descendant(
      of: streakMark,
      matching: findKapyIcon(KapyIcons.fireOutlined),
    );
    expect(
      find.descendant(of: streakMark, matching: find.text('3 days')),
      findsOne,
    );
    expect(tester.widget<KapyIcon>(flame).color, palette().textTertiary);
    expect(find.byTooltip('Write today to keep your 3-day streak'), findsOne);
  });

  for (final streak in [
    null,
    const WritingStreak(days: 0, wroteToday: false),
  ]) {
    testWidgets('no streak shows nothing before S ($streak)', (tester) async {
      await pumpHeader(tester, streak: streak);
      expect(streakMark, findsNothing);
      expect(findKapyIcon(KapyIcons.fireOutlined), findsNothing);
      expect(tester.getTopRight(circle).dx, 393 - 20);
    });
  }

  for (final scale in [1.0, 1.3, 3.1]) {
    testWidgets('an SE fits the row at $scale× text with the longest of '
        'everything', (tester) async {
      await pumpHeader(
        tester,
        tasks: true,
        notesCount: 999,
        tasksCount: 99,
        width: 375,
        scale: scale,
        streak: const WritingStreak(days: 365, wroteToday: true),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getTopRight(circle).dx, 375 - 20);
      expect(
        tester.getTopLeft(circle).dx - tester.getRect(streakMark).right,
        greaterThanOrEqualTo(12),
      );
      expect(
        tester.getRect(streakMark).left,
        greaterThanOrEqualTo(tester.getRect(tasksTitle).right + 12),
      );
    });
  }
}
