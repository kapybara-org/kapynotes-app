import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'linux_ffmpeg.dart';
import 'mp4_duration.dart';
import 'voice_player.dart';

/// Plays a recording on Linux, where just_audio has no implementation.
///
/// Two ffmpegs with this isolate between them: one decodes the `.m4a` from
/// the play head, at the chosen speed through `atempo`, and the other plays
/// the samples it is handed through PulseAudio. The samples pass through here
/// rather than straight from one to the other so that both end with the app:
/// if it quits or crashes, the decoder's next write fails and the player runs
/// out of input. A single ffmpeg playing the file would play it to the end
/// with nothing left to stop it.
///
/// Neither can be moved once running, so pausing, seeking and changing speed
/// stop both, and playing starts two more from the remembered position — a
/// few milliseconds each. The position is the time since the first samples
/// went out, times the speed, from where they started.
class LinuxVoicePlayerBackend implements VoicePlayerBackend {
  /// The rate the samples are handed over at: the desktop's own, so
  /// PulseAudio has nothing to convert, whatever rate the recording was made
  /// at.
  static const int _rate = 48000;

  /// How much the player asks PulseAudio to hold.
  ///
  /// ffmpeg's PulseAudio output drops whatever is still buffered when its
  /// input ends, so the end of every recording would be cut by this much
  /// without [_tail]. Small enough that the tail is short, large enough that
  /// a busy moment in this isolate is not heard as a gap.
  static const int _bufferMs = 200;

  /// Silence played after the recording, so that what [_bufferMs] drops at
  /// the end is silence.
  static const Duration _tail = Duration(milliseconds: 400);

  /// How often the position goes out while playing: four times a second, as
  /// [VoicePlayer] expects.
  static const Duration _tick = Duration(milliseconds: 250);

  /// How long playback waits after a seek before starting again. A drag
  /// along the scrubber seeks on every frame, and two processes a frame is
  /// not what anybody means by it.
  static const Duration _settle = Duration(milliseconds: 120);

  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();

  String? _path;
  Duration _duration = Duration.zero;
  double _speed = 1;
  bool _playing = false;

  /// Where the head is while nothing plays, and where the current run
  /// started while something does.
  Duration _from = Duration.zero;

  _Run? _run;
  Timer? _ticker;
  Timer? _restart;

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Stream<void> get completions => _completions.stream;

  Duration get _position {
    final run = _run;
    if (run == null) return _from;
    final at = _from + run.clock.elapsed * _speed;
    return at < _duration ? at : _duration;
  }

  /// Reads the length from the file's own header, as the recorder does.
  ///
  /// Throws when there is no ffmpeg to play it with, or no header to read,
  /// both of which [VoicePlayer] shows as a recording that would not open.
  @override
  Future<Duration?> load(File file) async {
    await stop();
    if (!await ffmpegIsInstalled()) {
      throw const ProcessException(ffmpegExecutable, [], 'not on PATH');
    }
    final ms = mp4DurationMs(await file.readAsBytes());
    if (ms == null) throw FormatException('no length in its header', file.path);
    _path = file.path;
    _duration = Duration(milliseconds: ms);
    return _duration;
  }

  @override
  Future<void> play() async {
    if (_playing || _path == null) return;
    _playing = true;
    await _begin();
  }

  @override
  Future<void> pause() async {
    if (!_playing) return;
    _from = _position;
    _playing = false;
    await _halt();
    _positions.add(_from);
  }

  @override
  Future<void> seek(Duration position) async {
    _from = position < Duration.zero
        ? Duration.zero
        : position > _duration
        ? _duration
        : position;
    if (_playing) {
      await _halt();
      _restart?.cancel();
      _restart = Timer(_settle, () => unawaited(_begin()));
    }
    _positions.add(_from);
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (speed == _speed) return;
    if (!_playing) {
      _speed = speed;
      return;
    }
    _from = _position;
    await _halt();
    _speed = speed;
    await _begin();
  }

  @override
  Future<void> stop() async {
    _playing = false;
    await _halt();
    _from = Duration.zero;
  }

  /// Stops playing and forgets the file. The backend stays usable: the
  /// player hands it the next recording after an idle release.
  @override
  Future<void> dispose() async {
    await stop();
    _path = null;
    _duration = Duration.zero;
  }

  Future<void> _begin() async {
    final path = _path;
    if (path == null || !_playing) return;
    await _halt();
    final run = _Run();
    _run = run;
    final Process decoder;
    final Process player;
    try {
      decoder = await startFfmpeg([
        '-ss',
        (_from.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(
          3,
        ),
        '-i',
        path,
        '-map',
        '0:a:0',
        '-af',
        'atempo=$_speed',
        '-ac',
        '1',
        '-ar',
        '$_rate',
        '-f',
        's16le',
        'pipe:1',
      ]);
      run.decoder = decoder;
      if (run.stopped) {
        await run.kill();
        return;
      }
      player = await startFfmpeg([
        '-f',
        's16le',
        '-ar',
        '$_rate',
        '-ac',
        '1',
        '-i',
        'pipe:0',
        '-f',
        'pulse',
        '-buffer_duration',
        '$_bufferMs',
        '-name',
        'Kapy Notes',
        'Voice note',
      ]);
      run.player = player;
      if (run.stopped) {
        await run.kill();
        return;
      }
    } on ProcessException catch (error) {
      await run.kill();
      if (identical(_run, run)) _ended('could not start ffmpeg: $error');
      return;
    }

    player.stdin.done.ignore();
    player.stdout.drain<void>().ignore();
    final decoderErrors = ffmpegErrors(decoder);
    final playerErrors = ffmpegErrors(player);
    unawaited(_relay(run, decoder, player));
    unawaited(
      player.exitCode.then((played) async {
        // A player that ended early leaves the decoder blocked on a full pipe.
        if (played != 0) decoder.kill(ProcessSignal.sigkill);
        final decoded = await decoder.exitCode;
        if (run.stopped || !identical(_run, run)) return;
        _ended(
          played == 0 && decoded == 0
              ? null
              : 'decoder exited $decoded (${await decoderErrors}), '
                    'player exited $played (${await playerErrors})',
        );
      }),
    );
  }

  /// Hands the decoder's samples to the player as fast as it takes them, then
  /// [_tail], then the end of its input.
  Future<void> _relay(_Run run, Process decoder, Process player) async {
    try {
      await player.stdin.addStream(
        decoder.stdout.map((chunk) {
          if (!run.clock.isRunning && !run.stopped) {
            run.clock.start();
            _ticker = Timer.periodic(_tick, (_) => _positions.add(_position));
          }
          return chunk;
        }),
      );
      player.stdin.add(Uint8List(_rate * 2 * _tail.inMilliseconds ~/ 1000));
      await player.stdin.close();
    } catch (_) {
      // The player went first; its exit says why.
    }
  }

  /// The run reached the end, or failed partway.
  ///
  /// A failure is reported as the end too. [VoicePlayer] listens for nothing
  /// else, and a player left showing a pause button over silence is worse
  /// than one that stops: the next play starts the recording again.
  void _ended(String? failure) {
    if (failure != null) debugPrint('KapyNotes: playback stopped: $failure');
    _run = null;
    _ticker?.cancel();
    _ticker = null;
    _playing = false;
    _from = _duration;
    _positions.add(_from);
    _completions.add(null);
  }

  /// Stops whatever is playing or about to, leaving [_from] alone, and
  /// completes once it is silent.
  Future<void> _halt() async {
    _restart?.cancel();
    _restart = null;
    _ticker?.cancel();
    _ticker = null;
    final run = _run;
    _run = null;
    await run?.kill();
  }
}

/// One decoder and one player, from one position at one speed.
class _Run {
  Process? decoder;
  Process? player;
  final Stopwatch clock = Stopwatch();
  bool stopped = false;

  /// SIGKILL rather than asking them to finish, because finishing is exactly
  /// what a pause must not do.
  Future<void> kill() async {
    stopped = true;
    clock.stop();
    final running = [?decoder, ?player];
    for (final process in running) {
      process.kill(ProcessSignal.sigkill);
    }
    await Future.wait([for (final process in running) process.exitCode]);
  }
}
