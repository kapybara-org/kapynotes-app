import 'dart:ui' show FontVariation;

import 'platform.dart';

/// The typeface used on the writing surface.
///
/// App chrome deliberately keeps the system UI face for clarity. This choice
/// only changes the note itself, where it can add personality without making
/// settings and controls harder to scan.
enum WritingFont { mixed, handwritten, clean, monospace }

extension WritingFontDetails on WritingFont {
  String get label => switch (this) {
    WritingFont.mixed => 'Mixed',
    WritingFont.handwritten => 'Handwritten',
    WritingFont.clean => 'Clean',
    WritingFont.monospace => 'Monospace',
  };

  String get description => switch (this) {
    WritingFont.mixed => 'Handwritten headings with tidy monospaced text',
    WritingFont.handwritten => 'Subtle pen strokes with a calm baseline',
    WritingFont.clean => 'Simple and calm for longer notes',
    WritingFont.monospace => 'Fixed-width characters for dense calculations',
  };

  String get preview => switch (this) {
    WritingFont.mixed => 'Ideas 42',
    WritingFont.handwritten => 'Ideas 42',
    WritingFont.clean => 'Ideas 42',
    WritingFont.monospace => 'Ideas 42',
  };

  String? get fontFamily => switch (this) {
    WritingFont.mixed => AppPlatform.monoFontFallback.first,
    WritingFont.handwritten => 'Shantell Sans',
    WritingFont.clean => null,
    WritingFont.monospace => AppPlatform.monoFontFallback.first,
  };

  List<String>? get fontFamilyFallback => switch (this) {
    WritingFont.mixed => AppPlatform.monoFontFallback,
    WritingFont.handwritten => const [
      'Roboto',
      'Noto Sans',
      '.AppleSystemUIFont',
      'sans-serif',
    ],
    WritingFont.clean => null,
    WritingFont.monospace => AppPlatform.monoFontFallback,
  };

  /// Shantell Sans is intentionally kept close to a clean sans: a hint of
  /// hand variation, with no artificial baseline bounce.
  List<FontVariation>? get fontVariations => switch (this) {
    WritingFont.handwritten => const [
      FontVariation('INFM', 16),
      FontVariation('BNCE', 0),
      FontVariation('SPAC', 0),
    ],
    WritingFont.mixed || WritingFont.clean || WritingFont.monospace => null,
  };

  /// Handwriting faces need a little more size to carry the same visual weight
  /// as a UI sans or a compact mono face.
  double get editorSize => switch (this) {
    WritingFont.mixed => 14.5,
    WritingFont.handwritten => 16.5,
    WritingFont.clean => 15.5,
    WritingFont.monospace => 14.5,
  };
}
