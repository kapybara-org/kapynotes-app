import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

Widget _harness(ValueChanged<BuildContext> onContext, {ThemeData? theme}) {
  final baseTheme = theme ?? KapyTheme.dark();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: 'Roboto'),
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) {
          onContext(context);
          return const SizedBox.expand();
        },
      ),
    ),
  );
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => Toast.debugAnimateLifetimeInTests = true);
  tearDown(() => Toast.debugAnimateLifetimeInTests = false);

  testWidgets('a waiting toast changes from progress to completion', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    final progress = Toast.showProgress(context, 'Adding image…');
    await tester.pump();

    expect(find.text('Adding image…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('toast-progress-indicator')),
      findsOneWidget,
    );

    progress.success('Image added');
    await tester.pump();

    expect(find.text('Adding image…'), findsNothing);
    expect(find.text('Image added'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('toast-progress-indicator')),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Image added'), findsNothing);
  });

  testWidgets('an Undo toast stays its full time with animations turned off', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    Toast.show(context, 'Removed Priya', action: 'Undo', onAction: () {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3900));
    expect(find.text('Undo'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Removed Priya'), findsNothing);
  });

  testWidgets('a waiting toast can complete before its first frame', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    final progress = Toast.showProgress(context, 'Exporting notes…');
    progress.success('Export ready');
    await tester.pump();

    expect(find.text('Exporting notes…'), findsNothing);
    expect(find.text('Export ready'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('toast-progress-indicator')),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Export ready'), findsNothing);
  });

  testWidgets('a progress toast stays above the mobile keyboard', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    final progress = Toast.showProgress(context, 'Uploading…');
    await tester.pump();

    final positioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.text('Uploading…'),
        matching: find.byType(Positioned),
      ),
    );
    expect(positioned.bottom, 296);

    progress.dismiss();
    await tester.pump();
  });

  testWidgets('uses a compact neutral pill with a clear status icon', (
    tester,
  ) async {
    Toast.debugAnimateLifetimeInTests = false;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 140);
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    Toast.show(context, 'Copied 1,234', icon: KapyIcons.copyRounded);
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('toast-surface'));
    expect(tester.getSize(surface).height, 40);
    final decoration = tester.widget<Container>(surface).decoration;
    expect(decoration, isA<BoxDecoration>());
    final boxDecoration = decoration! as BoxDecoration;
    expect(boxDecoration.borderRadius, BorderRadius.circular(999));
    expect(boxDecoration.boxShadow, anyOf(isNull, isEmpty));
    expect(
      tester.widget<Text>(find.text('Copied 1,234')).style!.fontWeight,
      FontWeight.w400,
    );
    final icon = tester.widget<KapyIcon>(
      find.byKey(const ValueKey('toast-status-icon')),
    );
    expect(icon.size, 14);
    expect(icon.color, Theme.of(tester.element(surface)).colorScheme.primary);
    expect(icon.color, isNot(KapyTheme.darkPalette.chipCurrency));

    await expectLater(
      find.byKey(const ValueKey('toast-repaint-boundary')),
      matchesGoldenFile('goldens/toast_success_dark.png'),
    );
  });

  testWidgets('uses the error treatment cleanly on a light surface', (
    tester,
  ) async {
    Toast.debugAnimateLifetimeInTests = false;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 140);
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      _harness((value) => context = value, theme: KapyTheme.light()),
    );

    Toast.show(context, 'Could not save', isError: true);
    await tester.pumpAndSettle();

    final icon = tester.widget<KapyIcon>(
      find.byKey(const ValueKey('toast-status-icon')),
    );
    expect(icon.icon, KapyIcons.errorOutlined);
    expect(icon.color, Theme.of(context).colorScheme.error);
    await expectLater(
      find.byKey(const ValueKey('toast-repaint-boundary')),
      matchesGoldenFile('goldens/toast_error_light.png'),
    );
  });
  group("a phone's notice", () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    Future<BuildContext> phone(
      WidgetTester tester, {
      Size size = const Size(393, 852),
    }) async {
      Toast.debugAnimateLifetimeInTests = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      late BuildContext context;
      await tester.pumpWidget(_harness((value) => context = value));
      return context;
    }

    final surface = find.byKey(const ValueKey('toast-surface'));
    final icon = find.byKey(const ValueKey('toast-status-icon'));
    final action = find.byKey(const ValueKey('toast-action'));

    testWidgets('is a card across the screen inside its 16 pt margins, with '
        '12 pt corners, the icon at its start and the action at its end', (
      tester,
    ) async {
      final context = await phone(tester);
      Toast.show(
        context,
        'Archived “Morning pages”',
        icon: KapyIcons.archiveOutlined,
        action: 'Undo',
        onAction: () {},
      );
      await tester.pumpAndSettle();

      final card = tester.getRect(surface);
      expect(card.left, 16);
      expect(card.width, 393 - 32);
      expect(card.height, 52 + 1.5, reason: '52 inside its hairline');
      final box = tester.widget<Container>(surface);
      expect(
        (box.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(12),
      );
      expect(box.padding, const EdgeInsets.fromLTRB(16, 12, 8, 12));
      expect(tester.widget<KapyIcon>(icon).icon, KapyIcons.archiveOutlined);
      expect(tester.getTopLeft(icon).dx, card.left + 0.75 + 16);
      expect(tester.getTopRight(action).dx, card.right - 0.75 - 8);
      expect(
        tester.getCenter(icon).dy,
        moreOrLessEquals(tester.getCenter(action).dy, epsilon: 0.5),
      );
      expect(
        tester.getCenter(find.text('Archived “Morning pages”')).dy,
        moreOrLessEquals(tester.getCenter(action).dy, epsilon: 0.5),
      );
    });

    testWidgets('is 52 pt inside its hairline even with nothing but words, '
        'which sit in its middle', (tester) async {
      final context = await phone(tester);
      Toast.show(context, 'Copied');
      await tester.pumpAndSettle();

      final card = tester.getRect(surface);
      expect(card.height, 52 + 1.5);
      expect(
        tester.getCenter(find.text('Copied')).dy,
        moreOrLessEquals(card.center.dy, epsilon: 0.5),
      );
    });

    testWidgets("keeps the action in the app's accent", (tester) async {
      final context = await phone(tester);
      Toast.show(context, 'Removed Priya', action: 'Undo', onAction: () {});
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextButton>(action).style!.foregroundColor!.resolve({}),
        KapyTheme.darkPalette.accentText,
      );
    });

    testWidgets('has no icon unless the notice brings one, so its words '
        'start at the edge', (tester) async {
      final context = await phone(tester);
      Toast.show(context, 'Sign in to open that link.');
      await tester.pumpAndSettle();

      expect(icon, findsNothing);
      expect(
        tester.getTopLeft(find.text('Sign in to open that link.')).dx,
        tester.getTopLeft(surface).dx + 0.75 + 16,
      );
      expect(tester.getSize(surface).width, 393 - 32);
    });

    testWidgets(
      "shows an error's own icon in the card's colours, with no red",
      (tester) async {
        final context = await phone(tester);
        Toast.show(context, 'Could not save', isError: true);
        await tester.pumpAndSettle();

        final glyph = tester.widget<KapyIcon>(icon);
        expect(glyph.icon, KapyIcons.errorOutlined);
        expect(glyph.color, KapyTheme.darkPalette.textSecondary);
        expect(glyph.color, isNot(Theme.of(context).colorScheme.error));
      },
    );

    testWidgets('wraps long words to two lines inside the card, the action '
        'level with the first', (tester) async {
      final context = await phone(tester);
      const message =
          'Invited Carol again. They can see the note once they accept '
          'the invitation in their email and open the link.';
      Toast.show(
        context,
        message,
        icon: KapyIcons.checkCircleRounded,
        action: 'Undo',
        onAction: () {},
      );
      await tester.pumpAndSettle();

      final card = tester.getRect(surface);
      final words = tester.getRect(find.text(message));
      final line = tester.getSize(find.text('Undo')).height;
      expect(words.height, greaterThan(line * 1.5));
      expect(words.height, lessThan(line * 2.5));
      expect(card.contains(words.topLeft), isTrue);
      expect(card.contains(words.bottomRight), isTrue);
      expect(words.right, lessThanOrEqualTo(tester.getTopLeft(action).dx));
      expect(tester.getTopLeft(action).dy, card.top + 0.75 + 12);
      expect(tester.getTopLeft(icon).dy, lessThan(words.center.dy));
      expect(card.bottom - words.bottom, greaterThanOrEqualTo(12));
    });

    testWidgets('stays above the keyboard at the same width', (tester) async {
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      final context = await phone(tester);
      Toast.show(context, 'Copied');
      await tester.pumpAndSettle();

      expect(tester.getRect(surface).bottom, 852 - 300 - 16);
      expect(tester.getSize(surface).width, 393 - 32);
    });

    testWidgets('keeps above the highest of what it keeps clear of', (
      tester,
    ) async {
      Toast.debugAnimateLifetimeInTests = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.reset);
      for (final order in [true, false]) {
        late BuildContext context;
        const low = ToastClearance(child: SizedBox(height: 60));
        const high = ToastClearance(child: SizedBox(height: 200));
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(order),
            theme: KapyTheme.dark(),
            home: Scaffold(
              body: Builder(
                builder: (value) {
                  context = value;
                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: order
                          ? const [Expanded(child: low), Expanded(child: high)]
                          : const [Expanded(child: high), Expanded(child: low)],
                    ),
                  );
                },
              ),
            ),
          ),
        );
        Toast.show(context, 'Copied');
        await tester.pumpAndSettle();
        expect(
          tester.getRect(surface).bottom,
          852 - 200 - 16,
          reason: '$order',
        );
      }
    });

    testWidgets('stops at 480 pt wide on a tablet', (tester) async {
      final context = await phone(tester, size: const Size(1024, 768));
      Toast.show(context, 'Copied');
      await tester.pumpAndSettle();

      expect(tester.getSize(surface).width, 480);
      expect(tester.getCenter(surface).dx, 512);
    });
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets("the action is in the app's own font on ${platform.name}", (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      Toast.debugAnimateLifetimeInTests = false;
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (value) {
                context = value;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );

      Toast.show(context, 'Archived', action: 'Undo', onAction: () {});
      await tester.pumpAndSettle();

      final style = tester
          .widget<RichText>(
            find.descendant(
              of: find.byKey(const ValueKey('toast-action')),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!;
      expect(style.fontFamily, AppFonts.ui);
      expect(style.fontFamilyFallback, AppFonts.uiFallback);
      expect(style.color, KapyTheme.darkPalette.accentText);
    });
  }

  testWidgets("a desktop's notice stays a pill sized to its words", (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    Toast.debugAnimateLifetimeInTests = false;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    Toast.show(context, 'Archived', action: 'Undo', onAction: () {});
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('toast-surface'));
    final box = tester.widget<Container>(surface);
    expect(
      (box.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(999),
    );
    expect(
      box.padding,
      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    );
    expect(tester.getSize(surface).height, 45.5);
    expect(tester.getSize(surface).width, lessThan(200));
    final glyph = tester.widget<KapyIcon>(
      find.byKey(const ValueKey('toast-status-icon')),
    );
    expect(glyph.icon, KapyIcons.checkRounded);
    expect(glyph.size, 14);
    expect(glyph.color, Theme.of(context).colorScheme.primary);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('toast-action')))
          .style!
          .foregroundColor!
          .resolve({}),
      KapyTheme.darkPalette.accentText,
    );
  });
}
