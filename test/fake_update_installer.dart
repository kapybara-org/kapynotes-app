import 'dart:async';

import 'package:kapy_notes/data/update_installer.dart';
import 'package:kapy_notes/data/update_manifest.dart';

/// The platform half, with every step in the test's hands: downloads wait
/// for [finish] or [fail], and nothing touches Sparkle, the disk or a
/// process.
class FakeUpdateInstaller implements UpdateInstaller {
  FakeUpdateInstaller({this.quitsTheApp = false});

  @override
  final bool quitsTheApp;

  final List<AvailableUpdate> downloads = [];
  final List<AvailableUpdate?> cleanUps = [];
  Completer<StagedUpdate>? _pending;

  /// What [restore] finds: a download an earlier run finished.
  StagedUpdate? onDisk;
  int installs = 0;
  Object? installError;

  @override
  Future<StagedUpdate> download(
    AvailableUpdate update, {
    void Function(double? fraction)? onProgress,
  }) {
    downloads.add(update);
    onProgress?.call(0.5);
    return (_pending = Completer<StagedUpdate>()).future;
  }

  void finish({String? version}) {
    final update = downloads.last;
    onDisk = StagedUpdate(
      version: version ?? update.version,
      build: version == null ? update.build : null,
    );
    _pending!.complete(onDisk);
  }

  void fail(String message) =>
      _pending!.completeError(UpdateInstallerException(message));

  @override
  Future<StagedUpdate?> restore(AvailableUpdate update) async => onDisk;

  @override
  Future<void> install() async {
    installs++;
    final error = installError;
    if (error != null) throw error;
  }

  @override
  Future<void> cleanUp({AvailableUpdate? keep}) async => cleanUps.add(keep);

  @override
  void dispose() {}
}
