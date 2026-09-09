import 'dart:io';

import 'package:flutter/services.dart';

import '../core/platform.dart';
import '../data/note_attachment.dart';
import 'transcriber.dart';

/// Apple's own recogniser, through the runners.
///
/// The framework is `Speech`'s `SpeechAnalyzer`, new in macOS and iOS 26, and
/// the whole appeal is that it costs the user nothing: no account, no minutes,
/// no 670 MB, and the model is on the machine before we ask.
///
/// Two things make it better here than the downloaded recogniser, not merely
/// cheaper. It reads the `.m4a` itself, so this is the one platform pair that
/// needs no audio decoding of ours at all; and it hands back finalised
/// sentences that already carry their time ranges, so the transcript view gets
/// real segments without anything guessing where a sentence ended.
///
/// Unlike [AppleSummarizer] this does **not** need Apple Intelligence, which
/// is why the two are separate channels: a device that cannot summarise here
/// can very often still transcribe here, and one availability answer for both
/// would have hidden that.
class AppleTranscriber implements Transcriber {
  AppleTranscriber({
    MethodChannel channel = const MethodChannel(channelName),
    String? Function()? language,
  }) : _channel = channel,
       _language = language ?? (() => null);

  static const String channelName = 'kapynotes/transcription';

  /// What the ref records, so a note can still say what wrote its transcript
  /// after the setting has changed twice.
  static const String engineId = 'apple/speech-analyzer';

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
      });
      return switch (answer) {
        'ready' => TranscriberReadiness.ready,
        'preparing' => TranscriberReadiness.preparing,
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
      });
    } on PlatformException catch (error) {
      // `unavailable` is the runner saying the framework went away between
      // the check above and the call. Everything else is a real failure of
      // the recogniser, and the queue should count it.
      if (error.code == 'unavailable') {
        throw TranscriberUnavailable(
          TranscriberReadiness.unsupported,
          error.message ?? 'On-device transcription is not available.',
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
    final raw = answer['segments'];
    final segments = <TranscriptSegment>[
      if (raw is List)
        for (final item in raw) ?TranscriptSegment.fromJson(item),
    ];
    // An empty list is not a failure: a recording of silence has no words in
    // it, and the note should say so rather than retry four more times.
    return TranscriptDraft(
      engine: engineId,
      lang: '${answer['lang'] ?? 'en'}',
      segments: segments,
    );
  }

  static String _reasonFor(TranscriberReadiness state) => switch (state) {
    TranscriberReadiness.preparing =>
      'This device is still fetching the language it needs.',
    _ => 'This device cannot transcribe on its own.',
  };
}
