import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final darkInk = KapyTheme.darkPalette.textPrimary;
  final lightInk = KapyTheme.lightPalette.textPrimary;

  bool lightened(TextStyle style) =>
      style.fontVariations?.any((v) => v.axis == 'wght') ?? false;

  test('writing is set at the regular weight in whole pixels', () {
    for (final font in WritingFont.values) {
      final style = EditorMetrics.textStyle(lightInk, font);
      expect(style.fontWeight, FontWeight.w400, reason: font.name);
      expect(style.fontSize! % 1, 0, reason: font.name);
    }
    expect(EditorMetrics.textStyle(lightInk, WritingFont.clean).fontSize, 16);
  });

  test('only light ink on dark paper is drawn a step lighter', () {
    final dark = EditorMetrics.textStyle(darkInk, WritingFont.clean);
    expect(dark.fontVariations, contains(const FontVariation('wght', 370)));
    expect(
      lightened(EditorMetrics.textStyle(lightInk, WritingFont.clean)),
      isFalse,
    );
  });

  test('a face keeps its own variations under the lighter dark weight', () {
    final dark = EditorMetrics.textStyle(darkInk, WritingFont.handwritten);
    for (final own in WritingFont.handwritten.faceVariations) {
      expect(dark.fontVariations, contains(own));
    }
  });

  test('the title and headings stay at 600 in dark', () {
    for (final font in WritingFont.values) {
      final base = EditorMetrics.textStyle(darkInk, font);
      final title = noteTitleStyle(base, writingFont: font);
      expect(title.fontWeight, FontWeight.w600, reason: font.name);
      expect(lightened(title), isFalse, reason: font.name);
      for (final level in [1, 2, 3, 4]) {
        final heading = markdownHeadingStyle(base, level, writingFont: font);
        expect(
          heading.fontWeight,
          FontWeight.w600,
          reason: '${font.name} h$level',
        );
        expect(lightened(heading), isFalse, reason: '${font.name} h$level');
      }
    }
  });

  test('the interface type scale has no half pixels', () {
    for (final size in [
      AppTypeScale.micro,
      AppTypeScale.keycap,
      AppTypeScale.railLabel,
      AppTypeScale.badge,
      AppTypeScale.caption,
      AppTypeScale.small,
      AppTypeScale.body,
      AppTypeScale.result,
      AppTypeScale.control,
      AppTypeScale.title,
      AppTypeScale.heading,
      AppTypeScale.spaceTitle,
      AppTypeScale.wordmark,
      AppTypeScale.display,
    ]) {
      expect(size % 1, 0);
    }
  });
}
