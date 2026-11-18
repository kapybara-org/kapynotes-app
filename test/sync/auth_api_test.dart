import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/sync/auth_api.dart';

HttpAuthApi _answering(int status, String body, {List<http.Request>? seen}) =>
    HttpAuthApi(
      baseUrl: Uri.parse('https://sync.test/'),
      client: MockClient((request) async {
        seen?.add(request);
        return http.Response(body, status);
      }),
    );

void main() {
  group('checkSession', () {
    test('a user is an active session', () async {
      final check = await _answering(
        200,
        jsonEncode({
          'session': {'token': 't'},
          'user': {'id': 'u1', 'email': 'a@b.co'},
        }),
      ).checkSession('t');
      expect(check, isA<SessionActive>());
    });

    test('200 null is Better Auth saying the session has ended', () async {
      expect(
        await _answering(200, 'null').checkSession('t'),
        isA<SessionRejected>(),
      );
    });

    test('a 401 is the session rejected', () async {
      expect(
        await _answering(401, '').checkSession('t'),
        isA<SessionRejected>(),
      );
    });

    test('a 403 from something in between revokes nothing', () async {
      expect(
        await _answering(403, '<html>Forbidden</html>').checkSession('t'),
        isA<SessionUnreachable>(),
      );
    });

    test('a captive portal page revokes nothing and does not throw', () async {
      expect(
        await _answering(
          200,
          '<html>Sign in to the Wi-Fi</html>',
        ).checkSession('t'),
        isA<SessionUnreachable>(),
      );
    });

    test('a 5xx or a 429 revokes nothing', () async {
      for (final status in [429, 500, 502, 503]) {
        expect(
          await _answering(status, '').checkSession('t'),
          isA<SessionUnreachable>(),
          reason: '$status',
        );
      }
    });
  });

  group('revokeOtherSessions', () {
    test('posts with the bearer and reports success', () async {
      final seen = <http.Request>[];
      final api = _answering(200, '{"status":true}', seen: seen);

      expect(await api.revokeOtherSessions('tok'), isTrue);
      expect(seen.single.url.path, '/api/auth/revoke-other-sessions');
      expect(seen.single.headers['authorization'], 'Bearer tok');
    });

    test('anything but 200 is a failure', () async {
      expect(await _answering(401, '').revokeOtherSessions('tok'), isFalse);
      expect(await _answering(503, '').revokeOtherSessions('tok'), isFalse);
    });
  });
}
