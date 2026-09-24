import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_installer.dart';
import 'update_manifest.dart';
import 'update_signature.dart';

/// Downloads the Windows installer in the background, checks its signature,
/// and runs it silently when asked.
///
/// This used to be WinSparkle's job, but WinSparkle cannot download without
/// its own window on screen, which is the one thing a background download
/// must not do. The parts that made it safe are kept exactly: the same DSA
/// signature over the same bytes, checked against the same public key before
/// anything is run, and the same Inno arguments it passed.
class WindowsUpdateInstaller implements UpdateInstaller {
  WindowsUpdateInstaller({
    http.Client? client,
    @visibleForTesting Future<Directory> Function()? directory,
    @visibleForTesting
    Future<void> Function(String executable, List<String> arguments)? launch,
    @visibleForTesting this.publicKeyPem = windowsUpdatePublicKey,
  }) : _client = client,
       _ownsClient = client == null,
       _directory = directory ?? _defaultDirectory,
       _launch = launch ?? _launchDetached;

  /// What WinSparkle ran the installer with. Very silent, because the app has
  /// already said what is about to happen; Inno's `[Run]` entry guarded by
  /// `WizardSilent` brings the new version back up once it is done.
  static const installerArguments = [
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
  ];

  /// How long a download may go without a byte before it is given up on. A
  /// stall is not an error the server will ever report, so without this a
  /// dropped connection leaves the row saying "Downloading" forever.
  static const stallTimeout = Duration(seconds: 45);

  final String publicKeyPem;
  http.Client? _client;

  /// A client handed in belongs to whoever handed it in.
  final bool _ownsClient;
  final Future<Directory> Function() _directory;
  final Future<void> Function(String, List<String>) _launch;

  _Staged? _staged;
  bool _disposed = false;

  static final _safeVersion = RegExp(r'^[0-9][0-9A-Za-z.\-]{0,31}$');

  @override
  bool get quitsTheApp => false;

  /// `%LOCALAPPDATA%\com.kapybara\Kapy Notes\Updates`: local rather than
  /// roaming, because a roaming profile would carry fifty megabytes of
  /// installer to every machine the user signs in to.
  static Future<Directory> _defaultDirectory() async {
    final cache = await getApplicationCacheDirectory();
    return Directory('${cache.path}${Platform.pathSeparator}Updates');
  }

  static Future<void> _launchDetached(String executable, List<String> args) =>
      Process.start(executable, args, mode: ProcessStartMode.detached);

  Future<File> _fileFor(AvailableUpdate update) async {
    // The name comes from the manifest, so it is checked before it goes
    // anywhere near a path.
    if (!_safeVersion.hasMatch(update.version)) {
      throw const UpdateInstallerException('The update has an invalid version');
    }
    final directory = await _directory();
    return File(
      '${directory.path}${Platform.pathSeparator}'
      'KapyNotes-${update.version}-setup.exe',
    );
  }

  @override
  Future<StagedUpdate> download(
    AvailableUpdate update, {
    void Function(double? fraction)? onProgress,
  }) async {
    final package = update.windows;
    if (package == null) {
      throw const UpdateInstallerException(
        'This release has no Windows installer',
      );
    }
    final target = await _fileFor(update);
    await target.parent.create(recursive: true);

    final existing = await _stagedAt(target, update, package);
    if (existing != null) return existing;

    final partial = File('${target.path}.part');
    try {
      await _fetch(package, partial, onProgress);
    } on UpdateInstallerException {
      rethrow;
    } on TimeoutException {
      throw const UpdateInstallerException('The download stalled');
    } catch (error) {
      debugPrint('KapyNotes: the update download failed: $error');
      throw const UpdateInstallerException('Could not download the update');
    }
    if (_disposed) throw const UpdateInstallerException('Stopped');

    if (!await _verify(partial, package)) {
      await _delete(partial);
      throw const UpdateInstallerException(
        'The download did not match its signature',
      );
    }
    await _delete(target);
    await partial.rename(target.path);
    return _stage(target, update, package);
  }

  /// Streams [package] into [partial], carrying on from where an earlier
  /// attempt stopped when the server allows it.
  Future<void> _fetch(
    UpdatePackage package,
    File partial,
    void Function(double? fraction)? onProgress,
  ) async {
    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset >= package.length) {
      // Either complete but never verified, or longer than the release —
      // neither is worth trusting. Start again.
      await _delete(partial);
      offset = 0;
    }

    final request = http.Request('GET', package.url);
    if (offset > 0) request.headers['range'] = 'bytes=$offset-';
    final client = _client ??= http.Client();
    final response = await client.send(request).timeout(stallTimeout);

    final FileMode mode;
    if (response.statusCode == 206 && offset > 0) {
      final range = response.headers['content-range'] ?? '';
      if (!range.startsWith('bytes $offset-')) {
        await response.stream.drain<void>();
        await _delete(partial);
        throw const UpdateInstallerException('Could not resume the download');
      }
      mode = FileMode.append;
    } else if (response.statusCode == 200) {
      // A server that ignores the range sends the whole file again.
      offset = 0;
      mode = FileMode.write;
    } else {
      await response.stream.drain<void>();
      debugPrint(
        'KapyNotes: the update download returned HTTP ${response.statusCode}',
      );
      throw const UpdateInstallerException('Could not download the update');
    }

    final sink = partial.openWrite(mode: mode);
    var received = offset;
    onProgress?.call(received / package.length);
    try {
      await for (final chunk in response.stream.timeout(stallTimeout)) {
        if (_disposed) throw const UpdateInstallerException('Stopped');
        received += chunk.length;
        if (received > package.length) {
          throw const UpdateInstallerException(
            'The download is larger than the release',
          );
        }
        sink.add(chunk);
        onProgress?.call(received / package.length);
      }
    } finally {
      await sink.close();
    }
    if (received != package.length) {
      throw const UpdateInstallerException('The download stopped early');
    }
  }

  /// Checked in full, signature and all: this runs in the background a few
  /// seconds after launch, so the hashing is paid for long before anyone
  /// clicks, rather than between the click and the restart.
  @override
  Future<StagedUpdate?> restore(AvailableUpdate update) async {
    final package = update.windows;
    if (package == null) return null;
    try {
      return await _stagedAt(await _fileFor(update), update, package);
    } on UpdateInstallerException {
      return null;
    } catch (error) {
      debugPrint('KapyNotes: could not read a downloaded update: $error');
      return null;
    }
  }

  Future<StagedUpdate?> _stagedAt(
    File target,
    AvailableUpdate update,
    UpdatePackage package,
  ) async {
    if (!await target.exists()) return null;
    if (await target.length() == package.length &&
        await _verify(target, package)) {
      return _stage(target, update, package);
    }
    await _delete(target);
    return null;
  }

  /// Records the file as it was when its signature last verified, so that
  /// [install] can tell whether it is still that file.
  Future<StagedUpdate> _stage(
    File file,
    AvailableUpdate update,
    UpdatePackage package,
  ) async {
    final stat = await file.stat();
    _staged = _Staged(
      file: file,
      package: package,
      size: stat.size,
      modified: stat.modified,
    );
    return StagedUpdate(version: update.version, build: update.build);
  }

  @override
  Future<void> install() async {
    final staged = _staged;
    if (staged == null) {
      throw const UpdateInstallerException('Nothing is ready to install');
    }
    // The signature verified when the file was staged. Anything that has
    // touched the file since — it sits in a folder the whole user session can
    // write to — changes its size or its modification time, and then it is
    // checked again in full before it may run.
    final stat = await staged.file.stat();
    final unchanged =
        stat.type == FileSystemEntityType.file &&
        stat.size == staged.size &&
        stat.modified == staged.modified;
    if (!unchanged && !await _verify(staged.file, staged.package)) {
      _staged = null;
      await _delete(staged.file);
      throw const UpdateInstallerException('The downloaded update was damaged');
    }
    try {
      await _launch(staged.file.path, installerArguments);
    } catch (error) {
      debugPrint('KapyNotes: could not start the installer: $error');
      throw const UpdateInstallerException('Could not start the installer');
    }
  }

  @override
  Future<void> cleanUp({AvailableUpdate? keep}) async {
    try {
      final directory = await _directory();
      if (!await directory.exists()) return;
      final kept = keep == null || !_safeVersion.hasMatch(keep.version)
          ? null
          : (await _fileFor(keep)).path;
      await for (final entry in directory.list()) {
        if (entry is! File) continue;
        if (kept != null &&
            (entry.path == kept || entry.path == '$kept.part')) {
          continue;
        }
        await _delete(entry);
      }
    } catch (error) {
      debugPrint('KapyNotes: could not tidy downloaded updates: $error');
    }
  }

  Future<bool> _verify(File file, UpdatePackage package) async {
    final path = file.path;
    final signature = package.signature;
    final key = publicKeyPem;
    try {
      // Fifty-odd megabytes of SHA-1, which would otherwise be dropped
      // frames.
      return await Isolate.run(
        () => verifyInstallerSignature(
          File(path),
          signature: signature,
          publicKeyPem: key,
        ),
      );
    } catch (error) {
      debugPrint('KapyNotes: could not check the update signature: $error');
      return false;
    }
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('KapyNotes: could not delete ${file.path}: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsClient) _client?.close();
  }
}

class _Staged {
  const _Staged({
    required this.file,
    required this.package,
    required this.size,
    required this.modified,
  });

  final File file;
  final UpdatePackage package;
  final int size;
  final DateTime modified;
}
