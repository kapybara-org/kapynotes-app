import 'package:material_ui/material_ui.dart';

/// Light, dark, or whatever the machine is set to.
enum AppearanceMode { system, light, dark }

extension AppearanceModeDetails on AppearanceMode {
  String get label => switch (this) {
    AppearanceMode.system => 'System',
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

/// One of the six looks the app can wear (Themes r2, p-N-0). Each has a dark
/// and a light side, except Midnight, which is dark only and uses Riverbank
/// light by day. The choice belongs to the device and is not synced: a phone
/// in bed and a desk by a window want different things.
enum AppTheme { riverbank, graphite, midnight, dusk, lamplight, fjord }

extension AppThemeDetails on AppTheme {
  String get label => switch (this) {
    AppTheme.riverbank => 'Riverbank',
    AppTheme.graphite => 'Graphite',
    AppTheme.midnight => 'Midnight',
    AppTheme.dusk => 'Dusk',
    AppTheme.lamplight => 'Lamplight',
    AppTheme.fjord => 'Fjord',
  };

  /// The line under its name in the picker.
  String get description => switch (this) {
    AppTheme.riverbank => 'Warm paper and sage',
    AppTheme.graphite => 'Pure greys, no tint at all',
    AppTheme.midnight => 'True black for OLED screens',
    AppTheme.dusk => 'Dim indigo, for reading in bed',
    AppTheme.lamplight => 'Amber with no blue, for late night',
    AppTheme.fjord => 'Cool sea-glass, crisp by day',
  };

  /// The word beside its name, where there is one to say.
  String? get badge => switch (this) {
    AppTheme.riverbank => 'Default',
    AppTheme.midnight => 'Dark only',
    AppTheme.fjord => 'New',
    _ => null,
  };
}

/// "At night, use a different theme": from [from] until [to], the window
/// wears [theme]'s dark side whatever the mode, and goes back by itself in
/// the morning.
///
/// Set hours only. The OS already turns light into dark at sunset, so this
/// is about a different dark late at night, which is a matter of the clock.
@immutable
class NightTheme {
  const NightTheme({
    this.enabled = false,
    this.theme = AppTheme.lamplight,
    this.from = 22 * 60,
    this.to = 6 * 60,
  });

  final bool enabled;
  final AppTheme theme;

  /// Minutes after midnight, on the clock the app shows.
  final int from;
  final int to;

  /// Whether [wallClock] falls in the night: from [from] up to but not
  /// including [to], across midnight when [to] comes first. The same two
  /// times mean no night at all.
  bool covers(DateTime wallClock) {
    final minute = wallClock.hour * 60 + wallClock.minute;
    return from <= to
        ? minute >= from && minute < to
        : minute >= from || minute < to;
  }

  /// Whether the night theme is on screen at [wallClock].
  bool activeAt(DateTime wallClock) => enabled && covers(wallClock);

  /// A minute after midnight as the picker writes it: 22:00.
  static String clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';

  NightTheme copyWith({bool? enabled, AppTheme? theme, int? from, int? to}) =>
      NightTheme(
        enabled: enabled ?? this.enabled,
        theme: theme ?? this.theme,
        from: from ?? this.from,
        to: to ?? this.to,
      );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'theme': theme.name,
    'from': from,
    'to': to,
  };

  /// What was saved, with anything missing or unknown at its default.
  factory NightTheme.fromJson(Object? json) {
    if (json is! Map) return const NightTheme();
    int minute(Object? value, int fallback) =>
        value is int && value >= 0 && value < 24 * 60 ? value : fallback;
    return NightTheme(
      enabled: json['enabled'] == true,
      theme: AppTheme.values.asNameMap()[json['theme']] ?? AppTheme.lamplight,
      from: minute(json['from'], 22 * 60),
      to: minute(json['to'], 6 * 60),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NightTheme &&
      other.enabled == enabled &&
      other.theme == theme &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(enabled, theme, from, to);
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
