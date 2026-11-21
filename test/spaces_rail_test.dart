import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/writing_streak.dart';
import 'package:kapy_notes/sync/auth_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';
import 'test_fonts.dart';

Widget harness(SpacesRail rail) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Material(
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(height: 760, child: rail),
    ),
  ),
);

SpacesRail rail({
  LibrarySpace space = LibrarySpace.notes,
  ValueChanged<LibrarySpace>? onSelected,
  int? invitations,
  int? openTasks,
  WritingStreak? streak,
  VoidCallback? onAccountPressed,
  AccountUser? user,
  SyncStatus? syncStatus,
}) => SpacesRail(
  space: space,
  onSelected: onSelected ?? (_) {},
  onSettingsPressed: () {},
  invitations: invitations,
  openTasks: openTasks,
  streak: streak,
  onAccountPressed: onAccountPressed,
  user: user,
  syncStatus: syncStatus,
);

/// The rail's semantics for the space called [name].
Object space(WidgetTester tester, String name) =>
    tester.getSemantics(find.byKey(ValueKey('rail-$name')));

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  testWidgets('Tasks sits after Notes once there is a task index, and counts '
      'what is open on its badge', (tester) async {
    await tester.pumpWidget(harness(rail()));
    expect(find.byKey(const ValueKey('rail-tasks')), findsNothing);

    LibrarySpace? asked;
    await tester.pumpWidget(
      harness(rail(openTasks: 10, onSelected: (open) => asked = open)),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('rail-tasks'))).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('rail-notes'))).dy,
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('rail-tasks-badge')),
        matching: find.text('10'),
      ),
      findsOneWidget,
    );
    expect(space(tester, 'tasks'), isSemantics(label: 'Tasks, 10 open'));
    await tester.tap(find.byKey(const ValueKey('rail-tasks')));
    expect(asked, LibrarySpace.tasks);

    await tester.pumpWidget(harness(rail(openTasks: 0)));
    expect(find.byKey(const ValueKey('rail-tasks-badge')), findsNothing);
  });

  testWidgets('a space asks to be opened, and the open one is marked', (
    tester,
  ) async {
    LibrarySpace? asked;
    await tester.pumpWidget(
      harness(
        rail(space: LibrarySpace.drawings, onSelected: (open) => asked = open),
      ),
    );

    expect(space(tester, 'drawings'), isSemantics(isSelected: true));
    expect(space(tester, 'notes'), isSemantics(isSelected: false));

    await tester.tap(find.byKey(const ValueKey('rail-notes')));
    expect(asked, LibrarySpace.notes);
  });

  testWidgets('Shared waits for an account, then counts its invitations', (
    tester,
  ) async {
    await tester.pumpWidget(harness(rail()));
    expect(find.byKey(const ValueKey('rail-shared')), findsNothing);

    await tester.pumpWidget(harness(rail(invitations: 0)));
    expect(find.byKey(const ValueKey('rail-shared')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-shared-badge')), findsNothing);
    expect(find.bySemanticsLabel('Shared with me'), findsOneWidget);

    await tester.pumpWidget(harness(rail(invitations: 2)));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('rail-shared-badge')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Shared with me, 2 invitations'),
      findsOneWidget,
    );
  });

  testWidgets('icons and captions rest in T2, light to T1 under the pointer, '
      'and take the tonal ink when open', (tester) async {
    const palette = KapyTheme.darkPalette;
    await tester.pumpWidget(harness(rail()));
    final drawings = find.byKey(const ValueKey('rail-drawings'));
    Color? icon(Finder item, KapyIconData data) => tester
        .widget<KapyIcon>(
          find.descendant(of: item, matching: findKapyIcon(data)),
        )
        .color;
    Color? caption(Finder item) => tester
        .widget<Text>(find.descendant(of: item, matching: find.byType(Text)))
        .style
        ?.color;

    expect(icon(drawings, KapyIcons.penRounded), palette.textSecondary);
    expect(caption(drawings), palette.textSecondary);
    expect(
      icon(find.byKey(const ValueKey('rail-notes')), KapyIcons.noteOutlined),
      palette.tonalForeground,
    );
    expect(
      icon(
        find.byKey(const ValueKey('rail-settings')),
        KapyIcons.settingsGearOutlined,
      ),
      palette.textSecondary,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(drawings));
    await tester.pumpAndSettle();
    expect(icon(drawings, KapyIcons.penRounded), palette.textPrimary);
    expect(caption(drawings), palette.textPrimary);
  });

  testWidgets('Hidden and the archive are filter choices, not places', (
    tester,
  ) async {
    await tester.pumpWidget(harness(rail(openTasks: 1, invitations: 0)));
    expect(find.byKey(const ValueKey('rail-hidden')), findsNothing);
    expect(find.byKey(const ValueKey('rail-archive')), findsNothing);
  });

  testWidgets('a run of days shows as a flame, and no run shows nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(rail(streak: const WritingStreak(days: 0, wroteToday: false))),
    );
    expect(find.byKey(const ValueKey('rail-streak')), findsNothing);

    await tester.pumpWidget(
      harness(rail(streak: const WritingStreak(days: 3, wroteToday: false))),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 days'), findsOneWidget);
    expect(
      find.byTooltip('Write today to keep your 3-day streak'),
      findsOneWidget,
    );
  });

  group('the account', () {
    const user = AccountUser(
      id: 'user-1',
      email: 'sanjay@example.com',
      emailVerified: true,
      name: 'Sanjay',
    );

    Color? dot(WidgetTester tester) {
      final found = find.descendant(
        of: find.byKey(const ValueKey('rail-sync-dot')),
        matching: find.byType(Container),
      );
      if (found.evaluate().isEmpty) return null;
      return (tester.widget<Container>(found).decoration! as BoxDecoration)
          .color;
    }

    testWidgets('is left off a build with no account to show', (tester) async {
      await tester.pumpWidget(harness(rail()));
      expect(find.byKey(const ValueKey('rail-account')), findsNothing);
    });

    testWidgets('shows who is signed in, and opens Account & sync', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        harness(
          rail(
            onAccountPressed: () => opened++,
            user: user,
            syncStatus: SyncStatus.idle,
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('rail-account')),
          matching: find.text('S'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Sanjay\nSynced'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('rail-account')));
      expect(opened, 1);
    });

    testWidgets('its dot says how sync is doing', (tester) async {
      Future<void> pumpWith(SyncStatus? status) => tester.pumpWidget(
        harness(rail(onAccountPressed: () {}, user: user, syncStatus: status)),
      );

      await pumpWith(null);
      expect(dot(tester), isNull);

      await pumpWith(SyncStatus.idle);
      final scheme = Theme.of(
        tester.element(find.byKey(const ValueKey('rail-account'))),
      ).colorScheme;
      expect(dot(tester), scheme.primary);

      await pumpWith(SyncStatus.offline);
      expect(dot(tester), isNot(anyOf(scheme.primary, scheme.error)));

      await pumpWith(SyncStatus.failed);
      expect(dot(tester), scheme.error);
    });
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('fits the smallest ${platform.name} window with every space', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      // A Windows minimum is the outer window, and its caption and frame take
      // some forty points of that. macOS draws its title bar over the rail.
      final height =
          LayoutPrefs.minimumWindowSize.height -
          (platform == TargetPlatform.windows ? 40 : 0);
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: height,
                child: rail(
                  invitations: 2,
                  openTasks: 10,
                  streak: const WritingStreak(days: 3, wroteToday: true),
                  onAccountPressed: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('rail-account'))).bottom,
        lessThanOrEqualTo(height),
      );
    });
  }
}
