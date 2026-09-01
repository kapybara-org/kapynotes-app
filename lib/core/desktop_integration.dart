import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../data/layout_prefs.dart';
import '../data/shortcut_prefs.dart';

/// Native desktop behavior that has no useful mobile equivalent: remembering
/// the window size and summoning an already-running app from anywhere.
class DesktopIntegration extends ChangeNotifier with WindowListener {
  DesktopIntegration({required this.layoutPrefs});

  final LayoutPrefs layoutPrefs;

  HotKey? _openHotKey;
  Timer? _resizeDebounce;
  String? _registrationError;

  String? get registrationError => _registrationError;

  Future<void> initialize(ShortcutBinding openAppShortcut) async {
    windowManager.addListener(this);
    _registrationError = await _replaceOpenHotKey(openAppShortcut);
    notifyListeners();
  }

  /// Registers [binding] before the preference is committed. A system-level
  /// collision therefore leaves the last working shortcut intact.
  Future<String?> tryOpenShortcut(ShortcutBinding binding) async {
    final error = await _replaceOpenHotKey(binding);
    _registrationError = error;
    notifyListeners();
    return error;
  }

  Future<String?> _replaceOpenHotKey(ShortcutBinding binding) async {
    final previous = _openHotKey;
    if (previous != null) {
      await hotKeyManager.unregister(previous);
      _openHotKey = null;
    }

    final candidate = HotKey(
      identifier: 'kapynotes.open-app',
      key: binding.physicalKey,
      modifiers: [
        if (binding.alt) HotKeyModifier.alt,
        if (binding.control) HotKeyModifier.control,
        if (binding.meta) HotKeyModifier.meta,
        if (binding.shift) HotKeyModifier.shift,
      ],
      scope: HotKeyScope.system,
    );

    try {
      await hotKeyManager.register(
        candidate,
        keyDownHandler: (_) => unawaited(showAndFocus()),
      );
      _openHotKey = candidate;
      return null;
    } catch (_) {
      if (previous != null) {
        try {
          await hotKeyManager.register(
            previous,
            keyDownHandler: (_) => unawaited(showAndFocus()),
          );
          _openHotKey = previous;
        } catch (_) {
          _openHotKey = null;
        }
      }
      return 'That shortcut is already used by macOS, Windows, or another app.';
    }
  }

  Future<void> showAndFocus() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowResize() {
    // Linux does not emit the one-shot onWindowResized event. The debounce is
    // also harmless on macOS and Windows and avoids a disk write per pixel.
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(_rememberWindowSize()),
    );
  }

  @override
  void onWindowResized() {
    _resizeDebounce?.cancel();
    unawaited(_rememberWindowSize());
  }

  Future<void> _rememberWindowSize() async {
    if (await windowManager.isMaximized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    layoutPrefs.windowSize = await windowManager.getSize();
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    windowManager.removeListener(this);
    final openHotKey = _openHotKey;
    if (openHotKey != null) unawaited(hotKeyManager.unregister(openHotKey));
    super.dispose();
  }
}
