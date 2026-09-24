import 'package:http/http.dart' as http;

import '../core/platform.dart';
import 'sparkle_update_installer.dart';
import 'update_manifest.dart';
import 'windows_update_installer.dart';

/// A release that has been downloaded and checked, and is one click away
/// from being installed.
class StagedUpdate {
  const StagedUpdate({required this.version, this.build});

  final String version;

  /// Null where the platform cannot say. Windows builds carry no build
  /// number at all: see `UpdateChecker`.
  final int? build;
}

/// Why a download or an install did not happen, in words fit for the row
/// that reports it.
class UpdateInstallerException implements Exception {
  const UpdateInstallerException(this.message);

  final String message;

  @override
  String toString() => 'UpdateInstallerException: $message';
}

/// The platform half of an update: fetching a release in the background and,
/// on request, installing it and starting the new version.
///
/// `UpdateChecker` decides *whether* there is a release and *when* to fetch
/// it; this does the fetching. Sparkle on macOS, because a sandboxed app
/// cannot replace its own bundle and Sparkle's installer service can. On
/// Windows the app downloads and checks the installer itself, since
/// WinSparkle can only download with its own window on screen.
abstract class UpdateInstaller {
  /// Whether [install] ends the process by itself.
  ///
  /// Sparkle does: it asks the app to quit, the same way the menu's Quit
  /// does, and starts the new version once it has. The Windows installer
  /// needs the app to leave on its own, or it waits on files still in use.
  bool get quitsTheApp;

  /// Fetches [update] and prepares it, completing once [install] can run.
  ///
  /// [onProgress] reports the fraction received, or null while that is not
  /// known. Throws [UpdateInstallerException].
  Future<StagedUpdate> download(
    AvailableUpdate update, {
    void Function(double? fraction)? onProgress,
  });

  /// A download an earlier run finished, if it is still there. Null
  /// otherwise, and always on macOS, where quitting installs it.
  Future<StagedUpdate?> restore(AvailableUpdate update);

  /// Installs what [download] prepared, and starts the new version.
  /// Throws [UpdateInstallerException].
  Future<void> install();

  /// Deletes anything downloaded for a release other than [keep].
  Future<void> cleanUp({AvailableUpdate? keep});

  void dispose();

  /// The installer for the platform the app is running on, or null where it
  /// cannot update itself — and in widget tests, which must never start
  /// Sparkle or a download on the machine running them.
  static UpdateInstaller? forCurrentPlatform({
    required String macFeedUrl,
    http.Client? client,
  }) {
    if (AppPlatform.isFlutterTest) return null;
    if (AppPlatform.isMacOS) return SparkleUpdateInstaller(feedUrl: macFeedUrl);
    if (AppPlatform.isWindows) return WindowsUpdateInstaller(client: client);
    return null;
  }
}
