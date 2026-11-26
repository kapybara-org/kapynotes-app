/// Takes the background noise out of a voice recording, on the device.
///
/// A thin binding to the Rust library under rust/, which runs DPDFNet-2 the
/// way sherpa-onnx does, a frame at a time. The library is prebuilt for every
/// platform the app ships on (see hook/build.dart); [denoiseAvailable] says
/// whether this build has it.
library;

import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Why a run stopped short.
enum DenoiseFailure {
  /// [DenoiseRun.cancel] was called.
  cancelled,

  /// The model file is missing, damaged, or not DPDFNet-2.
  badModel,

  /// The recording could not be read.
  badInput,

  /// The cleaned samples could not be written, usually for want of space.
  writeFailed,

  /// Anything else.
  failed,
}

class DenoiseException implements Exception {
  const DenoiseException(this.failure, this.detail);

  final DenoiseFailure failure;

  /// The library's own words, for the log. Never shown to anyone.
  final String detail;

  @override
  String toString() => 'DenoiseException(${failure.name}): $detail';
}

/// The library's kd_abi(): bumped whenever the functions below change shape.
const int _abi = 1;

const int _messageLength = 512;

@Native<Int32 Function()>(symbol: 'kd_abi')
external int _kdAbi();

@Native<
  Int32 Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Utf8>,
    Size,
  )
>(symbol: 'kd_clean')
external int _kdClean(
  Pointer<Utf8> model,
  Pointer<Utf8> input,
  Pointer<Utf8> output,
  Pointer<Int32> progress,
  Pointer<Int32> cancel,
  Pointer<Utf8> message,
  int messageLength,
);

/// Whether this build carries the library this binding was written for.
bool get denoiseAvailable {
  try {
    return _kdAbi() == _abi;
  } on ArgumentError {
    return false;
  }
}

/// One cleaning, on an isolate of its own: about a second per minute of
/// recording on a desktop, and longer on a phone.
///
/// Cleans [input], raw 16-bit little-endian mono PCM at 16 kHz, into [output]
/// in the same format and length, with the DPDFNet-2 model at [model]. [done]
/// completes when the file is written, or fails with a [DenoiseException].
/// The caller owns both files, including a partial [output] after a failure.
class DenoiseRun {
  DenoiseRun.start({
    required String model,
    required String input,
    required String output,
  }) : _flags = calloc<Int32>(2) {
    final address = _flags.address;
    done = Isolate.run(() => _clean(address, model, input, output))
        .then((result) {
          final (code, detail) = result;
          if (code != 0) {
            throw DenoiseException(
              _failures[code] ?? DenoiseFailure.failed,
              detail,
            );
          }
        })
        .whenComplete(_release);
  }

  static const Map<int, DenoiseFailure> _failures = {
    1: DenoiseFailure.cancelled,
    2: DenoiseFailure.badModel,
    3: DenoiseFailure.badInput,
    4: DenoiseFailure.writeFailed,
    5: DenoiseFailure.failed,
  };

  /// Progress and the cancel flag, two int32s the library reads and writes
  /// from the isolate while this one watches.
  final Pointer<Int32> _flags;

  late final Future<void> done;

  double? _final;

  /// From 0 to 1.
  double get progress => _final ?? _flags.value / 10000;

  /// Stops the run at the next frame; [done] then fails as cancelled.
  void cancel() {
    if (_final == null) (_flags + 1).value = 1;
  }

  void _release() {
    _final = _flags.value / 10000;
    calloc.free(_flags);
  }
}

(int, String) _clean(int flags, String model, String input, String output) {
  final progress = Pointer<Int32>.fromAddress(flags);
  final paths = [model, input, output].map((p) => p.toNativeUtf8()).toList();
  final message = calloc<Uint8>(_messageLength);
  try {
    final code = _kdClean(
      paths[0],
      paths[1],
      paths[2],
      progress,
      progress + 1,
      message.cast(),
      _messageLength,
    );
    return (code, code == 0 ? '' : message.cast<Utf8>().toDartString());
  } finally {
    paths.forEach(calloc.free);
    calloc.free(message);
  }
}
