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
  Stream<void> get completions => _live.processingStateStream.where(
    (state) => state == ProcessingState.completed,
  );

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
  VoicePlayer({
    VoicePlayerBackend? backend,
    this.idleTimeout = const Duration(minutes: 5),
  }) : _backend = backend ?? JustAudioBackend();

  final VoicePlayerBackend _backend;

  /// How long an untouched player is kept alive before its engine is released.
  final Duration idleTimeout;

  String? _activeHash;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  double _speed = 1;
  bool _disposed = false;

  /// Whether the active recording played all the way to its end.
  ///
  /// Kept because "play" means two different things at that point. Everywhere
  /// else it resumes; here it starts again, and without this the engine was
  /// asked to carry on from the last millisecond of the file and did exactly
  /// that — nothing.
  bool _completed = false;

  StreamSubscription<Duration>? _positions;
  StreamSubscription<void>? _completions;
  Timer? _idle;

  final Map<String, ValueNotifier<double?>> _progress = {};
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(
    Duration.zero,
  );

  String? get activeHash => _activeHash;
  bool get playing => _playing;
  Duration get position => _position;
  Duration? get duration => _duration;
  double get speed => _speed;

  /// How far through [hash] playback is, 0 to 1 — or null when this is not the
  /// recording being played, which is what tells a chip to draw itself idle.
  ValueListenable<double?> progressFor(String hash) => _notifierFor(hash);

  /// The play head, for anything that shows an elapsed time or a scrubber.
  ///
  /// Separate from [ChangeNotifier] for the same reason [progressFor] is: this
  /// moves four times a second, and the editor listens to the player itself.
  /// A dialog that wants the moving figure listens here and rebuilds only its
  /// own row.
  ValueListenable<Duration> get positionListenable => _positionNotifier;

  /// Created on demand from both sides. Playback can begin before a chip is
  /// ever built — scrolling a long note, or opening the dialog first — and a
  /// chip that mounted late must still find the position waiting for it.
  ValueNotifier<double?> _notifierFor(String hash) =>
      _progress.putIfAbsent(hash, () => ValueNotifier<double?>(null));

  bool isPlaying(String hash) => _playing && _activeHash == hash;

  /// Starts or resumes [hash], optionally [from] a position.
  ///
  /// [from] is what a tap on the waveform of a recording nobody has played yet
  /// means: start it, and start it there.
  Future<void> play(String hash, File file, {Duration? from}) async {
    _idle?.cancel();
    if (_activeHash == hash) {
      // Same recording: this is a resume, not a reload. Reloading would jump
      // the position back to zero, which is not what a play button means.
      //
      // Unless it finished, in which case the head is sitting on the last
      // millisecond and resuming from there plays nothing at all. A play
      // pressed on a recording that has ended means play it again.
      if (from != null) {
        await _moveTo(from);
      } else if (_completed) {
        await _moveTo(Duration.zero);
      }
      _playing = true;
      _notify();
      await _backend.play();
      return;
    }

    await _releaseActive();
    _activeHash = hash;
    _position = Duration.zero;
    _completed = false;
    _notify();

    try {
      _duration = await _backend.load(file);
      await _backend.setSpeed(_speed);
      if (from != null) await _moveTo(from);
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
    await _moveTo(position);
    _notify();
  }

  /// Moves the head, and stops the next play from treating the recording as
  /// finished — wherever it has been put, there is something after it.
  Future<void> _moveTo(Duration position) async {
    _completed = false;
    _position = position;
    _publishProgress();
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
    _completed = true;
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
    _positionNotifier.value = _position;
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
    _completed = false;
    _position = Duration.zero;
    _duration = null;
    _positionNotifier.value = Duration.zero;
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
    _positionNotifier.dispose();
    super.dispose();
  }
}
