import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:kapy_notes/ui/context_menu.dart';
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

  testWidgets('withdraw takes down only the toast that offers that action', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));
    void reopen() {}
    void undo() {}

    Toast.show(context, 'Removed Priya', action: 'Undo', onAction: undo);
    await tester.pump();
    Toast.withdraw(reopen);
    await tester.pump();
    expect(find.text('Removed Priya'), findsOneWidget);

    Toast.withdraw(undo);
    await tester.pump();
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

    for (final (theme, palette) in [
      (KapyTheme.dark(), KapyTheme.darkPalette),
      (KapyTheme.light(), KapyTheme.lightPalette),
    ]) {
      testWidgets('is edged with the hairline the bar has, in '
          '${theme.brightness.name}', (tester) async {
        Toast.debugAnimateLifetimeInTests = false;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(393, 852);
        addTearDown(tester.view.reset);
        late BuildContext context;
        await tester.pumpWidget(
          _harness((value) => context = value, theme: theme),
        );
        Toast.show(context, 'Archived', action: 'Undo', onAction: () {});
        await tester.pumpAndSettle();

        final border =
            (tester.widget<Container>(surface).decoration! as BoxDecoration)
                    .border!
                as Border;
        expect(border.top.color, palette.edge);
        expect(border.top.width, 0.75);
      });
    }

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

  group("a desktop's notice beside the notes list", () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    final surface = find.byKey(const ValueKey('toast-surface'));

    /// A window [width] wide laid out as Home's: the 76 wide rail, the notes
    /// list as wide as [list] says beside it, the page, and Kapy AI's panel
    /// [panel] wide at the right.
    Future<BuildContext> window(
      WidgetTester tester, {
      double width = 820,
      ValueNotifier<double>? list,
      double foot = 0,
      double panel = 0,
    }) async {
      Toast.debugAnimateLifetimeInTests = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey((width, list?.value, foot, panel)),
          theme: KapyTheme.dark(),
          home: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(width: 76),
              if (list != null)
                ToastClearance.beside(
                  child: ValueListenableBuilder(
                    valueListenable: list,
                    builder: (_, value, _) => SizedBox(
                      width: value,
                      child: Column(
                        children: [
                          const Spacer(),
                          if (foot > 0)
                            ToastClearance(child: SizedBox(height: foot)),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: Builder(
                  builder: (value) {
                    context = value;
                    return const SizedBox.expand();
                  },
                ),
              ),
              if (panel > 0)
                ToastClearance.beside(child: SizedBox(width: panel)),
            ],
          ),
        ),
      );
      return context;
    }

    ValueNotifier<double> listOf(double width) {
      final list = ValueNotifier(width);
      addTearDown(list.dispose);
      return list;
    }

    void opened(BuildContext context) => Toast.show(
      context,
      "Opened yesterday's 3 notes",
      action: 'Undo',
      onAction: () {},
    );

    testWidgets('centres on the page beside the list, clear of it, at every '
        'width the list stands beside the page', (tester) async {
      // 720 is the narrowest window with the list beside the page, which
      // then has the least the list ever leaves it: 324 and 320.
      for (final (width, list) in [
        (720.0, 324.0),
        (820.0, 336.0),
        (1280.0, 336.0),
      ]) {
        opened(await window(tester, width: width, list: listOf(list)));
        await tester.pumpAndSettle();

        final page = 76 + list;
        expect(
          tester.getCenter(surface).dx,
          (page + width) / 2,
          reason: '$width',
        );
        expect(
          tester.getRect(surface).left,
          greaterThanOrEqualTo(page + 16),
          reason: '$width',
        );
      }
    });

    testWidgets("and between the list and Kapy AI's panel", (tester) async {
      opened(await window(tester, width: 1280, list: listOf(336), panel: 360));
      await tester.pumpAndSettle();

      expect(tester.getCenter(surface).dx, (412 + 920) / 2);
      expect(tester.getRect(surface).right, lessThanOrEqualTo(920 - 16));
    });

    testWidgets('wraps its words inside the narrowest page rather than '
        'reach over the list', (tester) async {
      final context = await window(tester, width: 720, list: listOf(324));
      Toast.show(
        context,
        'Moved 12 notes to Hidden Notes. Choose Hidden in the notes filter to '
        'find them.',
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(surface).width, 320 - 32);
      expect(tester.getRect(surface).left, 400 + 16);
    });

    testWidgets('centres on the window where the room beside what it keeps '
        'beside is narrower than the least page the list leaves', (
      tester,
    ) async {
      for (final (width, list, panel, centre) in [
        // 319 beside the list, then 320.
        (731.0, 336.0, 0.0, 731 / 2),
        (732.0, 336.0, 0.0, (412 + 732) / 2),
        // The list open over a new window's page.
        (600.0, 336.0, 0.0, 300.0),
        // The list beside the page and Kapy AI over it.
        (1100.0, 336.0, 372.0, 550.0),
      ]) {
        opened(
          await window(tester, width: width, list: listOf(list), panel: panel),
        );
        await tester.pumpAndSettle();

        expect(tester.getCenter(surface).dx, centre, reason: '$width');
      }
    });

    testWidgets('centres on the window with the list slid shut, as with no '
        'list at all', (tester) async {
      for (final list in [listOf(0), null]) {
        opened(await window(tester, list: list));
        await tester.pumpAndSettle();

        expect(tester.getCenter(surface).dx, 410);
      }
    });

    testWidgets('follows the list as it opens and shuts', (tester) async {
      final list = listOf(0);
      opened(await window(tester, list: list));
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, 410);

      list.value = 336;
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, (412 + 820) / 2);

      list.value = 0;
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, 410);
    });

    testWidgets('centres on the window under a dialog, and on the page again '
        'once it closes', (tester) async {
      final context = await window(tester, list: listOf(336));
      late BuildContext dialog;
      unawaited(
        showDialog<void>(
          context: context,
          builder: (value) {
            dialog = value;
            return const SizedBox(width: 200, height: 200);
          },
        ),
      );
      await tester.pumpAndSettle();
      Toast.show(dialog, 'Copied');
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, 410);

      Navigator.pop(dialog);
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, (412 + 820) / 2);
    });

    // Parity item 64: a menu took it to the middle of the window, over the
    // list, until it closed.
    testWidgets('keeps its place under a menu and a menu from it, and centres '
        "on the window under a dialog a menu's item opens", (tester) async {
      final context = await window(tester, list: listOf(336));
      opened(context);
      await tester.pumpAndSettle();
      const page = (412 + 820) / 2;
      expect(tester.getCenter(surface).dx, page);

      Future<String?> menu(BuildContext over, String item) =>
          showKapyContextMenu<String>(
            context: over,
            globalPosition: const Offset(500, 200),
            items: [PopupMenuItem(value: item, child: Text(item))],
          );
      unawaited(menu(context, 'Tags'));
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, page);
      unawaited(menu(tester.element(find.text('Tags')), 'Work'));
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, page);

      Navigator.pop(context);
      await tester.pumpAndSettle();
      Navigator.pop(context);
      await tester.pumpAndSettle();
      expect(find.text('Tags'), findsNothing);
      expect(tester.getCenter(surface).dx, page);

      // As a shortcut can open one over a menu still open.
      unawaited(menu(context, 'Copy'));
      await tester.pumpAndSettle();
      unawaited(
        showDialog<void>(
          context: tester.element(find.text('Copy')),
          builder: (_) => const SizedBox(width: 200, height: 200),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, 410);
      Navigator.pop(context);
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(tester.getCenter(surface).dx, page);
      Navigator.pop(context);
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, page);

      unawaited(
        menu(context, 'Rename').then((_) {
          if (context.mounted) {
            unawaited(
              showDialog<void>(
                context: context,
                builder: (_) => const SizedBox(width: 200, height: 200),
              ),
            );
          }
        }),
      );
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, page);
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);
      expect(tester.getCenter(surface).dx, 410);
    });

    testWidgets("keeps its place under a popover, as the tag list a menu's "
        'Tags opens', (tester) async {
      final context = await window(tester, list: listOf(336));
      opened(context);
      await tester.pumpAndSettle();
      const page = (412 + 820) / 2;

      unawaited(
        showKapyContextMenu<String>(
          context: context,
          globalPosition: const Offset(500, 200),
          items: const [PopupMenuItem(value: 'Tags', child: Text('Tags'))],
        ).then((_) {
          if (context.mounted) {
            unawaited(
              showKapyPopover<void>(
                context: context,
                barrierLabel: 'Close tags',
                pageBuilder: (_, _, _) => const Center(child: Text('Work')),
              ),
            );
          }
        }),
      );
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface).dx, page);
      await tester.tap(find.text('Tags'));
      await tester.pump();
      expect(tester.getCenter(surface).dx, page);
      await tester.pumpAndSettle();
      expect(find.text('Work'), findsOneWidget);
      expect(tester.getCenter(surface).dx, page);

      Navigator.pop(context);
      await tester.pumpAndSettle();
      expect(find.text('Work'), findsNothing);
      expect(tester.getCenter(surface).dx, page);
    });

    testWidgets("keeps above the list's foot where it centres on the window "
        'over the list, and not where it keeps beside the list or the list '
        'is slid shut', (tester) async {
      for (final (width, list, panel, centre, bottom) in [
        (820.0, 336.0, 0.0, 616.0, 800.0 - 24),
        (600.0, 336.0, 0.0, 300.0, 800.0 - 80),
        (600.0, 0.0, 300.0, 300.0, 800.0 - 24),
      ]) {
        opened(
          await window(
            tester,
            width: width,
            list: listOf(list),
            foot: 64,
            panel: panel,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.getCenter(surface).dx, centre, reason: '$width $list');
        expect(tester.getRect(surface).bottom, bottom, reason: '$width $list');
      }
    });

    testWidgets("leaves a phone's card on the window", (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      opened(await window(tester, width: 1024, list: listOf(336)));
      await tester.pumpAndSettle();

      expect(tester.getCenter(surface).dx, 512);
      expect(tester.getSize(surface).width, 480);
    });

    testWidgets("leaves a phone's card stepping down under a menu, as under "
        'anything over its bar', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      Toast.debugAnimateLifetimeInTests = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Builder(
            builder: (value) {
              context = value;
              return const Align(
                alignment: Alignment.bottomCenter,
                child: ToastClearance(child: SizedBox(width: 400, height: 100)),
              );
            },
          ),
        ),
      );
      Toast.show(context, 'Copied');
      await tester.pumpAndSettle();
      expect(tester.getRect(surface).bottom, 800 - 100 - 16);

      unawaited(
        showKapyContextMenu<void>(
          context: context,
          globalPosition: const Offset(200, 300),
          items: const [PopupMenuItem(child: Text('Copy'))],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(surface).bottom, greaterThan(800 - 100 - 16));
    });
  });

  for (final (platform, size) in [
    (TargetPlatform.iOS, const Size(390, 844)),
    (TargetPlatform.macOS, const Size(1280, 800)),
  ]) {
    for (final undo in [false, true]) {
      testWidgets('on ${platform.name}, a tap on a notice '
          '${undo ? 'with' : 'without'} Undo never lands on what is under it', (
        tester,
      ) async {
        AppPlatform.debugTargetPlatformOverride = platform;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        Toast.debugAnimateLifetimeInTests = false;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        var under = 0;
        var undone = 0;
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            theme: KapyTheme.dark(),
            home: Builder(
              builder: (value) {
                context = value;
                return TextButton(
                  key: const ValueKey('under'),
                  onPressed: () => under++,
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        );

        Toast.show(
          context,
          'Archived',
          action: undo ? 'Undo' : null,
          onAction: undo ? () => undone++ : null,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Archived'));
        await tester.pump();
        expect(under, 0);

        await tester.tapAt(
          tester.getTopLeft(find.byKey(const ValueKey('toast-surface'))) -
              const Offset(0, 8),
        );
        await tester.pump();
        expect(under, 1, reason: 'just outside the card, it reaches');
        if (undo) {
          await tester.tap(find.text('Undo'));
          await tester.pump();
          expect(undone, 1);
          expect(under, 1);
        }
      });
    }
  }
  group("a toast's onGone", () {
    testWidgets('runs once its time is up, and never after its action', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(_harness((value) => context = value));
      var gone = 0;
      var undone = 0;

      Toast.show(
        context,
        'Note deleted',
        action: 'Undo',
        onAction: () => undone++,
        onGone: () => gone++,
      );
      await tester.pump();
      await tester.pump(
        Toast.actionLifetime - const Duration(milliseconds: 100),
      );
      expect(gone, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Note deleted'), findsNothing);
      expect(gone, 1);

      Toast.show(
        context,
        'Note deleted',
        action: 'Undo',
        onAction: () => undone++,
        onGone: () => gone++,
      );
      await tester.pump();
      await tester.tap(find.text('Undo'));
      await tester.pump(Toast.actionLifetime * 2);
      expect(undone, 1);
      expect(gone, 1);
    });

    testWidgets('runs as another toast takes its place', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(_harness((value) => context = value));
      final gone = <String>[];

      Toast.show(
        context,
        'Note deleted',
        action: 'Undo',
        onAction: () {},
        onGone: () => gone.add('first'),
      );
      await tester.pump();
      Toast.show(
        context,
        '2 notes deleted',
        action: 'Undo',
        onAction: () {},
        onGone: () => gone.add('second'),
      );
      expect(gone, ['first']);
      await tester.pump();
      expect(find.text('2 notes deleted'), findsOneWidget);

      Toast.show(context, 'Copied');
      expect(gone, ['first', 'second']);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('never runs for a toast still showing as the app closes', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(_harness((value) => context = value));
      var gone = 0;

      Toast.show(
        context,
        'Note deleted',
        action: 'Undo',
        onAction: () {},
        onGone: () => gone++,
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Toast.actionLifetime * 2);
      expect(gone, 0);

      await tester.pumpWidget(_harness((value) => context = value));
      Toast.show(context, 'Copied');
      await tester.pump(const Duration(seconds: 2));
      expect(gone, 0);
    });
  });
}
