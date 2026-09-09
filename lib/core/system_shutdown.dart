import 'package:flutter/services.dart';

/// The one thing the Windows runner says without being asked: Windows — or,
/// far more often, the installer's Restart Manager — wants this process gone.
///
/// It exists because a shutdown is not a close. "Keep running in the
/// background" turns the close button into a hide, and the runner's window
/// message says nothing about which of the two a caller meant, so an installer
/// asking the window to close was answered with a hidden window and a process
/// that went on holding every file it had open. That is an update that cannot
/// replace the app it is updating.
///
/// Nothing on the other platforms sends this. macOS hands its updates to
/// Sparkle, which quits the host itself.
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
}
