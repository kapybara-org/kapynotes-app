import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../core/platform.dart';
import 'adts.dart';

/// What a recording backend has to be able to do.
///
/// An interface rather than a direct `AudioRecorder` because the controller
/// above it holds the rules worth testing — the thirty-minute cap, what an
/// interruption does, whether a two-second tap is worth keeping — and none of
/// those should need a microphone, a plugin registrar, or a real device to
/// exercise.
abstract class VoiceRecorderBackend {
  Future<bool> hasPermission();

  /// Whether this computer has a microphone to record from at all. Asked
  /// before a recording starts, so one with none says so instead of
  /// recording silence.
  Future<bool> hasMicrophone();

  /// Begins a recording that [stop] leaves at [path]. The extension decides
  /// the container on Windows, where Media Foundation's sink writer picks its
  /// muxer from it, so it must end in `.m4a`.
  ///
  /// A phone writes the audio in progress to [adtsBeside] it instead, and
  /// [stop] rewraps it: see [mp4FromAdts].
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

/// The real one, everywhere but Linux: see `LinuxVoiceRecorder`.
class VoiceRecorder implements VoiceRecorderBackend {
  AudioRecorder? _recorder;
  StreamSubscription<Amplitude>? _amplitudes;
  StreamSubscription<RecordState>? _states;

  /// On a phone, the `.m4a` asked for and the ADTS written until [stop].
  String? _path;
  File? _adts;

  /// On Android, where `record` writes AAC to a file only as MPEG-4, its
  /// ADTS stream, put on disk by this as each frame arrives.
  StreamSubscription<Uint8List>? _frames;
  RandomAccessFile? _sink;

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

  /// Only a Mac is asked, and only an empty list is a no. A phone always has
  /// one. Windows records as before until its listing has been proven on a
  /// machine that has one (KAP-381).
  @override
  Future<bool> hasMicrophone() async =>
      !AppPlatform.isMacOS || (await _live.listInputDevices()).isNotEmpty;

  @override
  Future<void> start(String path) async {
    if (!AppPlatform.isMobile) {
      await _live.start(config, path: path);
    } else {
      final adts = File(adtsBeside(path));
      _path = path;
      _adts = adts;
      if (AppPlatform.isIOS) {
        // AVAudioRecorder picks its container from the extension: `.aac`
        // is ADTS.
        await _live.start(config, path: adts.path);
      } else {
        // Written as it comes, so the file holds every frame the app was
        // given whatever ends the app: a write is in the system's hands at
        // once, and a kill does not take those back.
        final sink = _sink = await adts.open(mode: FileMode.writeOnly);
        try {
          final frames = await _live.startStream(config);
          _frames = frames.listen(sink.writeFromSync);
        } catch (_) {
          await sink.close();
          await adts.delete();
          _sink = null;
          _adts = null;
          _path = null;
          rethrow;
        }
      }
    }
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
    final written = await _live.stop();
    await _stopListening();
    final adts = _adts;
    final path = _path;
    _adts = null;
    _path = null;
    if (adts == null || path == null) return written;
    if (!await adts.exists()) return null;
    return await finishAdtsRecording(adts, File(path)) ? path : null;
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
    final adts = _adts;
    _adts = null;
    _path = null;
    if (adts != null && await adts.exists()) await adts.delete();
  }

  /// Also closes the ADTS file. A frame that reaches Dart after `record`'s
  /// stop returns is lost, because `record` stops listening then. On
  /// Android that can be the last frame or two: record_android 2.1.2 sends
  /// stop's reply from its recording thread but each frame through the main
  /// thread.
  Future<void> _stopListening() async {
    await _amplitudes?.cancel();
    await _states?.cancel();
    await _frames?.cancel();
    await _sink?.close();
    _amplitudes = null;
    _states = null;
    _frames = null;
    _sink = null;
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
