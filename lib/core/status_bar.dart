import 'package:flutter/services.dart';

/// Android's status bar, hidden while a phone on its side has the keyboard up
/// so the lines being typed get its room.
///
/// Only the bar's visibility changes: the window keeps whatever system UI mode
/// it has, edge-to-edge on Android 15 and later, so showing the bar again
/// leaves the app as it was. A [SystemChrome] mode would put one in place
/// instead, and [SystemUiMode.edgeToEdge] does nothing before Android 10.
///
/// Only Android answers on this channel. Anywhere else, or if Android refuses,
/// the bar stays as it is.
class StatusBar {
  const StatusBar._();

  static const MethodChannel channel = MethodChannel('kapynotes/status_bar');

  static Future<void> setHidden(bool hidden) async {
    try {
      await channel.invokeMethod<void>(hidden ? 'hide' : 'show');
    } catch (_) {
      // A bar left as it was costs some room and nothing else.
    }
  }
}
