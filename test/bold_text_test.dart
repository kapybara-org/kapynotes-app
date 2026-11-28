import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/join/joining_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

/// Ink coverage of a chrome style drawn at [weight], with Bold Text as given.
///
/// The style is built after the setting changes, because the ladder reads it
/// when the style is made.
Future<int> inkOf(
  WidgetTester tester,
  double weight, {
  required bool boldText,
}) async {
  final dispatcher = tester.binding.platformDispatcher;
  dispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(
    boldText: boldText,
  );
  addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
  final style = chromeStyle(
    size: 16,
    line: 24,
    weight: weight,
    color: const Color(0xFF000000),
  );
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: const ValueKey('ink'),
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text('Illuminate', style: style),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('ink')),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  final data = bytes!.buffer.asUint8List();
  var ink = 0;
  for (var i = 0; i < data.length; i += 4) {
    if (data[i + 3] > 128 && data[i] < 200) ink++;
  }
  return ink;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('Bold Text thickens every step of the ladder', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 80));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final weight in [
      AppWeight.regular,
      AppWeight.regular,
      AppWeight.regular,
      AppWeight.regular,
      AppWeight.semibold,
    ]) {
      final gentle = await inkOf(tester, weight, boldText: false);
      final bold = await inkOf(tester, weight, boldText: true);
      expect(bold, greaterThan(gentle), reason: 'weight $weight stays bold');
    }
  });

  testWidgets('Bold Text thickens a label that sets its own step', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 80));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dispatcher = tester.binding.platformDispatcher;
    addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);

    Future<int> labelInk({required bool boldText}) async {
      dispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(
        boldText: boldText,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: const Material(
            type: MaterialType.transparency,
            child: Center(
              child: RepaintBoundary(
                key: ValueKey('label'),
                child: JoinLabel('Waiting to join'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('label')),
      );
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        return image.toByteData(format: ui.ImageByteFormat.rawRgba);
      });
      final data = bytes!.buffer.asUint8List();
      var ink = 0;
      for (var i = 0; i < data.length; i += 4) {
        if (data[i + 3] > 128) ink++;
      }
      return ink;
    }

    final gentle = await labelInk(boldText: false);
    final bold = await labelInk(boldText: true);
    expect(bold, greaterThan(gentle));
  });
}
