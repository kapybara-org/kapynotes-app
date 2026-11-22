import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the ladder uses the in-between steps the variable faces can draw', () {
    expect(AppWeight.axisOf(FontWeight.w400), 400);
    expect(AppWeight.axisOf(FontWeight.w500), 500);
    expect(AppWeight.axisOf(FontWeight.w600), 520);
    expect(AppWeight.axisOf(FontWeight.w700), 600);
    expect(AppWeight.selected, 460);
    expect(AppWeight.axisOf(FontWeight.w300), 300);

    final style = chromeStyle(
      size: 13,
      line: 20,
      weight: AppWeight.rowTitle,
      color: const Color(0xFF2A2620),
      tabular: true,
    );
    expect(style.fontVariations, contains(const FontVariation('wght', 500)));
    expect(style.fontFeatures, contains(FontFeature.tabularFigures()));
    expect(style.letterSpacing, 0);
    expect(style.fontFamily, AppFonts.ui);
  });

  test('font and wght give a style its step, and Bold Text raises both', () {
    expect(AppWeight.font(AppWeight.section), FontWeight.w600);
    expect(AppWeight.wght(AppWeight.section), [
      const FontVariation('wght', 520),
    ]);
    expect(
      AppWeight.wght(
        AppWeight.button,
        extra: const [FontVariation('INFM', 0), FontVariation('wght', 300)],
      ),
      [const FontVariation('INFM', 0), const FontVariation('wght', 500)],
    );

    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(binding.platformDispatcher.clearAccessibilityFeaturesTestValue);
    expect(AppWeight.font(AppWeight.body), FontWeight.w700);
    expect(AppWeight.wght(AppWeight.body), [const FontVariation('wght', 600)]);
    expect(AppWeight.font(AppWeight.section), FontWeight.w700);
    expect(AppWeight.wght(AppWeight.section), [
      const FontVariation('wght', 700),
    ]);
  });
}
