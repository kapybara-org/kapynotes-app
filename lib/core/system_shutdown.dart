import 'package:flutter/services.dart';

/// The one thing the Windows and Linux runners say without being asked: the
/// session is ending, or — on Windows far more often — the installer's
/// Restart Manager wants this process gone. On Linux it is also SIGTERM,
/// SIGINT or SIGHUP, which a logout or `kill` sends.
///
/// It exists because a shutdown is not a close. "Keep running in the
/// background" turns the close button into a hide, and the runner's window
/// message says nothing about which of the two a caller meant, so an installer
/// asking the window to close was answered with a hidden window and a process
/// that went on holding every file it had open. That is an update that cannot
/// replace the app it is updating.
///
/// Nothing on the phones or macOS sends this. macOS hands its updates to
/// Sparkle, which asks the app to quit the ordinary way.
class SystemShutdown {
  const SystemShutdown._();

  static const MethodChannel channel = MethodChannel(
    'kapynotes/system_shutdown',
  );

  /// Runs [quit] when the runner reports the session — or the installer — is
  /// ending.
  ///
  /// [quit] is expected to end the process. The runner gives it ten seconds
  /// before it leaves on its own terms, and Restart Manager gives the runner
  /// thirty before it stops asking.
  static void listen(Future<void> Function() quit) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'shutdown') return null;
      await quit();
      return null;
    });
  }

  static void stopListening() => channel.setMethodCallHandler(null);

  /// Ends the process on Linux, once the app has done what it does before
  /// quitting.
  ///
  /// The runner stops its main loop with the window still up. Destroying the
  /// window first, the way the other desktops leave, would leave this isolate
  /// running against a window that is gone while GTK still dispatches the
  /// calls already queued for it, and the first of those crashes the process
  /// on its way out.
  static Future<void> quit() => channel.invokeMethod<void>('quit');
}
