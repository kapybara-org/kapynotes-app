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
    expect(AppWeight.regular, 460);
    expect(AppWeight.axisOf(FontWeight.w300), 300);

    final style = chromeStyle(
      size: 13,
      line: 20,
      weight: AppWeight.regular,
      color: const Color(0xFF2A2620),
      tabular: true,
    );
    expect(style.fontVariations, contains(const FontVariation('wght', 500)));
    expect(style.fontFeatures, contains(FontFeature.tabularFigures()));
    expect(style.letterSpacing, 0);
    expect(style.fontFamily, AppFonts.ui);
  });

  test('font and wght give a style its step, and Bold Text raises both', () {
    expect(AppWeight.font(AppWeight.regular), FontWeight.w600);
    expect(AppWeight.wght(AppWeight.regular), [
      const FontVariation('wght', 520),
    ]);
    expect(
      AppWeight.wght(
        AppWeight.regular,
        extra: const [FontVariation('INFM', 0), FontVariation('wght', 300)],
      ),
      [const FontVariation('INFM', 0), const FontVariation('wght', 500)],
    );

    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(binding.platformDispatcher.clearAccessibilityFeaturesTestValue);
    expect(AppWeight.font(AppWeight.regular), FontWeight.w700);
    expect(AppWeight.wght(AppWeight.regular), [const FontVariation('wght', 600)]);
    expect(AppWeight.font(AppWeight.regular), FontWeight.w700);
    expect(AppWeight.wght(AppWeight.regular), [
      const FontVariation('wght', 700),
    ]);
  });

  test("the text theme's styles sit on the ladder, Bold Text off and on", () {
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
          // The display cut stays under 400, off the ladder (axisOf).
          if (name.startsWith('display')) {
            expect(style.fontWeight, FontWeight.w300, reason: reason);
            expect(style.fontVariations, isNull, reason: reason);
            continue;
          }
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
