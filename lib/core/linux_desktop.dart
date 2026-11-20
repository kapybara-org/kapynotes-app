import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform.dart';

/// The `kapynotes/linux` channel: what the Linux session can do for the
/// app, which depends on the desktop the person runs rather than on the OS.
///
/// Every question answers rather than throws. A host with no runner behind
/// the channel is taken to be an X11 session with nothing to draw a tray
/// icon.
class LinuxDesktop {
  const LinuxDesktop._();

  @visibleForTesting
  static const MethodChannel channel = MethodChannel('kapynotes/linux');

  /// Whether GTK is drawing through Wayland, where an app can neither place
  /// its own window nor listen for keys pressed in other apps.
  static Future<bool> isWayland() => _ask('isWayland');

  /// Whether a StatusNotifierWatcher with a host is on the session bus, which
  /// is what makes a tray icon appear. Stock GNOME has none, and accepts an
  /// icon it never shows. Asked afresh each time: a host arrives or leaves
  /// when an extension is switched on or a panel restarts.
  static Future<bool> hasTrayHost() => _ask('hasTrayHost');

  /// Whether the session bus has a keyring, or can start one. A missing bus
  /// answers no. Not Linux answers yes: other platforms keep their own store.
  static Future<bool> hasKeyring() async {
    if (!AppPlatform.isLinux) return true;
    try {
      return await channel.invokeMethod<bool>('hasKeyring') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _ask(String method) async {
    if (!AppPlatform.isLinux) return false;
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Runs [onNewNote] when a launch asks for a new note: `kapynotes
  /// --new-note`, which is what a system shortcut runs on Wayland.
  static void listen({required VoidCallback onNewNote}) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'newNote') onNewNote();
      return null;
    });
  }

  static void stopListening() => channel.setMethodCallHandler(null);

  /// The command that starts this copy of the app, for an autostart entry or
  /// a system shortcut to run.
  ///
  /// The AppImage's own path rather than the mount it runs from, which moves
  /// every launch; the .deb's /usr/bin/kapynotes; and otherwise the binary
  /// itself, wherever the tarball was unpacked.
  static String launchCommand({
    Map<String, String>? environment,
    String? executable,
    String installed = '/usr/bin/kapynotes',
  }) {
    final appImage = (environment ?? Platform.environment)['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) return appImage;
    final running = executable ?? Platform.resolvedExecutable;
    try {
      if (File(installed).resolveSymbolicLinksSync() == running) {
        return installed;
      }
    } on FileSystemException {
      // Not installed from the .deb.
    }
    return running;
  }

  /// [launchCommand] as a person would type it into a shortcut's command
  /// field: the bare name where it is on PATH, and otherwise the path, in
  /// single quotes when a shell would read anything in it as syntax. The
  /// Flatpak's own path is inside its sandbox, so the host starts it by ID.
  static String shortcutCommand([String? command]) {
    if (AppPlatform.isFlatpak) return 'flatpak run com.kapybara.kapynotes';
    final launch = command ?? launchCommand();
    if (launch == '/usr/bin/kapynotes') return 'kapynotes';
    return RegExp(r'^[\w./+@%:,=-]+$').hasMatch(launch)
        ? launch
        : "'${launch.replaceAll("'", r"'\''")}'";
  }
}
