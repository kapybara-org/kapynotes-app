import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../audio/audio_decode.dart';
import '../core/platform.dart';
import 'local_model_store.dart';
import 'local_models.dart';
import 'transcriber.dart';

/// Parakeet, running here, on everything Apple's own recogniser does not cover.
///
/// This is the half of Phase 5 that took the longest to be worth building: a
/// downloader with nothing that read what it downloaded shipped months before
/// this did. What it buys is the same thing [AppleTranscriber] buys — no
/// account, no minutes, nothing leaving the device — for Windows, for Android,
/// and for the Macs and iPhones too old for `SpeechAnalyzer`.
///
/// What it costs is 670 MB the user chose to spend, which is why
/// [readiness] answers [TranscriberReadiness.needsDownload] rather than
/// quietly fetching anything.
class SherpaTranscriber implements Transcriber {
  SherpaTranscriber({
    required LocalModelStore models,
    AudioDecoder decoder = const AudioDecoder(),
    LocalSpeechModel model = parakeetTdt06bV3Int8,
    String? Function()? language,
  }) : _models = models,
       _decoder = decoder,
       _model = model,
       _language = language ?? (() => null);

  final LocalModelStore _models;
  final AudioDecoder _decoder;
  final LocalSpeechModel _model;
  final String? Function() _language;

  /// Every platform the native library is vendored for. Not a guess: the
  /// package ships prebuilt binaries for exactly these, and asking on any
  /// other would be a crash rather than an answer.
  static bool get isPossibleHere =>
      AppPlatform.isMacOS ||
      AppPlatform.isIOS ||
      AppPlatform.isWindows ||
      AppPlatform.isAndroid ||
      AppPlatform.isLinux;

  /// What the ref records. Names the exact export, because a different
  /// quantisation of the same model is a different transcript.
  String get engineId => 'sherpa/${_model.id}';

  @override
  Future<TranscriberReadiness> readiness() async {
    if (!isPossibleHere) return TranscriberReadiness.unsupported;
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
            ? 'Download ${_model.name} to transcribe on this device.'
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

    try {
      final words = await Isolate.run(
        () => _recognise(
          _RecogniseRequest(
            encoder: '${directory.path}/encoder.int8.onnx',
            decoder: '${directory.path}/decoder.int8.onnx',
            joiner: '${directory.path}/joiner.int8.onnx',
            tokens: '${directory.path}/tokens.txt',
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
    }
  }
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
    required this.pcmPath,
    required this.sampleRate,
    required this.frames,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
  final String pcmPath;
  final int sampleRate;
  final int frames;
}

/// The longest run of audio handed to the model at once.
///
/// Not a limit of the model — Parakeet will take far more — but of the
/// machine: an offline recogniser holds the encoder output for the whole
/// utterance, and thirty minutes at once is hundreds of megabytes on a phone
/// that has better uses for them. Ninety seconds keeps the peak flat and
/// costs nothing, because the split is made where nobody is speaking.
const int _windowSeconds = 90;

/// How far back from a window's edge to hunt for a quiet moment.
///
/// Fifteen seconds is long enough to find the gap between two sentences in
/// any ordinary speech and short enough that the windows stay near their
/// nominal length.
const int _searchSeconds = 15;

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
  final words = <TimedWord>[];
  try {
    var start = 0;
    while (start < request.frames) {
      final end = _windowEnd(file, request, start);
      final samples = _readWindow(file, start, end - start);
      if (samples.isEmpty) break;

      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(
          samples: samples,
          sampleRate: request.sampleRate,
        );
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        final offsetMs = (start * 1000) ~/ request.sampleRate;
        words.addAll(_wordsFrom(result, offsetMs));
      } finally {
        stream.free();
      }
      start = end;
    }
  } finally {
    file.closeSync();
    recognizer.free();
  }
  return words;
}

/// Where the next window should stop.
///
/// The end of the recording if it is close enough, otherwise the quietest
/// 20 ms in the last [_searchSeconds] of the window — which in speech is a
/// pause, and cutting there means no window ever starts or ends mid-word.
int _windowEnd(RandomAccessFile file, _RecogniseRequest request, int start) {
  final nominal = start + _windowSeconds * request.sampleRate;
  if (nominal >= request.frames) return request.frames;

  final searchFrom = nominal - _searchSeconds * request.sampleRate;
  final from = searchFrom < start ? start : searchFrom;
  final samples = _readWindow(file, from, nominal - from);
  if (samples.isEmpty) return nominal;

  // 20 ms of audio: shorter than any syllable, long enough that one quiet
  // sample in the middle of speech cannot win.
  final step = (request.sampleRate * 20) ~/ 1000;
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
List<TimedWord> _wordsFrom(sherpa.OfflineRecognizerResult result, int offsetMs) {
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
