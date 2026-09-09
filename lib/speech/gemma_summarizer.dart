import 'dart:async';
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import '../core/device_memory.dart';
import 'local_model_store.dart';
import 'local_models.dart';
import 'summarizer.dart';

/// A downloaded language model, writing summaries on this device.
///
/// This is the fallback for everyone the platform does not cover: Windows and
/// Linux, and every Mac and phone without Apple Intelligence. It costs a
/// download the platform model does not, so everything here is arranged
/// around not making anyone pay for it twice:
///
///   * **Nothing loads until a summary is asked for.** No engine, no weights,
///     no native library. A user who never summarises on the device pays the
///     29 MB the runtime adds to the app and not one byte of RAM — the
///     LiteRT-LM framework is not linked at load time, so `dyld` never opens
///     it either, which `vmmap` confirms on a running app.
///   * **The session is closed after every summary.** The KV cache is the
///     largest live allocation after the weights, and holding one between two
///     recordings buys nothing.
///   * **The model is unloaded after [idleTimeout].** Summarising is bursty;
///     a gigabyte resident for the rest of the afternoon is not a trade
///     anybody would make on purpose.
///   * **One at a time.** Two notes finishing together must not load two
///     copies of a billion parameters.
///
/// What it cannot do is be good at long recordings. The bundle holds a few
/// thousand tokens; anything longer is trimmed before it is sent in, and the
/// summary is of what fits.
class GemmaSummarizer implements Summarizer {
  GemmaSummarizer({
    required LocalModelStore models,
    LocalSummaryModel model = gemma4E2bIt,
    DeviceMemory? memory,
    this.idleTimeout = const Duration(minutes: 2),
  }) : _models = models,
       _model = model,
       _memory = memory ?? DeviceMemory();

  final LocalModelStore _models;
  final LocalSummaryModel _model;
  final DeviceMemory _memory;

  /// How long a loaded model survives with nothing to do.
  ///
  /// Two minutes covers the case this is really for — several recordings
  /// finishing in a row after a meeting — without holding the weights while
  /// somebody goes to lunch.
  final Duration idleTimeout;

  InferenceModel? _loaded;
  Future<InferenceModel>? _loading;
  Timer? _idle;

  /// Held so a second note waits for the first rather than loading its own
  /// copy of the model.
  Future<void>? _busy;

  static const String engineId = 'gemma-4-e2b-it';

  /// How much transcript this can actually read, in characters.
  ///
  /// Roughly four characters to the token, and the context has to hold the
  /// instructions and the answer as well as the transcript, so two thirds of
  /// the window is the transcript's share. Public because it is a real limit
  /// of the feature rather than a detail: a recording longer than this is
  /// summarised from its beginning only.
  int get maximumTranscriptChars => (_model.contextTokens * 4 * 2) ~/ 3;

  @override
  Future<SummarizerReadiness> readiness() async {
    if (!await _isInstalled()) return SummarizerReadiness.needsDownload;
    return SummarizerReadiness.ready;
  }

  Future<bool> _isInstalled() async {
    await _models.refresh();
    return _models.stateOf(_model).status == LocalModelStatus.ready;
  }

  /// Whether this device has the memory to load it.
  ///
  /// Null memory means unmeasurable, which is allowed to try — see
  /// [DeviceMemory].
  Future<bool> hasEnoughMemory() async {
    final total = await _memory.total();
    return total == null || total >= _model.minimumMemoryBytes;
  }

  @override
  Future<SummaryDraft> summarize({
    required String text,
    required String lang,
    String? jobId,
    String? instruction,
  }) async => draftFromText(
    await _queued(_summaryPrompt(text, instruction), maxTokens: 320),
    engine: engineId,
  );

  @override
  Future<String> rewrite({
    required String text,
    required String lang,
    required String instruction,
    String? jobId,
  }) async {
    // A little more room than a summary: a LinkedIn post is longer than five
    // points, and a post cut off mid-sentence is worse than a slow one.
    final raw = await _queued(
      _rewritePrompt(text, instruction),
      maxTokens: 520,
    );
    final written = raw.trim();
    if (written.isEmpty) {
      throw const SummarizerUnavailable(
        SummarizerReadiness.unsupported,
        'The model came back with nothing.',
      );
    }
    return written;
  }

  /// Runs one prompt, and only one at a time.
  ///
  /// Two of these at once would mean two copies of a multi-billion-parameter
  /// model resident, which is the one thing this must never do.
  Future<String> _queued(String prompt, {required int maxTokens}) async {
    while (_busy != null) {
      await _busy;
    }
    final completer = Completer<void>();
    _busy = completer.future;
    try {
      return await _write(prompt, maxTokens: maxTokens);
    } finally {
      _busy = null;
      completer.complete();
    }
  }

  Future<String> _write(String prompt, {required int maxTokens}) async {
    if (!await _isInstalled()) {
      throw const SummarizerUnavailable(
        SummarizerReadiness.needsDownload,
        'Download the summary model to write summaries on this device.',
      );
    }
    _idle?.cancel();

    final model = await _ensureLoaded();
    final session = await model.createSession(
      // Low and narrow: a summary should be the same every time you ask, and
      // topK 1 is also the cheapest sampling there is.
      temperature: 0.2,
      topK: 1,
      // The cap that matters for CPU. A title and five points is well under
      // this; without it the model is free to keep going for the whole
      // remaining window.
      maxOutputTokens: maxTokens,
    );
    try {
      await session.addQueryChunk(Message.text(text: prompt));
      return await session.getResponse();
    } finally {
      // Always, including after a failure: the KV cache is the biggest thing
      // this holds and a thrown exception is no reason to keep it.
      await session.close();
      _scheduleUnload();
    }
  }

  /// What the model is told regardless of what the user asked for.
  ///
  /// A user's instruction is added after this, never in place of it: they
  /// are choosing what kind of summary they get, not whether the model may
  /// make things up about their own notes.
  static const String _groundRules =
      'Use the transcript\'s own words and names. Add nothing that is not in '
      'it. Do not explain what you are doing and do not address the reader.';

  String _clamped(String transcript) =>
      transcript.length > maximumTranscriptChars
      ? transcript.substring(0, maximumTranscriptChars)
      : transcript;

  String _summaryPrompt(String transcript, String? instruction) {
    // The format is asked for explicitly because this model has no guided
    // generation to constrain it — see parseSummaryText for what happens when
    // it answers in its own shape anyway.
    final asked = instruction?.trim().isNotEmpty ?? false
        ? instruction!.trim()
        : 'Answer with a title on the first line, at most six words, and then '
              'two to five short points, each on its own line beginning '
              'with "- ".';
    return 'Here is a transcript of someone talking into a notes app.\n\n'
        '$asked\n\n'
        '$_groundRules\n\n'
        'Transcript:\n${_clamped(transcript)}';
  }

  String _rewritePrompt(String transcript, String instruction) =>
      'Here is a transcript of someone talking into a notes app.\n\n'
      '${instruction.trim()}\n\n'
      '$_groundRules\n'
      'Reply with the finished text only: no preamble, no explanation, and '
      'no surrounding quotation marks.\n\n'
      'Transcript:\n${_clamped(transcript)}';

  Future<InferenceModel> _ensureLoaded() async {
    final ready = _loaded;
    if (ready != null) return ready;
    return _loading ??= _load().whenComplete(() {
      _loading = null;
    });
  }

  Future<InferenceModel> _load() async {
    await FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()]);

    final directory = await _models.directoryFor(_model);
    final path = '${directory.path}/${_model.files.single.name}';
    if (!await File(path).exists()) {
      throw const SummarizerUnavailable(
        SummarizerReadiness.needsDownload,
        'The summary model is not on this device.',
      );
    }

    // Our own file, already downloaded and checksummed by LocalModelStore.
    // The plugin's downloader is deliberately unused: it would be a second
    // way to fetch models, with its own progress, its own retries and its own
    // idea of where things live.
    // gemma4 rather than gemmaIt: the newer models carry their own tool-call
    // tokens, and the plugin routes the chat template differently for them.
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(path).install();

    final model = await FlutterGemma.getActiveModel(
      maxTokens: _model.contextTokens,
      // The GPU does this in a fraction of the CPU's time and leaves the
      // machine responsive while it works. The runtime falls back on its own
      // where there is no accelerator.
      preferredBackend: PreferredBackend.gpu,
    );
    _loaded = model;
    return model;
  }

  void _scheduleUnload() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () => unawaited(unload()));
  }

  /// Gives the weights back to the operating system.
  ///
  /// Called on the idle timer, and worth calling directly when the app goes
  /// to the background — a phone will kill a large resident process there
  /// long before it kills a small one.
  Future<void> unload() async {
    _idle?.cancel();
    _idle = null;
    final model = _loaded;
    _loaded = null;
    if (model == null) return;
    try {
      await model.close();
    } catch (_) {
      // Closing something already gone is not a failure worth surfacing; the
      // reference is dropped either way.
    }
  }
}
