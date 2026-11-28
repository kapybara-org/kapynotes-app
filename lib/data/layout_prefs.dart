import 'dart:async';
import 'dart:ui' show Locale, Offset, PlatformDispatcher, Rect, Size;

import 'package:flutter/foundation.dart';

import '../calc/format.dart';
import '../core/appearance.dart';
import '../core/editor_font.dart';
import '../core/platform.dart';
import '../core/system_region.dart';
import 'daily_separator.dart';
import 'local_store.dart';
import 'time_zones.dart';

/// How the user wants grouped numbers written, including deferring to the
/// device.
enum NumberSystem { auto, international, indian }

/// How the notes list groups what Pinned leaves: the View menu's Group by.
enum NotesGrouping {
  byDate('By date'),
  byTag('By tag'),
  aToZ('A–Z');

  const NotesGrouping(this.label);

  final String label;
}

extension NumberSystemCopy on NumberSystem {
  String get label => switch (this) {
    NumberSystem.auto => 'Match my region',
    NumberSystem.international => 'International',
    NumberSystem.indian => 'Indian',
  };

  String get description => switch (this) {
    NumberSystem.auto => 'Use your device region',
    NumberSystem.international => 'Thousands, millions, and billions',
    NumberSystem.indian => 'Thousands, lakhs, and crores',
  };

  /// The grouping this choice means for a device set to [region], falling
  /// back to [locale] where the platform will not name one. Only
  /// [NumberSystem.auto] looks at either.
  DigitGrouping resolve(Locale locale, {String? region}) => switch (this) {
    NumberSystem.international => DigitGrouping.international,
    NumberSystem.indian => DigitGrouping.indian,
    NumberSystem.auto => _autoGrouping(locale, region),
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

DigitGrouping _autoGrouping(Locale locale, String? region) {
  // The device's own region setting is the answer whenever there is one:
  // where the two disagree — English (US) read in India — it is the region
  // that says how the reader counts. See [SystemRegion].
  final named = region ?? locale.countryCode;
  if (named != null && named.isNotEmpty) {
    return _indianRegions.contains(named.toUpperCase())
        ? DigitGrouping.indian
        : DigitGrouping.international;
  }
  // Nothing named a country at all: a Linux desktop, a test, an older build.
  // A South Asian language is the last thing left to go on.
  return _indianLanguages.contains(locale.languageCode.toLowerCase())
      ? DigitGrouping.indian
      : DigitGrouping.international;
}

/// User preferences that survive restarts: panel sizes, window geometry, the
/// handful of display options the settings dialog exposes, and how the app
/// behaves once its window is closed.
class LayoutPrefs extends ChangeNotifier {
  static const Size defaultWindowSize = Size(600, 720);

  /// The smallest window that still holds the spaces rail and a page: tall
  /// enough for the rail with every space, the streak and the account on it,
  /// and wide enough for the page's toolbar beside the rail.
  static const Size minimumWindowSize = Size(520, 520);

  static const double minSidebarWidth = 150;
  static const double maxSidebarWidth = 420;
  static const double defaultSidebarWidth = 336;

  /// v1 recorded the old results column folded away to make room. Results
  /// now take no width, so they start out shown again.
  static const String _resultsVisibleKey = 'resultsVisible.v2';
  static const String _sidebarKey = 'sidebar.v1';
  static const String _hiddenFolderVisibleKey = 'hiddenFolderVisible.v1';
  static const String _askBeforeDeletingKey = 'askBeforeDeleting.v1';
  static const String _noteCardsKey = 'noteCards.v1';
  static const String _notesGroupingKey = 'notesGrouping.v1';
  static const String _foldersShownKey = 'foldersShown.v1';
  static const String _openFoldersKey = 'openFolders.v1';
  static const String _addNotesShownKey = 'addNotesShown.v1';
  static const String _windowWidthKey = 'windowWidth.v1';
  static const String _windowHeightKey = 'windowHeight.v1';
  static const String _windowXKey = 'windowX.v1';
  static const String _windowYKey = 'windowY.v1';
  static const String _readyToTypeOnOpenKey = 'readyToTypeOnOpen.v1';
  static const String _dailySeparatorsKey = 'dailySeparators.v1';
  static const String _spellCheckKey = 'spellCheck.v1';
  static const String _autoTitlesKey = 'autoTitles.v1';
  static const String _markdownKey = 'markdownInNotes.v1';
  static const String _numberSystemKey = 'numberSystem.v1';
  static const String _writingFontKey = 'writingFont.v1';
  static const String _editorTextScaleKey = 'editorTextScale.v1';
  static const String _transparencyKey = 'transparencyEnabled.v1';
  static const String _transparencyAmountKey = 'transparencyAmount.v1';
  static const String _timeZoneKey = 'timeZone.v1';
  static const String _keepRunningKey = 'keepRunningInBackground.v1';
  static const String _alwaysOnTopKey = 'alwaysOnTop.v1';
  static const String _loginItemDefaultKey = 'loginItemDefaulted.v1';
  static const String _menuBarTasksKey = 'menuBarOpensTasks.v1';
  static const String _lastSlashCommandKey = 'lastSlashCommand.v1';
  static const String _cameraVideoKey = 'cameraVideo.v1';
  static const String _cameraDeviceKey = 'cameraDevice.v1';

  /// The version whose "What's new" notice was closed. A later version shows
  /// the notice again.
  static const String _whatsNewDismissedKey = 'whatsNewDismissed.v1';

  static const String _lastOpenedNoteKey = 'selectedNote.v1';
  static const String _recentlyOpenedNotesKey = 'recentlyOpenedNotes.v1';
  static const String _caretKey = 'caret.v1';
  static const String _keyboardRoomKey = 'keyboardRoom.v1';
  static const String _appearanceKey = 'appearance.v1';
  static const String _themeKey = 'theme.v1';
  static const String _nightThemeKey = 'nightTheme.v1';
  static const String _increaseContrastKey = 'increaseContrast.v1';
  static const String _appTextSizeKey = 'appTextSize.v1';
  static const String _zoomKey = 'zoom.v1';
  static const String _paperKey = 'paper.v1';
  static const String _defaultNoteKey = 'defaultNote.v1';

  final LocalStore _store;

  /// The language the device is read in, which [NumberSystem.auto] falls back
  /// to. Injectable so tests can resolve against a locale they choose.
  final Locale Function() _locale;

  /// The country the device is set to, asked of the platform once per launch.
  /// Injectable for the same reason as [_locale].
  final Future<String?> Function() _readRegion;

  /// That answer, once it has arrived. Null until then, and on any platform
  /// that will not name one — both of which read as "fall back to the
  /// locale", which is what this did before it could ask.
  String? _region;

  bool _resultsVisible = true;
  double _sidebarWidth = defaultSidebarWidth;
  bool _sidebarVisible = false;
  bool _hiddenFolderVisible = true;
  bool _askBeforeDeleting = true;
  bool _noteCards = true;
  NotesGrouping _notesGrouping = NotesGrouping.byDate;
  bool _foldersShown = false;
  Set<String> _openFolders = const {};
  bool _addNotesShown = true;
  Size _windowSize = defaultWindowSize;
  Offset? _windowPosition;
  bool _readyToTypeOnOpen = true;
  bool _dailySeparatorsEnabled = true;
  bool _spellCheckEnabled = true;
  bool _autoTitlesEnabled = autoTitlesByDefault;
  bool _markdownEnabled = true;
  NumberSystem _numberSystem = NumberSystem.auto;
  WritingFont _writingFont = WritingFont.clean;
  double _editorTextScale = defaultEditorTextScale;
  final ValueNotifier<AppearanceMode> _appearance = ValueNotifier(
    AppearanceMode.system,
  );
  final ValueNotifier<AppTheme> _theme = ValueNotifier(AppTheme.riverbank);
  final ValueNotifier<NightTheme> _nightTheme = ValueNotifier(
    const NightTheme(),
  );
  final ValueNotifier<bool?> _increaseContrast = ValueNotifier(null);
  final ValueNotifier<AppTextSize> _appTextSize = ValueNotifier(
    AppTextSize.standard,
  );
  final ValueNotifier<double> _zoom = ValueNotifier(1);
  PaperStyle _paperStyle = PaperStyle.plain;
  final ValueNotifier<bool> _transparencyEnabled = ValueNotifier(false);
  final ValueNotifier<double> _transparencyAmount = ValueNotifier(
    defaultTransparencyAmount,
  );
  String? _timeZoneId;
  bool _keepRunningInBackground = false;
  bool _loginItemDefaultApplied = false;
  bool _menuBarOpensTasks = false;
  String? _lastSlashCommand;
  bool _cameraVideo = false;
  String? _cameraDevice;
  String? _dismissedWhatsNewVersion;
  bool _alwaysOnTop = false;
  String? _lastOpenedNoteId;
  List<String> _recentlyOpenedNoteIds = const [];
  String? _defaultNoteId;
  final Map<String, ({int offset, DateTime at})> _carets = {};
  final Map<String, double> _keyboardRooms = {};

  LayoutPrefs(
    this._store, {
    Locale Function()? locale,
    Future<String?> Function()? region,
  }) : _locale = locale ?? (() => PlatformDispatcher.instance.locale),
       _readRegion = region ?? SystemRegion.read;

  bool get resultsVisible => _resultsVisible;
  double get sidebarWidth => _sidebarWidth;
  bool get sidebarVisible => _sidebarVisible;
  bool get hiddenFolderVisible => _hiddenFolderVisible;

  /// Whether deleting one note asks first. Turned off by the question's own
  /// "Don't ask again", and back on from Settings. Deleting several notes at
  /// once asks whatever this says. Kept on this device, as every other
  /// preference here is.
  bool get askBeforeDeleting => _askBeforeDeleting;

  /// Whether the desktop notes list draws its notes as sticky cards rather
  /// than as rows. Cards are how the list first appears.
  bool get noteCards => _noteCards;

  /// How the notes list groups its notes: by date until another way is
  /// picked.
  NotesGrouping get notesGrouping => _notesGrouping;

  /// Whether the Notes list beside the rail shows the folder tree rather
  /// than the notes by date: the Notes | Folders switch at its foot.
  bool get foldersShown => _foldersShown;

  /// The folders open in that tree, so it opens the way it was left.
  Set<String> get openFolders => _openFolders;

  /// Whether a folder's page has Add notes beside it: until its × closes
  /// it, and again once the page's Add notes or a new folder opens it.
  bool get addNotesShown => _addNotesShown;
  Size get windowSize => _windowSize;
  Offset? get windowPosition => _windowPosition;

  /// The complete desktop placement once this install has seen a real
  /// window. A missing position distinguishes a first launch from a window
  /// deliberately left at `(0, 0)`.
  Rect? get windowBounds {
    final position = _windowPosition;
    return position == null ? null : position & _windowSize;
  }

  bool get readyToTypeOnOpen => _readyToTypeOnOpen;
  bool get dailySeparatorsEnabled => _dailySeparatorsEnabled;
  bool get spellCheckEnabled => _spellCheckEnabled;

  /// Name new notes from what is in them, where a model on the device can.
  bool get autoTitlesEnabled => _autoTitlesEnabled;

  /// Whether new notes are named until the person says otherwise. Off
  /// everywhere until a model on the device has named a note in a real run:
  /// Gemini Nano on a phone, Apple Intelligence on a Mac.
  static const bool autoTitlesByDefault = false;

  /// Whether notes are written in markdown: `# `, `**`, `- ` and the rest
  /// drawn as what they mean, and the formatting controls writing them.
  ///
  /// On by default, and a matter of how this device shows and edits notes
  /// rather than of the notes: nothing is converted either way, so switching
  /// it back leaves every note exactly as it was written. The setting is only
  /// stored once the writer changes it, so a device that has never stored it
  /// gets markdown, and one that switched it off keeps it off.
  bool get markdownEnabled => _markdownEnabled;
  WritingFont get writingFont => _writingFont;

  /// An editor-only multiplier, set from Settings. The app-wide text
  /// preference, the device accessibility scale and [zoom] are applied after
  /// this, so each choice keeps doing its own job.
  double get editorTextScale => _editorTextScale;

  static const double minEditorTextScale = 0.8;
  static const double maxEditorTextScale = 1.8;
  static const double defaultEditorTextScale = 1;
  static const double editorTextScaleStep = 0.1;

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

  /// Which of the six themes this device wears. Its own, never synced.
  AppTheme get theme => _theme.value;
  ValueListenable<AppTheme> get themeListenable => _theme;

  /// "At night, use a different theme", with its theme and hours.
  NightTheme get nightTheme => _nightTheme.value;
  ValueListenable<NightTheme> get nightThemeListenable => _nightTheme;

  /// Increase contrast as the person set it, or null where they never have
  /// and it follows the system's own request for more contrast.
  bool? get increaseContrast => _increaseContrast.value;
  ValueListenable<bool?> get increaseContrastListenable => _increaseContrast;

  /// The text-size signal listened to by the app root. Keeping it narrower
  /// than [LayoutPrefs] avoids rebuilding the Navigator for panel drags and
  /// other unrelated preferences.
  ValueListenable<AppTextSize> get appTextSizeListenable => _appTextSize;
  AppTextSize get appTextSize => _appTextSize.value;

  /// How much larger the whole desktop window draws, one of [zoomLevels].
  /// This device's own, never synced, and narrower than [LayoutPrefs] for the
  /// same reason as [appTextSizeListenable].
  double get zoom => _zoom.value;
  ValueListenable<double> get zoomListenable => _zoom;

  /// The steps the zoom keys move through, as a browser's do.
  static const List<double> zoomLevels = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2];

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

  /// Whether the menu bar panel opens on Tasks, the tab used last, rather
  /// than on Notes, where a first run opens. Nothing else shows it, so
  /// nothing is told when it changes.
  bool get menuBarOpensTasks => _menuBarOpensTasks;

  set menuBarOpensTasks(bool value) {
    if (value == _menuBarOpensTasks) return;
    _menuBarOpensTasks = value;
    _store.putNow(_menuBarTasksKey, value);
  }

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

  /// Device-local MRU order used by the sidebar and note switcher.
  List<String> get recentlyOpenedNoteIds => _recentlyOpenedNoteIds;

  /// Converts a stored instant to the zone selected for note timestamps.
  DateTime displayTime(DateTime instant) =>
      AppTimeZones.convert(instant, _timeZoneId);

  /// The user's choice, which may be [NumberSystem.auto].
  NumberSystem get numberSystem => _numberSystem;

  /// That choice resolved against the device — what results are formatted in.
  DigitGrouping get digitGrouping =>
      _numberSystem.resolve(_locale(), region: _region);

  /// The sample the settings dialog shows beside [system], resolved against
  /// the same device results are formatted for.
  String exampleFor(NumberSystem system) =>
      ResultFormatter.sample(system.resolve(_locale(), region: _region));

  void load() {
    _resultsVisible = _store.read<bool>(_resultsVisibleKey) ?? true;
    _sidebarWidth = _clampSidebar(
      _readDouble(_sidebarKey) ?? defaultSidebarWidth,
    );
    // Every launch begins on the page itself. Sidebar visibility is a window
    // state for this session, not a preference carried into the next one.
    _sidebarVisible = false;
    _hiddenFolderVisible = _store.read<bool>(_hiddenFolderVisibleKey) ?? true;
    _askBeforeDeleting = _store.read<bool>(_askBeforeDeletingKey) ?? true;
    _noteCards = _store.read<bool>(_noteCardsKey) ?? true;
    final grouping = _store.read<String>(_notesGroupingKey);
    _notesGrouping = NotesGrouping.values.firstWhere(
      (each) => each.name == grouping,
      orElse: () => NotesGrouping.byDate,
    );
    _foldersShown = _store.read<bool>(_foldersShownKey) ?? false;
    _addNotesShown = _store.read<bool>(_addNotesShownKey) ?? true;
    final open = _store.data[_openFoldersKey];
    _openFolders = Set.unmodifiable({
      if (open is List)
        for (final id in open)
          if (id is String) id,
    });
    _windowSize = _clampWindowSize(
      Size(
        _readDouble(_windowWidthKey) ?? defaultWindowSize.width,
        _readDouble(_windowHeightKey) ?? defaultWindowSize.height,
      ),
    );
    _windowPosition = _readWindowPosition();
    _readyToTypeOnOpen = _store.read<bool>(_readyToTypeOnOpenKey) ?? true;
    _dailySeparatorsEnabled = _store.read<bool>(_dailySeparatorsKey) ?? true;
    _spellCheckEnabled = _store.read<bool>(_spellCheckKey) ?? true;
    _autoTitlesEnabled =
        _store.read<bool>(_autoTitlesKey) ?? autoTitlesByDefault;
    _markdownEnabled = _store.read<bool>(_markdownKey) ?? true;
    _numberSystem = _readNumberSystem();
    _writingFont = _readWritingFont();
    _editorTextScale = _normalizeEditorTextScale(
      _readDouble(_editorTextScaleKey) ?? defaultEditorTextScale,
    );
    unawaited(_loadRegion());
    _appearance.value = _readEnum(
      _appearanceKey,
      AppearanceMode.values,
      AppearanceMode.system,
    );
    _theme.value = _readEnum(_themeKey, AppTheme.values, AppTheme.riverbank);
    _nightTheme.value = NightTheme.fromJson(_store.data[_nightThemeKey]);
    _increaseContrast.value = _store.read<bool>(_increaseContrastKey);
    _appTextSize.value = _readEnum(
      _appTextSizeKey,
      AppTextSize.values,
      AppTextSize.standard,
    );
    _zoom.value = _nearestZoomLevel(_readDouble(_zoomKey) ?? 1);
    _paperStyle = _readEnum(_paperKey, PaperStyle.values, PaperStyle.plain);
    _transparencyEnabled.value =
        supportsTransparency && (_store.read<bool>(_transparencyKey) ?? false);
    _transparencyAmount.value =
        (_readDouble(_transparencyAmountKey) ?? defaultTransparencyAmount)
            .clamp(0.0, 1.0);
    // As stored, not checked against the zone table: checking parses the
    // whole IANA database, and this runs in front of the first frame. Every
    // reader normalizes on use, so an id the table does not know follows the
    // device there exactly as it would have here.
    _timeZoneId = _storedTimeZoneId();
    _keepRunningInBackground =
        _store.read<bool>(_keepRunningKey) ?? AppPlatform.isDesktop;
    _loginItemDefaultApplied = _store.read<bool>(_loginItemDefaultKey) ?? false;
    _menuBarOpensTasks = _store.read<bool>(_menuBarTasksKey) ?? false;
    _lastSlashCommand = _store.read<String>(_lastSlashCommandKey);
    _cameraVideo = _store.read<bool>(_cameraVideoKey) ?? false;
    _cameraDevice = _store.read<String>(_cameraDeviceKey);
    final dismissed = _store.read<String>(_whatsNewDismissedKey)?.trim();
    _dismissedWhatsNewVersion = dismissed == null || dismissed.isEmpty
        ? null
        : dismissed;
    _alwaysOnTop = _store.read<bool>(_alwaysOnTopKey) ?? false;
    _lastOpenedNoteId = _readNoteId(_lastOpenedNoteKey);
    _recentlyOpenedNoteIds = _readRecentlyOpenedNoteIds();
    final lastOpened = _lastOpenedNoteId;
    if (lastOpened != null &&
        _recentlyOpenedNoteIds.firstOrNull != lastOpened) {
      _recentlyOpenedNoteIds = List.unmodifiable([
        lastOpened,
        ..._recentlyOpenedNoteIds.where((id) => id != lastOpened),
      ]);
    }
    _defaultNoteId = _readNoteId(_defaultNoteKey);
    _readCarets();
    _pruneCarets();
    _keyboardRooms
      ..clear()
      ..addAll({
        for (final MapEntry(:key, :value)
            in (_store.read<Map>(_keyboardRoomKey) ?? const {}).entries)
          if (key is String && value is num && value > 0) key: value.toDouble(),
      });
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
    // Queue both fields before forcing the write, so a single resize becomes
    // one atomic JSON-file replacement rather than two successive writes.
    _store.put(_windowWidthKey, clamped.width);
    _store.putNow(_windowHeightKey, clamped.height);
    notifyListeners();
  }

  /// Remembers the normal desktop window in one operation.
  ///
  /// Maximized and full-screen bounds are filtered by [DesktopIntegration]
  /// before they arrive here. Invalid native values are ignored rather than
  /// replacing the last placement with something the next launch cannot use.
  void rememberWindowBounds(Rect value) {
    if (!value.left.isFinite ||
        !value.top.isFinite ||
        !value.width.isFinite ||
        !value.height.isFinite) {
      return;
    }

    final size = _clampWindowSize(value.size);
    final position = value.topLeft;
    final sizeChanged = size != _windowSize;
    if (!sizeChanged && position == _windowPosition) return;

    _windowSize = size;
    _windowPosition = position;
    // All four values are in memory before putNow starts the write. This
    // matters when a resize also moves the top-left corner.
    _store.put(_windowWidthKey, size.width);
    _store.put(_windowHeightKey, size.height);
    _store.put(_windowXKey, position.dx);
    _store.putNow(_windowYKey, position.dy);
    if (sizeChanged) notifyListeners();
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

  set autoTitlesEnabled(bool value) {
    if (value == _autoTitlesEnabled) return;
    _autoTitlesEnabled = value;
    _store.putNow(_autoTitlesKey, value);
    notifyListeners();
  }

  set markdownEnabled(bool value) {
    if (value == _markdownEnabled) return;
    _markdownEnabled = value;
    _store.putNow(_markdownKey, value);
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

  set theme(AppTheme value) {
    if (value == _theme.value) return;
    _theme.value = value;
    _store.putNow(_themeKey, value.name);
    notifyListeners();
  }

  set nightTheme(NightTheme value) {
    if (value == _nightTheme.value) return;
    _nightTheme.value = value;
    _store.putNow(_nightThemeKey, value.toJson());
    notifyListeners();
  }

  /// Sets Increase contrast to [on] where the system currently [asks] for
  /// something else, and otherwise goes back to following the system, so
  /// that turning it off while the system asks keeps it off, and agreeing
  /// with the system lets it lead again.
  void setIncreaseContrast(bool on, {required bool asks}) {
    final value = on == asks ? null : on;
    if (value == _increaseContrast.value) return;
    _increaseContrast.value = value;
    _store.putNow(_increaseContrastKey, value);
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

  set editorTextScale(double value) {
    final normalized = _normalizeEditorTextScale(value);
    if (normalized == _editorTextScale) return;
    _editorTextScale = normalized;
    _store.putNow(_editorTextScaleKey, normalized);
    notifyListeners();
  }

  void increaseEditorTextSize() =>
      editorTextScale = _editorTextScale + editorTextScaleStep;

  void decreaseEditorTextSize() =>
      editorTextScale = _editorTextScale - editorTextScaleStep;

  void resetEditorTextSize() => editorTextScale = defaultEditorTextScale;

  set appTextSize(AppTextSize value) {
    if (value == _appTextSize.value) return;
    _appTextSize.value = value;
    _store.putNow(_appTextSizeKey, value.name);
    notifyListeners();
  }

  set zoom(double value) {
    final level = _nearestZoomLevel(value);
    if (level == _zoom.value) return;
    _zoom.value = level;
    _store.putNow(_zoomKey, level);
    notifyListeners();
  }

  void zoomIn() =>
      zoom = zoomLevels.firstWhere((level) => level > zoom, orElse: () => zoom);

  void zoomOut() =>
      zoom = zoomLevels.lastWhere((level) => level < zoom, orElse: () => zoom);

  void resetZoom() => zoom = 1;

  /// Where the window can put a blurred desktop behind the Flutter view:
  /// macOS through its visual effect material, Windows through acrylic. Linux
  /// has no compositor API the runner could ask, and a phone has no window
  /// to see through at all. Ignoring a stale or hand-edited value on those
  /// also keeps the first editable frame on its opaque fast path.
  static bool get supportsTransparency =>
      AppPlatform.isMacOS || AppPlatform.isWindows;

  /// Linux has no system spell checker to ask, so the switch is left out.
  static bool get supportsSpellCheck => !AppPlatform.isLinux;

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

  String? _storedTimeZoneId() {
    final id = _store.read<String>(_timeZoneKey)?.trim();
    return id == null || id.isEmpty ? null : id;
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

  /// How much of a note's height the soft keyboard took the last time it came
  /// up in a window [width] wide, if it has: what a note opened there lays
  /// out for before the keyboard arrives.
  double? keyboardRoom(double width) => _keyboardRooms['${width.round()}'];

  /// Records the room [keyboardRoom] offers back, per width, so a phone on
  /// its side and upright each keep their own.
  void rememberKeyboardRoom(double width, double room) {
    final key = '${width.round()}';
    if (_keyboardRooms[key] == room) return;
    _keyboardRooms[key] = room;
    _store.put(_keyboardRoomKey, Map.of(_keyboardRooms));
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
    var changed = false;
    if (normalized != _lastOpenedNoteId) {
      _lastOpenedNoteId = normalized;
      _store.putNow(_lastOpenedNoteKey, normalized ?? '');
      changed = true;
    }
    if (normalized != null &&
        _recentlyOpenedNoteIds.firstOrNull != normalized) {
      _recentlyOpenedNoteIds = List.unmodifiable([
        normalized,
        ..._recentlyOpenedNoteIds.where((id) => id != normalized),
      ]);
      _store.putNow(_recentlyOpenedNotesKey, _recentlyOpenedNoteIds);
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
  }

  /// Removes notes that no longer exist without promoting any survivor.
  void retainRecentlyOpenedNoteIds(Iterable<String> noteIds) {
    final available = noteIds.toSet();
    final retained = _recentlyOpenedNoteIds
        .where(available.contains)
        .toList(growable: false);
    var changed = false;
    if (!listEquals(retained, _recentlyOpenedNoteIds)) {
      _recentlyOpenedNoteIds = List.unmodifiable(retained);
      _store.putNow(_recentlyOpenedNotesKey, _recentlyOpenedNoteIds);
      changed = true;
    }
    if (_lastOpenedNoteId case final last? when !available.contains(last)) {
      _lastOpenedNoteId = null;
      _store.putNow(_lastOpenedNoteKey, '');
      changed = true;
    }
    if (!changed) return;
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

  /// The notes list is the one panel left with a width of its own: results
  /// sit at the ends of their lines.
  void resetPanelWidths() => sidebarWidth = defaultSidebarWidth;

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

  /// The command last chosen from Commands on this device, by name.
  String? get lastSlashCommand => _lastSlashCommand;

  set lastSlashCommand(String? value) {
    if (value == _lastSlashCommand) return;
    _lastSlashCommand = value;
    _store.put(_lastSlashCommandKey, value ?? '');
    notifyListeners();
  }

  /// Whether the camera was last left in Video, which it opens in next time.
  bool get cameraVideo => _cameraVideo;

  set cameraVideo(bool value) {
    if (value == _cameraVideo) return;
    _cameraVideo = value;
    _store.put(_cameraVideoKey, value);
    notifyListeners();
  }

  /// The camera last chosen in the camera window on a Mac or PC, which it
  /// opens with while that camera is there.
  String? get cameraDevice => _cameraDevice;

  set cameraDevice(String? value) {
    if (value == _cameraDevice) return;
    _cameraDevice = value;
    _store.put(_cameraDeviceKey, value);
    notifyListeners();
  }

  /// The version whose "What's new" notice was closed, or null if it never was.
  String? get dismissedWhatsNewVersion => _dismissedWhatsNewVersion;

  /// Whether the notice for [version] should show. A newer version shows again.
  bool showWhatsNew(String version) {
    final trimmed = version.trim();
    if (trimmed.isEmpty) return false;
    return trimmed != _dismissedWhatsNewVersion;
  }

  /// Hides the "What's new" notice for [version] until a later version.
  void dismissWhatsNew(String version) {
    final trimmed = version.trim();
    if (trimmed.isEmpty || trimmed == _dismissedWhatsNewVersion) return;
    _dismissedWhatsNewVersion = trimmed;
    _store.putNow(_whatsNewDismissedKey, trimmed);
    notifyListeners();
  }

  void toggleAlwaysOnTop() => alwaysOnTop = !_alwaysOnTop;

  /// Hides the results at the ends of calculating lines, or brings them back.
  void toggleResults() => resultsVisible = !_resultsVisible;

  set hiddenFolderVisible(bool value) {
    if (value == _hiddenFolderVisible) return;
    _hiddenFolderVisible = value;
    _store.putNow(_hiddenFolderVisibleKey, value);
    notifyListeners();
  }

  set askBeforeDeleting(bool value) {
    if (value == _askBeforeDeleting) return;
    _askBeforeDeleting = value;
    _store.putNow(_askBeforeDeletingKey, value);
    notifyListeners();
  }

  set noteCards(bool value) {
    if (value == _noteCards) return;
    _noteCards = value;
    _store.putNow(_noteCardsKey, value);
    notifyListeners();
  }

  set notesGrouping(NotesGrouping value) {
    if (value == _notesGrouping) return;
    _notesGrouping = value;
    _store.putNow(_notesGroupingKey, value.name);
    notifyListeners();
  }

  set foldersShown(bool value) {
    if (value == _foldersShown) return;
    _foldersShown = value;
    _store.putNow(_foldersShownKey, value);
    notifyListeners();
  }

  set addNotesShown(bool value) {
    if (value == _addNotesShown) return;
    _addNotesShown = value;
    _store.putNow(_addNotesShownKey, value);
    notifyListeners();
  }

  void setFolderOpen(String folderId, bool open) {
    if (_openFolders.contains(folderId) == open) return;
    _openFolders = Set.unmodifiable(
      open ? {..._openFolders, folderId} : _openFolders.difference({folderId}),
    );
    _store.putNow(_openFoldersKey, _openFolders.toList());
    notifyListeners();
  }

  void toggleSidebar() {
    _sidebarVisible = !_sidebarVisible;
    notifyListeners();
  }

  /// Asks the platform what country it is set to, once, on the way up.
  ///
  /// Not awaited by [load]: a note list must not wait on a channel, and until
  /// the answer lands the locale stands in — which is only ever a frame or
  /// two, and is the same reading this had before. Listeners are told when it
  /// changes anything, so a result already on screen re-groups itself.
  Future<void> _loadRegion() async {
    final region = await _readRegion();
    if (region == null || region == _region) return;
    final before = digitGrouping;
    _region = region;
    if (digitGrouping != before) notifyListeners();
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

  /// New installs open in the clean system face. Unknown values can come from
  /// a newer app version, so they also fall back to that safe default.
  WritingFont _readWritingFont() {
    final stored = _store.read<String>(_writingFontKey);
    return WritingFont.values.firstWhere(
      (font) => font.name == stored,
      orElse: () => WritingFont.clean,
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

  static double _nearestZoomLevel(double value) => value.isFinite
      ? zoomLevels.reduce(
          (best, level) =>
              (level - value).abs() < (best - value).abs() ? level : best,
        )
      : 1;

  static double _normalizeEditorTextScale(double value) {
    if (!value.isFinite) return defaultEditorTextScale;
    final clamped = value.clamp(minEditorTextScale, maxEditorTextScale);
    // Divide the integral number of tenths rather than multiplying it by 0.1.
    // That keeps repeated shortcut presses stable for equality and persistence.
    return (clamped * 10).round() / 10;
  }

  Offset? _readWindowPosition() {
    final x = _readDouble(_windowXKey);
    final y = _readDouble(_windowYKey);
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return Offset(x, y);
  }

  String? _readNoteId(String key) => _normalizeNoteId(_store.read<String>(key));

  List<String> _readRecentlyOpenedNoteIds() {
    final stored = _store.data[_recentlyOpenedNotesKey];
    if (stored is! List) return const [];
    final seen = <String>{};
    return List.unmodifiable([
      for (final value in stored)
        if (value is String)
          if (_normalizeNoteId(value) case final id?)
            if (seen.add(id)) id,
    ]);
  }

  static String? _normalizeNoteId(String? value) {
    final clean = value?.trim() ?? '';
    return clean.isEmpty ? null : clean;
  }

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
