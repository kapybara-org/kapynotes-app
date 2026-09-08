import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../data/note_attachment.dart';
import '../sync/sync_api.dart';

/// The transcription terms this account has accepted.
class SpeechConsentStatus {
  final int acceptedVersion;
  final int currentVersion;
  final DateTime? acceptedAt;

  const SpeechConsentStatus({
    required this.acceptedVersion,
    required this.currentVersion,
    this.acceptedAt,
  });

  bool get isAccepted => acceptedVersion >= currentVersion;

  static SpeechConsentStatus fromJson(Map<String, Object?> raw) {
    final at = raw['acceptedAt'];
    return SpeechConsentStatus(
      acceptedVersion: raw['acceptedVersion'] is int ? raw['acceptedVersion']! as int : 0,
      currentVersion: raw['currentVersion'] is int ? raw['currentVersion']! as int : 1,
      acceptedAt: at is String ? DateTime.tryParse(at) : null,
    );
  }
}

/// This month's transcription allowance and what is left of it.
class SpeechUsage {
  final int usedSeconds;
  final int quotaSeconds;
  final DateTime resetsAt;

  const SpeechUsage({
    required this.usedSeconds,
    required this.quotaSeconds,
    required this.resetsAt,
  });

  int get remainingSeconds =>
      usedSeconds >= quotaSeconds ? 0 : quotaSeconds - usedSeconds;

  bool get isExhausted => remainingSeconds <= 0;

  static SpeechUsage fromJson(Map<String, Object?> raw) => SpeechUsage(
    usedSeconds: raw['usedSeconds'] is int ? raw['usedSeconds']! as int : 0,
    quotaSeconds: raw['quotaSeconds'] is int ? raw['quotaSeconds']! as int : 0,
    resetsAt:
        DateTime.tryParse('${raw['resetsAt']}')?.toLocal() ?? DateTime.now(),
  );
}

/// What one transcription produced.
class TranscribeResult {
  final String jobId;
  final String lang;
  final String engine;
  final List<TranscriptSegment> segments;
  final SpeechUsage usage;

  const TranscribeResult({
    required this.jobId,
    required this.lang,
    required this.engine,
    required this.segments,
    required this.usage,
  });
}

class SummaryResult {
  final String engine;
  final String title;
  final List<String> points;

  const SummaryResult({
    required this.engine,
    required this.title,
    required this.points,
  });
}

/// The speech endpoints. Abstract for the same reason [SyncApi] is: the queue
/// above it is most of what there is to get wrong, and it should be testable
/// without a server, a network, or a provider bill.
abstract class SpeechApi {
  Future<SpeechConsentStatus> consent();

  /// [version] of 0 withdraws.
  Future<SpeechConsentStatus> acceptConsent(int version);

  Future<SpeechUsage> usage();

  /// [requestId] names one *intent* to transcribe: every retry of it is free,
  /// and asking again deliberately means minting a new one.
  Future<TranscribeResult> transcribe({
    required Uint8List audio,
    required String requestId,
    String? language,
  });

  Future<SummaryResult> summarize({
    required String jobId,
    required String lang,
    required String text,
  });
}

/// Error codes the server names, mirrored so the app can act on them rather
/// than on status codes.
class SpeechCodes {
  static const consentRequired = 'speech-consent-required';
  static const minutesExhausted = 'speech-minutes-exhausted';
  static const busy = 'speech-busy';
  static const tooLarge = 'speech-too-large';
  static const tooLong = 'speech-too-long';
  static const unreadable = 'speech-unreadable';
  static const unavailable = 'speech-unavailable';
  static const jobUnknown = 'speech-job-unknown';
  static const summaryLimit = 'speech-summary-limit';
  static const summaryFailed = 'speech-summary-failed';
  static const retryLimit = 'speech-retry-limit';
}

/// The current consent version this build knows about. Kept in step with
/// `SPEECH_CONSENT_VERSION` in the contract.
const int speechConsentVersion = 1;

/// Whole-request timeout, covering a slow upload as well as the providers.
/// Longer than every timeout inside it, so a slow provider surfaces as a
/// refusal from the server rather than a socket closed under us.
const Duration speechClientTimeout = Duration(seconds: 300);

class HttpSpeechApi implements SpeechApi {
  HttpSpeechApi({
    required Uri baseUrl,
    required Future<String?> Function() token,
    http.Client? client,
    this.timeout = speechClientTimeout,
  }) : _baseUrl = baseUrl,
       _token = token,
       _client = client ?? http.Client();

  final Uri _baseUrl;
  final Future<String?> Function() _token;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<SpeechConsentStatus> consent() async =>
      SpeechConsentStatus.fromJson(await _json('GET', 'speech/consent'));

  @override
  Future<SpeechConsentStatus> acceptConsent(int version) async =>
      SpeechConsentStatus.fromJson(
        await _json('POST', 'speech/consent', payload: {'version': version}),
      );

  @override
  Future<SpeechUsage> usage() async =>
      SpeechUsage.fromJson(await _json('GET', 'speech/usage'));

  @override
  Future<TranscribeResult> transcribe({
    required Uint8List audio,
    required String requestId,
    String? language,
  }) async {
    final body = await _json(
      'POST',
      'speech/transcribe',
      bytes: audio,
      headers: {
        'content-type': 'audio/mp4',
        'x-speech-request-id': requestId,
        if (language case final String value) 'x-speech-language': value,
      },
    );
    return TranscribeResult(
      jobId: '${body['jobId']}',
      lang: '${body['lang']}',
      engine: '${body['engine']}',
      segments: [
        for (final raw in (body['segments'] as List? ?? const []))
          ?TranscriptSegment.fromJson(raw),
      ],
      usage: SpeechUsage.fromJson(
        (body['usage'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
    );
  }

  @override
  Future<SummaryResult> summarize({
    required String jobId,
    required String lang,
    required String text,
  }) async {
    final body = await _json(
      'POST',
      'speech/summarize',
      payload: {'jobId': jobId, 'lang': lang, 'text': text},
    );
    return SummaryResult(
      engine: '${body['engine']}',
      title: '${body['title']}',
      points: [
        for (final point in (body['points'] as List? ?? const [])) '$point',
      ],
    );
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Map<String, Object?>? payload,
    Uint8List? bytes,
    Map<String, String> headers = const {},
  }) async {
    final token = await _token();
    if (token == null) throw const SyncAuthException('not signed in');

    final request = http.Request(method, _baseUrl.resolve(path))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json'
      ..headers[protocolHeader] = '$protocolVersion';
    request.headers.addAll(headers);
    if (payload != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(payload);
    }
    if (bytes != null) request.bodyBytes = bytes;

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      );
    } on TimeoutException {
      throw const SyncTransientException('timed out');
    } catch (error) {
      throw SyncTransientException('$error');
    }

    final status = response.statusCode;
    if (status == 401) throw const SyncAuthException('session rejected');
    // 429 and 5xx are the server asking for patience — with one exception:
    // a 503 naming `speech-unavailable` is the providers being down, which is
    // worth retrying but must reach the queue as a named refusal so the chip
    // can say something true.
    if (status == 429 || (status >= 500 && status != 503)) {
      throw SyncTransientException('server returned $status');
    }

    final decoded = _decodeBody(response.body);
    if (status >= 400) {
      final code = decoded['error'];
      throw SyncRefusedException(status, code is String ? code : 'error', decoded);
    }
    return decoded;
  }

  Map<String, Object?> _decodeBody(String body) {
    if (body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }
}
