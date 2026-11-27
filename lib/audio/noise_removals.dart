import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../data/clean_copies.dart';
import '../data/voice_prefs.dart';
import '../speech/local_model_store.dart';
import '../speech/local_models.dart';
import 'noise_removal.dart';

/// Where Remove noise stands for one recording.
enum NoiseStage {
  /// The original plays.
  off,

  /// The model is being fetched, the first time noise is removed anywhere.
  downloading,

  /// The clean copy is being made.
  removing,

  /// The clean copy plays.
  on,
}

@immutable
class NoiseState {
  const NoiseState(this.stage, {this.progress = 0});

  static const NoiseState off = NoiseState(NoiseStage.off);
  static const NoiseState on = NoiseState(NoiseStage.on);

  final NoiseStage stage;

  /// 0 to 1 through the current stage.
  final double progress;

  bool get isBusy =>
      stage == NoiseStage.downloading || stage == NoiseStage.removing;
}

/// Why a press on Remove noise left the recording as it was.
enum NoiseProblem {
  /// The model could not be fetched: almost always no connection.
  couldNotDownload,

  /// The recording is on another device and could not be fetched.
  notDownloaded,

  /// No room for the copy.
  noSpace,

  /// Anything else.
  failed,
}

/// Remove noise, app-wide: which recordings play their clean copy, the runs
/// making copies, and the model they need.
///
/// One for the whole app rather than one per window, because a run takes
/// minutes on a phone and must carry on when the window that started it
/// closes. The cards in the note read it too.
class NoiseRemovals extends ChangeNotifier {
  NoiseRemovals({
    required this.models,
    required this.prefs,
    required CleanCopies copies,
    required Future<File?> Function(String hash) originals,
    required void Function(String hash) switched,
    this.model = noiseRemovalModel,
    NoiseRemover? remover,
  }) : _copies = copies,
       _originals = originals,
       _switched = switched,
       _remover = remover ?? NoiseRemover(copies: copies) {
    // The setting shows the model's download, which no recording owns.
    models.addListener(_notify);
  }

  /// Holds the model in the same folder as the other downloaded models, but
  /// as a store of its own: it needs no engine pack, and has no card among
  /// theirs in Settings.
  final LocalModelStore models;

  /// What [models] fetches for it.
  final DownloadableModel model;
  final VoicePrefs prefs;
  final CleanCopies _copies;
  final Future<File?> Function(String hash) _originals;

  /// Told when a recording changes which file it plays, so playback can carry
  /// on in the other one from the same moment.
  final void Function(String hash) _switched;
  final NoiseRemover _remover;

  /// Whether each recording has a clean copy, as last looked.
  final Map<String, bool> _made = {};
  final Set<String> _looking = {};
  final Map<String, _Job> _jobs = {};
  bool _disposed = false;

  NoiseState stateOf(String hash) {
    final job = _jobs[hash];
    if (job != null) return job.state;
    final made = _made[hash];
    if (made == null) {
      unawaited(_look(hash));
      return NoiseState.off;
    }
    return made && !prefs.isNoiseOff(hash) ? NoiseState.on : NoiseState.off;
  }

  /// Whether this recording has never been cleaned here, which is when the
  /// button explains itself.
  bool isNew(String hash) => _made[hash] != true;

  /// The clean copy, when it is the one to play.
  Future<File?> playable(String hash) async {
    if (prefs.isNoiseOff(hash) || _jobs.containsKey(hash)) return null;
    return _existing(hash);
  }

  Future<File?> _existing(String hash) async {
    try {
      final copy = await _copies.existing(hash);
      _made[hash] = copy != null;
      return copy;
    } on ArgumentError {
      _made[hash] = false;
      return null;
    }
  }

  /// Plays the clean copy, making it first if there is none yet.
  ///
  /// Completes with null once it plays, or when [stop] called it off, and
  /// with what went wrong otherwise. A second call while one runs joins it.
  Future<NoiseProblem?> turnOn(String hash) async {
    final running = _jobs[hash];
    if (running != null) return running.done.future;
    final job = _Job();
    _jobs[hash] = job;
    final problem = await _existing(hash) != null
        ? null
        : await _run(hash, job);
    _jobs.remove(hash);
    job.done.complete(problem);
    final made = await _existing(hash) != null;
    // Stopped once the copy was already written: kept, and the original
    // still plays, because that is what Stop promised.
    if (!made) {
      _notify();
      return problem;
    }
    prefs.setNoiseOff(hash, job.stopped);
    _changed(hash);
    return problem;
  }

  /// Plays the original again, keeping the clean copy.
  void turnOff(String hash) {
    if (prefs.isNoiseOff(hash)) return;
    prefs.setNoiseOff(hash, true);
    _changed(hash);
  }

  /// Calls off a run, leaving the recording as it was.
  void stop(String hash) {
    final job = _jobs[hash];
    if (job == null) return;
    job.stopped = true;
    job.run?.cancel();
    final sharing = _jobs.values.any(
      (other) => other != job && other.state.stage == NoiseStage.downloading,
    );
    if (job.state.stage == NoiseStage.downloading && !sharing) {
      models.cancel(model);
    }
  }

  /// A recording has just been saved: cleaned when the setting asks for it.
  /// Nobody pressed anything, so a failure stays quiet and the recording
  /// plays as it was made.
  void recorded(String hash) {
    if (!prefs.removeNoise) return;
    unawaited(turnOn(hash));
  }

  /// Fetches the model ahead of the first recording, for the setting. A
  /// failure is not final: the next recording asks again.
  Future<void> prepare() async {
    await models.refresh();
    if (models.stateOf(model).status == LocalModelStatus.ready) {
      return;
    }
    await models.download(model);
  }

  Future<NoiseProblem?> _run(String hash, _Job job) async {
    try {
      final weights = await _model(job);
      if (job.stopped) return null;
      if (weights == null) return NoiseProblem.couldNotDownload;
      final original = await _originals(hash);
      if (job.stopped) return null;
      if (original == null) return NoiseProblem.notDownloaded;
      job.state = const NoiseState(NoiseStage.removing);
      _notify();
      final run = _remover.clean(
        recording: original,
        hash: hash,
        model: weights,
      );
      job.run = run;
      if (job.stopped) run.cancel();
      void tick() => _step(job, NoiseStage.removing, run.progress.value);
      run.progress.addListener(tick);
      try {
        await run.done;
      } finally {
        run.progress.removeListener(tick);
      }
      return null;
    } on NoiseRemovalException catch (error) {
      debugPrint('KapyNotes: noise removal stopped: $error');
      switch (error.failure) {
        case NoiseRemovalFailure.cancelled:
          return null;
        case NoiseRemovalFailure.storage:
          return NoiseProblem.noSpace;
        case NoiseRemovalFailure.model:
          // Damaged on disk since it was checked. Fetched again next time.
          await models.remove(model);
          return NoiseProblem.failed;
        case NoiseRemovalFailure.recording || NoiseRemovalFailure.other:
          return NoiseProblem.failed;
      }
    } catch (error) {
      debugPrint('KapyNotes: noise removal stopped: $error');
      return NoiseProblem.failed;
    }
  }

  /// The model file, fetched first if it is not here yet.
  Future<File?> _model(_Job job) async {
    if (models.stateOf(model).status != LocalModelStatus.ready) {
      await models.refresh();
    }
    if (models.stateOf(model).status != LocalModelStatus.ready) {
      job.state = const NoiseState(NoiseStage.downloading);
      _notify();
      void tick() =>
          _step(job, NoiseStage.downloading, models.stateOf(model).progress);
      models.addListener(tick);
      try {
        await models.download(model);
      } finally {
        models.removeListener(tick);
      }
      if (models.stateOf(model).status != LocalModelStatus.ready) return null;
    }
    final dir = await models.directoryFor(model);
    return File('${dir.path}/${model.files.single.name}');
  }

  /// Progress, told in whole percent: finer than anyone reads, and coarser
  /// than rebuilding every card ten times a second.
  void _step(_Job job, NoiseStage stage, double progress) {
    if (job.stopped || job.state.stage != stage) return;
    if ((progress * 100).floor() == (job.state.progress * 100).floor()) return;
    job.state = NoiseState(stage, progress: progress);
    _notify();
  }

  Future<void> _look(String hash) async {
    if (!_looking.add(hash)) return;
    try {
      _made[hash] = await _copies.existing(hash) != null;
    } on ArgumentError {
      _made[hash] = false;
    } finally {
      _looking.remove(hash);
    }
    _notify();
  }

  void _changed(String hash) {
    _notify();
    if (!_disposed) _switched(hash);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      job.stopped = true;
      job.run?.cancel();
    }
    models.dispose();
    super.dispose();
  }
}

class _Job {
  NoiseState state = NoiseState.off;
  NoiseRemovalRun? run;
  bool stopped = false;
  final Completer<NoiseProblem?> done = Completer();
}

/// Hands [NoiseRemovals] to the voice window and the cards, and rebuilds them
/// as it changes. Absent where this build cannot remove noise.
class NoiseRemovalScope extends InheritedNotifier<NoiseRemovals> {
  const NoiseRemovalScope({
    super.key,
    required NoiseRemovals super.notifier,
    required super.child,
  });

  static NoiseRemovals? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoiseRemovalScope>()?.notifier;

  /// For a callback, which must not subscribe to rebuilds.
  static NoiseRemovals? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NoiseRemovalScope>()?.notifier;
}
