import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../data/layout_prefs.dart';
import '../data/shortcut_prefs.dart';
import 'app_tray.dart';
import 'login_item.dart';

/// Native desktop behavior that has no useful mobile equivalent: remembering
/// the window size, summoning an already-running app from anywhere — either
/// to whatever you left on screen, or straight onto a blank note — and, for
/// those who ask for it, staying alive in the tray once the window is closed.
class DesktopIntegration extends ChangeNotifier with WindowListener {
  DesktopIntegration({required this.layoutPrefs}) {
    _tray = AppTray(
      onOpen: () => unawaited(_summon()),
      onNewNote: () => unawaited(_summonForNewNote()),
      onQuit: () => unawaited(quit()),
    );
    // Whoever changes the preference — the settings pane today, anything
    // else later — the OS follows from here, rather than every caller having
    // to remember to tell us.
    layoutPrefs.addListener(_onPrefsChanged);
  }

  final LayoutPrefs layoutPrefs;

  late final AppTray _tray;

  final Map<ShortcutAction, HotKey> _hotKeys = {};
  Timer? _resizeDebounce;
  String? _registrationError;

  /// Called when the new-note shortcut or the tray's New Note fires, once the
  /// window is up. Set by the notes UI when it mounts, which is a frame later
  /// than the shortcut starts answering, so a press with nobody listening is
  /// dropped rather than queued — there is no note list yet to add to.
  VoidCallback? onNewNoteRequested;

  /// Run before the process ends, so unsaved work reaches disk. Set by the
  /// app root, which owns the store.
  Future<void> Function()? onBeforeQuit;

  bool? _appliedKeepRunning;
  bool _hidesOnClose = false;
  bool _loginItemSupported = false;
  bool _loginItemEnabled = false;

  String? get registrationError => _registrationError;

  /// Whether this host can open the app at login. False on macOS 12 and on
  /// anything without a runner behind the channel, and the settings pane
  /// leaves the row out entirely rather than offer a switch that does nothing.
  bool get loginItemSupported => _loginItemSupported;
  bool get loginItemEnabled => _loginItemEnabled;

  Future<void> initialize(ShortcutPrefs shortcuts) async {
    windowManager.addListener(this);
    for (final action in _globalActions) {
      // The first refusal is the one worth reporting: it names a shortcut the
      // user can go and change, and the later ones may well be fine.
      _registrationError ??= await _replaceHotKey(
        action,
        shortcuts.bindingFor(action),
      );
    }
    await _applyBackgroundBehavior();
    await refreshLoginItem();
    notifyListeners();
  }

  /// Re-reads the login item from the OS. Worth doing whenever the settings
  /// pane opens: System Settings and the Task Manager can both remove it
  /// behind the app's back.
  Future<void> refreshLoginItem() async {
    _loginItemSupported = await LoginItem.isSupported();
    _loginItemEnabled = _loginItemSupported && await LoginItem.isEnabled();
    notifyListeners();
  }

  /// Returns what went wrong, in words worth showing, or null.
  Future<String?> setLoginItemEnabled(bool enabled) async {
    final error = await LoginItem.setEnabled(enabled);
    // Read back rather than assume. A registration can be refused after the
    // fact — an unsigned build, a policy — and the switch should show what
    // the OS did, not what was asked of it.
    _loginItemEnabled = await LoginItem.isEnabled();
    notifyListeners();
    return error;
  }

  void _onPrefsChanged() => unawaited(_applyBackgroundBehavior());

  /// Brings the tray and the close button in line with the preference.
  ///
  /// Guarded on the last applied value because [LayoutPrefs] also notifies for
  /// every dragged pixel of the sidebar, and re-registering a tray icon on
  /// each one would be visible.
  Future<void> _applyBackgroundBehavior() async {
    final keepRunning = layoutPrefs.keepRunningInBackground;
    if (keepRunning == _appliedKeepRunning) return;
    _appliedKeepRunning = keepRunning;

    // The tray goes up first, because whether it managed to is what decides
    // the rest: a close that hides the window is only safe while there is
    // something left on screen to bring it back.
    await _tray.setVisible(keepRunning);
    _hidesOnClose = keepRunning && _tray.isVisible;
    await windowManager.setPreventClose(_hidesOnClose);

    // Turning it off while the window is already tucked away would leave
    // nothing on screen and nothing in the tray to bring it back.
    if (!keepRunning && !await windowManager.isVisible()) {
      await _summon();
    }
  }

  /// Ends the process, having given the app a chance to finish writing.
  ///
  /// The tray goes first: an icon that outlives the app it belongs to is one
  /// the user clicks and clicks at.
  Future<void> quit() async {
    await onBeforeQuit?.call();
    await _tray.dispose();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  /// Registers [binding] before the preference is committed. A system-level
  /// collision therefore leaves the last working shortcut intact.
  Future<String?> trySystemShortcut(
    ShortcutAction action,
    ShortcutBinding binding,
  ) async {
    final error = await _replaceHotKey(action, binding);
    _registrationError = error;
    notifyListeners();
    return error;
  }

  static Iterable<ShortcutAction> get _globalActions =>
      ShortcutAction.values.where((action) => action.isGlobal);

  Future<String?> _replaceHotKey(
    ShortcutAction action,
    ShortcutBinding binding,
  ) async {
    final previous = _hotKeys.remove(action);
    if (previous != null) await hotKeyManager.unregister(previous);

    final candidate = HotKey(
      identifier: 'kapynotes.${action.name}',
      key: binding.physicalKey,
      modifiers: [
        if (binding.alt) HotKeyModifier.alt,
        if (binding.control) HotKeyModifier.control,
        if (binding.meta) HotKeyModifier.meta,
        if (binding.shift) HotKeyModifier.shift,
      ],
      scope: HotKeyScope.system,
    );

    if (await _register(action, candidate)) return null;
    if (previous != null) await _register(action, previous);
    return 'That shortcut is already used by macOS, Windows, or another app.';
  }

  Future<bool> _register(ShortcutAction action, HotKey hotKey) async {
    try {
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) => unawaited(_fire(action)),
      );
      _hotKeys[action] = hotKey;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fire(ShortcutAction action) => switch (action) {
    ShortcutAction.newNoteAnywhere => _summonForNewNote(),
    _ => toggleWindow(),
  };

  /// Unlike the summon shortcut this one never hides the window. The press
  /// asked for somewhere to write, and a note behind the app you were in is
  /// not somewhere to write.
  Future<void> _summonForNewNote() async {
    await _summon();
    onNewNoteRequested?.call();
  }

  Future<void> _summon() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Both platforms report the close before honouring it, whether or not it
  /// was prevented. Doing nothing is therefore the correct response to a
  /// close the app did not ask to intercept: Windows quits, macOS keeps the
  /// process alive for the summon shortcut, and both are what should happen.
  @override
  void onWindowClose() {
    if (!_hidesOnClose) return;
    unawaited(windowManager.hide());
  }

  /// Brings the window up, or puts it away if it is already the window you
  /// are looking at.
  ///
  /// "Already there" deliberately means visible *and* focused. A window that
  /// is merely visible behind something else should come forward on the first
  /// press rather than disappear, which is what a plain visibility check would
  /// have done.
  Future<void> toggleWindow() async {
    if (await windowManager.isVisible() && await windowManager.isFocused()) {
      await windowManager.hide();
      return;
    }
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
    layoutPrefs.removeListener(_onPrefsChanged);
    unawaited(_tray.dispose());
    onNewNoteRequested = null;
    onBeforeQuit = null;
    for (final hotKey in _hotKeys.values) {
      unawaited(hotKeyManager.unregister(hotKey));
    }
    _hotKeys.clear();
    super.dispose();
  }
}
