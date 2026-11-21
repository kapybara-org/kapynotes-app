import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
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
