import 'dart:async';
import 'dart:ffi';

import 'package:flutter/services.dart';

import '../core/platform.dart';

/// The native code the local engines run on, where the app does not carry it.
///
/// Parakeet runs on ONNX Runtime and Gemma on LiteRT-LM, and between them the
/// two runtimes are over a hundred megabytes of a phone's download — for a
/// feature most people will never switch on, and one that is useless without
/// a further 670 MB or 2.6 GB of model on top. So on Android the runtimes are
/// not in the app at all. They are an on-demand module that Google Play
/// delivers the first time somebody presses Download on a local model, and
/// takes back when the last model is removed. A cloud user installs the same
/// app they always did.
///
/// On the desktops the runtimes ship in the installer, because there is no
/// store to hand them out later and no store size to answer for; and on
/// Apple's platforms they are not shipped or fetched at all, because the
/// platform has its own recogniser (see `AppleTranscriber`) and iOS forbids
/// loading code the App Store did not deliver.
///
/// The store asks this before fetching any model, and reports the fetch as
/// the first stage of the download. Nothing else knows it exists.
abstract class RuntimePack {
  /// Whether this process can load the engines' native code right now.
  ///
  /// "Right now" is the point: not whether the store says it is installed,
  /// but whether `dlopen` would succeed in this process. Those differ in the
  /// minute after an install, and on a development build that carries the
  /// code itself.
  Future<bool> isInstalled();

  /// Fetches the code, reporting bytes as they arrive.
  ///
  /// [total] is 0 until the store says how much is coming. Completes when the
  /// code is loadable, and throws [RuntimePackException] when it is not going
  /// to be.
  Future<void> install({void Function(int received, int total)? onProgress});

  /// Stops a fetch that [install] started, if one is running. What arrived
  /// is the store's to keep or drop; asking again resumes where it can.
  Future<void> cancel();

  /// Lets the store reclaim it. Called when the last model that needs it is
  /// removed; the store may take its time.
  Future<void> remove();
}

/// The runtimes are in the app already. Every desktop.
class BundledRuntimePack implements RuntimePack {
  const BundledRuntimePack();

  @override
  Future<bool> isInstalled() async => true;

  @override
  Future<void> install({
    void Function(int received, int total)? onProgress,
  }) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> remove() async {}
}

/// Why a runtime could not be fetched, in words for the card.
class RuntimePackException implements Exception {
  const RuntimePackException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Google Play's on-demand module, through the runner.
///
/// The module is `speech_runtime` in `android/`, and it holds nothing but
/// the two runtimes' shared libraries. Play Feature Delivery downloads it
/// into the app's own install, so the code is loadable by name afterwards
/// like anything the app shipped with — which is what `sherpa_onnx` and
/// `flutter_gemma` both do, and why neither has to know about this.
///
/// A debug build made with `flutter run` has no Play behind it and no module
/// either: the base APK carries the libraries itself in that build type, so
/// [isInstalled] answers yes and nothing here is ever asked to fetch.
class PlayRuntimePack implements RuntimePack {
  PlayRuntimePack({MethodChannel channel = const MethodChannel(channelName)})
    : _channel = channel {
    _channel.setMethodCallHandler(_fromRunner);
  }

  static const String channelName = 'kapynotes/speech_runtime';

  /// The library Dart opens first, and the one whose presence proves the
  /// module is here as far as this process is concerned.
  static const String probeLibrary = 'libsherpa-onnx-c-api.so';

  /// Android only. Everywhere else the runtimes are bundled or absent.
  static bool get isPossibleHere => AppPlatform.isAndroid;

  final MethodChannel _channel;
  void Function(int received, int total)? _onProgress;

  @override
  Future<bool> isInstalled() async {
    if (!isPossibleHere) return false;
    // The runner's answer covers what Play has installed and made loadable
    // for Java; the `dlopen` below covers this process's own linker path,
    // which is the one `DynamicLibrary.open` will actually use.
    try {
      final installed = await _channel.invokeMethod<bool>('isInstalled');
      if (installed != true) return false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
    return _loadableHere();
  }

  @override
  Future<void> install({
    void Function(int received, int total)? onProgress,
  }) async {
    if (!isPossibleHere) {
      throw const RuntimePackException(
        'On-device models are not available on this platform.',
      );
    }
    _onProgress = onProgress;
    try {
      await _channel.invokeMethod<void>('install');
    } on PlatformException catch (error) {
      throw RuntimePackException(
        error.message ?? 'The on-device engine could not be added.',
      );
    } on MissingPluginException {
      throw const RuntimePackException(
        'This build cannot add the on-device engine.',
      );
    } finally {
      _onProgress = null;
    }
    if (!_loadableHere()) {
      throw const RuntimePackException(
        'The on-device engine was added. Quit and reopen Kapy Notes to use it.',
      );
    }
  }

  @override
  Future<void> cancel() async {
    if (!isPossibleHere) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // Nothing to cancel, or too late to: either way the install finishes
      // or fails on its own and the store hears about it from `install`.
    } on MissingPluginException {
      // A build with no runner half has nothing to cancel.
    }
  }

  @override
  Future<void> remove() async {
    if (!isPossibleHere) return;
    try {
      await _channel.invokeMethod<void>('remove');
    } on PlatformException {
      // Play declined. The module stays until it decides otherwise; it is
      // Play's disk to manage and nothing of ours depends on it going.
    } on MissingPluginException {
      // See above.
    }
  }

  Future<Object?> _fromRunner(MethodCall call) async {
    if (call.method == 'progress') {
      final arguments = call.arguments;
      if (arguments is Map) {
        final received = arguments['received'];
        final total = arguments['total'];
        _onProgress?.call(
          received is int ? received : 0,
          total is int ? total : 0,
        );
      }
    }
    return null;
  }

  /// Whether this process's linker can find the module's code by name.
  ///
  /// Opening a library twice is a reference count, not a second copy, so
  /// asking on every scan costs nothing once the answer is yes.
  static bool _loadableHere() {
    if (AppPlatform.isFlutterTest) return true;
    try {
      DynamicLibrary.open(probeLibrary);
      return true;
    } on ArgumentError {
      return false;
    }
  }
}
