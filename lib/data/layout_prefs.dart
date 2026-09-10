import 'dart:ui' show Locale, PlatformDispatcher, Size;

import 'package:flutter/foundation.dart';

import '../calc/format.dart';
import '../core/appearance.dart';
import '../core/editor_font.dart';
import '../core/platform.dart';
import 'daily_separator.dart';
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
  static const String _windowWidthKey = 'windowWidth.v1';
  static const String _windowHeightKey = 'windowHeight.v1';
  static const String _readyToTypeOnOpenKey = 'readyToTypeOnOpen.v1';
  static const String _dailySeparatorsKey = 'dailySeparators.v1';
  static const String _spellCheckKey = 'spellCheck.v1';
  static const String _numberSystemKey = 'numberSystem.v1';
  static const String _writingFontKey = 'writingFont.v1';
  static const String _transparencyKey = 'transparencyEnabled.v1';
  static const String _transparencyAmountKey = 'transparencyAmount.v1';
  static const String _timeZoneKey = 'timeZone.v1';
  static const String _keepRunningKey = 'keepRunningInBackground.v1';
  static const String _alwaysOnTopKey = 'alwaysOnTop.v1';
  static const String _loginItemDefaultKey = 'loginItemDefaulted.v1';
  static const String _lastOpenedNoteKey = 'selectedNote.v1';
  static const String _caretKey = 'caret.v1';
  static const String _appearanceKey = 'appearance.v1';
  static const String _paperKey = 'paper.v1';
  static const String _defaultNoteKey = 'defaultNote.v1';

  final LocalStore _store;

  /// Where [NumberSystem.auto] reads the device's region from. Injectable so
  /// tests can resolve against a locale they choose.
  final Locale Function() _locale;

  double _gutterWidth = defaultGutterWidth;
  bool _resultsVisible = true;
  double _sidebarWidth = defaultSidebarWidth;
  bool _sidebarVisible = false;
  Size _windowSize = defaultWindowSize;
  bool _readyToTypeOnOpen = true;
  bool _dailySeparatorsEnabled = true;
  bool _spellCheckEnabled = true;
  NumberSystem _numberSystem = NumberSystem.auto;
  WritingFont _writingFont = WritingFont.handwritten;
  final ValueNotifier<AppearanceMode> _appearance = ValueNotifier(
    AppearanceMode.system,
  );
  PaperStyle _paperStyle = PaperStyle.notepad;
  final ValueNotifier<bool> _transparencyEnabled = ValueNotifier(false);
  final ValueNotifier<double> _transparencyAmount = ValueNotifier(
    defaultTransparencyAmount,
  );
  String? _timeZoneId;
  bool _keepRunningInBackground = false;
  bool _loginItemDefaultApplied = false;
  bool _alwaysOnTop = false;
  String? _lastOpenedNoteId;
  String? _defaultNoteId;
  final Map<String, ({int offset, DateTime at})> _carets = {};

  LayoutPrefs(this._store, {Locale Function()? locale})
    : _locale = locale ?? (() => PlatformDispatcher.instance.locale);

  double get gutterWidth => _gutterWidth;
  bool get resultsVisible => _resultsVisible;
  double get sidebarWidth => _sidebarWidth;
  bool get sidebarVisible => _sidebarVisible;
  Size get windowSize => _windowSize;
  bool get readyToTypeOnOpen => _readyToTypeOnOpen;
  bool get dailySeparatorsEnabled => _dailySeparatorsEnabled;
  bool get spellCheckEnabled => _spellCheckEnabled;
  WritingFont get writingFont => _writingFont;

  /// Light, dark, or whatever the machine is set to.
  ///
  /// The machine was the only answer until now, which is right until it is
  /// not: people read light on a dark desk and dark on a bright one, and an
  /// app that follows the OS gives them no way to say so.
  AppearanceMode get appearance => _appearance.value;

  /// A property-specific signal, for the same reason as
  /// [transparencyListenable]: the app root rebuilds its theme from this, and
  /// [LayoutPrefs] notifies for every dragged pixel of the sidebar.
  ValueListenable<AppearanceMode> get appearanceListenable => _appearance;

  /// What the sheet behind the writing looks like.
  PaperStyle get paperStyle => _paperStyle;
  bool get transparencyEnabled => _transparencyEnabled.value;

  /// A property-specific signal for the app theme.
  ///
  /// Panel widths notify [LayoutPrefs] for every dragged pixel. Listening to
  /// this narrower value keeps a resize from rebuilding the whole app root
  /// merely because transparency also lives in this object.
  ValueListenable<bool> get transparencyListenable => _transparencyEnabled;

  /// How much of the desktop shows through in transparency mode, from 0 (the
  /// note still clearly a note) to 1 (barely a film over the window's blur).
  /// Kept while the mode is off, so turning it back on finds the amount it
  /// was left at.
  double get transparencyAmount => _transparencyAmount.value;
  ValueListenable<double> get transparencyAmountListenable =>
      _transparencyAmount;

  /// Where a new install starts: the subtle end of the slider, the most body
  /// the mode has to offer.
  ///
  /// Switching transparency on is not a request for a particular amount of
  /// it, and the far end of this scale leaves barely a film — somewhere to
  /// arrive at by choice, not to be handed. Starting here, every drag of the
  /// slider takes more away, which is the direction somebody who opened the
  /// setting is looking to go.
  static const double defaultTransparencyAmount = 0;
  String? get timeZoneId => _timeZoneId;

  /// Whether closing the window tucks the app into the tray instead of
  /// ending it.
  ///
  /// On by default on desktop, because everything this app is for assumes it
  /// is already running: a global summon shortcut, a new-note shortcut, and a
  /// tray icon to reach both from. An app that quit whenever its window was
  /// closed would answer none of them until it was launched again.
  ///
  /// The switch in Settings still turns it off, and that choice is written
  /// down — so this default only ever reaches somebody who has not expressed
  /// one. Never true on mobile, which has no window to close and no tray to
  /// close it into.
  bool get keepRunningInBackground => _keepRunningInBackground;

  /// Whether this install has already introduced itself to the login items.
  ///
  /// "Open at login" is not a preference this class stores — it lives in the
  /// OS, and [DesktopIntegration] reads it back from there every launch, since
  /// System Settings and the Task Manager can both revoke it behind the app's
  /// back. So the default cannot be expressed as a fallback value the way the
  /// one above is; it has to be an action taken once.
  ///
  /// This is the record of having taken it. Without it, a user who turned the
  /// login item off would find it back on at the next launch, which is not a
  /// default — it is refusing to take no for an answer.
  bool get loginItemDefaultApplied => _loginItemDefaultApplied;

  /// Whether the window floats over other applications. Persisted like every
  /// other window preference here, so a window pinned for a task is still
  /// pinned after a restart — the toolbar button and its shortcut are right
  /// there to undo it, and a pin that quietly forgot itself overnight would
  /// be the more surprising behaviour.
  bool get alwaysOnTop => _alwaysOnTop;

  /// Null means follow whichever note was most recently opened.
  String? get defaultNoteId => _defaultNoteId;
  String? get lastOpenedNoteId => _lastOpenedNoteId;

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
    // Every launch begins on the page itself. Sidebar visibility is a window
    // state for this session, not a preference carried into the next one.
    _sidebarVisible = false;
    _windowSize = _clampWindowSize(
      Size(
        _readDouble(_windowWidthKey) ?? defaultWindowSize.width,
        _readDouble(_windowHeightKey) ?? defaultWindowSize.height,
      ),
    );
    _readyToTypeOnOpen = _store.read<bool>(_readyToTypeOnOpenKey) ?? true;
    _dailySeparatorsEnabled = _store.read<bool>(_dailySeparatorsKey) ?? true;
    _spellCheckEnabled = _store.read<bool>(_spellCheckKey) ?? true;
    _numberSystem = _readNumberSystem();
    _writingFont = _readWritingFont();
    _appearance.value = _readEnum(
      _appearanceKey,
      AppearanceMode.values,
      AppearanceMode.system,
    );
    _paperStyle = _readEnum(_paperKey, PaperStyle.values, PaperStyle.notepad);
    _transparencyEnabled.value =
        supportsTransparency && (_store.read<bool>(_transparencyKey) ?? false);
    _transparencyAmount.value =
        (_readDouble(_transparencyAmountKey) ?? defaultTransparencyAmount)
            .clamp(0.0, 1.0);
    _timeZoneId = AppTimeZones.normalize(_store.read<String>(_timeZoneKey));
    _keepRunningInBackground =
        _store.read<bool>(_keepRunningKey) ?? AppPlatform.isDesktop;
    _loginItemDefaultApplied = _store.read<bool>(_loginItemDefaultKey) ?? false;
    _alwaysOnTop = _store.read<bool>(_alwaysOnTopKey) ?? false;
    _lastOpenedNoteId = _readNoteId(_lastOpenedNoteKey);
    _defaultNoteId = _readNoteId(_defaultNoteKey);
    _readCarets();
    _pruneCarets();
    notifyListeners();
  }

  set gutterWidth(double value) {
    final clamped = _clampGutter(value);
    if (clamped == _gutterWidth) return;
    _gutterWidth = clamped;
    _store.putNow(_gutterKey, clamped);
    notifyListeners();
  }

  set resultsVisible(bool value) {
    if (value == _resultsVisible) return;
    _resultsVisible = value;
    _store.putNow(_resultsVisibleKey, value);
    notifyListeners();
  }

  set sidebarWidth(double value) {
    final clamped = _clampSidebar(value);
    if (clamped == _sidebarWidth) return;
    _sidebarWidth = clamped;
    _store.putNow(_sidebarKey, clamped);
    notifyListeners();
  }

  set windowSize(Size value) {
    final clamped = _clampWindowSize(value);
    if (clamped == _windowSize) return;
    _windowSize = clamped;
    _store.putNow(_windowWidthKey, clamped.width);
    _store.putNow(_windowHeightKey, clamped.height);
    notifyListeners();
  }

  set dailySeparatorsEnabled(bool value) {
    if (value == _dailySeparatorsEnabled) return;
    _dailySeparatorsEnabled = value;
    _store.putNow(_dailySeparatorsKey, value);
    notifyListeners();
  }

  set readyToTypeOnOpen(bool value) {
    if (value == _readyToTypeOnOpen) return;
    _readyToTypeOnOpen = value;
    _store.putNow(_readyToTypeOnOpenKey, value);
    notifyListeners();
  }

  set spellCheckEnabled(bool value) {
    if (value == _spellCheckEnabled) return;
    _spellCheckEnabled = value;
    _store.putNow(_spellCheckKey, value);
    notifyListeners();
  }

  set numberSystem(NumberSystem value) {
    if (value == _numberSystem) return;
    _numberSystem = value;
    _store.putNow(_numberSystemKey, value.name);
    notifyListeners();
  }

  set appearance(AppearanceMode value) {
    if (value == _appearance.value) return;
    _appearance.value = value;
    _store.putNow(_appearanceKey, value.name);
    notifyListeners();
  }

  set paperStyle(PaperStyle value) {
    if (value == _paperStyle) return;
    _paperStyle = value;
    _store.putNow(_paperKey, value.name);
    notifyListeners();
  }

  set writingFont(WritingFont value) {
    if (value == _writingFont) return;
    _writingFont = value;
    _store.putNow(_writingFontKey, value.name);
    notifyListeners();
  }

  /// Where the window can put a blurred desktop behind the Flutter view:
  /// macOS through its visual effect material, Windows through acrylic. Linux
  /// has no compositor API the runner could ask, and a phone has no window
  /// to see through at all. Ignoring a stale or hand-edited value on those
  /// also keeps the first editable frame on its opaque fast path.
  static bool get supportsTransparency =>
      AppPlatform.isMacOS || AppPlatform.isWindows;

  set transparencyEnabled(bool value) {
    final supportedValue = supportsTransparency && value;
    if (supportedValue == _transparencyEnabled.value) return;
    _transparencyEnabled.value = supportedValue;
    _store.putNow(_transparencyKey, supportedValue);
    notifyListeners();
  }

  set transparencyAmount(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped == _transparencyAmount.value) return;
    _transparencyAmount.value = clamped;
    _store.putNow(_transparencyAmountKey, clamped);
    notifyListeners();
  }

  set timeZoneId(String? value) {
    final normalized = AppTimeZones.normalize(value);
    if (normalized == _timeZoneId) return;
    _timeZoneId = normalized;
    // LocalStore has no removal operation. An empty value is the durable
    // representation of following the device time zone.
    _store.putNow(_timeZoneKey, normalized ?? '');
    notifyListeners();
  }

  set keepRunningInBackground(bool value) {
    if (value == _keepRunningInBackground) return;
    _keepRunningInBackground = value;
    _store.putNow(_keepRunningKey, value);
    notifyListeners();
  }

  set alwaysOnTop(bool value) {
    if (value == _alwaysOnTop) return;
    _alwaysOnTop = value;
    _store.putNow(_alwaysOnTopKey, value);
    notifyListeners();
  }

  /// Where the caret was left in [noteId], if that was today.
  ///
  /// Null on any other day, which is the whole of the rule. Coming back to a
  /// note within the day, you are still in the middle of whatever you were
  /// doing and the cursor belongs where you left it; coming back tomorrow,
  /// you are starting something, and the bottom of the note is where that
  /// goes — under a dated line, if those are on.
  ///
  /// "Today" is read in the zone note timestamps use, so somebody who has set
  /// one gets the same midnight here as they see on their notes.
  int? caretIn(String noteId) {
    final caret = _carets[noteId];
    if (caret == null) return null;
    return DailySeparator.isSameDay(
          caret.at,
          DateTime.now(),
          displayTime: displayTime,
        )
        ? caret.offset
        : null;
  }

  /// Records where the caret is, to be offered back by [caretIn].
  ///
  /// Written through the coalescing [LocalStore.put] rather than [putNow]:
  /// this moves with every keystroke and every arrow key, exactly like the
  /// note body it belongs to, and the two should cost the same.
  void rememberCaret(String noteId, int offset) {
    final existing = _carets[noteId];
    if (existing != null && existing.offset == offset) return;
    _carets[noteId] = (offset: offset, at: DateTime.now());
    _store.put(_caretKey, _caretsToJson());
    // No notifyListeners: nothing on screen is drawn from this, and telling
    // the whole app the cursor moved would rebuild the sidebar on every key.
  }

  /// Drops yesterday's positions, which [caretIn] would refuse anyway.
  ///
  /// Called from [load], and that is enough to bound the map: what survives
  /// is the notes touched today, and a note deleted since is one entry that
  /// expires at midnight rather than something to go hunting for.
  void _pruneCarets() {
    final now = DateTime.now();
    final before = _carets.length;
    _carets.removeWhere(
      (id, caret) =>
          !DailySeparator.isSameDay(caret.at, now, displayTime: displayTime),
    );
    if (_carets.length != before) _store.put(_caretKey, _caretsToJson());
  }

  Map<String, Object?> _caretsToJson() => {
    for (final entry in _carets.entries)
      entry.key: [entry.value.offset, entry.value.at.millisecondsSinceEpoch],
  };

  void _readCarets() {
    _carets.clear();
    final stored = _store.read<Map>(_caretKey);
    if (stored == null) return;
    for (final entry in stored.entries) {
      final id = entry.key;
      final value = entry.value;
      // Anything that is not a pair of numbers is a record this version does
      // not understand. A caret is not worth throwing on, so it is dropped.
      if (id is! String || value is! List || value.length != 2) continue;
      final offset = value[0];
      final at = value[1];
      if (offset is! int || at is! int || offset < 0) continue;
      _carets[id] = (
        offset: offset,
        at: DateTime.fromMillisecondsSinceEpoch(at),
      );
    }
  }

  set lastOpenedNoteId(String? value) {
    final normalized = _normalizeNoteId(value);
    if (normalized == _lastOpenedNoteId) return;
    _lastOpenedNoteId = normalized;
    _store.putNow(_lastOpenedNoteKey, normalized ?? '');
    notifyListeners();
  }

  set defaultNoteId(String? value) {
    final normalized = _normalizeNoteId(value);
    if (normalized == _defaultNoteId) return;
    _defaultNoteId = normalized;
    _store.putNow(_defaultNoteKey, normalized ?? '');
    notifyListeners();
  }

  /// Resolves the startup choice against notes that still exist and are not
  /// archived. A deleted fixed note also clears that preference immediately,
  /// so future launches naturally return to Last opened note.
  String? resolveOpeningNoteId(Iterable<String> activeNoteIds) {
    final ids = activeNoteIds.toSet();
    final fixed = _defaultNoteId;
    if (fixed != null) {
      if (ids.contains(fixed)) return fixed;
      defaultNoteId = null;
    }
    final recent = _lastOpenedNoteId;
    if (recent != null && ids.contains(recent)) return recent;
    return null;
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
    _store.putNow(_gutterKey, _gutterWidth);
    _store.putNow(_sidebarKey, _sidebarWidth);
    _store.putNow(_resultsVisibleKey, _resultsVisible);
    notifyListeners();
  }

  /// Records that the login-item default has had its one chance, whether or
  /// not the OS accepted it. A machine whose policy forbids login items would
  /// otherwise be asked again on every launch, forever.
  ///
  /// Deliberately silent: nothing on screen reads this, and notifying here
  /// would wake [DesktopIntegration] in the middle of its own startup.
  void markLoginItemDefaultApplied() {
    if (_loginItemDefaultApplied) return;
    _loginItemDefaultApplied = true;
    _store.putNow(_loginItemDefaultKey, true);
  }

  void toggleAlwaysOnTop() => alwaysOnTop = !_alwaysOnTop;

  /// The right-hand column's counterpart to [toggleSidebar]. The divider's
  /// own handle already collapses and restores it; this is the same door for
  /// anyone whose hands are on the keyboard.
  void toggleResults() => resultsVisible = !_resultsVisible;

  void toggleSidebar() {
    _sidebarVisible = !_sidebarVisible;
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

  /// Reads an enum by name, and falls back rather than throwing: a value
  /// written by a later version is one this one has no opinion about.
  T _readEnum<T extends Enum>(String key, List<T> values, T fallback) {
    final stored = _store.read<String>(key);
    for (final value in values) {
      if (value.name == stored) return value;
    }
    return fallback;
  }

  double? _readDouble(String key) {
    final value = _store.data[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  String? _readNoteId(String key) => _normalizeNoteId(_store.read<String>(key));

  static String? _normalizeNoteId(String? value) {
    final clean = value?.trim() ?? '';
    return clean.isEmpty ? null : clean;
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
