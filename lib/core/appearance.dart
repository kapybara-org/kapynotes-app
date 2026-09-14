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
