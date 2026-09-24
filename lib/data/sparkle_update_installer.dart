import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'update_installer.dart';
import 'update_manifest.dart';

/// Drives Sparkle through `macos/Runner/Updater.swift`: the release downloads
/// in the background, and installs and relaunches on one click, without
/// Sparkle opening a window of its own.
///
/// Sparkle reads its own appcast rather than the manifest, and checks the
/// release's EdDSA signature and code signature before it will install it,
/// so none of that is repeated here. What it hands back is a version that is
/// ready, or a reason it is not.
class SparkleUpdateInstaller implements UpdateInstaller {
  SparkleUpdateInstaller({
    required this.feedUrl,
    @visibleForTesting MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('kapynotes/updater') {
    _channel.setMethodCallHandler(_onEvent);
  }

  static const _downloadFailed = 'Could not download the update';

  final String feedUrl;
  final MethodChannel _channel;

  Completer<StagedUpdate>? _pending;
  StagedUpdate? _ready;
  bool _disposed = false;

  @override
  bool get quitsTheApp => true;

  @override
  Future<StagedUpdate> download(
    AvailableUpdate update, {
    void Function(double? fraction)? onProgress,
  }) {
    final ready = _ready;
    if (ready != null) return Future.value(ready);
    final pending = _pending;
    if (pending != null) return pending.future;
    final completer = _pending = Completer<StagedUpdate>();
    // Sparkle reports no progress for a download it makes in the background.
    onProgress?.call(null);
    unawaited(_start());
    return completer.future;
  }

  Future<void> _start() async {
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>(
        'download',
        {'feedUrl': feedUrl},
      );
      switch (reply?['status']) {
        case 'ready':
          _finish(reply!);
        // Either way the answer arrives as an event. "busy" is Sparkle
        // already in the middle of something — an earlier request, or a
        // window of its own — and it reports when that ends.
        case 'started' || 'busy':
          break;
        default:
          debugPrint(
            'KapyNotes: Sparkle would not start: ${reply?['message']}',
          );
          _fail(_downloadFailed);
      }
    } on PlatformException catch (error) {
      debugPrint('KapyNotes: Sparkle would not start: ${error.message}');
      _fail(_downloadFailed);
    } on MissingPluginException {
      _fail('This build cannot update itself');
    }
  }

  Future<Object?> _onEvent(MethodCall call) async {
    if (_disposed) return null;
    final arguments = call.arguments;
    final details = arguments is Map ? arguments : const <Object?, Object?>{};
    switch (call.method) {
      case 'ready':
        _finish(details);
      case 'failed':
        debugPrint('KapyNotes: Sparkle failed: ${details['message']}');
        _fail(_downloadFailed);
      // The manifest said there was a release and the appcast disagreed:
      // one was read either side of a release, or has not propagated yet.
      // Nothing is wrong that the next attempt will not settle.
      case 'notFound':
        _fail('The update is not ready to download yet');
      // The end of Sparkle's cycle. Ready or failed has normally been said
      // by now; if neither was, the cycle ended some other way — its own
      // window closed, most likely — and the download is not coming.
      case 'finished':
        if (_ready == null) _fail(_downloadFailed);
    }
    return null;
  }

  void _finish(Map<Object?, Object?> details) {
    final version = details['version'];
    if (version is! String || version.isEmpty) {
      _fail(_downloadFailed);
      return;
    }
    final build = details['build'];
    final staged = StagedUpdate(
      version: version,
      build: build is String ? int.tryParse(build) : null,
    );
    _ready = staged;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(staged);
  }

  void _fail(String message) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(UpdateInstallerException(message));
    }
  }

  @override
  Future<StagedUpdate?> restore(AvailableUpdate update) async => _ready;

  @override
  Future<void> install() async {
    if (_ready == null) {
      throw const UpdateInstallerException('Nothing is ready to install');
    }
    final bool? started;
    try {
      started = await _channel.invokeMethod<bool>('install');
    } on PlatformException catch (error) {
      debugPrint('KapyNotes: Sparkle would not install: ${error.message}');
      throw const UpdateInstallerException('Could not install the update');
    } on MissingPluginException {
      throw const UpdateInstallerException('This build cannot update itself');
    }
    if (started != true) {
      // Sparkle no longer holds a prepared update — its installer went away
      // under it. Forget ours too, so the next attempt downloads again.
      _ready = null;
      throw const UpdateInstallerException('The download is no longer ready');
    }
  }

  @override
  Future<void> cleanUp({AvailableUpdate? keep}) async {}

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    _fail('Stopped');
  }
}
