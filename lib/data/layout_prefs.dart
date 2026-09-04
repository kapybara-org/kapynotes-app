import 'dart:ui' show Locale, PlatformDispatcher, Size;

import 'package:flutter/foundation.dart';

import '../calc/format.dart';
import '../core/editor_font.dart';
import 'local_store.dart';
import 'time_zones.dart';

/// How the user wants grouped numbers written, including deferring to the
/// device.
enum NumberSystem { auto, international, indian }

extension NumberSystemCopy on NumberSystem {
  String get label => switch (this) {
    NumberSystem.auto => 'Match my region',
    NumberSystem.international => 'International',
    NumberSystem.indian => 'Indian',
  };

  String get description => switch (this) {
    NumberSystem.auto => 'Follow the number format your system uses',
    NumberSystem.international => 'Thousands, millions, billions',
    NumberSystem.indian => 'Thousands, lakh, crore',
  };

  /// The grouping this choice means for [locale]. Only [NumberSystem.auto]
  /// looks at the locale at all.
  DigitGrouping resolve(Locale locale) => switch (this) {
    NumberSystem.international => DigitGrouping.international,
    NumberSystem.indian => DigitGrouping.indian,
    NumberSystem.auto => _localeGrouping(locale),
  };
}

/// Regions that write in lakh and crore, plus the South Asian languages that
/// imply one when a locale carries no region at all.
const Set<String> _indianRegions = {'IN', 'PK', 'BD', 'NP', 'LK', 'BT'};
const Set<String> _indianLanguages = {
  'as',
  'bn',
  'gu',
  'hi',
  'kn',
  'ml',
  'mr',
  'ne',
  'or',
  'pa',
  'si',
  'ta',
  'te',
  'ur',
};

DigitGrouping _localeGrouping(Locale locale) {
  final region = locale.countryCode;
  if (region != null && region.isNotEmpty) {
    return _indianRegions.contains(region.toUpperCase())
        ? DigitGrouping.indian
        : DigitGrouping.international;
  }
  return _indianLanguages.contains(locale.languageCode.toLowerCase())
      ? DigitGrouping.indian
      : DigitGrouping.international;
}

/// User preferences that survive restarts: panel sizes, window geometry, the
/// handful of display options the settings dialog exposes, and how the app
/// behaves once its window is closed.
class LayoutPrefs extends ChangeNotifier {
  static const Size defaultWindowSize = Size(600, 630);
  static const Size minimumWindowSize = Size(520, 360);

  static const double minGutterWidth = 72;
  static const double maxGutterWidth = 480;
  static const double defaultGutterWidth = 190;

  static const double minSidebarWidth = 150;
  static const double maxSidebarWidth = 420;
  static const double defaultSidebarWidth = 260;

  static const String _gutterKey = 'gutter.v1';
  static const String _resultsVisibleKey = 'resultsVisible.v1';
  static const String _sidebarKey = 'sidebar.v1';
  static const String _sidebarVisibleKey = 'sidebarVisible.v1';
  static const String _windowWidthKey = 'windowWidth.v1';
  static const String _windowHeightKey = 'windowHeight.v1';
  static const String _dailySeparatorsKey = 'dailySeparators.v1';
  static const String _numberSystemKey = 'numberSystem.v1';
  static const String _writingFontKey = 'writingFont.v1';
  static const String _timeZoneKey = 'timeZone.v1';
  static const String _keepRunningKey = 'keepRunningInBackground.v1';

  final LocalStore _store;

  /// Where [NumberSystem.auto] reads the device's region from. Injectable so
  /// tests can resolve against a locale they choose.
  final Locale Function() _locale;

  double _gutterWidth = defaultGutterWidth;
  bool _resultsVisible = true;
  double _sidebarWidth = defaultSidebarWidth;
  bool _sidebarVisible = true;
  Size _windowSize = defaultWindowSize;
  bool _dailySeparatorsEnabled = true;
  NumberSystem _numberSystem = NumberSystem.auto;
  WritingFont _writingFont = WritingFont.handwritten;
  String? _timeZoneId;
  bool _keepRunningInBackground = false;

  LayoutPrefs(this._store, {Locale Function()? locale})
    : _locale = locale ?? (() => PlatformDispatcher.instance.locale);

  double get gutterWidth => _gutterWidth;
  bool get resultsVisible => _resultsVisible;
  double get sidebarWidth => _sidebarWidth;
  bool get sidebarVisible => _sidebarVisible;
  Size get windowSize => _windowSize;
  bool get dailySeparatorsEnabled => _dailySeparatorsEnabled;
  WritingFont get writingFont => _writingFont;
  String? get timeZoneId => _timeZoneId;

  /// Whether closing the window tucks the app into the tray instead of
  /// ending it. Off unless asked for: an app that will not go away when you
  /// close it is a decision the user gets to make, not one made for them.
  bool get keepRunningInBackground => _keepRunningInBackground;

  /// Converts a stored instant to the zone selected for note timestamps.
  DateTime displayTime(DateTime instant) =>
      AppTimeZones.convert(instant, _timeZoneId);

  /// The user's choice, which may be [NumberSystem.auto].
  NumberSystem get numberSystem => _numberSystem;

  /// That choice resolved against the device — what results are formatted in.
  DigitGrouping get digitGrouping => _numberSystem.resolve(_locale());

  /// The sample the settings dialog shows beside [system], resolved against
  /// the same locale results are formatted with.
  String exampleFor(NumberSystem system) =>
      ResultFormatter.sample(system.resolve(_locale()));

  void load() {
    _gutterWidth = _clampGutter(_readDouble(_gutterKey) ?? defaultGutterWidth);
    _resultsVisible = _store.read<bool>(_resultsVisibleKey) ?? true;
    _sidebarWidth = _clampSidebar(
      _readDouble(_sidebarKey) ?? defaultSidebarWidth,
    );
    _sidebarVisible = _store.read<bool>(_sidebarVisibleKey) ?? true;
    _windowSize = _clampWindowSize(
      Size(
        _readDouble(_windowWidthKey) ?? defaultWindowSize.width,
        _readDouble(_windowHeightKey) ?? defaultWindowSize.height,
      ),
    );
    _dailySeparatorsEnabled = _store.read<bool>(_dailySeparatorsKey) ?? true;
    _numberSystem = _readNumberSystem();
    _writingFont = _readWritingFont();
    _timeZoneId = AppTimeZones.normalize(_store.read<String>(_timeZoneKey));
    _keepRunningInBackground = _store.read<bool>(_keepRunningKey) ?? false;
    notifyListeners();
  }

  set gutterWidth(double value) {
    final clamped = _clampGutter(value);
    if (clamped == _gutterWidth) return;
    _gutterWidth = clamped;
    _store.put(_gutterKey, clamped);
    notifyListeners();
  }

  set resultsVisible(bool value) {
    if (value == _resultsVisible) return;
    _resultsVisible = value;
    _store.put(_resultsVisibleKey, value);
    notifyListeners();
  }

  set sidebarWidth(double value) {
    final clamped = _clampSidebar(value);
    if (clamped == _sidebarWidth) return;
    _sidebarWidth = clamped;
    _store.put(_sidebarKey, clamped);
    notifyListeners();
  }

  set windowSize(Size value) {
    final clamped = _clampWindowSize(value);
    if (clamped == _windowSize) return;
    _windowSize = clamped;
    _store.put(_windowWidthKey, clamped.width);
    _store.put(_windowHeightKey, clamped.height);
    notifyListeners();
  }

  set dailySeparatorsEnabled(bool value) {
    if (value == _dailySeparatorsEnabled) return;
    _dailySeparatorsEnabled = value;
    _store.put(_dailySeparatorsKey, value);
    notifyListeners();
  }

  set numberSystem(NumberSystem value) {
    if (value == _numberSystem) return;
    _numberSystem = value;
    _store.put(_numberSystemKey, value.name);
    notifyListeners();
  }

  set writingFont(WritingFont value) {
    if (value == _writingFont) return;
    _writingFont = value;
    _store.put(_writingFontKey, value.name);
    notifyListeners();
  }

  set timeZoneId(String? value) {
    final normalized = AppTimeZones.normalize(value);
    if (normalized == _timeZoneId) return;
    _timeZoneId = normalized;
    // LocalStore has no removal operation. An empty value is the durable
    // representation of following the device time zone.
    _store.put(_timeZoneKey, normalized ?? '');
    notifyListeners();
  }

  set keepRunningInBackground(bool value) {
    if (value == _keepRunningInBackground) return;
    _keepRunningInBackground = value;
    _store.put(_keepRunningKey, value);
    notifyListeners();
  }

  void resetGutterWidth() => gutterWidth = defaultGutterWidth;

  void resetPanelWidths() {
    if (_gutterWidth == defaultGutterWidth &&
        _sidebarWidth == defaultSidebarWidth &&
        _resultsVisible) {
      return;
    }
    _gutterWidth = defaultGutterWidth;
    _sidebarWidth = defaultSidebarWidth;
    _resultsVisible = true;
    _store.put(_gutterKey, _gutterWidth);
    _store.put(_sidebarKey, _sidebarWidth);
    _store.put(_resultsVisibleKey, _resultsVisible);
    notifyListeners();
  }

  void toggleSidebar() {
    _sidebarVisible = !_sidebarVisible;
    _store.put(_sidebarVisibleKey, _sidebarVisible);
    notifyListeners();
  }

  /// An unrecognised stored name means a downgrade or a hand-edited file;
  /// deferring to the device is the safe reading either way.
  NumberSystem _readNumberSystem() {
    final stored = _store.read<String>(_numberSystemKey);
    return NumberSystem.values.firstWhere(
      (system) => system.name == stored,
      orElse: () => NumberSystem.auto,
    );
  }

  /// New installs open with the paper-like face. Unknown values can come from
  /// a newer app version, so they also fall back to that safe default.
  WritingFont _readWritingFont() {
    final stored = _store.read<String>(_writingFontKey);
    return WritingFont.values.firstWhere(
      (font) => font.name == stored,
      orElse: () => WritingFont.handwritten,
    );
  }

  double? _readDouble(String key) {
    final value = _store.data[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static double _clampGutter(double value) => value.isFinite
      ? value.clamp(minGutterWidth, maxGutterWidth)
      : defaultGutterWidth;

  static double _clampSidebar(double value) => value.isFinite
      ? value.clamp(minSidebarWidth, maxSidebarWidth)
      : defaultSidebarWidth;

  static Size _clampWindowSize(Size value) {
    if (!value.width.isFinite || !value.height.isFinite) {
      return defaultWindowSize;
    }
    return Size(
      value.width.clamp(minimumWindowSize.width, 2400),
      value.height.clamp(minimumWindowSize.height, 1800),
    );
  }
}
