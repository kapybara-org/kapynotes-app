import 'dart:async';
import 'dart:io';

import 'package:denoise/denoise.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/clean_copies.dart';
import 'audio_decode.dart';

/// Why a cleaning stopped short.
enum NoiseRemovalFailure {
  /// The person stopped it.
  cancelled,

  /// The downloaded model is damaged or the wrong file; fetching it again is
  /// the remedy.
  model,

  /// The recording itself could not be read.
  recording,

  /// The copy could not be written, usually for want of space.
  storage,

  /// Anything else.
  other,
}

class NoiseRemovalException implements Exception {
  const NoiseRemovalException(this.failure, this.detail);

  final NoiseRemovalFailure failure;

  /// For the log. The words a person sees are the caller's to choose.
  final String detail;

  @override
  String toString() => 'NoiseRemovalException(${failure.name}): $detail';
}

/// Turns PCM into the app's recording format, leaving nothing at
/// [destination] if it fails. [AacEncoder.encode] in the app; a stand-in in
/// tests.
typedef EncodeRecording = Future<void> Function(File pcm, File destination);

/// Starts the cleaner on two PCM files. [DenoiseRun.start] in the app.
typedef StartDenoise =
    DenoiseRun Function({
      required String model,
      required String input,
      required String output,
    });

/// Cleans a recording into its copy: decoded with the platform's own decoder,
/// cleaned by DPDFNet-2, and encoded back into the original's format, so the
/// copy plays, saves and shares exactly as the original does.
///
/// The original is only ever read. The two PCM files in between, about 4 MB
/// per minute of recording, live in the temporary directory and are deleted
/// however the run ends.
class NoiseRemover {
  NoiseRemover({
    required this.copies,
    AudioDecoder decoder = const AudioDecoder(),
    EncodeRecording? encode,
    StartDenoise start = DenoiseRun.start,
  }) : _decoder = decoder,
       _encode = encode ?? const AacEncoder().encode,
       _start = start;

  final CleanCopies copies;
  final AudioDecoder _decoder;
  final EncodeRecording _encode;
  final StartDenoise _start;

  /// Whether this build can clean at all.
  static bool get isPossibleHere => denoiseAvailable;

  /// Starts cleaning [recording], whose blob hash is [hash], with the model
  /// file at [model].
  NoiseRemovalRun clean({
    required File recording,
    required String hash,
    required File model,
  }) {
    final run = NoiseRemovalRun._();
    run.done = _clean(run, recording, hash, model);
    return run;
  }

  Future<File> _clean(
    NoiseRemovalRun run,
    File recording,
    String hash,
    File model,
  ) async {
    DecodedAudio? decoded;
    File? cleaned;
    try {
      final destination = await copies.fileFor(hash);
      decoded = await _decoder.decode(recording);
      run._check();
      cleaned = File('${decoded.file.path}.clean');
      final denoise = _start(
        model: model.path,
        input: decoded.file.path,
        output: cleaned.path,
      );
      run._denoise = denoise;
      final ticker = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => run._progress.value = denoise.progress * _cleaningShare,
      );
      try {
        await denoise.done;
      } finally {
        ticker.cancel();
        run._denoise = null;
      }
      run._check();
      run._progress.value = _cleaningShare;
      await destination.parent.create(recursive: true);
      await _encode(cleaned, destination);
      run._progress.value = 1;
      return destination;
    } on NoiseRemovalException {
      rethrow;
    } on DenoiseException catch (error) {
      throw NoiseRemovalException(switch (error.failure) {
        DenoiseFailure.cancelled => NoiseRemovalFailure.cancelled,
        DenoiseFailure.badModel => NoiseRemovalFailure.model,
        DenoiseFailure.badInput => NoiseRemovalFailure.recording,
        DenoiseFailure.writeFailed => NoiseRemovalFailure.storage,
        DenoiseFailure.failed => NoiseRemovalFailure.other,
      }, error.detail);
    } on AudioDecodeException catch (error) {
      throw NoiseRemovalException(NoiseRemovalFailure.recording, error.message);
    } on FileSystemException catch (error) {
      throw NoiseRemovalException(NoiseRemovalFailure.storage, '$error');
    } catch (error) {
      throw NoiseRemovalException(NoiseRemovalFailure.other, '$error');
    } finally {
      await decoded?.dispose();
      try {
        if (cleaned != null && await cleaned.exists()) await cleaned.delete();
      } on FileSystemException {
        // Temporary debris the OS takes later.
      }
    }
  }

  /// The share of [NoiseRemovalRun.progress] the model's pass stands for.
  /// Decoding and encoding take seconds even for thirty minutes; the model
  /// takes the rest.
  static const double _cleaningShare = 0.95;
}

/// A cleaning in progress.
class NoiseRemovalRun {
  NoiseRemovalRun._();

  final ValueNotifier<double> _progress = ValueNotifier(0);
  DenoiseRun? _denoise;
  bool _cancelled = false;

  /// The copy once it is written; fails with a [NoiseRemovalException].
  late final Future<File> done;

  /// From 0 to 1.
  ValueListenable<double> get progress => _progress;

  /// Stops the run as soon as it can; [done] then fails as
  /// [NoiseRemovalFailure.cancelled] and nothing is left behind.
  void cancel() {
    _cancelled = true;
    _denoise?.cancel();
  }

  void _check() {
    if (_cancelled) {
      throw const NoiseRemovalException(
        NoiseRemovalFailure.cancelled,
        'cancelled',
      );
    }
  }
}

/// Lists the noise removal model's licence on the licences page. The model is
/// downloaded rather than bundled, but it is still part of what the app runs.
void registerNoiseModelLicense() {
  if (!NoiseRemover.isPossibleHere) return;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'DPDFNet-2 (Ceva)',
    ], await rootBundle.loadString('assets/audio/DPDFNet-LICENSE.txt'));
  });
}
