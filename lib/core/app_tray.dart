import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import 'platform.dart';

/// The notification-area icon on Windows, the menu bar item on macOS.
///
/// It exists only while the app is set to keep running past its window, and
/// that is not a coincidence: a hidden window with nothing in the tray is an
/// app with no way back and no way out. The two are switched together, and
/// [DesktopIntegration] is the only thing that switches them.
class AppTray with TrayListener {
  AppTray({
    required this.onOpen,
    required this.onNewNote,
    required this.onQuit,
  });

  /// Bring the window forward. Also what a Windows tray click means.
  final VoidCallback onOpen;
  final VoidCallback onNewNote;
  final VoidCallback onQuit;

  static const String _openKey = 'open';
  static const String _newNoteKey = 'new-note';
  static const String _quitKey = 'quit';

  /// Windows draws the notification area from an .ico and picks the size it
  /// wants out of it; macOS is handed one template image and tints it.
  static const String _icon = 'assets/branding/kapynotes_tray_windows.ico';
  static const String _templateIcon =
      'assets/branding/kapynotes_tray_macos.png';

  bool _visible = false;

  bool get isVisible => _visible;

  /// Never throws. A tray is a convenience, and a host that refuses one —
  /// a Windows session with the notification area locked down, a macOS menu
  /// bar with no room left — must not take the app down with it.
  Future<void> setVisible(bool visible) async {
    if (visible == _visible) return;
    _visible = visible;

    try {
      if (!visible) {
        trayManager.removeListener(this);
        await trayManager.destroy();
        return;
      }

      trayManager.addListener(this);
      await trayManager.setIcon(
        AppPlatform.isMacOS ? _templateIcon : _icon,
        isTemplate: true,
      );
      await trayManager.setToolTip('Kapy Notes');
      await trayManager.setContextMenu(_menu());
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
      MenuItem.separator(),
      // Always last, always present. This is the only way out of an app whose
      // window closes to the tray, so nothing may ever hide it.
      MenuItem(key: _quitKey, label: 'Quit Kapy Notes'),
    ],
  );

  @override
  void onTrayIconMouseDown() {
    // A Windows tray icon opens its app on click and its menu on right-click.
    // A macOS menu bar item opens its menu either way.
    if (AppPlatform.isMacOS) {
      unawaited(_showMenu());
      return;
    }
    onOpen();
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
