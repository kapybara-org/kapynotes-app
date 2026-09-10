import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/window_chrome.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/ui/app_logo.dart';
import 'package:kapy_notes/ui/toolbar.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

SpaceMember member(
  String id,
  String email, {
  SpaceRole role = SpaceRole.member,
  String name = '',
}) => SpaceMember(
  userId: id,
  email: email,
  name: name,
  role: role,
  joinedAt: DateTime(2026),
  hasKey: true,
);

Widget harness(
  NoteToolbar toolbar, {
  double width = 1100,
  bool light = false,
}) => MaterialApp(
  theme: light ? KapyTheme.light() : KapyTheme.dark(),
  home: Scaffold(
    body: SizedBox(
      width: width,
      child: Column(children: [toolbar, const Spacer()]),
    ),
  ),
);

/// The mark in the lockup is an asset, and an asset that has not decoded yet
/// paints as nothing. Without this the golden captures whichever of the two it
/// happens to be, which depends on what ran before it in the file.
Future<void> settleLogo(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => precacheImage(
      const AssetImage(AppLogo.assetPath),
      tester.element(find.byType(NoteToolbar)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  group('placement', () {
    testWidgets('macOS starts the menu after its traffic lights', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        harness(
          NoteToolbar(onToggleSidebar: () {}, onCreate: () {}, onShare: () {}),
        ),
      );

      // The drawer's button leads here as it does everywhere else; the only
      // difference is that the corner it leads from belongs to the window
      // controls, so it begins where they end rather than underneath them.
      expect(
        tester.getTopLeft(find.byIcon(Icons.menu_rounded)).dx,
        greaterThanOrEqualTo(WindowChrome.trafficLightsWidth),
      );
    });

    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.android,
    ]) {
      testWidgets('${platform.name} leads with the menu and trails the rest', (
        tester,
      ) async {
        AppPlatform.debugTargetPlatformOverride = platform;
        await tester.pumpWidget(
          harness(
            NoteToolbar(
              onToggleSidebar: () {},
              onCreate: () {},
              onShare: () {},
            ),
          ),
        );

        final wordmark = tester.getRect(
          find.byKey(const ValueKey('toolbar-app-wordmark')),
        );
        expect(
          tester.getCenter(find.byIcon(Icons.menu_rounded)).dx,
          lessThan(wordmark.left),
        );
        expect(
          tester.getCenter(find.byIcon(Icons.add_rounded)).dx,
          greaterThan(wordmark.right),
        );
        expect(
          tester.getCenter(find.byIcon(Icons.add_rounded)).dx,
          lessThan(
            tester.getCenter(find.byIcon(Icons.people_outline_rounded)).dx,
          ),
        );
      });
    }

    testWidgets('the wordmark keeps the exact centre either way', (
      tester,
    ) async {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
        AppPlatform.debugTargetPlatformOverride = platform;
        await tester.pumpWidget(
          harness(
            NoteToolbar(
              onToggleSidebar: () {},
              onCreate: () {},
              onShare: () {},
              members: [
                member('user-1', 'alice@example.com'),
                member('user-2', 'bob@example.com'),
              ],
              currentUserId: 'user-1',
              noteShared: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .getCenter(find.byKey(const ValueKey('toolbar-app-wordmark')))
              .dx,
          closeTo(tester.getCenter(find.byType(NoteToolbar)).dx, 0.5),
          reason: 'the roster shouldered the wordmark off centre on $platform',
        );
      }
    });
  });

  group('sharing', () {
    testWidgets('the share action greys out with no note open', (tester) async {
      await tester.pumpWidget(
        harness(NoteToolbar(onToggleSidebar: () {}, onCreate: () {})),
      );

      final button = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byIcon(Icons.people_outline_rounded),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('the share action opens the sheet for the note that is open', (
      tester,
    ) async {
      var shared = 0;
      await tester.pumpWidget(
        harness(
          NoteToolbar(
            onToggleSidebar: () {},
            onCreate: () {},
            onShare: () => shared++,
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.people_outline_rounded));
      await tester.pumpAndSettle();
      expect(shared, 1);
    });
  });

  group('members', () {
    testWidgets('a shared note names everyone in it, this account first', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        harness(
          NoteToolbar(
            onToggleSidebar: () {},
            onCreate: () {},
            onShare: () {},
            members: [
              member('user-2', 'bob@example.com', name: 'Bob'),
              member(
                'user-1',
                'alice@example.com',
                name: 'Alice',
                role: SpaceRole.owner,
              ),
            ],
            currentUserId: 'user-1',
            noteShared: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Shared with You, Bob'), findsOneWidget);
      expect(find.byKey(const ValueKey('member-avatar-names')), findsNothing);
      // Own initial, not the "Y" of the word standing in for the name.
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      // Left of the wordmark, beside the window controls rather than over them.
      final avatars = tester.getRect(
        find.byKey(const ValueKey('toolbar-members')),
      );
      expect(
        avatars.left,
        greaterThanOrEqualTo(WindowChrome.trafficLightsWidth),
      );
      expect(
        avatars.right,
        lessThan(
          tester
              .getRect(find.byKey(const ValueKey('toolbar-app-wordmark')))
              .left,
        ),
      );
    });

    testWidgets('a personal note leaves the corner empty', (tester) async {
      await tester.pumpWidget(
        harness(
          NoteToolbar(onToggleSidebar: () {}, onCreate: () {}, onShare: () {}),
        ),
      );
      expect(find.byKey(const ValueKey('toolbar-members')), findsNothing);
      expect(find.byKey(const ValueKey('member-avatar-names')), findsNothing);
    });

    testWidgets('a crowded space collapses into a count', (tester) async {
      await tester.pumpWidget(
        harness(
          NoteToolbar(
            onToggleSidebar: () {},
            onCreate: () {},
            onShare: () {},
            members: [
              member('user-1', 'alice@example.com'),
              for (var i = 2; i <= 6; i++)
                member('user-$i', 'person$i@example.com'),
            ],
            currentUserId: 'user-1',
            noteShared: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Three slots: two people and everybody else.
      expect(
        find.byKey(const ValueKey('member-avatar-user-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('member-avatar-user-2')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('member-avatar-user-3')), findsNothing);
      expect(find.text('+4'), findsOneWidget);
    });

    testWidgets('a narrow bar drops the names rather than truncating them', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(
          NoteToolbar(
            onToggleSidebar: () {},
            onCreate: () {},
            onShare: () {},
            members: [
              member('user-1', 'alice@example.com'),
              member('user-2', 'bartholomew@example.com'),
            ],
            currentUserId: 'user-1',
            noteShared: true,
          ),
          width: 390,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('toolbar-members')), findsOneWidget);
      expect(find.byKey(const ValueKey('member-avatar-names')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('shared note title bar golden', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(900, 60);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        NoteToolbar(
          onToggleSidebar: () {},
          onCreate: () {},
          onShare: () {},
          members: [
            member('user-1', 'alice@example.com', role: SpaceRole.owner),
            member('user-2', 'bob@example.com'),
            member('user-3', 'carla@example.com'),
          ],
          currentUserId: 'user-1',
          noteShared: true,
        ),
        width: 900,
      ),
    );
    await settleLogo(tester);

    await expectLater(
      find.byType(NoteToolbar),
      matchesGoldenFile('goldens/toolbar_shared_note_dark.png'),
    );
  });

  testWidgets('shared note title bar golden, light', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(900, 60);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        NoteToolbar(
          onToggleSidebar: () {},
          onCreate: () {},
          onShare: () {},
          members: [
            member('user-1', 'alice@example.com', role: SpaceRole.owner),
            member('user-2', 'bob@example.com'),
            member('user-3', 'carla@example.com'),
          ],
          currentUserId: 'user-1',
          noteShared: true,
        ),
        width: 900,
        light: true,
      ),
    );
    await settleLogo(tester);

    await expectLater(
      find.byType(NoteToolbar),
      matchesGoldenFile('goldens/toolbar_shared_note_light.png'),
    );
  });
}
