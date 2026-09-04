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
      unawaited(trayManager.popUpContextMenu());
      return;
    }
    onOpen();
  }

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

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
