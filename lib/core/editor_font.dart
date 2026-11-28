import 'dart:ui' show FontVariation;

import 'theme.dart';

/// The typeface used on the writing surface.
///
/// App chrome keeps the interface face, Geist, for clarity. This choice only
/// changes the note itself, where it can add personality without making
/// settings and controls harder to scan.
enum WritingFont { mixed, handwritten, clean, monospace, pixel }

extension WritingFontDetails on WritingFont {
  String get label => switch (this) {
    WritingFont.mixed => 'Mixed',
    WritingFont.handwritten => 'Handwritten',
    WritingFont.clean => 'Clean',
    WritingFont.monospace => 'Monospace',
    WritingFont.pixel => 'Pixel',
  };

  String get description => switch (this) {
    WritingFont.mixed => 'Handwritten titles and headings with clean text',
    WritingFont.handwritten => 'Your whole note in handwriting',
    WritingFont.clean => 'Comfortable text for longer notes',
    WritingFont.monospace => 'Every letter the same width, so numbers line up',
    WritingFont.pixel => 'Blocky letters, like an old computer screen',
  };

  String? get fontFamily => switch (this) {
    WritingFont.mixed => AppFonts.ui,
    WritingFont.handwritten => AppFonts.hand,
    WritingFont.clean => AppFonts.ui,
    WritingFont.monospace => AppFonts.mono,
    WritingFont.pixel => AppFonts.pixel,
  };

  List<String>? get fontFamilyFallback => switch (this) {
    WritingFont.mixed => AppFonts.uiFallback,
    WritingFont.handwritten => const [
      'Roboto',
      'Noto Sans',
      '.AppleSystemUIFont',
      'sans-serif',
    ],
    WritingFont.clean => AppFonts.uiFallback,
    WritingFont.monospace => AppFonts.monoFallback,
    WritingFont.pixel => [AppFonts.ui, ...AppFonts.uiFallback],
  };

  /// Shantell Sans is intentionally kept close to a clean sans: a hint of
  /// hand variation, with no artificial baseline bounce.
  ///
  /// The bundled font is an instance with exactly these three axes baked in
  /// (see assets/fonts/README.md), which halves it; only the weight axis is
  /// left variable. The values stay here so that the look is stated in one
  /// place, and so that the full font, dropped in, would render the same.
  List<FontVariation>? get fontVariations => switch (this) {
    WritingFont.handwritten => const [
      FontVariation('INFM', 16),
      FontVariation('BNCE', 0),
      FontVariation('SPAC', 0),
    ],
    WritingFont.mixed ||
    WritingFont.clean ||
    WritingFont.monospace ||
    WritingFont.pixel => null,
  };

  List<FontVariation> get faceVariations => fontVariations ?? const [];

  /// Each face at the size that reads like Clean's 16: a compact mono face a
  /// step smaller, and Geist Pixel, whose letters are small for their size,
  /// two steps larger.
  double get editorSize => switch (this) {
    WritingFont.mixed => 16,
    WritingFont.handwritten => 16,
    WritingFont.clean => 16,
    WritingFont.monospace => 14,
    WritingFont.pixel => 18,
  };
}
