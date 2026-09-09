import 'speech_api.dart';
import 'summarizer.dart';

/// The summary our server writes, behind the same interface as the local ones.
///
/// Still the best of the three, and the default: it is the only one that has
/// read the whole transcript with a model big enough to be worth reading
/// back, and the only one that exists on every device. What it costs is an
/// account, a network, and the transcript leaving the machine — which is
/// exactly what the other two implementations are for.
class CloudSummarizer implements Summarizer {
  CloudSummarizer(this._api);

  /// Read on every call rather than held: signing in and out replaces it, and
  /// a captured null would outlive the sign-in that fixed it.
  final SpeechApi? Function() _api;

  @override
  Future<SummarizerReadiness> readiness() async => _api() == null
      ? SummarizerReadiness.needsAccount
      : SummarizerReadiness.ready;

  @override
  Future<SummaryDraft> summarize({
    required String text,
    required String lang,
    String? jobId,
    String? instruction,
  }) async {
    final api = _requireApi(jobId);
    final result = await api.summarize(
      jobId: jobId!,
      lang: lang,
      text: text,
      instruction: instruction,
    );
    return SummaryDraft(
      engine: result.engine,
      title: result.title,
      points: result.points,
    );
  }

  @override
  Future<String> rewrite({
    required String text,
    required String lang,
    required String instruction,
    String? jobId,
  }) async {
    final api = _requireApi(jobId);
    final result = await api.rewrite(
      jobId: jobId!,
      lang: lang,
      text: text,
      instruction: instruction,
    );
    return result.text;
  }

  /// The signed-in client, or the reason there is not one.
  ///
  /// The job id is checked here rather than at each call site because both
  /// endpoints are bound to the transcription the server bills for: there is
  /// nothing to ask it about a transcript it never made.
  SpeechApi _requireApi(String? jobId) {
    final api = _api();
    if (api == null) {
      throw const SummarizerUnavailable(
        SummarizerReadiness.needsAccount,
        'Sign in to have summaries written for you.',
      );
    }
    if (jobId == null) {
      // Either a transcript this server never made, or — far more likely —
      // one made before the id was kept on the note. Says the thing that
      // fixes it rather than the thing that is true, because "not made by
      // the server" is baffling to somebody whose transcript plainly was.
      throw const SummarizerUnavailable(
        SummarizerReadiness.unsupported,
        'Transcribe this recording again to write from it.',
      );
    }
    return api;
  }
}
