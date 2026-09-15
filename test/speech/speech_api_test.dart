import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/speech/speech_api.dart';
import 'package:kapy_notes/speech/transcriber.dart';

void main() {
  test('transcription sends the selected cloud model to the server', () async {
    late http.Request sent;
    final api = HttpSpeechApi(
      baseUrl: Uri.parse('https://api.kapynotes.test/'),
      token: () async => 'session-token',
      client: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'jobId': '11111111-1111-4111-8111-111111111111',
            'lang': 'en',
            'engine': 'openrouter/${CloudTranscriptionModel.nvidia.id}',
            'segments': [
              {'s': 0, 'e': 800, 't': 'hello'},
            ],
            'usage': {
              'usedSeconds': 10,
              'quotaSeconds': 900,
              'resetsAt': '2026-10-01T00:00:00.000Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await api.transcribe(
      audio: Uint8List.fromList([1, 2, 3]),
      requestId: '22222222-2222-4222-8222-222222222222',
      model: CloudTranscriptionModel.nvidia.id,
    );

    expect(sent.url.path, '/speech/transcribe');
    expect(sent.headers['x-speech-model'], CloudTranscriptionModel.nvidia.id);
    expect(sent.headers['content-type'], 'audio/mp4');
    expect(sent.bodyBytes, [1, 2, 3]);
    expect(result.engine, 'openrouter/${CloudTranscriptionModel.nvidia.id}');
  });
}
