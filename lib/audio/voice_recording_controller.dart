import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'mp4_duration.dart';
import 'peaks.dart';
import 'voice_recorder.dart';

/// A recording in progress.
class VoiceRecordingSession {
  final String noteId;
  final Duration elapsed;

  /// 0 to 1, for the bar's level meter.
  final double level;

  /// Advances for every microphone sample, even when two levels are equal.
  ///
  /// The recording bar uses this to distinguish a sustained sound from an
  /// unrelated rebuild without carrying an ever-growing waveform in session
  /// state. The visual history stays bounded inside the bar itself.
  final int sampleSequence;

  /// The user pressed pause.
  final bool paused;

  /// Something else did — a phone call, another app taking the microphone.
  /// Shown differently, because the user has to press resume to carry on.
  final bool interrupted;

  /// Set while [VoiceRecordingController.finishRecordingAndFlush] is running,
  /// so the bar can say "Saving…" rather than appearing to hang.
  final bool finishing;

  const VoiceRecordingSession({
    required this.noteId,
    this.elapsed = Duration.zero,
    this.level = 0,
    this.sampleSequence = 0,
    this.paused = false,
    this.interrupted = false,
    this.finishing = false,
  });

  VoiceRecordingSession copyWith({
    Duration? elapsed,
    double? level,
    int? sampleSequence,
    bool? paused,
    bool? interrupted,
    bool? finishing,
  }) => VoiceRecordingSession(
    noteId: noteId,
    elapsed: elapsed ?? this.elapsed,
    level: level ?? this.level,
    sampleSequence: sampleSequence ?? this.sampleSequence,
    paused: paused ?? this.paused,
    interrupted: interrupted ?? this.interrupted,
    finishing: finishing ?? this.finishing,
  );
}

/// A finished recording, before it becomes an attachment.
class VoiceRecordingResult {
  final File file;
  final Duration duration;
  final Uint8List peaks;

  const VoiceRecordingResult({
    required this.file,
    required this.duration,
    required this.peaks,
  });
}

/// Owns the microphone, the clock, and the rules about when a recording ends.
///
/// Lives above the editor (in `HomePage` state) so that a recording survives a
/// note switch and a layout change between the compact and wide editors — both
/// of which rebuild the editor from scratch.
class VoiceRecordingController extends ChangeNotifier {
  VoiceRecordingController({
    VoiceRecorderBackend? recorder,
    Directory? tempDirectory,
    Future<void> Function(VoiceRecordingResult result, String noteId)?
    onFinished,
  }) : _recorder = recorder ?? VoiceRecorder(),
       _tempDirectory = tempDirectory,
       _onFinished = onFinished;

  final VoiceRecorderBackend _recorder;
  final Directory? _tempDirectory;

  /// Called with a finished recording, to turn it into a ref in its note.
  /// Set by `HomePage`, which is the only thing that knows about editors.
  Future<void> Function(VoiceRecordingResult result, String noteId)?
  _onFinished;
  set onFinished(
    Future<void> Function(VoiceRecordingResult result, String noteId)? value,
  ) => _onFinished = value;

  /// Awaited after delivery, so a recording is on disk before the app can die.
  Future<void> Function()? onFlush;

  VoiceRecordingSession? _session;
  VoiceRecordingSession? get session => _session;
  bool get isRecording => _session != null;

  String? _path;
  Timer? _ticker;
  StreamSubscription<double>? _amplitudes;
  StreamSubscription<bool>? _paused;
  final List<double> _samples = [];
  bool _userPaused = false;
  bool _disposed = false;
  Future<void>? _finishing;

  /// A recording is never allowed past this. Thirty minutes of AAC is about
  /// 10 MB, and 20 MB on Windows — both inside the 25 MB per-file limit the
  /// attachment endpoint enforces. Past that the upload would simply be
  /// refused, so the cap is here where it can be explained instead.
  static const Duration maxDuration = Duration(minutes: 30);

  /// Notifies unless this controller is already gone.
  ///
  /// Every state change here sits behind at least one `await` — stopping the
  /// backend, reading the file back — and the app can be torn down inside that
  /// gap, which is exactly what quitting mid-recording does. A bare
  /// `notifyListeners` would throw on the way out.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// The point at which the bar starts counting down instead of up.
  static const Duration warnAfter = Duration(minutes: 29);

  /// Shorter than this and a stop was a mis-tap, not a note.
  static const Duration minimumKept = Duration(seconds: 1);

  /// True once the recording is long enough that Cancel should confirm first.
  static const Duration confirmCancelAfter = Duration(seconds: 10);

  bool get shouldConfirmCancel =>
      (_session?.elapsed ?? Duration.zero) >= confirmCancelAfter;

  /// Begins recording into [noteId]. Returns false when the microphone was
  /// refused, which the caller turns into the one piece of UI this needs.
  Future<bool> start({required String noteId}) async {
    if (_session != null) return false;
    try {
      if (!await _recorder.hasPermission()) return false;
    } catch (error) {
      // No microphone plugin on this platform — a test binding, or a build
      // without the native side registered. A platform that cannot answer the
      // permission question is one that cannot record, and saying so beats
      // letting the failure surface later as a hang.
      debugPrint('KapyNotes: no microphone available: $error');
      return false;
    }

    final directory = _tempDirectory ?? Directory.systemTemp;
    final name =
        'voice-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}.m4a';
    final path = '${directory.path}/$name';

    _samples.clear();
    _userPaused = false;
    _path = path;
    _session = VoiceRecordingSession(noteId: noteId);
    _notify();

    try {
      await _recorder.start(path);
    } catch (error) {
      debugPrint('KapyNotes: could not start recording: $error');
      _session = null;
      _path = null;
      _notify();
      return false;
    }

    _amplitudes = _recorder.amplitude.listen(_onAmplitude);
    _paused = _recorder.paused.listen(_onBackendPaused);
    _ticker = Timer.periodic(const Duration(seconds: 1), _onTick);
    return true;
  }

  void _onAmplitude(double dbfs) {
    final session = _session;
    if (session == null || session.paused || session.interrupted) return;
    _samples.add(dbfs);
    _session = session.copyWith(
      level: levelFromAmplitude(dbfs),
      sampleSequence: session.sampleSequence + 1,
    );
    _notify();
  }

  /// The backend pauses itself on an interruption. Telling that apart from a
  /// pause the user asked for is the whole reason this listener exists: one
  /// shows "Paused", the other shows "Interrupted — resume to carry on".
  void _onBackendPaused(bool paused) {
    final session = _session;
    if (session == null) return;
    if (_userPaused) return;
    if (session.interrupted == paused) return;
    _session = session.copyWith(interrupted: paused, level: 0);
    _notify();
  }

  /// Simulates the backend reporting an interruption, for tests that cannot
  /// reach the plugin's state stream.
  @visibleForTesting
  void debugInterrupt() => _onBackendPaused(true);

  void _onTick(Timer timer) {
    final session = _session;
    if (session == null) return;
    if (session.paused || session.interrupted) return;

    final elapsed = session.elapsed + const Duration(seconds: 1);
    _session = session.copyWith(elapsed: elapsed);
    _notify();
    if (elapsed >= maxDuration) {
      // Stopped for them rather than truncated under them: the recording is
      // delivered whole, and the bar has been counting down for a minute.
      unawaited(finishRecordingAndFlush());
    }
  }

  Future<void> pause() async {
    final session = _session;
    if (session == null || session.paused) return;
    _userPaused = true;
    await _recorder.pause();
    _session = session.copyWith(paused: true, level: 0);
    _notify();
  }

  Future<void> resume() async {
    final session = _session;
    if (session == null) return;
    _userPaused = false;
    await _recorder.resume();
    _session = session.copyWith(paused: false, interrupted: false);
    _notify();
  }

  /// Ends the recording and returns it, or null when there was nothing worth
  /// keeping. Does not deliver it anywhere; see [finishRecordingAndFlush].
  Future<VoiceRecordingResult?> stop() async {
    final session = _session;
    if (session == null) return null;

    await _teardown();
    final path = _path;
    _path = null;
    _session = null;
    _notify();
    if (path == null) return null;

    final String? written;
    try {
      written = await _recorder.stop();
    } catch (error) {
      debugPrint('KapyNotes: could not stop recording: $error');
      return null;
    }

    final file = File(written ?? path);
    if (!await file.exists()) return null;

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      await _delete(file);
      return null;
    }

    final duration = durationFor(bytes, session.elapsed);

    if (duration < minimumKept) {
      await _delete(file);
      return null;
    }

    return VoiceRecordingResult(
      file: file,
      duration: duration,
      peaks: bucketPeaks(_samples),
    );
  }

  /// How long the recording actually is.
  ///
  /// The file's own header beats the timer, always: a pause, an interruption,
  /// or a sample rate the platform clamped all leave the two disagreeing, and
  /// the header is what a player will believe. [elapsed] is only the fallback
  /// for a file whose header could not be read — which happens, and is not a
  /// reason to throw a recording away.
  @visibleForTesting
  static Duration durationFor(Uint8List bytes, Duration elapsed) {
    final fromFile = mp4DurationMs(bytes);
    return fromFile != null ? Duration(milliseconds: fromFile) : elapsed;
  }

  /// Throws the recording away.
  Future<void> cancel() async {
    if (_session == null) return;
    await _teardown();
    final path = _path;
    _path = null;
    _session = null;
    _notify();
    try {
      await _recorder.cancel();
    } catch (error) {
      debugPrint('KapyNotes: could not cancel recording: $error');
    }
    if (path != null) await _delete(File(path));
  }

  /// Stops any recording, delivers it to its note, and flushes every store it
  /// touched. Resolves immediately when nothing is recording.
  ///
  /// This is the single exit path. Every way a recording can end — switching
  /// notes, closing the window, quitting, the OS asking the app to exit, a
  /// phone going to the background, the thirty-minute cap — funnels through
  /// here, because each of those was previously either synchronous or flushed
  /// only the notes file. Safe to call from several places at once: the second
  /// caller awaits the first rather than racing it, which matters because a
  /// window close and an app exit can both fire.
  Future<void> finishRecordingAndFlush() {
    if (_session == null) return Future.value();
    return _finishing ??= _finish().whenComplete(() => _finishing = null);
  }

  Future<void> _finish() async {
    final session = _session;
    if (session == null) return;
    _session = session.copyWith(finishing: true);
    _notify();

    final noteId = session.noteId;
    final result = await stop();
    if (result != null) {
      try {
        await _onFinished?.call(result, noteId);
      } catch (error) {
        debugPrint('KapyNotes: could not deliver recording: $error');
      }
    }
    try {
      await onFlush?.call();
    } catch (error) {
      debugPrint('KapyNotes: could not flush after recording: $error');
    }
  }

  Future<void> _teardown() async {
    _ticker?.cancel();
    _ticker = null;
    await _amplitudes?.cancel();
    await _paused?.cancel();
    _amplitudes = null;
    _paused = null;
  }

  /// Removes a recording nobody is going to keep.
  ///
  /// Failure is caught, because a leftover file is not worth taking a note
  /// editor down for, but it is no longer silent: this is the only thing
  /// standing between a discarded recording and the disk, so a regression here
  /// should leave a trace rather than nothing at all.
  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('KapyNotes: could not delete a discarded recording: $error');
    }
  }

  /// Removes stray `voice-*.m4a` files an hour old or more.
  ///
  /// A force quit or an OOM kill is the one exit nothing can catch: the file
  /// is left without its `moov` box, so it is unreadable and unrecoverable.
  /// It still takes up space, and nothing else will ever clean it up.
  static Future<void> sweepTempFiles({Directory? directory}) async {
    try {
      final dir = directory ?? Directory.systemTemp;
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('voice-') || !name.endsWith('.m4a')) continue;
        final stat = await entity.stat();
        if (stat.modified.isAfter(cutoff)) continue;
        await entity.delete();
      }
    } catch (error) {
      debugPrint('KapyNotes: could not sweep stray recordings: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    unawaited(_amplitudes?.cancel());
    unawaited(_paused?.cancel());
    unawaited(_recorder.dispose());
    super.dispose();
  }
}
