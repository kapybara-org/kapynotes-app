import 'dart:io';

import 'speech_api.dart';
import 'transcriber.dart';

/// The transcript our server writes, behind the same interface as the local
/// ones.
///
/// Still the default, and for most people still the best: it knows the most
/// languages, it is the same on a five-year-old phone as on a new laptop, and
/// it costs the device nothing but the upload. What it costs the user is an
/// account, a network, minutes from the month's allowance, and the recording
/// leaving the machine — which is exactly what the other two implementations
/// are for.
class CloudTranscriber implements Transcriber {
  CloudTranscriber(this._api);

  /// Read on every call rather than held: signing in and out replaces it, and
  /// a captured null would outlive the sign-in that fixed it.
  final SpeechApi? Function() _api;

  @override
  Future<TranscriberReadiness> readiness() async => _api() == null
      ? TranscriberReadiness.needsAccount
      : TranscriberReadiness.ready;

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async {
    final api = _api();
    if (api == null) {
      throw const TranscriberUnavailable(
        TranscriberReadiness.needsAccount,
        'Sign in to have recordings transcribed for you.',
      );
    }
    // Read here rather than by the caller: this is the one implementation
    // that needs every byte in memory, because it is the one that uploads.
    final bytes = await audio.readAsBytes();
    final result = await api.transcribe(
      audio: bytes,
      requestId: requestId,
      language: language,
    );
    return TranscriptDraft(
      engine: result.engine,
      lang: result.lang,
      segments: result.segments,
      jobId: result.jobId,
      usage: result.usage,
    );
  }
}
