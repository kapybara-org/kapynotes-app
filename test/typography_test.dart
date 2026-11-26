import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/font_licenses.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

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

  test('the title and headings are not lightened in dark', () {
    for (final font in WritingFont.values) {
      final base = EditorMetrics.textStyle(darkInk, font);
      final title = noteTitleStyle(base, writingFont: font);
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

  test('the default writing font titles a note in the interface face', () {
    final base = EditorMetrics.textStyle(lightInk, WritingFont.clean);
    final title = noteTitleStyle(base, writingFont: WritingFont.clean);
    expect(title.fontFamily, AppFonts.ui);
    expect(title.fontWeight, FontWeight.w600);
    expect(title.fontFamilyFallback!.first, AppFonts.uiFallback.first);
    expect(title.fontSize, 26);
    expect(title.fontSize! / base.fontSize!, inInclusiveRange(1.5, 1.8));
  });

  test("a writing font the person picked titles the note too", () {
    for (final (font, family) in [
      (WritingFont.handwritten, WritingFont.handwritten.fontFamily),
      (WritingFont.mixed, WritingFont.handwritten.fontFamily),
      (WritingFont.monospace, WritingFont.monospace.fontFamily),
    ]) {
      final base = EditorMetrics.textStyle(lightInk, font);
      final title = noteTitleStyle(base, writingFont: font);
      expect(title.fontFamily, family, reason: font.name);
      expect(title.fontWeight, EditorMetrics.titleWeight, reason: font.name);
    }
  });

  test('every heading stays under the title', () {
    for (final level in [1, 2, 3, 4]) {
      expect(
        EditorMetrics.headingFontSize(level),
        lessThan(EditorMetrics.titleFontSize),
      );
    }
  });

  testWidgets('a Greek title falls back to the writing face, not to tofu', (
    tester,
  ) async {
    final base = EditorMetrics.textStyle(lightInk, WritingFont.clean);
    final title = noteTitleStyle(base, writingFont: WritingFont.clean);
    final writing = title.copyWith(
      fontFamily: base.fontFamily,
      fontFamilyFallback: base.fontFamilyFallback,
    );
    double width(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    // No spaces: the fallback face has those, and draws them itself.
    const greek = 'Λισαβόνα';
    expect(
      width(greek, title),
      isNot(greek.length * title.fontSize!),
      reason: 'the test font draws every glyph a square em wide',
    );
  });

  test('Inter and Shantell stay on the licences page, and the retired faces go', () async {
    final entries = await fontLicenseEntries().toList();
    final names = entries.expand((e) => e.packages).toList();
    expect(names, containsAll(['Inter', 'Shantell Sans', 'Geist Mono']));
    expect(names, isNot(contains('Figtree')));
    expect(names, isNot(contains('Newsreader')));
    final inter = entries.where((e) => e.packages.contains('Inter'));
    expect(
      inter.first.paragraphs.map((p) => p.text).join(' '),
      contains('SIL Open Font License'),
    );
  });

  test('the interface type scale stays on whole and half points', () {
    for (final size in [
      AppTypeScale.micro,
      AppTypeScale.keycap,
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
      expect(size * 2 % 1, 0);
    }
  });
}
