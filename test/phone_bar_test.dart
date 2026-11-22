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
          space: LibrarySpace.notes,
          onSelected: (_) {},
          onSettingsPressed: () {},
          createLabel: 'New note',
          onCreate: () {},
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
        // Android's bar is the platform's own and sizes its labels itself.
        if (platform != TargetPlatform.iOS) return;
        for (final label in ['Notes', 'Tasks', 'Drawings', 'Settings']) {
          final text = find.text(label);
          if (text.evaluate().isEmpty) continue;
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
                  space: LibrarySpace.notes,
                  onSelected: (_) {},
                  onSettingsPressed: () {},
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
    expect(tab('drawings'), isNull);
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
    for (final name in ['notes', 'tasks', 'drawings', 'settings']) {
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

  testWidgets("Android's bar keeps Material's shape on the crisp surface, and "
      'the open tab is the 7% fill', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpBar(tester, scale: 1, size: const Size(393, 852));
    const palette = KapyTheme.darkPalette;
    final bar = tester.widget<NavigationBar>(
      find.byKey(const ValueKey('phone-bar')),
    );
    expect(bar.backgroundColor, palette.railBackground);
    expect(bar.backgroundColor, palette.sidebarBackground);
    expect(bar.indicatorColor, palette.fillSelected);
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
        icon('drawings', KapyIcons.penRounded).color,
        palette.textTertiary,
      );
      expect(
        icon('settings', KapyIcons.settingsGearOutlined).color,
        palette.textTertiary,
      );
    });
  }
}
