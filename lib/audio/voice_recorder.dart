import 'dart:async';

import 'package:record/record.dart';

/// What a recording backend has to be able to do.
///
/// An interface rather than a direct `AudioRecorder` because the controller
/// above it holds the rules worth testing — the thirty-minute cap, what an
/// interruption does, whether a two-second tap is worth keeping — and none of
/// those should need a microphone, a plugin registrar, or a real device to
/// exercise.
abstract class VoiceRecorderBackend {
  Future<bool> hasPermission();

  /// Begins writing to [path]. The extension decides the container on
  /// Windows, where Media Foundation's sink writer picks its muxer from it,
  /// so it must end in `.m4a`.
  Future<void> start(String path);

  Future<void> pause();
  Future<void> resume();

  /// Ends the recording and returns the file written, or null if the backend
  /// produced nothing.
  Future<String?> stop();

  Future<void> cancel();

  /// dBFS, roughly ten a second.
  Stream<double> get amplitude;

  /// Backend-driven state. The one that matters is a pause the user did not
  /// ask for: a phone call, or another app taking the microphone.
  Stream<bool> get paused;

  Future<void> dispose();
}

/// The real one.
class VoiceRecorder implements VoiceRecorderBackend {
  AudioRecorder? _recorder;
  StreamSubscription<Amplitude>? _amplitudes;
  StreamSubscription<RecordState>? _states;

  final _amplitude = StreamController<double>.broadcast();
  final _paused = StreamController<bool>.broadcast();

  /// Created on the first recording, never at launch.
  ///
  /// Constructing an `AudioRecorder` sets up a platform channel and, on iOS
  /// and macOS, touches the audio session. A user who never records must not
  /// pay for either — see the startup budget in docs/voice-notes.md §2.5.
  AudioRecorder get _live => _recorder ??= AudioRecorder();

  /// 48 kbps mono AAC-LC at 16 kHz: speech, not music, and about 360 KB a
  /// minute — a thirty-minute note is 10 MB, inside the 25 MB per-file cap.
  ///
  /// Windows does not honour all of it. The Media Foundation AAC encoder takes
  /// only 44.1/48 kHz in and 96 kbps or more out, so `record` picks the
  /// nearest it supports and a Windows recording is about twice the size.
  /// Still inside the cap at the thirty-minute limit, which is why this asks
  /// for what it wants rather than special-casing the platform.
  static const RecordConfig config = RecordConfig(
    encoder: AudioEncoder.aacLc,
    bitRate: 48000,
    sampleRate: 16000,
    numChannels: 1,
    audioInterruption: AudioInterruptionMode.pause,
  );

  @override
  Future<bool> hasPermission() => _live.hasPermission();

  @override
  Future<void> start(String path) async {
    await _live.start(config, path: path);
    _amplitudes = _live
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((amplitude) {
          if (!_amplitude.isClosed) _amplitude.add(amplitude.current);
        });
    _states = _live.onStateChanged().listen((state) {
      if (!_paused.isClosed) _paused.add(state == RecordState.pause);
    });
  }

  @override
  Future<void> pause() => _live.pause();

  @override
  Future<void> resume() => _live.resume();

  @override
  Future<String?> stop() async {
    final path = await _live.stop();
    await _stopListening();
    return path;
  }

  /// Stops, and leaves the file for the caller to delete.
  ///
  /// Deliberately not `AudioRecorder.cancel()`. That returns before Android has
  /// finished with the recording: `MediaRecorder` finalises on its own thread,
  /// so the file the caller then deletes does not exist yet, and the encoder
  /// writes it a moment later — a recording the user threw away, still on disk.
  /// Measured on an API 36 emulator, where `moov` was written after the delete
  /// had already run and found nothing.
  ///
  /// `stop()` returns only once the container is complete, which is the whole
  /// reason the too-short path can read a duration out of one. Finalising a
  /// file we are about to remove costs a few milliseconds; losing track of
  /// discarded audio costs rather more.
  @override
  Future<void> cancel() async {
    await _live.stop();
    await _stopListening();
  }

  Future<void> _stopListening() async {
    await _amplitudes?.cancel();
    await _states?.cancel();
    _amplitudes = null;
    _states = null;
  }

  @override
  Stream<double> get amplitude => _amplitude.stream;

  @override
  Stream<bool> get paused => _paused.stream;

  @override
  Future<void> dispose() async {
    await _stopListening();
    await _recorder?.dispose();
    _recorder = null;
    await _amplitude.close();
    await _paused.close();
  }
}
