import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/cloud_client.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/retrieval.dart';
import 'package:kapy_notes/sync/sync_api.dart';

import 'ai_fakes.dart';

void main() {
  final resetsAt = testNow.add(const Duration(days: 14));
  final usage = {
    'used': 10,
    'limit': 500,
    'remaining': 490,
    'resetsAt': resetsAt.toUtc().toIso8601String(),
  };
  final request = AnswerRequest(
    question: 'Lisbon?',
    notes: [
      ReadNote(
        id: 'never-sent',
        title: 'Trip',
        text: 'Lisbon flights',
        edited: DateTime.utc(2026, 11, 2),
      ),
    ],
    history: [
      KapyMessage(
        id: 'm',
        role: KapyRole.user,
        text: 'Earlier',
        at: DateTime.utc(2026),
      ),
    ],
    today: DateTime(2026, 11, 17),
  );

  KapyCloudClient client(
    http.Response Function(http.Request) answer, {
    List<http.Request>? log,
    String? token = 'tok',
  }) => KapyCloudClient(
    baseUrl: Uri.parse('https://api.test/'),
    token: () => token,
    client: MockClient((request) async {
      log?.add(request);
      return answer(request);
    }),
  );

  test('200 sends the contract and reads the answer and usage', () async {
    final log = <http.Request>[];
    final cloud = client(
      (_) =>
          http.Response(jsonEncode({'answer': ' Yes. ', 'usage': usage}), 200),
      log: log,
    );
    expect(await cloud.answer(KapyModel.cloud, request), 'Yes.');
    expect(cloud.usage!.remaining, 490);
    final sent = log.single;
    expect(sent.method, 'POST');
    expect(sent.url.toString(), 'https://api.test/ai/answer');
    expect(sent.headers['authorization'], 'Bearer tok');
    expect(sent.headers[protocolHeader], '$protocolVersion');
    expect(jsonDecode(sent.body), {
      'question': 'Lisbon?',
      'notes': [
        {
          'title': 'Trip',
          'text': 'Lisbon flights',
          'edited': '2026-11-02T00:00:00.000Z',
        },
      ],
      'history': [
        {'role': 'user', 'text': 'Earlier'},
      ],
    });
  });

  test('usage', () async {
    final log = <http.Request>[];
    final cloud = client(
      (_) => http.Response(jsonEncode(usage), 200),
      log: log,
    );
    final read = await cloud.fetchUsage();
    expect(read.remaining, 490);
    expect(read.limit, 500);
    expect(read.resetsAt, resetsAt);
    expect(log.single.url.path, '/ai/usage');
  });

  test('402 is Pro only', () async {
    final cloud = client((_) => http.Response('{"error":"pro-required"}', 402));
    expect(
      () => cloud.answer(KapyModel.cloud, request),
      throwsA(isA<AnswerProNeeded>()),
    );
  });

  test(
    '401 asks for a sign-in, and 426 for an update a retry cannot bring',
    () async {
      expect(
        () => client(
          (_) => http.Response('{"error":"unauthorized"}', 401),
        ).answer(KapyModel.cloud, request),
        throwsA(isA<AnswerSignInNeeded>()),
      );
      expect(
        () => client(
          (_) => http.Response('{}', 426),
        ).answer(KapyModel.cloud, request),
        throwsA(isA<AnswerFailed>().having((e) => e.retry, 'retry', isFalse)),
      );
    },
  );

  test("a 401 that isn't the server's own is tried again", () async {
    expect(
      () => client(
        (_) => http.Response('<html>Sign in to the Wi-Fi</html>', 401),
      ).answer(KapyModel.cloud, request),
      throwsA(isA<AnswerFailed>().having((e) => e.retry, 'retry', isTrue)),
    );
  });

  test('429 is the limit, with its usage', () async {
    final cloud = client(
      (_) => http.Response(
        jsonEncode({
          'error': 'limit reached',
          'usage': {...usage, 'remaining': 0},
        }),
        429,
      ),
    );
    await expectLater(
      cloud.answer(KapyModel.cloud, request),
      throwsA(
        isA<AnswerLimitReached>().having(
          (e) => e.usage.remaining,
          'remaining',
          0,
        ),
      ),
    );
    expect(cloud.usage!.remaining, 0);
  });

  test('429 going too fast says how long to wait, and is no limit', () async {
    for (final (headers, body, wait) in [
      (
        {'retry-after': '7'},
        {'error': 'too many requests', 'retryAfter': 7},
        7,
      ),
      (<String, String>{}, {'error': 'too many requests', 'retryAfter': 3}, 3),
    ]) {
      final cloud = client(
        (_) => http.Response(jsonEncode(body), 429, headers: headers),
      );
      await expectLater(
        cloud.answer(KapyModel.cloud, request),
        throwsA(
          isA<AnswerTooFast>()
              .having((e) => e.wait, 'wait', Duration(seconds: wait))
              .having((e) => e.retry, 'retry', isTrue),
        ),
      );
      expect(cloud.usage, isNull);
    }
    await expectLater(
      client(
        (_) => http.Response('{"error":"too many requests"}', 429),
      ).answer(KapyModel.cloud, request),
      throwsA(isNot(isA<AnswerTooFast>())),
    );
  });

  test('503 and 502 fail with a sentence', () async {
    for (final status in [503, 502, 500]) {
      final cloud = client((_) => http.Response('{"error":"x"}', status));
      await expectLater(
        cloud.answer(KapyModel.cloud, request),
        throwsA(isA<AnswerFailed>()),
      );
    }
  });

  test('no connection is offline', () async {
    final cloud = client((_) => throw http.ClientException('down'));
    await expectLater(
      cloud.answer(KapyModel.cloud, request),
      throwsA(isA<AnswerOffline>()),
    );
  });

  test('signed out sends nothing', () async {
    final log = <http.Request>[];
    final cloud = client(
      (_) => http.Response('{}', 200),
      log: log,
      token: null,
    );
    await expectLater(
      cloud.answer(KapyModel.cloud, request),
      throwsA(isA<AnswerSignInNeeded>()),
    );
    expect(log, isEmpty);
  });
}
