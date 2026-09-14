import '../sync/sync_api.dart';
import 'speech_api.dart';

/// One sentence a person can act on, for every way transcription can refuse.
///
/// A sibling of `describeSharingError`, and written to the same rule: say what
/// happened and what would fix it, never the status code and never the
/// provider's own words. Nothing here is ever the recording's fault in a way
/// that loses it — the audio is on disk before any of this is asked to run.
String describeSpeechError(Object error) => switch (error) {
  SyncAuthException() => 'Sign in again to transcribe voice notes.',
  SyncOutdatedException() => 'Update Kapy Notes to keep transcribing.',
  SyncRefusedException(:final code, :final body) => switch (code) {
    SpeechCodes.consentRequired => 'Turn on transcription first.',
    SpeechCodes.minutesExhausted => _outOfMinutes(body),
    SpeechCodes.busy => 'Another recording is processing. This one is next.',
    SpeechCodes.tooLarge => 'This recording exceeds the size limit.',
    SpeechCodes.tooLong => 'This recording is longer than 30 minutes.',
    SpeechCodes.unreadable => 'The server could not read this recording.',
    SpeechCodes.unavailable =>
      'Transcription is temporarily unavailable. Retrying soon.',
    SpeechCodes.jobUnknown => 'Transcribe this recording again first.',
    SpeechCodes.summaryLimit =>
      'Summary rewrite limit reached for this recording.',
    SpeechCodes.summariesExhausted => _outOfSummaries(body),
    SpeechCodes.summaryFailed =>
      'Could not write a summary. The transcript is here.',
    SpeechCodes.retryLimit => 'Retry limit reached. Transcribe again.',
    SpeechCodes.sessionRejected => 'Sign in again to transcribe voice notes.',
    SpeechCodes.offline =>
      'Could not reach the server. This will finish when you are back online.',
    _ => 'That action is not available.',
  },
  SyncTransientException() =>
    'Could not reach the server. This will finish when you are back online.',
  SyncProtocolException(:final message) => message,
  _ => 'That did not work.',
};

/// Says when the minutes come back, because "out of minutes" without a date
/// reads as "broken" rather than "wait".
String _outOfMinutes(Map<String, Object?> body) {
  final resetsAt = DateTime.tryParse('${body['resetsAt']}')?.toLocal();
  if (resetsAt == null) return 'Monthly transcription limit reached.';
  return 'Transcription minutes reset on ${_shortDate(resetsAt)}.';
}

String _outOfSummaries(Map<String, Object?> body) {
  final resetsAt = DateTime.tryParse('${body['resetsAt']}')?.toLocal();
  if (resetsAt == null) return 'Monthly cloud summary limit reached.';
  return 'Cloud summaries reset on ${_shortDate(resetsAt)}.';
}

String _shortDate(DateTime at) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${at.day} ${months[at.month - 1]}';
}
