import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'local_store.dart';

/// User-adjustable layout sizes that survive restarts.
class LayoutPrefs extends ChangeNotifier {
  static const Size defaultWindowSize = Size(600, 630);
  static const Size minimumWindowSize = Size(520, 360);

  static const double minGutterWidth = 110;
  static const double maxGutterWidth = 480;
  static const double defaultGutterWidth = 190;

  static const double minSidebarWidth = 180;
  static const double maxSidebarWidth = 420;
  static const double defaultSidebarWidth = 260;

  static const String _gutterKey = 'gutter.v1';
  static const String _sidebarKey = 'sidebar.v1';
  static const String _sidebarVisibleKey = 'sidebarVisible.v1';
  static const String _windowWidthKey = 'windowWidth.v1';
  static const String _windowHeightKey = 'windowHeight.v1';
  static const String _dailySeparatorsKey = 'dailySeparators.v1';

  final LocalStore _store;

  double _gutterWidth = defaultGutterWidth;
  double _sidebarWidth = defaultSidebarWidth;
  bool _sidebarVisible = true;
  Size _windowSize = defaultWindowSize;
  bool _dailySeparatorsEnabled = true;

  LayoutPrefs(this._store);

  double get gutterWidth => _gutterWidth;
  double get sidebarWidth => _sidebarWidth;
  bool get sidebarVisible => _sidebarVisible;
  Size get windowSize => _windowSize;
  bool get dailySeparatorsEnabled => _dailySeparatorsEnabled;

  void load() {
    _gutterWidth = _clampGutter(_readDouble(_gutterKey) ?? defaultGutterWidth);
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
    notifyListeners();
  }

  set gutterWidth(double value) {
    final clamped = _clampGutter(value);
    if (clamped == _gutterWidth) return;
    _gutterWidth = clamped;
    _store.put(_gutterKey, clamped);
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

  void resetGutterWidth() => gutterWidth = defaultGutterWidth;

  void resetPanelWidths() {
    if (_gutterWidth == defaultGutterWidth &&
        _sidebarWidth == defaultSidebarWidth) {
      return;
    }
    _gutterWidth = defaultGutterWidth;
    _sidebarWidth = defaultSidebarWidth;
    _store.put(_gutterKey, _gutterWidth);
    _store.put(_sidebarKey, _sidebarWidth);
    notifyListeners();
  }

  void toggleSidebar() {
    _sidebarVisible = !_sidebarVisible;
    _store.put(_sidebarVisibleKey, _sidebarVisible);
    notifyListeners();
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
