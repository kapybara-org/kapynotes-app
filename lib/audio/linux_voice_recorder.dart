import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'linux_ffmpeg.dart';
import 'voice_recorder.dart';

/// Records a voice note on Linux.
///
/// One ffmpeg captures the microphone from PulseAudio as raw samples, this
/// passes them on, and a second ffmpeg encodes them into the same AAC-in-
/// `.m4a` every other platform writes, at [VoiceRecorder.config].
///
/// Not `package:record`'s Linux side, although it runs the same two kinds of
/// program, because of three things measured on it:
///
///   * **A pause recorded the pause.** It pauses by sending the capture
///     process SIGSTOP, and PulseAudio goes on filling a stopped client's
///     buffer, so all of it arrived on resume: two seconds, a four-second
///     pause and two more made an eight-second note. Here a pause ends
///     capture, and resuming starts a new one; nothing said in between can
///     reach the file.
///   * **Stopping while paused kept the microphone.** The stopped process
///     never saw the signal meant to end it.
///   * **A failed capture made an empty note.** With no sound server the
///     capture exits at once, the encoder writes a file with no audio in it,
///     and the elapsed timer gives it a length. Here [start] waits for the
///     first samples and fails if they do not come, and a capture that dies
///     partway is reported as an interruption the user can resume from.
class LinuxVoiceRecorder implements VoiceRecorderBackend {
  /// How long [start] and [resume] wait for the microphone's first samples.
  ///
  /// A capture that works delivers them within a tenth of a second; one that
  /// has not in this long is not going to, and a hang here is a frozen
  /// "Starting recording…".
  static const Duration _firstSamples = Duration(seconds: 5);

  /// How long finishing the file may take before the encoder is given up on.
  ///
  /// Writing the `moov` box of a thirty-minute note takes milliseconds;
  /// this is only so a wedged encoder cannot hold the app's exit forever.
  static const Duration _finishing = Duration(seconds: 30);

  final _amplitude = StreamController<double>.broadcast();
  final _paused = StreamController<bool>.broadcast();

  String? _path;
  Process? _encoder;
  Process? _capture;
  StreamSubscription<List<int>>? _samples;

  /// The first byte of a sample split across two reads. Samples are two
  /// bytes, and a pipe is free to hand them over one byte at a time; passing
  /// half of one on and dropping the rest would shift every sample after it.
  int? _carry;

  /// The loudest sample since the last level, and how many samples that was.
  int _loudest = 0;
  int _measured = 0;

  @override
  Future<bool> hasPermission() async => true;

  /// Asks the sound server, through the ffmpeg that would record, what it
  /// can record from. Anything short of a definite "nothing" records as
  /// before, and [start] finds out for itself: no ffmpeg to ask, or an
  /// answer this does not recognise.
  @override
  Future<bool> hasMicrophone() async {
    try {
      final result = await Process.run(ffmpegExecutable, [
        '-hide_banner',
        '-sources',
        'pulse',
      ]);
      return listsMicrophone('${result.stdout}') ?? true;
    } on ProcessException {
      return true;
    }
  }

  /// Whether what `ffmpeg -sources pulse` printed lists a microphone, or
  /// null when it does not say either way.
  ///
  /// Two answers are a definite no. A sound server with no microphone still
  /// lists its outputs' monitors, `auto_null.monitor` on a computer with no
  /// sound card at all, and its default source is then one of them, so a
  /// list of nothing but monitors records silence. And a listing that could
  /// not reach a sound server means capture, which goes to the same server
  /// through the same library, cannot either.
  @visibleForTesting
  static bool? listsMicrophone(String output) {
    if (!output.contains('Auto-detected sources for pulse:')) return null;
    if (output.contains('Cannot list sources')) return false;
    final sources = RegExp(
      r'^[* ] (\S+) \[',
      multiLine: true,
    ).allMatches(output).map((source) => source.group(1)!).toList();
    if (sources.isEmpty) return null;
    return sources.any((name) => !name.endsWith('.monitor'));
  }

  @override
  Future<void> start(String path) async {
    final config = VoiceRecorder.config;
    _path = path;
    try {
      final encoder = await startFfmpeg([
        '-f',
        's16le',
        '-ar',
        '${config.sampleRate}',
        '-ac',
        '${config.numChannels}',
        '-i',
        'pipe:0',
        '-c:a',
        'aac',
        '-b:a',
        '${config.bitRate}',
        '-f',
        'ipod',
        '-y',
        path,
      ]);
      _encoder = encoder;
      _watchEncoder(encoder);
      await _startCapture();
    } catch (_) {
      _path = null;
      await _finish();
      try {
        await File(path).delete();
      } on FileSystemException {
        // Never written: the encoder had nothing to start it.
      }
      rethrow;
    }
  }

  @override
  Future<void> pause() async => _stopCapture();

  /// Starts capture again, into the same file.
  ///
  /// When the microphone will not come back, the recording stays interrupted
  /// rather than this throwing: what was recorded is still there to be saved.
  /// The news goes out on a timer, so it lands after the controller has
  /// finished treating this resume as a success.
  @override
  Future<void> resume() async {
    if (_path == null || _capture != null) return;
    try {
      if (_encoder == null) throw StateError('the encoder has stopped');
      await _startCapture();
    } catch (error) {
      debugPrint('KapyNotes: could not resume recording: $error');
      Timer.run(() {
        if (!_paused.isClosed) _paused.add(true);
      });
    }
  }

  @override
  Future<String?> stop() async {
    final path = _path;
    _path = null;
    await _finish();
    return path;
  }

  /// Stops, and leaves the file for the caller to delete, as
  /// [VoiceRecorder.cancel] does.
  @override
  Future<void> cancel() async {
    await stop();
  }

  @override
  Stream<double> get amplitude => _amplitude.stream;

  @override
  Stream<bool> get paused => _paused.stream;

  @override
  Future<void> dispose() async {
    _path = null;
    await _finish();
    await _amplitude.close();
    await _paused.close();
  }

  /// Captures the default source, a packet a tenth of a second, which is
  /// also how often the level meter moves. Completes once the first samples
  /// arrive.
  Future<void> _startCapture() async {
    final config = VoiceRecorder.config;
    final capture = await startFfmpeg([
      '-f',
      'pulse',
      '-name',
      'Kapy Notes',
      '-stream_name',
      'Voice note',
      '-sample_rate',
      '${config.sampleRate}',
      '-channels',
      '${config.numChannels}',
      '-fragment_size',
      '${config.sampleRate * config.numChannels * 2 ~/ 10}',
      '-i',
      'default',
      '-c:a',
      'copy',
      '-f',
      's16le',
      'pipe:1',
    ]);
    _capture = capture;
    _carry = null;
    final errors = ffmpegErrors(capture);
    final heard = Completer<void>();
    _samples = capture.stdout.listen((chunk) {
      if (!identical(capture, _capture)) return;
      if (!heard.isCompleted) heard.complete();
      _forward(chunk);
    }, onError: (Object _) {});
    unawaited(
      capture.exitCode.then((code) async {
        if (!identical(capture, _capture)) return;
        _capture = null;
        _carry = null;
        await _samples?.cancel();
        _samples = null;
        final reason =
            'the microphone stopped (ffmpeg exited $code): '
            '${await errors}';
        if (!heard.isCompleted) {
          heard.completeError(
            ProcessException(ffmpegExecutable, const [], reason, code),
          );
          return;
        }
        debugPrint('KapyNotes: $reason');
        if (!_paused.isClosed) _paused.add(true);
      }),
    );
    try {
      await heard.future.timeout(_firstSamples);
    } catch (_) {
      await _stopCapture();
      rethrow;
    }
  }

  /// Ends capture at once, and completes once the microphone is free.
  /// Whatever it had not yet handed over belongs to the moment the user
  /// stopped or paused, and is dropped with it.
  Future<void> _stopCapture() async {
    final capture = _capture;
    _capture = null;
    _carry = null;
    await _samples?.cancel();
    _samples = null;
    if (capture == null) return;
    capture.kill(ProcessSignal.sigkill);
    await capture.exitCode;
  }

  void _forward(List<int> chunk) {
    final carry = _carry;
    final bytes = carry == null ? chunk : [carry, ...chunk];
    final whole = bytes.length & ~1;
    _carry = whole < bytes.length ? bytes[whole] : null;
    if (whole == 0) return;
    final samples = whole == bytes.length ? bytes : bytes.sublist(0, whole);
    _encoder?.stdin.add(samples);
    _measure(samples);
  }

  /// One level a tenth of a second, in dBFS from the loudest sample in it,
  /// which is what `record` reports on the other platforms.
  void _measure(List<int> samples) {
    final window = VoiceRecorder.config.sampleRate ~/ 10;
    for (var i = 0; i + 1 < samples.length; i += 2) {
      final raw = samples[i] | (samples[i + 1] << 8);
      final magnitude = (raw >= 0x8000 ? raw - 0x10000 : raw).abs();
      if (magnitude > _loudest) _loudest = magnitude;
      if (++_measured < window) continue;
      if (!_amplitude.isClosed) {
        _amplitude.add(
          _loudest == 0 ? -160 : 20 * math.log(_loudest / 32768) / math.ln10,
        );
      }
      _loudest = 0;
      _measured = 0;
    }
  }

  /// Treats an encoder that dies mid-recording as an interruption, since the
  /// recording cannot go on; [resume] then keeps it interrupted.
  void _watchEncoder(Process encoder) {
    encoder.stdin.done.ignore();
    encoder.stdout.drain<void>().ignore();
    final errors = ffmpegErrors(encoder);
    unawaited(
      encoder.exitCode.then((code) async {
        if (!identical(encoder, _encoder)) {
          if (code != 0) {
            debugPrint(
              'KapyNotes: the voice note encoder failed (ffmpeg exited $code): '
              '${await errors}',
            );
          }
          return;
        }
        _encoder = null;
        debugPrint(
          'KapyNotes: the voice note encoder stopped (ffmpeg exited $code): '
          '${await errors}',
        );
        await _stopCapture();
        if (!_paused.isClosed) _paused.add(true);
      }),
    );
  }

  /// Ends capture, then lets the encoder write out what it has and close the
  /// file, which is the step that makes it readable.
  Future<void> _finish() async {
    await _stopCapture();
    final encoder = _encoder;
    _encoder = null;
    if (encoder == null) return;
    try {
      await encoder.stdin.close();
    } catch (_) {
      // Already gone; its exit code says why.
    }
    await encoder.exitCode.timeout(
      _finishing,
      onTimeout: () {
        encoder.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
