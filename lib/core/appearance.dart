import 'package:material_ui/material_ui.dart';

/// Light, dark, or whatever the machine is set to.
enum AppearanceMode { system, light, dark }

extension AppearanceModeDetails on AppearanceMode {
  String get label => switch (this) {
    AppearanceMode.system => 'Match the system',
    AppearanceMode.light => 'Light',
    AppearanceMode.dark => 'Dark',
  };

  String get description => switch (this) {
    AppearanceMode.system => 'Follow your device setting',
    AppearanceMode.light => 'Always use the light theme',
    AppearanceMode.dark => 'Always use the dark theme',
  };

  ThemeMode get themeMode => switch (this) {
    AppearanceMode.system => ThemeMode.system,
    AppearanceMode.light => ThemeMode.light,
    AppearanceMode.dark => ThemeMode.dark,
  };
}

/// The reader's preferred size for text throughout the app.
///
/// This is deliberately a multiplier over the device's accessibility scale,
/// not a replacement for it. A person who has already asked the operating
/// system for larger text keeps that request, and can make Kapy Notes larger
/// still if this is the app they spend the most time reading.
enum AppTextSize { small, standard, large }

extension AppTextSizeDetails on AppTextSize {
  String get label => switch (this) {
    AppTextSize.small => 'Small',
    AppTextSize.standard => 'Default',
    AppTextSize.large => 'Large',
  };

  String get description => switch (this) {
    AppTextSize.small => 'Smaller text throughout Kapy Notes',
    AppTextSize.standard => 'Use the standard Kapy Notes text size',
    AppTextSize.large => 'Larger text throughout Kapy Notes',
  };

  double get scaleFactor => switch (this) {
    AppTextSize.small => 0.9,
    AppTextSize.standard => 1,
    AppTextSize.large => 1.2,
  };

  /// Adds this preference to [device] without flattening a nonlinear system
  /// text scale into one approximate number.
  TextScaler applyTo(TextScaler device) => scaleFactor == 1
      ? device
      : _PreferredTextScaler(device: device, factor: scaleFactor);
}

final class _PreferredTextScaler extends TextScaler {
  const _PreferredTextScaler({required this.device, required this.factor});

  final TextScaler device;
  final double factor;

  @override
  double scale(double fontSize) => device.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(1);

  @override
  bool operator ==(Object other) =>
      other is _PreferredTextScaler &&
      other.device == device &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(device, factor);
}

/// The sheet behind the writing.
///
/// Only the light theme has paper to speak of: the fibres are a warm tint
/// that reads as stock on a pale page and as dirt on a dark one, and the
/// ruling is drawn in the same ink. [PaperStyle.notepad] therefore looks like
/// [PaperStyle.plain] in the dark, which is what it always did.
enum PaperStyle { plain, notepad, ruled }

extension PaperStyleDetails on PaperStyle {
  String get label => switch (this) {
    PaperStyle.plain => 'Plain',
    PaperStyle.notepad => 'Notepad',
    PaperStyle.ruled => 'Ruled',
  };

  String get description => switch (this) {
    PaperStyle.plain => 'Clean background with no texture',
    PaperStyle.notepad => 'Warm paper texture with softer colors',
    PaperStyle.ruled => 'Faint guide lines under your writing',
  };
}
