import 'platform.dart';

/// The typeface used on the writing surface.
///
/// App chrome deliberately keeps the system UI face for clarity. This choice
/// only changes the note itself, where it can add personality without making
/// settings and controls harder to scan.
enum WritingFont { handwritten, clean, monospace }

extension WritingFontDetails on WritingFont {
  String get label => switch (this) {
    WritingFont.handwritten => 'Handwritten',
    WritingFont.clean => 'Clean',
    WritingFont.monospace => 'Monospace',
  };

  String get description => switch (this) {
    WritingFont.handwritten => 'Natural pen strokes, made for the page',
    WritingFont.clean => 'Simple and calm for longer notes',
    WritingFont.monospace => 'Fixed-width characters for dense calculations',
  };

  String get preview => switch (this) {
    WritingFont.handwritten => 'Ideas 42',
    WritingFont.clean => 'Ideas 42',
    WritingFont.monospace => 'Ideas 42',
  };

  String? get fontFamily => switch (this) {
    WritingFont.handwritten => 'Kalam',
    WritingFont.clean => null,
    WritingFont.monospace => AppPlatform.monoFontFallback.first,
  };

  List<String>? get fontFamilyFallback => switch (this) {
    WritingFont.handwritten => const [
      'Roboto',
      'Noto Sans',
      '.AppleSystemUIFont',
      'sans-serif',
    ],
    WritingFont.clean => null,
    WritingFont.monospace => AppPlatform.monoFontFallback,
  };

  /// Handwriting faces need a little more size to carry the same visual weight
  /// as a UI sans or a compact mono face.
  double get editorSize => switch (this) {
    WritingFont.handwritten => 17.5,
    WritingFont.clean => 15.5,
    WritingFont.monospace => 14.5,
  };
}
