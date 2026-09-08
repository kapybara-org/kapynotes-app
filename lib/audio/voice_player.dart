import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// What playing a recording needs from an audio engine.
///
/// Behind an interface so the chip, the dialog and the follow-along transcript
/// can all be tested without a plugin registrar or a sound card.
abstract class VoicePlayerBackend {
  Future<Duration?> load(File file);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> stop();
  Stream<Duration> get positions;

  /// Fires when a recording reaches its end.
  Stream<void> get completions;
  Future<void> dispose();
}

class JustAudioBackend implements VoicePlayerBackend {
  AudioPlayer? _player;

  /// Created on the first play, never at launch: constructing an `AudioPlayer`
  /// opens a platform channel and, on Apple platforms, touches the shared
  /// audio session.
  AudioPlayer get _live => _player ??= AudioPlayer();

  @override
  Future<Duration?> load(File file) => _live.setFilePath(file.path);

  @override
  Future<void> play() => _live.play();

  @override
  Future<void> pause() => _live.pause();

  @override
  Future<void> seek(Duration position) => _live.seek(position);

  @override
  Future<void> setSpeed(double speed) => _live.setSpeed(speed);

  @override
  Future<void> stop() => _live.stop();

  @override
  Stream<Duration> get positions => _live.positionStream;

  @override
  Stream<void> get completions => _live.processingStateStream
      .where((state) => state == ProcessingState.completed);

  @override
  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
  }
}

/// Plays back one recording at a time, app-wide.
///
/// One player rather than one per chip: a note can hold a dozen recordings,
/// and a dozen idle audio engines is a dozen platform channels and, on iOS, a
/// dozen claims on the audio session. Starting a different recording stops the
/// one playing, which is also the behaviour anyone expects.
///
/// The chip does not rebuild as playback moves. [progressFor] hands out a
/// [ValueListenable] per hash, so the waveform's painter repaints inside its
/// own [RepaintBoundary] while the editor above it does nothing at all.
class VoicePlayer extends ChangeNotifier {
  VoicePlayer({VoicePlayerBackend? backend, this.idleTimeout = const Duration(minutes: 5)})
    : _backend = backend ?? JustAudioBackend();

  final VoicePlayerBackend _backend;

  /// How long an untouched player is kept alive before its engine is released.
  final Duration idleTimeout;

  String? _activeHash;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  double _speed = 1;
  bool _disposed = false;

  StreamSubscription<Duration>? _positions;
  StreamSubscription<void>? _completions;
  Timer? _idle;

  final Map<String, ValueNotifier<double?>> _progress = {};

  String? get activeHash => _activeHash;
  bool get playing => _playing;
  Duration get position => _position;
  Duration? get duration => _duration;
  double get speed => _speed;

  /// How far through [hash] playback is, 0 to 1 — or null when this is not the
  /// recording being played, which is what tells a chip to draw itself idle.
  ValueListenable<double?> progressFor(String hash) => _notifierFor(hash);

  /// Created on demand from both sides. Playback can begin before a chip is
  /// ever built — scrolling a long note, or opening the dialog first — and a
  /// chip that mounted late must still find the position waiting for it.
  ValueNotifier<double?> _notifierFor(String hash) =>
      _progress.putIfAbsent(hash, () => ValueNotifier<double?>(null));

  bool isPlaying(String hash) => _playing && _activeHash == hash;

  Future<void> play(String hash, File file) async {
    _idle?.cancel();
    if (_activeHash == hash) {
      // Same recording: this is a resume, not a reload. Reloading would jump
      // the position back to zero, which is not what a play button means.
      _playing = true;
      _notify();
      await _backend.play();
      return;
    }

    await _releaseActive();
    _activeHash = hash;
    _position = Duration.zero;
    _notify();

    try {
      _duration = await _backend.load(file);
      await _backend.setSpeed(_speed);
    } catch (error) {
      debugPrint('KapyNotes: could not open recording $hash: $error');
      _activeHash = null;
      _notify();
      return;
    }

    _positions = _backend.positions.listen(_onPosition);
    _completions = _backend.completions.listen((_) => _onCompleted());
    _playing = true;
    _notify();
    await _backend.play();
  }

  Future<void> pause() async {
    if (!_playing) return;
    _playing = false;
    _notify();
    await _backend.pause();
    _startIdleTimer();
  }

  Future<void> seek(Duration position) async {
    if (_activeHash == null) return;
    _position = position;
    _publishProgress();
    _notify();
    await _backend.seek(position);
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed;
    _notify();
    if (_activeHash != null) await _backend.setSpeed(speed);
  }

  Future<void> stop() async {
    if (_activeHash == null) return;
    await _releaseActive();
    _notify();
  }

  void _onPosition(Duration position) {
    if (_disposed) return;
    _position = position;
    _publishProgress();
  }

  void _onCompleted() {
    if (_disposed) return;
    _playing = false;
    _position = _duration ?? _position;
    _publishProgress();
    _notify();
    _startIdleTimer();
  }

  /// Position goes to the per-hash notifier, not through `notifyListeners`.
  ///
  /// At four updates a second, notifying the whole tree would rebuild the
  /// editor — and with it every result chip and every highlight — while a
  /// recording plays.
  void _publishProgress() {
    final hash = _activeHash;
    if (hash == null) return;
    final total = _duration;
    final fraction = total == null || total.inMilliseconds <= 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    _notifierFor(hash).value = fraction;
  }

  Future<void> _releaseActive() async {
    final hash = _activeHash;
    // Nothing loaded: there is no engine to stop and no listener to cancel.
    if (hash == null) return;
    await _positions?.cancel();
    await _completions?.cancel();
    _positions = null;
    _completions = null;
    _notifierFor(hash).value = null;
    _activeHash = null;
    _playing = false;
    _position = Duration.zero;
    _duration = null;
    try {
      await _backend.stop();
    } catch (_) {}
  }

  /// Releases the engine after five idle minutes.
  ///
  /// A paused player holds a decoder and, on iOS, a claim on the audio session
  /// that stops other apps resuming. Nobody comes back to a voice note twenty
  /// minutes later expecting the play head to still be where they left it.
  void _startIdleTimer() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () async {
      if (_playing) return;
      await _releaseActive();
      await _backend.dispose();
      _notify();
    });
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _idle?.cancel();
    unawaited(_positions?.cancel());
    unawaited(_completions?.cancel());
    unawaited(_backend.dispose());
    for (final notifier in _progress.values) {
      notifier.dispose();
    }
    _progress.clear();
    super.dispose();
  }
}
