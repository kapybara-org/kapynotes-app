import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required double scale,
    required Size size,
    PhoneTab tab = PhoneTab.notes,
    ValueChanged<PhoneTab>? onSelected,
    VoidCallback? onCreate,
    bool showKapyAi = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: PhoneSpaces(
          tab: tab,
          onSelected: onSelected ?? (_) {},
          createLabel: 'New note',
          onCreate: onCreate ?? () {},
          showKapyAi: showKapyAi,
          createActions: const [],
          onCreateAction: (_) {},
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final (scale, size) in [
      (1.0, const Size(393, 852)),
      (1.3, const Size(393, 852)),
      (2.0, const Size(412, 915)),
      (3.1, const Size(375, 667)),
    ]) {
      testWidgets('the bar fits its labels at $scale× text on '
          '${platform.name}', (tester) async {
        AppPlatform.debugTargetPlatformOverride = platform;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        await pumpBar(tester, scale: scale, size: size);
        expect(tester.takeException(), isNull);
        for (final label in ['Notes', 'Folders', 'Kapy AI']) {
          final text = find.text(label);
          expect(text, findsOneWidget, reason: label);
          expect(
            tester.getSize(text).height,
            lessThanOrEqualTo(13 * 1.3 + 0.5),
            reason: label,
          );
        }
      });
    }
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name} a toast sits above the bar and its +, '
        'and back at the bottom edge over a sheet', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      tester.view.padding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.resetPadding);
      await pumpBar(tester, scale: 1, size: const Size(393, 852));
      final context = tester.element(find.byType(SizedBox).last);
      final toast = find.byKey(const ValueKey('toast-surface'));

      Toast.show(context, 'Removed Carol from this note');
      await tester.pumpAndSettle();
      final top = [
        tester.getTopLeft(find.byKey(const ValueKey('phone-bar'))).dy,
        tester.getTopLeft(find.bySemanticsLabel('New note')).dy,
      ].reduce((a, b) => a < b ? a : b);
      expect(tester.getBottomLeft(toast).dy, lessThanOrEqualTo(top - 16));

      unawaited(
        showModalBottomSheet<void>(
          context: context,
          builder: (_) => const SizedBox(height: 200),
        ),
      );
      await tester.pumpAndSettle();
      Toast.show(context, 'Removed Carol from this note');
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(toast).dy, 852 - 34 - 16);
    });
  }

  testWidgets('with the bar in a navigator of its own, as on Home, a sheet '
      'from the one around it takes a toast back to the bottom edge', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: ToastClearanceScope(
          child: Navigator(
            pages: [
              MaterialPage<void>(
                child: PhoneSpaces(
                  tab: PhoneTab.notes,
                  onSelected: (_) {},
                  createLabel: 'New note',
                  onCreate: () {},
                  createActions: const [],
                  onCreateAction: (_) {},
                  child: const SizedBox.expand(),
                ),
              ),
            ],
            onDidRemovePage: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final outer = tester.element(find.byType(ToastClearanceScope));
    final toast = find.byKey(const ValueKey('toast-surface'));

    Toast.show(outer, 'Removed Carol from this note');
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(toast).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byKey(const ValueKey('phone-bar'))).dy - 16,
      ),
    );

    unawaited(
      showModalBottomSheet<void>(
        context: outer,
        builder: (_) => const SizedBox(height: 200),
      ),
    );
    await tester.pumpAndSettle();
    Toast.show(outer, 'Removed Carol from this note');
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(toast).dy, 852 - 34 - 16);
  });

  testWidgets("iOS's bar is a quiet opaque pill with an 8% edge, and the open "
      'tab is the 7% fill', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpBar(tester, scale: 1, size: const Size(393, 852));
    const palette = KapyTheme.darkPalette;
    BoxDecoration decorationOf(Finder finder) =>
        tester.widget<Container>(finder).decoration! as BoxDecoration;

    final bar = decorationOf(find.byKey(const ValueKey('phone-bar')));
    expect(
      bar.color,
      Color.alphaBlend(palette.fillRest, palette.sidebarBackground),
    );
    expect(bar.color!.a, 1);
    expect((bar.border! as Border).top.color, palette.edge);
    Color? tab(String name) => decorationOf(
      find
          .descendant(
            of: find.byKey(ValueKey('bar-$name')),
            matching: find.byType(Container),
          )
          .first,
    ).color;
    expect(tab('notes'), palette.fillSelected);
    expect(tab('folders'), isNull);
    expect(tab('kapyAi'), isNull);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets("iOS's bar is 56 high, its tabs 46 high with radius 23", (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpBar(tester, scale: 1, size: const Size(393, 852));
    final bar = find.byKey(const ValueKey('phone-bar'));
    expect(tester.getSize(bar).height, 56);
    expect(
      (tester.widget<Container>(bar).decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(28),
    );
    for (final name in ['notes', 'folders', 'kapyAi']) {
      final tab = find
          .descendant(
            of: find.byKey(ValueKey('bar-$name')),
            matching: find.byType(Container),
          )
          .first;
      expect(tester.getSize(tab).height, 46, reason: name);
      expect(
        (tester.widget<Container>(tab).decoration! as BoxDecoration)
            .borderRadius,
        BorderRadius.circular(23),
        reason: name,
      );
    }
  });

  group("Android's bar", () {
    final android = TargetPlatformVariant.only(TargetPlatform.android);
    setUp(
      () => AppPlatform.debugTargetPlatformOverride = TargetPlatform.android,
    );
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final bar = find.byKey(const ValueKey('phone-bar'));
    final plus = find.byKey(const ValueKey('phone-new'));

    testWidgets("is M01's pill with the + on its own beside it, and not "
        "Material's bar and button", (tester) async {
      await pumpBar(tester, scale: 1, size: const Size(412, 915));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(tester.getSize(bar).height, 56);
      expect(
        (tester.widget<Container>(bar).decoration! as BoxDecoration)
            .borderRadius,
        BorderRadius.circular(28),
      );
      expect(tester.getSize(plus), const Size.square(56));
      expect(tester.getRect(plus).left - tester.getRect(bar).right, 12);
      expect(tester.getCenter(plus).dy, tester.getCenter(bar).dy);
    }, variant: android);

    testWidgets('reads each tab to TalkBack as a button by its name, the '
        'open one selected', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpBar(
        tester,
        scale: 1,
        size: const Size(412, 915),
        tab: PhoneTab.folders,
      );
      for (final (tab, label) in [
        (PhoneTab.notes, 'Notes'),
        (PhoneTab.folders, 'Folders'),
        (PhoneTab.kapyAi, 'Kapy AI'),
      ]) {
        expect(
          tester.getSemantics(find.byKey(ValueKey('bar-${tab.name}'))),
          matchesSemantics(
            label: label,
            isButton: true,
            hasSelectedState: true,
            isSelected: tab == PhoneTab.folders,
            hasTapAction: true,
          ),
          reason: label,
        );
      }
      semantics.dispose();
    }, variant: android);

    for (final (mode, inset, lift) in [
      ('no', 0.0, 30.0),
      ('three-button', 48.0, 56.0),
      ('gesture', 24.0, 32.0),
    ]) {
      testWidgets('clears $mode navigation, $lift above the bottom', (
        tester,
      ) async {
        tester.view.viewPadding = FakeViewPadding(bottom: inset);
        tester.view.padding = FakeViewPadding(bottom: inset);
        await pumpBar(tester, scale: 1, size: const Size(412, 915));
        expect(915 - tester.getRect(bar).bottom, lift);
        expect(915 - tester.getRect(plus).bottom, lift);
      }, variant: android);
    }
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name} the tabs rest in T3 and the open one is '
        'T1, at 20', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpBar(tester, scale: 1, size: const Size(393, 852));
      const palette = KapyTheme.darkPalette;
      KapyIcon icon(String tab, KapyIconData data) => tester.widget<KapyIcon>(
        find.descendant(
          of: find.byKey(ValueKey('bar-$tab')),
          matching: findKapyIcon(data),
        ),
      );

      expect(icon('notes', KapyIcons.noteOutlined).color, palette.textPrimary);
      expect(icon('notes', KapyIcons.noteOutlined).size, 20);
      expect(
        icon('folders', KapyIcons.folderOutlined).color,
        palette.textTertiary,
      );
      expect(
        icon('kapyAi', KapyIcons.sparklesOutlined).color,
        palette.textTertiary,
      );
    });

    testWidgets('on ${platform.name} the bar is Notes, Folders and Kapy AI, '
        'each tab handing back its own, with + on its own', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      final chosen = <PhoneTab>[];
      var made = 0;
      await pumpBar(
        tester,
        scale: 1,
        size: const Size(393, 852),
        tab: PhoneTab.folders,
        onSelected: chosen.add,
        onCreate: () => made++,
      );
      final bar = find.byKey(const ValueKey('phone-bar'));
      final plus = find.byKey(const ValueKey('phone-new'));
      final tabs = [
        for (final tab in PhoneTab.values)
          find.byKey(ValueKey('bar-${tab.name}')),
      ];
      expect(
        tester.getCenter(tabs[0]).dx,
        lessThan(tester.getCenter(tabs[1]).dx),
      );
      expect(
        tester.getCenter(tabs[1]).dx,
        lessThan(tester.getCenter(tabs[2]).dx),
      );
      for (final tab in tabs) {
        expect(find.descendant(of: bar, matching: tab), findsOneWidget);
      }
      for (final gone in ['tasks', 'drawings', 'settings']) {
        expect(find.byKey(ValueKey('bar-$gone')), findsNothing, reason: gone);
      }
      expect(find.descendant(of: bar, matching: plus), findsNothing);
      expect(tester.getRect(plus).left - tester.getRect(bar).right, 12);
      expect(tester.getRect(plus).right, 393 - 16);
      expect(tester.getRect(bar).left, 16);
      expect(tester.getCenter(plus).dy, closeTo(tester.getCenter(bar).dy, 0.5));
      expect(
        tester.getSemantics(tabs[1]),
        matchesSemantics(
          label: 'Folders',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      expect(tester.getSize(plus), const Size.square(56));

      for (final tab in tabs) {
        await tester.tap(tab);
      }
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(chosen, PhoneTab.values);
      expect(made, 1);
    });

    testWidgets('on ${platform.name} a build without Kapy AI leaves its tab '
        'out', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpBar(
        tester,
        scale: 1,
        size: const Size(393, 852),
        showKapyAi: false,
      );
      expect(find.byKey(const ValueKey('bar-notes')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-folders')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-kapyAi')), findsNothing);
      expect(find.text('Kapy AI'), findsNothing);
    });
  }

  testWidgets('every tab and the + are at least 44 pt each way, on an SE at '
      '3.1× text', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpBar(tester, scale: 3.1, size: const Size(375, 667));
    expect(tester.takeException(), isNull);
    for (final key in ['bar-notes', 'bar-folders', 'bar-kapyAi', 'phone-new']) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
      expect(size.height, greaterThanOrEqualTo(44), reason: key);
    }
  });
}
