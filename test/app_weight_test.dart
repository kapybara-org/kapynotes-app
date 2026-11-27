import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the interface has two weights, and anything under 400 is left alone',
    () {
      expect(AppWeight.regular, 400);
      expect(AppWeight.semibold, 600);
      expect(AppWeight.axisOf(FontWeight.w300), 300);
      expect(AppWeight.axisOf(FontWeight.w400), 400);
      expect(AppWeight.axisOf(FontWeight.w500), 400);
      expect(AppWeight.axisOf(FontWeight.w600), 600);
      expect(AppWeight.axisOf(FontWeight.w700), 600);

      final style = chromeStyle(
        size: 13,
        line: 20,
        weight: AppWeight.regular,
        color: const Color(0xFF2B2B2B),
        tabular: true,
      );
      expect(style.fontVariations, contains(const FontVariation('wght', 400)));
      expect(style.fontFeatures, contains(FontFeature.tabularFigures()));
      expect(style.letterSpacing, 0);
      expect(style.fontFamily, AppFonts.ui);
    },
  );

  test('font and wght give a style its step, and Bold Text raises both', () {
    expect(AppWeight.font(AppWeight.regular), FontWeight.w400);
    expect(AppWeight.wght(AppWeight.regular), [
      const FontVariation('wght', 400),
    ]);
    expect(AppWeight.font(AppWeight.semibold), FontWeight.w600);
    expect(
      AppWeight.wght(
        AppWeight.regular,
        extra: const [FontVariation('INFM', 0), FontVariation('wght', 300)],
      ),
      [const FontVariation('INFM', 0), const FontVariation('wght', 400)],
    );

    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(binding.platformDispatcher.clearAccessibilityFeaturesTestValue);
    expect(AppWeight.font(AppWeight.regular), FontWeight.w600);
    expect(AppWeight.wght(AppWeight.regular), [
      const FontVariation('wght', 600),
    ]);
    expect(AppWeight.font(AppWeight.semibold), FontWeight.w700);
    expect(AppWeight.wght(AppWeight.semibold), [
      const FontVariation('wght', 700),
    ]);
  });

  test("the text theme's styles sit on regular, Bold Text off and on", () {
    final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
    addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
    for (final boldText in [false, true]) {
      dispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(
        boldText: boldText,
      );
      for (final theme in [KapyTheme.light(), KapyTheme.dark()]) {
        final text = theme.textTheme;
        final styles = <String, TextStyle?>{
          'displayLarge': text.displayLarge,
          'displayMedium': text.displayMedium,
          'displaySmall': text.displaySmall,
          'headlineLarge': text.headlineLarge,
          'headlineMedium': text.headlineMedium,
          'headlineSmall': text.headlineSmall,
          'titleLarge': text.titleLarge,
          'titleMedium': text.titleMedium,
          'titleSmall': text.titleSmall,
          'bodyLarge': text.bodyLarge,
          'bodyMedium': text.bodyMedium,
          'bodySmall': text.bodySmall,
          'labelLarge': text.labelLarge,
          'labelMedium': text.labelMedium,
          'labelSmall': text.labelSmall,
        };
        for (final MapEntry(key: name, value: style) in styles.entries) {
          if (style == null) continue;
          final reason = '$name, ${theme.brightness.name}, Bold Text $boldText';
          expect(
            style.fontWeight,
            AppWeight.font(AppWeight.regular),
            reason: reason,
          );
          expect(
            style.fontVariations,
            AppWeight.wght(AppWeight.regular),
            reason: reason,
          );
        }
      }
    }
  });
}
