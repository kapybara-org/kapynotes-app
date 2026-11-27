import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';

import 'platform.dart';

/// The notification-area icon on Windows, the menu bar item on macOS, and
/// on Linux the indicator a panel draws.
///
/// It exists only while the app is set to keep running past its window, and
/// that is not a coincidence: a hidden window with nothing in the tray is an
/// app with no way back and no way out. The two are switched together, and
/// [DesktopIntegration] is the only thing that switches them.
class AppTray with TrayListener {
  AppTray({
    required this.onOpen,
    required this.onNewNote,
    required this.onNewTask,
    required this.onSettings,
    required this.onQuit,
    required this.onClick,
  });

  /// Bring the window forward. Also what a Windows tray click means.
  final VoidCallback onOpen;
  final VoidCallback onNewNote;
  final VoidCallback onNewTask;
  final VoidCallback onSettings;
  final VoidCallback onQuit;

  /// A plain click on the macOS menu bar item: opens or closes the menu bar
  /// panel and answers true, or answers false for the menu to open instead.
  final Future<bool> Function() onClick;

  static const String _openKey = 'open';
  static const String _newNoteKey = 'new-note';
  static const String _newTaskKey = 'new-task';
  static const String _settingsKey = 'settings';
  static const String _quitKey = 'quit';

  /// Windows draws the notification area from an .ico and picks the size it
  /// wants out of it; macOS is handed one template image and tints it. A
  /// Linux panel scales one full-colour PNG, which reads on light panels and
  /// dark ones alike.
  static const String _icon = 'assets/branding/kapynotes_tray_windows.ico';
  static const String templateIcon = 'assets/branding/kapynotes_tray_macos.png';
  static const String _linuxIcon = 'assets/branding/kapynotes_tray_linux.png';

  /// The icon's own button, which takes a press through accessibility
  /// (macos/Runner/MenuBarIcon.swift). tray_manager only hears the mouse.
  static const MethodChannel _button = MethodChannel('kapynotes/menubar_icon');

  bool _visible = false;

  bool get isVisible => _visible;

  /// Never throws. A tray is a convenience, and a host that refuses one —
  /// a Windows session with the notification area locked down, a macOS menu
  /// bar with no room left — must not take the app down with it.
  Future<void> setVisible(bool visible, {String toolTip = 'Kapy Notes'}) async {
    if (visible == _visible) return;
    _visible = visible;

    try {
      if (!visible) {
        trayManager.removeListener(this);
        if (AppPlatform.isMacOS) _button.setMethodCallHandler(null);
        await trayManager.destroy();
        return;
      }

      trayManager.addListener(this);
      await trayManager.setIcon(
        AppPlatform.isMacOS
            ? templateIcon
            : AppPlatform.isLinux
            ? _linuxIcon
            : _icon,
        isTemplate: true,
      );
      // An indicator has no tooltip, and tray_manager's Linux side refuses
      // the call rather than ignoring it.
      if (!AppPlatform.isLinux) await trayManager.setToolTip(toolTip);
      await trayManager.setContextMenu(_menu());
      if (AppPlatform.isMacOS) unawaited(_takePresses());
    } catch (error, stack) {
      // Leaves the flag where the caller asked for it: a second attempt is
      // the user toggling the setting again, which should retry rather than
      // silently no-op.
      _visible = !visible;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'kapy notes',
          context: ErrorDescription('setting up the tray icon'),
        ),
      );
    }
  }

  Menu _menu() => Menu(
    items: [
      MenuItem(key: _openKey, label: 'Open Kapy Notes'),
      MenuItem(key: _newNoteKey, label: 'New Note'),
      if (AppPlatform.isMacOS) ...[
        MenuItem(key: _newTaskKey, label: 'New Task'),
        MenuItem.separator(),
        MenuItem(key: _settingsKey, label: 'Settings…'),
      ] else
        MenuItem.separator(),
      // Always last, always present. This is the only way out of an app whose
      // window closes to the tray, so nothing may ever hide it.
      MenuItem(key: _quitKey, label: 'Quit Kapy Notes'),
    ],
  );

  /// Changes what the icon says on hover, while it is showing.
  Future<void> setToolTip(String toolTip) async {
    if (!_visible) return;
    try {
      await trayManager.setToolTip(toolTip);
    } catch (_) {
      // Only the hover text; the icon itself is unaffected.
    }
  }

  @override
  void onTrayIconMouseDown() {
    // A Windows tray icon opens its app on click and its menu on right-click.
    // A macOS menu bar item opens the menu bar panel on click, and its menu on
    // right-click, ⌃-click, or wherever there is no panel.
    if (AppPlatform.isMacOS) {
      unawaited(_click());
      return;
    }
    onOpen();
  }

  /// A press on the icon through accessibility is a click on it.
  Future<void> _takePresses() async {
    _button.setMethodCallHandler((call) async {
      if (call.method == 'pressed') await _click();
    });
    try {
      await _button.invokeMethod<bool>('takePresses');
    } on MissingPluginException {
      // No native side, as under flutter test: only the mouse opens it.
    }
  }

  Future<void> _click() async {
    if (await onClick()) return;
    await _showMenu();
  }

  @override
  void onTrayIconRightMouseDown() => unawaited(_showMenu());

  /// Opens the menu, and on Windows makes it possible to close again.
  ///
  /// `TrackPopupMenu` only cancels on a click elsewhere when the window that
  /// owns it is the foreground window. Microsoft has said so since KB135788,
  /// and `tray_manager` calls `SetForegroundWindow` only when asked — which it
  /// is not by default. Without this the menu opens over the notification area
  /// and then will not go away: clicking outside does nothing, and it sits on
  /// top of every other window until an item is picked.
  ///
  /// Upstream deprecates the parameter for being Windows-only, which is
  /// exactly what it is wanted for, so the deprecation is the wrong signal
  /// rather than a warning worth acting on. If a later `tray_manager` removes
  /// it this stops compiling, which beats quietly returning to a menu nobody
  /// can dismiss. There is nowhere newer to move: 0.5.3 is the latest release
  /// and carries the same code.
  Future<void> _showMenu() => trayManager.popUpContextMenu(
    // ignore: deprecated_member_use
    bringAppToFront: AppPlatform.isWindows,
  );

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _openKey:
        onOpen();
      case _newNoteKey:
        onNewNote();
      case _newTaskKey:
        onNewTask();
      case _settingsKey:
        onSettings();
      case _quitKey:
        onQuit();
    }
  }

  Future<void> dispose() async {
    trayManager.removeListener(this);
    if (_visible) {
      _visible = false;
      try {
        await trayManager.destroy();
      } catch (_) {
        // Nothing left to do about it; the process is on its way out.
      }
    }
  }
}
