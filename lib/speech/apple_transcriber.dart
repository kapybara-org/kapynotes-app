import 'dart:io';

import 'package:flutter/services.dart';

import '../core/platform.dart';
import '../data/note_attachment.dart';
import 'transcriber.dart';

/// Apple's own recognisers, through the runners.
///
/// Two frameworks behind one channel, chosen by the runner: `SpeechAnalyzer`
/// from macOS and iOS 26, and on-device `SFSpeechRecognizer` on everything
/// older, back to the oldest OS this app runs on. Either way the appeal is
/// the same: no account, no minutes, no 670 MB, and the model is on the
/// machine before we ask. Between them they cover every Apple device, which
/// is why the downloaded recogniser is not in the Apple builds at all.
///
/// The newer one reads the `.m4a` itself and hands back finalised sentences
/// with time ranges; the older one hands back timed words, which are grouped
/// here with [segmentsFromWords] exactly as Parakeet's are. The transcript
/// records which one wrote it.
///
/// Unlike [AppleSummarizer] neither needs Apple Intelligence, which is why
/// the two are separate channels: a device that cannot summarise here can
/// very often still transcribe here, and one availability answer for both
/// would have hidden that.
class AppleTranscriber implements Transcriber {
  AppleTranscriber({
    MethodChannel channel = const MethodChannel(channelName),
    String? Function()? language,
  }) : _channel = channel,
       _language = language ?? (() => null);

  static const String channelName = 'kapynotes/transcription';

  /// What the ref records when the runner does not say — the newer engine,
  /// which is the one that answered before there were two.
  static const String engineId = 'apple/speech-analyzer';

  /// Asks the runner for the older engine on a machine that has both. Only
  /// ever set by a test build: `--dart-define=KAPY_APPLE_SPEECH=legacy`.
  static const String _forcedEngine = String.fromEnvironment(
    'KAPY_APPLE_SPEECH',
  );

  final MethodChannel _channel;

  /// The user's language preference, read on every call: it is a setting, and
  /// a captured value would go stale the moment they changed it.
  final String? Function() _language;

  /// Apple only. Not a guess at eligibility — that is the runner's answer —
  /// just the platforms where the framework exists at all.
  static bool get isPossibleHere => AppPlatform.isMacOS || AppPlatform.isIOS;

  @override
  Future<TranscriberReadiness> readiness() async {
    if (!isPossibleHere) return TranscriberReadiness.unsupported;
    try {
      final answer = await _channel.invokeMethod<String>('availability', {
        if (_language() != null) 'language': _language(),
        if (_forcedEngine.isNotEmpty) 'engine': _forcedEngine,
      });
      return switch (answer) {
        'ready' => TranscriberReadiness.ready,
        'preparing' => TranscriberReadiness.preparing,
        // The older engine's permission, refused. The one answer here the
        // user can change, so it is its own state rather than "unsupported".
        'denied' => TranscriberReadiness.needsSystemFeature,
        _ => TranscriberReadiness.unsupported,
      };
    } on PlatformException {
      return TranscriberReadiness.unsupported;
    } on MissingPluginException {
      // An older runner, or a platform whose Runner has no such channel. Not
      // an error: it is the same answer as an OS without the framework.
      return TranscriberReadiness.unsupported;
    }
  }

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async {
    final state = await readiness();
    if (state != TranscriberReadiness.ready) {
      throw TranscriberUnavailable(state, _reasonFor(state));
    }
    final Object? answer;
    try {
      answer = await _channel.invokeMethod<Object?>('transcribe', {
        'path': audio.path,
        if ((language ?? _language()) != null) 'language': language ?? _language(),
        if (_forcedEngine.isNotEmpty) 'engine': _forcedEngine,
      });
    } on PlatformException catch (error) {
      // `unavailable` is the runner saying the framework went away between
      // the check above and the call, and `denied` that the user refused the
      // permission when asked. Everything else is a real failure of the
      // recogniser, and the queue should count it.
      if (error.code == 'unavailable') {
        throw TranscriberUnavailable(
          TranscriberReadiness.unsupported,
          error.message ?? 'On-device transcription is not available.',
        );
      }
      if (error.code == 'denied') {
        throw TranscriberUnavailable(
          TranscriberReadiness.needsSystemFeature,
          error.message ?? 'Kapy Notes was not allowed to use speech recognition.',
        );
      }
      rethrow;
    }
    if (answer is! Map) {
      throw const TranscriberUnavailable(
        TranscriberReadiness.unsupported,
        'The transcript came back empty.',
      );
    }
    // Sentences from the newer engine, words from the older; a runner that
    // sends both is read for its sentences.
    final rawSegments = answer['segments'];
    final rawWords = answer['words'];
    final segments = rawSegments is List
        ? <TranscriptSegment>[
            for (final item in rawSegments) ?TranscriptSegment.fromJson(item),
          ]
        : segmentsFromWords(_timedWords(rawWords));
    // An empty list is not a failure: a recording of silence has no words in
    // it, and the note should say so rather than retry four more times.
    final engine = answer['engine'];
    return TranscriptDraft(
      engine: engine is String && engine.isNotEmpty ? engine : engineId,
      lang: '${answer['lang'] ?? 'en'}',
      segments: segments,
    );
  }

  static List<TimedWord> _timedWords(Object? raw) => [
    if (raw is List)
      for (final item in raw)
        if (item is Map && item['t'] is String)
          TimedWord(
            text: item['t'] as String,
            startMs: item['s'] is int ? item['s'] as int : 0,
            endMs: item['e'] is int ? item['e'] as int : 0,
          ),
  ];

  static String _reasonFor(TranscriberReadiness state) => switch (state) {
    TranscriberReadiness.preparing =>
      'This device is still fetching the language it needs.',
    TranscriberReadiness.needsSystemFeature =>
      'Allow Kapy Notes to use speech recognition in Privacy settings.',
    _ => 'This device cannot transcribe on its own.',
  };
}
