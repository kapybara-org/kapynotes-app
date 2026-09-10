import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../data/layout_prefs.dart';
import '../data/shortcut_prefs.dart';
import 'app_tray.dart';
import 'login_item.dart';
import 'system_shutdown.dart';
import 'window_pin.dart';

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

  /// Called after an existing window is brought forward from the tray or a
  /// system-wide shortcut. The notes UI uses this to restore its chosen
  /// ready-to-type behavior after the native window owns focus again.
  VoidCallback? onOpenRequested;

  /// Run before the process ends, so unsaved work reaches disk. Set by the
  /// app root, which owns the store.
  Future<void> Function()? onBeforeQuit;

  /// Awaited before the window is put away.
  ///
  /// A window hidden to the tray is still a running app, so this is not a
  /// flush point in general — but it *is* the point a recording has to stop.
  /// An app with nothing on screen that is still holding the microphone is
  /// the worst thing this feature could do.
  Future<void> Function()? onBeforeClose;

  Future<void>? _quitting;
  bool? _appliedKeepRunning;
  bool? _appliedAlwaysOnTop;
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
    // An installer, or a logoff, asking the app to end. It arrives as its own
    // message rather than as a close because the two want opposite things:
    // this one is not allowed to become a hide.
    SystemShutdown.listen(quit);
    // The runner's own windows — the About panel today — open at the ordinary
    // level, so it asks for the pin before it puts one up rather than let it
    // arrive underneath this one. See [releaseAlwaysOnTop].
    WindowPin.listen(releaseAlwaysOnTop);
    for (final action in _globalActions) {
      // The first refusal is the one worth reporting: it names a shortcut the
      // user can go and change, and the later ones may well be fine.
      _registrationError ??= await _replaceHotKey(
        action,
        shortcuts.bindingFor(action),
      );
    }
    await _applyBackgroundBehavior();
    // A pin survives a restart, so it has to be re-asserted on the new
    // window rather than waiting for the preference to change again.
    await _applyAlwaysOnTop();
    // Only whether the mechanism exists, not whether it is switched on. The
    // on/off answer comes from `SMAppService.status`, and the first call to
    // that copies the LaunchServices database into the process — sixteen
    // megabytes that stay resident for the life of the app. Nothing at launch
    // reads the answer; the settings pane asks for it when it opens, and the
    // first-run default below reads it back after registering.
    _loginItemSupported = await LoginItem.isSupported();
    await _applyLoginItemDefault();
    notifyListeners();
  }

  /// Adds the app to the user's login items the first time it is able to, and
  /// never again.
  ///
  /// The app is built to be already running — a summon shortcut, a new-note
  /// shortcut and a tray icon are all worth less if it is not — so it starts
  /// with the machine unless told otherwise.
  ///
  /// Once only, and the record of having done it is kept even when the OS
  /// refuses. Turning the switch off in Settings, or removing the item from
  /// System Settings, is the last word: this never runs again to undo either.
  Future<void> _applyLoginItemDefault() async {
    // Nothing to record on a host with no mechanism — macOS 12 has none this
    // sandbox may use — so a later OS upgrade still gets its one chance.
    if (!_loginItemSupported || layoutPrefs.loginItemDefaultApplied) return;
    layoutPrefs.markLoginItemDefaultApplied();
    // Through the same path the switch uses, which reads the result back from
    // the OS rather than assuming it. A refusal needs no message of its own:
    // it leaves the switch showing off, which is the truth, and flicking it
    // there reports why.
    await setLoginItemEnabled(true);
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

  void _onPrefsChanged() {
    unawaited(_applyBackgroundBehavior());
    unawaited(_applyAlwaysOnTop());
  }

  /// Floats the window above other applications, or stops.
  ///
  /// Guarded on the last applied value for the same reason as
  /// [_applyBackgroundBehavior]: [LayoutPrefs] notifies for every dragged
  /// pixel of the sidebar, and this would otherwise cross the platform
  /// channel on each one.
  Future<void> _applyAlwaysOnTop() async {
    final onTop = layoutPrefs.alwaysOnTop;
    if (onTop == _appliedAlwaysOnTop) return;
    _appliedAlwaysOnTop = onTop;
    await windowManager.setAlwaysOnTop(onTop);
  }

  /// Stops the window floating, and turns the preference off with it.
  ///
  /// For the moments the app puts something on screen that it does not draw:
  /// Sparkle's update panel, WinSparkle's, the standard About panel. Every
  /// one of them opens at the ordinary window level, so a floating window
  /// sits over the top and the click that asked for it looks like it did
  /// nothing — the app says the updater is open, and the user never sees it.
  ///
  /// The pin is given up rather than borrowed, because nothing says when to
  /// give it back. Sparkle emits no event when its panel is closed, so a
  /// restore could only be guessed at: on a timer, or the next time this
  /// window is focused. Both put the window back over a panel that is still
  /// open, which is the same bug with more moving parts. Given up, it is
  /// visibly given up — the toolbar's pin button goes out — and one press
  /// puts it back.
  ///
  /// Returns whether there was anything to give up, so the caller can say so.
  Future<bool> releaseAlwaysOnTop() async {
    if (!layoutPrefs.alwaysOnTop) return false;
    // Straight at the window, and awaited, before the preference is touched.
    // The caller is about to put the other window on screen and cannot wait
    // for a change to find its way back through [_onPrefsChanged], which is
    // unawaited by design. Recording it as applied first keeps that listener
    // from crossing the channel a second time when it does arrive.
    _appliedAlwaysOnTop = false;
    await windowManager.setAlwaysOnTop(false);
    layoutPrefs.alwaysOnTop = false;
    return true;
  }

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
  ///
  /// Callable more than once, and answered by the first attempt every time.
  /// An update ends up here twice: WinSparkle asks the app to leave at the
  /// same moment the installer it already launched asks Windows to make it,
  /// and the two arrive in either order. Saving twice would be wasteful;
  /// destroying a window twice is a crash.
  Future<void> quit() => _quitting ??= _quit();

  Future<void> _quit() async {
    try {
      await onBeforeQuit?.call();
    } catch (error) {
      debugPrint('KapyNotes: could not finish saving before quit: $error');
    }
    try {
      await _tray.dispose();
    } catch (error) {
      debugPrint('KapyNotes: could not remove the tray icon: $error');
    }
    try {
      await windowManager.setPreventClose(false);
    } catch (error) {
      debugPrint('KapyNotes: could not release close interception: $error');
    }
    await windowManager.destroy();
  }

  /// Registers [binding] before the preference is committed. A system-level
  /// collision therefore leaves the last working shortcut intact.
  ///
  /// A null [binding] hands the chord back to the OS instead, which is the
  /// point of clearing a system-wide shortcut: until it is released, this app
  /// goes on swallowing a key combination it no longer does anything with.
  /// Releasing cannot collide with anything, so it never reports an error.
  Future<String?> trySystemShortcut(
    ShortcutAction action,
    ShortcutBinding? binding,
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
    ShortcutBinding? binding,
  ) async {
    final previous = _hotKeys.remove(action);
    if (previous != null) await hotKeyManager.unregister(previous);
    if (binding == null) return null;

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
    await _summon(notifyOpen: false);
    onNewNoteRequested?.call();
  }

  Future<void> _summon({bool notifyOpen = true}) async {
    await windowManager.show();
    await windowManager.focus();
    if (notifyOpen) onOpenRequested?.call();
  }

  /// Both platforms report the close before honouring it, whether or not it
  /// was prevented. Doing nothing is therefore the correct response to a
  /// close the app did not ask to intercept: Windows quits, macOS keeps the
  /// process alive for the summon shortcut, and both are what should happen.
  @override
  void onWindowClose() {
    if (!_hidesOnClose) return;
    unawaited(_hideAfterClosing());
  }

  Future<void> _hideAfterClosing() async {
    await onBeforeClose?.call();
    await windowManager.hide();
  }

  @override
  void onWindowFocus() {
    onOpenRequested?.call();
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
    await _summon();
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
    SystemShutdown.stopListening();
    WindowPin.stopListening();
    layoutPrefs.removeListener(_onPrefsChanged);
    unawaited(_tray.dispose());
    onNewNoteRequested = null;
    onOpenRequested = null;
    onBeforeQuit = null;
    onBeforeClose = null;
    for (final hotKey in _hotKeys.values) {
      unawaited(hotKeyManager.unregister(hotKey));
    }
    _hotKeys.clear();
    super.dispose();
  }
}
