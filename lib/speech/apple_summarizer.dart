import 'package:flutter/services.dart';

import '../core/platform.dart';
import 'summarizer.dart';

/// Apple's own on-device model, through the runners.
///
/// The framework is `FoundationModels`, the model is the one Apple
/// Intelligence already downloaded, and the whole appeal is that it costs the
/// user nothing: no account, no minutes, no 584 MB, and it is on the machine
/// before we ask. What it costs *us* is that it is not always there — the
/// device may be ineligible, the feature may be off, the weights may still be
/// arriving — so [readiness] is asked every time rather than cached.
///
/// Only macOS and iOS have it. Everywhere else this reports
/// [SummarizerReadiness.unsupported] without touching a channel, so no other
/// platform pays for a method call that would answer
/// `MissingPluginException`.
class AppleSummarizer implements Summarizer {
  AppleSummarizer({MethodChannel channel = const MethodChannel(channelName)})
    : _channel = channel;

  static const String channelName = 'kapynotes/summaries';

  /// What the ref records, so a note can still say what wrote its summary
  /// after the setting has changed twice.
  static const String engineId = 'apple/foundation-models';

  final MethodChannel _channel;

  /// Apple only. Not a guess at eligibility — that is the runner's answer —
  /// just the platforms where the framework exists at all.
  static bool get isPossibleHere => AppPlatform.isMacOS || AppPlatform.isIOS;

  @override
  Future<SummarizerReadiness> readiness() async {
    if (!isPossibleHere) return SummarizerReadiness.unsupported;
    try {
      final answer = await _channel.invokeMethod<String>('availability');
      return switch (answer) {
        'ready' => SummarizerReadiness.ready,
        'disabled' => SummarizerReadiness.needsSystemFeature,
        'preparing' => SummarizerReadiness.preparing,
        _ => SummarizerReadiness.unsupported,
      };
    } on PlatformException {
      return SummarizerReadiness.unsupported;
    } on MissingPluginException {
      // An older runner, or a platform whose Runner has no such channel. Not
      // an error: it is the same answer as an ineligible Mac.
      return SummarizerReadiness.unsupported;
    }
  }

  @override
  Future<SummaryDraft> summarize({
    required String text,
    required String lang,
    String? jobId,
    String? instruction,
  }) async {
    final answer = await _invoke('summarize', {
      'text': text,
      'language': lang,
      if (instruction != null && instruction.trim().isNotEmpty)
        'instruction': instruction.trim(),
    });
    if (answer is! Map) {
      throw const SummarizerUnavailable(
        SummarizerReadiness.unsupported,
        'The summary came back empty.',
      );
    }
    final title = answer['title'];
    final points = answer['points'];
    // Guided generation gives back the two fields directly; a build that
    // could not use it sends `text` and this end does the reading.
    if (title is String && points is List) {
      return SummaryDraft(
        engine: engineId,
        title: title.trim(),
        points: [
          for (final point in points)
            if (point is String && point.trim().isNotEmpty) point.trim(),
        ],
      );
    }
    return draftFromText('${answer['text'] ?? ''}', engine: engineId);
  }

  @override
  Future<String> rewrite({
    required String text,
    required String lang,
    required String instruction,
    String? jobId,
  }) async {
    final answer = await _invoke('rewrite', {
      'text': text,
      'language': lang,
      'instruction': instruction.trim(),
    });
    final written = '${answer ?? ''}'.trim();
    if (written.isEmpty) {
      throw const SummarizerUnavailable(
        SummarizerReadiness.unsupported,
        'The model came back with nothing.',
      );
    }
    return written;
  }

  /// One call to the runner, with the readiness check and the one platform
  /// error worth translating. Both jobs need exactly this around them.
  Future<Object?> _invoke(String method, Map<String, Object?> arguments) async {
    final state = await readiness();
    if (state != SummarizerReadiness.ready) {
      throw SummarizerUnavailable(state, _reasonFor(state));
    }
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      // `unavailable` is the runner saying the model went away between the
      // check above and the call — Apple Intelligence can be switched off
      // mid-session. Everything else is a real failure of the model.
      if (error.code == 'unavailable') {
        throw SummarizerUnavailable(
          SummarizerReadiness.unsupported,
          error.message ?? 'Apple Intelligence is not available.',
        );
      }
      rethrow;
    }
  }

  static String _reasonFor(SummarizerReadiness state) => switch (state) {
    SummarizerReadiness.needsSystemFeature =>
      'Turn on Apple Intelligence in System Settings to summarise here.',
    SummarizerReadiness.preparing =>
      'Apple Intelligence is still downloading its model.',
    _ => 'Apple Intelligence is not available on this device.',
  };
}
