import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../data/layout_prefs.dart';
import '../data/shortcut_prefs.dart';
import 'app_tray.dart';
import 'linux_autostart.dart';
import 'linux_desktop.dart';
import 'login_item.dart';
import 'menu_bar_panel.dart';
import 'platform.dart';
import 'system_shutdown.dart';
import 'window_pin.dart';
import 'window_placement.dart';

/// Native desktop behavior that has no useful mobile equivalent: remembering
/// the window size and position; summoning an already-running app from
/// anywhere, either to whatever you left on screen or straight onto a blank
/// note; and, for those who ask for it, staying alive in the tray once the
/// window is closed.
class DesktopIntegration extends ChangeNotifier with WindowListener {
  DesktopIntegration({required this.layoutPrefs, MenuBarPanelController? panel})
    : panel = panel ?? MenuBarPanelController() {
    _tray = AppTray(
      onOpen: () => unawaited(_summon()),
      onNewNote: () => unawaited(_summonForNewNote()),
      onNewTask: () => unawaited(openInWindow((window) => window.newTask())),
      onSettings: () =>
          unawaited(openInWindow((window) => window.openSettings())),
      onQuit: () => unawaited(quit()),
      onClick: this.panel.click,
    );
    // Whoever changes the preference — the settings pane today, anything
    // else later — the OS follows from here, rather than every caller having
    // to remember to tell us.
    layoutPrefs.addListener(_onPrefsChanged);
    layoutPrefs.zoomListenable.addListener(_onZoomChanged);
  }

  final LayoutPrefs layoutPrefs;

  /// The panel under the menu bar icon. It exists only on macOS, and only
  /// while the icon does.
  final MenuBarPanelController panel;

  /// What the panel and the icon's menu ask of the window, answered by the
  /// home page while it is mounted.
  MenuBarWindowActions? window;

  late final AppTray _tray;
  ShortcutPrefs? _shortcuts;
  final Set<ShortcutAction> _taken = {};
  bool _disposed = false;

  final Map<ShortcutAction, HotKey> _hotKeys = {};
  Timer? _windowGeometryDebounce;
  String? _registrationError;
  int _temporaryWindowResizeDepth = 0;
  double _appliedZoom = 1;
  Size _minimumWindowSize = LayoutPrefs.minimumWindowSize;

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
  Future<void>? _saving;
  bool? _appliedKeepRunning;
  bool? _appliedAlwaysOnTop;
  bool _hidesOnClose = false;
  bool _loginItemSupported = false;
  bool _loginItemEnabled = false;
  bool _wayland = false;
  bool _trayHost = !AppPlatform.isLinux;

  String? get registrationError => _registrationError;

  /// Whether the OS refused [action]'s chord, because another app holds it.
  bool isTaken(ShortcutAction action) => _taken.contains(action);

  /// The panel's shortcut is registered only while there is a menu bar icon
  /// for the panel to open under, which on Windows is not yet.
  bool get _panelShortcutActive =>
      AppPlatform.isMacOS && layoutPrefs.keepRunningInBackground;

  /// Whether this host can open the app at login. False on macOS 12 and on
  /// anything without a runner behind the channel, and the settings pane
  /// leaves the row out entirely rather than offer a switch that does nothing.
  bool get loginItemSupported => _loginItemSupported;
  bool get loginItemEnabled => _loginItemEnabled;

  /// False on Wayland, where an app cannot hear keys pressed in other apps.
  /// There the summon shortcuts are system shortcuts that run the app, and
  /// the settings pane says how to add one.
  bool get systemShortcutsSupported => !_wayland;

  /// Whether closing the window can leave the app running in the tray. On
  /// Linux only while something on the desktop will show the icon: stock
  /// GNOME accepts one and never draws it, and a hidden window with no icon
  /// is an app with no way back.
  bool get canKeepRunningInBackground => _trayHost;

  Future<void> initialize(ShortcutPrefs shortcuts) async {
    _shortcuts = shortcuts;
    windowManager.addListener(this);
    // An installer, or a logoff, asking the app to end. It arrives as its own
    // message rather than as a close because the two want opposite things:
    // this one is not allowed to become a hide. A Linux logout asks first,
    // while the user can still call it off, and that one only wants the save.
    SystemShutdown.listen(quit: quit, save: save);
    // The runner's own windows — the About panel today — open at the ordinary
    // level, so it asks for the pin before it puts one up rather than let it
    // arrive underneath this one. See [releaseAlwaysOnTop].
    WindowPin.listen(releaseAlwaysOnTop);
    if (AppPlatform.isLinux) await _initializeLinux();
    for (final action in _globalActions) {
      // Registered with the menu bar icon instead, in _applyBackgroundBehavior.
      if (action == ShortcutAction.openMenuBarPanel) continue;
      // The first refusal is the one worth reporting: it names a shortcut the
      // user can go and change, and the later ones may well be fine.
      _registrationError ??= await _replaceHotKey(
        action,
        shortcuts.bindingFor(action),
      );
    }
    await _applyBackgroundBehavior();
    await _applyZoom();
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

  /// What this Linux session allows, which decides whether the summon
  /// shortcuts are registered and whether a close can hide to the tray.
  Future<void> _initializeLinux() async {
    LinuxDesktop.listen(onNewNote: () => unawaited(_summonForNewNote()));
    _wayland = await LinuxDesktop.isWayland();
    _trayHost = await LinuxDesktop.hasTrayHost();
    try {
      await LinuxAutostart().refresh();
    } catch (error) {
      debugPrint('KapyNotes: could not update the autostart entry: $error');
    }
  }

  /// Re-reads the login item from the OS. Worth doing whenever the settings
  /// pane opens: System Settings and the Task Manager can both remove it
  /// behind the app's back. On Linux it also asks again whether a tray icon
  /// would be shown, which an extension or a panel can change at any time.
  Future<void> refreshLoginItem() async {
    if (AppPlatform.isLinux) {
      _trayHost = await LinuxDesktop.hasTrayHost();
      await _applyBackgroundBehavior();
    }
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

  void _onZoomChanged() => unawaited(_applyZoom());

  /// Keeps the narrowest window as roomy inside as it is at 100%: the
  /// smallest window grows with the zoom, never past the display, and a
  /// window already smaller than that grows to it, staying on its display.
  Future<void> _applyZoom() async {
    final zoom = layoutPrefs.zoom;
    if (zoom == _appliedZoom) return;
    _appliedZoom = zoom;
    try {
      final bounds = await windowManager.getBounds();
      final area = await workAreaHolding(bounds);
      final wanted = LayoutPrefs.minimumWindowSize * zoom;
      final minimum = area == null
          ? wanted
          : Size(
              math.min(wanted.width, area.width),
              math.min(wanted.height, area.height),
            );
      if (zoom != _appliedZoom) return;
      _minimumWindowSize = minimum;
      await windowManager.setMinimumSize(minimum);
      if (bounds.width >= minimum.width && bounds.height >= minimum.height) {
        return;
      }
      final grown =
          bounds.topLeft &
          Size(
            math.max(bounds.width, minimum.width),
            math.max(bounds.height, minimum.height),
          );
      await windowManager.setBounds(
        area == null
            ? grown
            : grown.shift(
                Offset(
                  math.min(0, area.right - grown.right),
                  math.min(0, area.bottom - grown.bottom),
                ),
              ),
      );
    } catch (error) {
      debugPrint('KapyNotes: could not fit the window to the zoom: $error');
    }
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
  /// For the moments the app puts something on screen that it does not draw,
  /// such as the standard About panel. It opens at the ordinary window level,
  /// so a floating window sits over the top and the click that asked for it
  /// looks like it did nothing.
  ///
  /// The pin is given up rather than borrowed, because nothing says when to
  /// give it back. AppKit emits no event when such a panel is closed, so a
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
    final keepRunning = layoutPrefs.keepRunningInBackground && _trayHost;
    if (keepRunning == _appliedKeepRunning) return;
    _appliedKeepRunning = keepRunning;

    // The tray goes up first, because whether it managed to is what decides
    // the rest: a close that hides the window is only safe while there is
    // something left on screen to bring it back.
    await _tray.setVisible(keepRunning, toolTip: _toolTip);
    _hidesOnClose = keepRunning && _tray.isVisible;
    if (!keepRunning) await panel.close();
    await _replaceHotKey(
      ShortcutAction.openMenuBarPanel,
      _panelShortcutActive
          ? _shortcuts?.bindingFor(ShortcutAction.openMenuBarPanel)
          : null,
    );
    await _tray.setToolTip(_toolTip);
    if (!_disposed) notifyListeners();
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
  /// An update ends up here twice: the updater quits the app at the same
  /// moment the installer it has just launched asks Windows to make it, and
  /// the two arrive in either order. Saving twice would be wasteful;
  /// destroying a window twice is a crash.
  Future<void> quit() => _quitting ??= _quit();

  /// Saves what quitting saves, and leaves the app running: a Linux logout
  /// that has only asked so far, which the user can still call off.
  ///
  /// A quit that arrives while it runs waits for it, rather than writing the
  /// same notes twice at once.
  Future<void> save() => _saving ??= _save().whenComplete(() => _saving = null);

  Future<void> _save() async {
    // Catch a last Linux move whose debounced event has not landed yet, and
    // make tray quits just as faithful as closing a visible window.
    await _rememberWindowBounds();
    try {
      await onBeforeQuit?.call();
    } catch (error) {
      debugPrint('KapyNotes: could not finish saving before quit: $error');
    }
  }

  Future<void> _quit() async {
    await save();
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
    if (AppPlatform.isLinux) {
      await SystemShutdown.quit();
      return;
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
    final panelOff =
        action == ShortcutAction.openMenuBarPanel && !_panelShortcutActive;
    final error = await _replaceHotKey(action, panelOff ? null : binding);
    _registrationError = error;
    if (action == ShortcutAction.openMenuBarPanel) {
      await _tray.setToolTip(error == null ? _toolTipFor(binding) : _toolTip);
    }
    notifyListeners();
    return error;
  }

  String get _toolTip => _toolTipFor(
    isTaken(ShortcutAction.openMenuBarPanel)
        ? null
        : _shortcuts?.bindingFor(ShortcutAction.openMenuBarPanel),
  );

  String _toolTipFor(ShortcutBinding? panelKeys) =>
      AppPlatform.isMacOS && panelKeys != null
      ? 'Kapy Notes  ${panelKeys.keycapLabel}'
      : 'Kapy Notes';

  /// Closes the panel, brings the window forward, and has it do [action].
  Future<void> openInWindow(
    void Function(MenuBarWindowActions window) action,
  ) async {
    await panel.close();
    await _summon(notifyOpen: false);
    final window = this.window;
    if (window != null) action(window);
  }

  static Iterable<ShortcutAction> get _globalActions =>
      ShortcutAction.values.where((action) => action.isGlobal);

  Future<String?> _replaceHotKey(
    ShortcutAction action,
    ShortcutBinding? binding,
  ) async {
    if (_wayland) return null;
    final previous = _hotKeys.remove(action);
    if (previous != null) await hotKeyManager.unregister(previous);
    _taken.remove(action);
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
    if (!_hotKeys.containsKey(action)) _taken.add(action);
    return AppPlatform.isLinux
        ? 'That shortcut is already used by your desktop or another app.'
        : 'That shortcut is already used by macOS, Windows, or another app.';
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
    ShortcutAction.openMenuBarPanel => _togglePanel(),
    _ => toggleWindow(),
  };

  Future<void> _togglePanel() async {
    if (await panel.isSupported) return panel.toggle();
    await toggleWindow();
  }

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

  /// Gives a modal enough horizontal room, then returns the window to the
  /// bounds the user chose before it opened.
  ///
  /// Flutter dialogs cannot be wider than their host window. Windows users
  /// can keep the notes window narrow, so a modal which needs two panes has
  /// to borrow width from that window while it is on screen. The temporary
  /// minimum also stops a resize from collapsing the modal midway through.
  /// [minimumWidth] is the room the modal lays out in, so the window borrows
  /// it at the zoom the window is drawn at.
  Future<T> withMinimumWindowWidth<T>(
    double minimumWidth,
    Future<T> Function() action,
  ) async {
    Rect originalBounds;
    try {
      originalBounds = await windowManager.getBounds();
    } catch (error) {
      // Settings is still useful if an older or incomplete runner does not
      // answer the sizing call. Its in-window fallback remains functional.
      debugPrint('KapyNotes: could not read the window before a modal: $error');
      return action();
    }
    final width = minimumWidth * layoutPrefs.zoom;
    if (originalBounds.width >= width) return action();

    final expandedBounds = Rect.fromCenter(
      center: originalBounds.center,
      width: width,
      height: originalBounds.height,
    );
    _temporaryWindowResizeDepth++;
    var minimumWasRaised = false;
    try {
      await windowManager.setMinimumSize(
        Size(width, _minimumWindowSize.height),
      );
      minimumWasRaised = true;
      await windowManager.setBounds(expandedBounds);
    } catch (error) {
      if (minimumWasRaised) {
        try {
          await windowManager.setMinimumSize(_minimumWindowSize);
        } catch (_) {}
      }
      _temporaryWindowResizeDepth--;
      debugPrint('KapyNotes: could not widen the window for a modal: $error');
      return action();
    }

    try {
      return await action();
    } finally {
      // Drop the borrowed minimum first, otherwise Windows quite correctly
      // refuses to put the narrow bounds back.
      try {
        await windowManager.setMinimumSize(_minimumWindowSize);
        await windowManager.setBounds(originalBounds);
      } catch (error) {
        debugPrint(
          'KapyNotes: could not restore the window after a modal: $error',
        );
      } finally {
        _temporaryWindowResizeDepth--;
        // A user can finish a resize and open Settings before the ordinary
        // debounce writes it. The captured pre-modal bounds are authoritative
        // and must not be replaced by the borrowed width.
        layoutPrefs.rememberWindowBounds(originalBounds);
      }
    }
  }

  /// Every platform reports the close before honouring it, whether or not it
  /// was prevented. Doing nothing is therefore the correct response to a
  /// close the app did not ask to intercept: Windows quits, macOS keeps the
  /// process alive for the summon shortcut, the Linux runner asks for the
  /// same [quit] a logout does, and each is what should happen.
  @override
  void onWindowClose() {
    if (!_hidesOnClose) {
      unawaited(_rememberWindowBounds());
      return;
    }
    unawaited(_hideAfterClosing());
  }

  Future<void> _hideAfterClosing() async {
    await _rememberWindowBounds();
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
    _scheduleWindowGeometrySave();
  }

  @override
  void onWindowMove() {
    _scheduleWindowGeometrySave();
  }

  /// Linux emits the continuous events but not their one-shot counterparts.
  /// The debounce is also harmless on macOS and Windows and avoids a disk
  /// write for every pixel of a drag.
  void _scheduleWindowGeometrySave() {
    _windowGeometryDebounce?.cancel();
    _windowGeometryDebounce = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(_rememberWindowBounds()),
    );
  }

  @override
  void onWindowResized() {
    _rememberCompletedWindowGeometry();
  }

  @override
  void onWindowMoved() {
    _rememberCompletedWindowGeometry();
  }

  void _rememberCompletedWindowGeometry() {
    _windowGeometryDebounce?.cancel();
    unawaited(_rememberWindowBounds());
  }

  Future<void> _rememberWindowBounds() async {
    if (_temporaryWindowResizeDepth > 0) return;
    try {
      if (await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      layoutPrefs.rememberWindowBounds(
        await rememberedWindowBounds(layoutPrefs, wayland: _wayland),
      );
    } catch (error) {
      // Window events must never become unhandled async errors because an
      // older runner omitted one of the geometry methods.
      debugPrint('KapyNotes: could not remember the window bounds: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _windowGeometryDebounce?.cancel();
    windowManager.removeListener(this);
    SystemShutdown.stopListening();
    WindowPin.stopListening();
    LinuxDesktop.stopListening();
    layoutPrefs.removeListener(_onPrefsChanged);
    layoutPrefs.zoomListenable.removeListener(_onZoomChanged);
    unawaited(_tray.dispose());
    panel.dispose();
    window = null;
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
