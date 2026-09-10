import 'package:flutter/services.dart';

/// The macOS runner asking for the window to stop floating, because it is
/// about to put up a panel of the system's that would open underneath it.
///
/// The App menu's About item is the only caller today: `NSApplication` opens
/// that panel at the ordinary window level, where a window kept on top covers
/// it and the menu item looks like it did nothing.
///
/// The runner asks rather than simply lowering the window itself because the
/// pin is a preference as much as a window level. Dropping the level alone
/// would leave the toolbar's pin button lit over a window that no longer
/// floats, and the next press of it would try to turn off something already
/// off. [DesktopIntegration.releaseAlwaysOnTop] owns both halves, so both
/// callers go through it.
class WindowPin {
  const WindowPin._();

  static const MethodChannel channel = MethodChannel('kapynotes/window_pin');

  /// Runs [release] when the runner is about to show a window of its own.
  ///
  /// The runner waits for the reply before it puts the panel up, so this is
  /// the whole of the ordering guarantee: awaiting the window manager here is
  /// what stops the panel opening under a window that is still floating.
  static void listen(Future<void> Function() release) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'release') return null;
      await release();
      return null;
    });
  }

  static void stopListening() => channel.setMethodCallHandler(null);
}
