import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sync/sync_api.dart' show protocolHeader, protocolVersion;
import 'answer_engine.dart';
import 'kapy_ai.dart';

/// Kapy AI Cloud: Kapy's server, which hands the question and the notes it
/// read to a model it never names, and keeps nothing but a count.
///
/// The contract is `GET /ai/usage` and `POST /ai/answer` (see the kapynotes
/// repository), behind the same session and protocol header as every other
/// call, and Pro only.
class KapyCloudClient implements AnswerEngine {
  KapyCloudClient({
    required Uri baseUrl,
    required String? Function() token,
    required http.Client client,
    this.timeout = const Duration(seconds: 90),
  }) : _baseUrl = baseUrl,
       _token = token,
       _client = client;

  final Uri _baseUrl;
  final String? Function() _token;
  final http.Client _client;

  /// Longer than the server's own wait on the model, so a slow model comes
  /// back as the server's 502 rather than a socket closed under us.
  final Duration timeout;

  /// What the server said last, from any of its answers.
  CloudUsage? usage;

  Future<CloudUsage> fetchUsage() async {
    final body = await _send(http.Request('GET', _baseUrl.resolve('ai/usage')));
    return usage = _usageFrom(body) ?? (throw const AnswerFailed(_broken));
  }

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    final body = await _send(
      http.Request('POST', _baseUrl.resolve('ai/answer'))
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode({
          'question': request.question,
          'notes': [
            for (final note in request.notes)
              {
                'title': note.title,
                'text': note.text,
                'edited': note.edited.toUtc().toIso8601String(),
              },
          ],
          'history': [
            for (final message in request.history)
              {'role': message.role.name, 'text': message.text},
          ],
        }),
    );
    usage = _usageFrom(body['usage']) ?? usage;
    final answer = body['answer'];
    if (answer is! String || answer.trim().isEmpty) {
      throw const AnswerFailed(_broken);
    }
    return answer.trim();
  }

  Future<Map<String, Object?>> _send(http.Request request) async {
    final token = _token();
    if (token == null) {
      throw const AnswerFailed('Sign in to use Kapy AI Cloud.');
    }
    request.headers
      ..['authorization'] = 'Bearer $token'
      ..['accept'] = 'application/json'
      ..[protocolHeader] = '$protocolVersion';

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      );
    } catch (_) {
      throw const AnswerOffline();
    }

    final body = _decode(response.body);
    switch (response.statusCode) {
      case 200:
        return body;
      case 401:
        throw const AnswerFailed('Sign in again to use Kapy AI Cloud.');
      case 402:
        throw const AnswerFailed('Kapy AI Cloud is part of Pro.');
      case 426:
        throw const AnswerFailed('Update Kapy Notes to use Kapy AI Cloud.');
      case 429:
        final usage = _usageFrom(body['usage']);
        if (usage == null) throw const AnswerFailed(_busy);
        this.usage = usage;
        throw AnswerLimitReached(usage);
      case 502:
        throw const AnswerFailed("Couldn't answer just now. Try again.");
      default:
        throw const AnswerFailed(_busy);
    }
  }

  static const String _broken = "Kapy AI couldn't answer. Try again.";
  static const String _busy = "Kapy AI Cloud can't answer right now.";

  static CloudUsage? _usageFrom(Object? raw) {
    if (raw is! Map) return null;
    final remaining = raw['remaining'];
    final limit = raw['limit'];
    final resetsAt = DateTime.tryParse('${raw['resetsAt']}');
    if (remaining is! int || limit is! int || resetsAt == null) return null;
    return CloudUsage(
      remaining: remaining,
      limit: limit,
      resetsAt: resetsAt.toLocal(),
    );
  }

  static Map<String, Object?> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } on FormatException {
      return const {};
    }
  }
}
