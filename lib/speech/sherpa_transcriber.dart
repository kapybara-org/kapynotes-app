import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../audio/audio_decode.dart';
import '../core/platform.dart';
import 'local_model_store.dart';
import 'local_models.dart';
import 'transcriber.dart';

/// Parakeet, running here, on the platforms with no recogniser of their own.
///
/// This is the half of Phase 5 that took the longest to be worth building: a
/// downloader with nothing that read what it downloaded shipped months before
/// this did. What it buys is the same thing [AppleTranscriber] buys — no
/// account, no minutes, nothing leaving the device — for Windows, for Android
/// and for Linux, where the OS has nothing of the kind.
///
/// What it costs is 670 MB the user chose to spend, which is why
/// [readiness] answers [TranscriberReadiness.needsDownload] rather than
/// quietly fetching anything.
class SherpaTranscriber implements Transcriber {
  SherpaTranscriber({
    required LocalModelStore models,
    AudioDecoder decoder = const AudioDecoder(),
    AssetBundle? assets,
    LocalSpeechModel model = parakeetTdt06bV3Int8,
    String? Function()? language,
  }) : _models = models,
       _decoder = decoder,
       _assets = assets ?? rootBundle,
       _model = model,
       _language = language ?? (() => null);

  final LocalModelStore _models;
  final AudioDecoder _decoder;
  final AssetBundle _assets;
  final LocalSpeechModel _model;
  final String? Function() _language;

  /// The platforms with no recogniser of their own, which are the only ones
  /// this build carries the runtime for.
  ///
  /// Apple's are deliberately absent. Every Mac and iPhone this app runs on
  /// has an on-device recogniser already — `SpeechAnalyzer` from the 26s,
  /// `SFSpeechRecognizer` before that — so the 26 MB the runtime would add
  /// to every iPhone, and the 56 MB `dyld` would map at every Mac launch,
  /// bought nothing that [AppleTranscriber] does not give for free. The
  /// package's binaries for those two are stubbed out of the build (see
  /// `packages/apple_stubs`), and asking here would be a crash, not an
  /// answer.
  static bool get isPossibleHere =>
      AppPlatform.isWindows || AppPlatform.isAndroid || AppPlatform.isLinux;

  /// What the ref records. Names the exact export, because a different
  /// quantisation of the same model is a different transcript.
  String get engineId => 'sherpa/${_model.id}';

  @override
  Future<TranscriberReadiness> readiness() async {
    if (!isPossibleHere) return TranscriberReadiness.unsupported;
    // A language the model never learned is not a download away.
    final language = _language();
    if (language != null && !_model.languages.contains(language)) {
      return TranscriberReadiness.unsupported;
    }
    // The catalogue is the app's; whether the bytes are here is the disk's.
    // Asked every time rather than cached because the user can delete a model
    // from the pane this readiness is being drawn in.
    await _models.refresh();
    return _models.stateOf(_model).status == LocalModelStatus.ready
        ? TranscriberReadiness.ready
        : TranscriberReadiness.needsDownload;
  }

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async {
    final state = await readiness();
    if (state != TranscriberReadiness.ready) {
      throw TranscriberUnavailable(
        state,
        state == TranscriberReadiness.needsDownload
            ? 'Download the speech model to transcribe on this device.'
            : 'This device cannot transcribe on its own.',
      );
    }

    final directory = await _models.directoryFor(_model);
    final DecodedAudio decoded;
    try {
      decoded = await _decoder.decode(audio);
    } on AudioDecodeException catch (error) {
      // Terminal on purpose. A file that will not decode now will not decode
      // on the fourth retry, and "this recording cannot be read" is a truer
      // thing to tell somebody than a spinner.
      throw TranscriberUnavailable(
        TranscriberReadiness.unsupported,
        error.message,
      );
    }

    final vad = File('${decoded.file.path}.vad.onnx');
    try {
      final vadPath = await _unpackVad(vad);
      final words = await Isolate.run(
        () => _recognise(
          _RecogniseRequest(
            encoder: '${directory.path}/encoder.int8.onnx',
            decoder: '${directory.path}/decoder.int8.onnx',
            joiner: '${directory.path}/joiner.int8.onnx',
            tokens: '${directory.path}/tokens.txt',
            vad: vadPath,
            pcmPath: decoded.file.path,
            sampleRate: decoded.sampleRate,
            frames: decoded.frames,
          ),
        ),
      );
      return TranscriptDraft(
        engine: engineId,
        // The model is multilingual and does not say which language it heard.
        // The user's setting is the only claim anybody has made, and its
        // absence is honestly reported as the model's own name for "many".
        lang: language ?? _language() ?? 'mul',
        segments: segmentsFromWords(words),
      );
    } finally {
      // Whatever happened, the 57 MB of decoded audio goes. A failure that
      // leaves its scratch file behind is a leak nobody would attribute to
      // transcription.
      await decoded.dispose();
      try {
        if (await vad.exists()) await vad.delete();
      } on FileSystemException {
        // Already gone with the rest of the temporary directory.
      }
    }
  }

  /// Copies the bundled voice activity model to [to], where the native side
  /// can open it, and answers its path.
  ///
  /// Null when the asset is missing or the copy fails. That costs the cuts at
  /// pauses, not the transcript: [_recognise] falls back to cutting at the
  /// quietest moment it can find.
  Future<String?> _unpackVad(File to) async {
    try {
      final data = await _assets.load(sileroVadAsset);
      await to.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return to.path;
    } catch (_) {
      return null;
    }
  }
}

/// Silero's voice activity model, which finds the pauses a recording is cut
/// at. Bundled only for Android, Windows and Linux (see pubspec.yaml), the
/// platforms this recogniser runs on.
const String sileroVadAsset = 'assets/speech/silero_vad.onnx';

/// Lists the voice activity model's licence on the licences page, in the
/// builds that carry the model.
void registerVadLicense() {
  if (!SherpaTranscriber.isPossibleHere) return;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Silero VAD',
    ], await rootBundle.loadString('assets/speech/silero_vad-LICENSE.txt'));
  });
}

/// Everything the isolate needs, and nothing that cannot cross into one.
///
/// Paths rather than a [LocalModelStore] and a [File]: an isolate gets a copy
/// of what it is sent, and neither of those would survive the trip.
class _RecogniseRequest {
  const _RecogniseRequest({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
    required this.vad,
    required this.pcmPath,
    required this.sampleRate,
    required this.frames,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
  final String? vad;
  final String pcmPath;
  final int sampleRate;
  final int frames;
}

/// The longest run of audio handed to the model at once.
///
/// Parakeet will take far more, and was given ninety seconds until KAP-314.
/// Over that long it now and then skips a whole passage and carries on as if
/// nothing were missing: 129 words of one five-minute audiobook chapter, gone
/// without a trace. Cut at pauses into twenty seconds or less, the same
/// recordings lost no sentence and came out as accurate as transcribing one
/// sentence at a time, and a little faster than the long windows were.
const int _chunkSeconds = 20;

/// Recognises the whole recording, in one isolate, and answers with words.
///
/// Runs off the main isolate because it is seconds to minutes of solid CPU:
/// on it, every frame of the app would be dropped for the duration, which is
/// the one thing the voice feature promised never to do.
List<TimedWord> _recognise(_RecogniseRequest request) {
  // Bindings are per-isolate. Skipping this in the isolate that actually uses
  // them is the documented way to get a null function pointer instead of a
  // recogniser.
  sherpa.initBindings();

  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: request.encoder,
          decoder: request.decoder,
          joiner: request.joiner,
        ),
        tokens: request.tokens,
        // Measured on an M-series Mac, 56 s of speech, this exact int8 pack:
        // 1 thread 20.7 s, 2 threads 10.9 s, 4 threads 6.0 s, 6 threads
        // 5.4 s, 8 threads 4.7 s. Four is where the curve bends — it is
        // nearly twice as fast as two, and everything past it buys a few per
        // cent for a core the rest of the machine wanted.
        numThreads: 4,
        debug: false,
      ),
    ),
  );

  final file = File(request.pcmPath).openSync();
  try {
    List<TimedWord> decode(int start, int end) {
      final samples = _readWindow(file, start, end - start);
      if (samples.isEmpty) return const [];
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: request.sampleRate);
        recognizer.decode(stream);
        final offsetMs = (start * 1000) ~/ request.sampleRate;
        return _wordsFrom(recognizer.getResult(stream), offsetMs);
      } finally {
        stream.free();
      }
    }

    final speech = _speechIn(file, request);
    final chunks = chunksAtPauses(
      frames: request.frames,
      pauses: [
        for (var i = 1; i < speech.length; i++)
          (speech[i - 1].$2 + speech[i].$1) ~/ 2,
      ],
      limit: _chunkSeconds * request.sampleRate,
      quietest: (from, to) => _quietestBetween(file, request, from, to),
    );
    return hearAgain(
      words: [for (final (start, end) in chunks) ...decode(start, end)],
      speech: speech,
      frames: request.frames,
      sampleRate: request.sampleRate,
      decode: decode,
    );
  } finally {
    file.closeSync();
    recognizer.free();
  }
}

/// Where to cut [frames] samples into chunks of at most [limit] samples.
///
/// Each chunk ends at the last of the [pauses] that fits in it, so no chunk
/// starts or ends inside a word. When none fits, which is a speaker who has
/// not stopped for twenty seconds or a recording the voice activity model
/// could not read, it ends where [quietest] finds the quietest moment in the
/// chunk's last third.
@visibleForTesting
List<(int, int)> chunksAtPauses({
  required int frames,
  required List<int> pauses,
  required int limit,
  required int Function(int from, int to) quietest,
}) {
  final chunks = <(int, int)>[];
  var start = 0;
  var next = 0;
  while (start < frames) {
    if (frames - start <= limit) {
      chunks.add((start, frames));
      break;
    }
    int? end;
    while (next < pauses.length && pauses[next] <= start + limit) {
      if (pauses[next] > start) end = pauses[next];
      next++;
    }
    end ??= quietest(start + limit - limit ~/ 3, start + limit);
    chunks.add((start, end));
    start = end;
  }
  return chunks;
}

/// Hears again, on its own, any stretch of [speech] the model gave no
/// words for, and keeps the second hearing when it found more.
///
/// Parakeet now and then skips whole sentences, most often when a new voice
/// starts partway through a chunk over background noise, and far less often
/// when it hears them alone. More than three seconds of speech between two
/// words is that skip: speech is counted, pauses are not, so the voice
/// activity model splitting a sentence at its breaths does not hide it.
/// Each stretch of speech in there with no word in it is heard again on its
/// own, from the pause before it to the pause after it: heard together, or
/// with the voices around them, a run of skipped sentences can be skipped
/// again. A stretch with words in it is heard again only when more than
/// three seconds of it had none. Less is left alone, since a cough or a
/// breath is speech to the voice activity model too.
@visibleForTesting
List<TimedWord> hearAgain({
  required List<TimedWord> words,
  required List<(int, int)> speech,
  required int frames,
  required int sampleRate,
  required List<TimedWord> Function(int start, int end) decode,
}) {
  int ms(int sample) => (sample * 1000) ~/ sampleRate;
  final anchors = [
    0,
    ...[for (final word in words) word.startMs]..sort(),
    ms(frames),
  ];
  final skipped = <int>{};
  var first = 0;
  for (var g = 1; g < anchors.length; g++) {
    final from = anchors[g - 1];
    final to = anchors[g];
    while (first < speech.length && ms(speech[first].$2) <= from) {
      first++;
    }
    var unheardMs = 0;
    final touched = <int>[];
    for (var k = first; k < speech.length && ms(speech[k].$1) < to; k++) {
      final start = ms(speech[k].$1);
      final end = ms(speech[k].$2);
      final wordless = min(end, to) - max<int>(start, from);
      if (wordless <= 0) continue;
      unheardMs += wordless;
      if ((start >= from && end <= to) || wordless > 3000) touched.add(k);
    }
    if (unheardMs > 3000) skipped.addAll(touched);
  }

  var heard = words;
  for (final i in skipped.toList()..sort()) {
    final start = i == 0 ? 0 : (speech[i - 1].$2 + speech[i].$1) ~/ 2;
    final end = i == speech.length - 1
        ? frames
        : (speech[i].$2 + speech[i + 1].$1) ~/ 2;
    final again = decode(start, end);
    final before = heard.where((word) => word.startMs < ms(start)).toList();
    final after = heard.where((word) => word.startMs >= ms(end)).toList();
    if (again.length > heard.length - before.length - after.length) {
      heard = [...before, ...again, ...after];
    }
  }
  return heard;
}

/// Every stretch of speech in the recording, as start and end samples.
///
/// Found by Silero's voice activity model, a quarter of a second of quiet
/// ending a stretch. Empty when there is no model, it will not load, or the
/// audio is at a rate it was not trained on, which leaves every cut to
/// [_quietestBetween] and nothing to hear again.
List<(int, int)> _speechIn(RandomAccessFile file, _RecogniseRequest request) {
  final model = request.vad;
  if (model == null || request.sampleRate != 16000) return const [];

  sherpa.VoiceActivityDetector? vad;
  try {
    final detector = vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: model,
          minSilenceDuration: 0.25,
          maxSpeechDuration: _chunkSeconds.toDouble(),
        ),
        sampleRate: request.sampleRate,
        debug: false,
      ),
      bufferSizeInSeconds: 3.0 * _chunkSeconds,
    );
    final speech = <(int, int)>[];
    void drain() {
      while (!detector.isEmpty()) {
        final segment = detector.front();
        speech.add((segment.start, segment.start + segment.samples.length));
        detector.pop();
      }
    }

    // One model window per call. The detector makes a single speech or
    // silence call for everything it is handed at once, so a second per call
    // hides every pause shorter than that second: one five-minute chapter
    // came out as six stretches of speech instead of sixty.
    const window = 512;
    final block = window * 32;
    for (var at = 0; at < request.frames; at += block) {
      final count = at + block > request.frames ? request.frames - at : block;
      final samples = _readWindow(file, at, count);
      for (var i = 0; i < samples.length; i += window) {
        final end = i + window > samples.length ? samples.length : i + window;
        detector.acceptWaveform(Float32List.sublistView(samples, i, end));
      }
      drain();
    }
    detector.flush();
    drain();
    return speech;
  } catch (_) {
    return const [];
  } finally {
    vad?.free();
  }
}

/// The middle of the quietest 20 ms between [from] and [to].
///
/// 20 ms is shorter than any syllable, and long enough that one quiet sample
/// in the middle of speech cannot win.
int _quietestBetween(
  RandomAccessFile file,
  _RecogniseRequest request,
  int from,
  int to,
) {
  final samples = _readWindow(file, from, to - from);
  final step = (request.sampleRate * 20) ~/ 1000;
  if (samples.length < step) return to;

  var quietestAt = 0;
  var quietest = double.infinity;
  for (var at = 0; at + step <= samples.length; at += step) {
    var energy = 0.0;
    for (var i = at; i < at + step; i++) {
      energy += samples[i] * samples[i];
    }
    if (energy < quietest) {
      quietest = energy;
      quietestAt = at;
    }
  }
  return from + quietestAt + step ~/ 2;
}

/// Reads [count] samples from [start], widened to the floats the model wants.
///
/// Sixteen-bit on disk and float in memory, one window at a time: the whole
/// reason the decoder wrote a file instead of answering with the samples.
Float32List _readWindow(RandomAccessFile file, int start, int count) {
  if (count <= 0) return Float32List(0);
  file.setPositionSync(start * 2);
  final bytes = file.readSync(count * 2);
  final shorts = bytes.buffer.asInt16List(
    bytes.offsetInBytes,
    bytes.lengthInBytes ~/ 2,
  );
  final out = Float32List(shorts.length);
  for (var i = 0; i < shorts.length; i++) {
    out[i] = shorts[i] / 32768.0;
  }
  return out;
}

/// Turns the model's tokens and their times into words.
///
/// Parakeet's vocabulary is sentencepiece, where `▁` marks a word start —
/// but **sherpa has already turned that into a plain leading space** by the
/// time the tokens reach here. Measured, not assumed: a real result comes
/// back as `[' W', 'r', 'ite', ' not', 'es', ' from']`, and testing for `▁`
/// matches nothing at all, which silently glues an entire recording into one
/// word and one segment. Both are accepted, so a model that does keep the
/// marker is read correctly too.
///
/// Falls back to the plain text when the tokens or their timings are missing,
/// because a transcript with no times is worth far more than no transcript.
List<TimedWord> _wordsFrom(
  sherpa.OfflineRecognizerResult result,
  int offsetMs,
) {
  final tokens = result.tokens;
  final timestamps = result.timestamps;
  if (tokens.isEmpty || timestamps.length != tokens.length) {
    final text = result.text.trim();
    if (text.isEmpty) return const [];
    return [TimedWord(text: text, startMs: offsetMs, endMs: offsetMs)];
  }

  final words = <TimedWord>[];
  var current = StringBuffer();
  var startMs = offsetMs;
  var endMs = offsetMs;

  void flush() {
    final text = current.toString().trim();
    if (text.isNotEmpty) {
      words.add(TimedWord(text: text, startMs: startMs, endMs: endMs));
    }
    current = StringBuffer();
  }

  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    final at = offsetMs + (timestamps[i] * 1000).round();
    if (token.startsWith('▁') || token.startsWith(' ')) {
      flush();
      startMs = at;
      current.write(token.substring(1));
    } else {
      if (current.isEmpty) startMs = at;
      current.write(token);
    }
    endMs = at;
  }
  flush();
  return words;
}
