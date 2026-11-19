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

    test("a 401 in the server's words is the session rejected", () async {
      for (final body in [
        '{"message":"Unauthorized","code":"UNAUTHORIZED"}',
        '{"error":"unauthorized"}',
      ]) {
        expect(
          await _answering(401, body).checkSession('t'),
          isA<SessionRejected>(),
          reason: body,
        );
      }
    });

    test('a 401 from anything else revokes nothing', () async {
      for (final body in ['', '<html>Log in</html>', '{"error":"denied"}']) {
        expect(
          await _answering(401, body).checkSession('t'),
          isA<SessionUnreachable>(),
          reason: body,
        );
      }
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

  group('hasPassword', () {
    test('a credential account is a password', () async {
      final seen = <http.Request>[];
      final api = _answering(
        200,
        jsonEncode([
          {'providerId': 'credential'},
        ]),
        seen: seen,
      );

      expect(await api.hasPassword('tok'), isTrue);
      expect(seen.single.url.path, '/api/auth/list-accounts');
      expect(seen.single.headers['authorization'], 'Bearer tok');
    });

    test('no accounts, or only other kinds, is no password', () async {
      for (final body in [
        '[]',
        jsonEncode([
          {'providerId': 'google'},
        ]),
      ]) {
        expect(
          await _answering(200, body).hasPassword('tok'),
          isFalse,
          reason: body,
        );
      }
    });

    test('anything else is not knowing', () async {
      for (final (status, body) in [
        (401, '{"code":"UNAUTHORIZED"}'),
        (500, ''),
        (200, '<html>Sign in to the Wi-Fi</html>'),
        (200, '{}'),
      ]) {
        expect(
          await _answering(status, body).hasPassword('tok'),
          isNull,
          reason: '$status $body',
        );
      }
    });
  });

  group('resetPassword', () {
    test("sends this device's session only when given one", () async {
      final seen = <http.Request>[];
      final api = _answering(200, '{"success":true}', seen: seen);

      expect(
        await api.resetPassword(
          email: 'a@b.co',
          code: '123456',
          password: 'a new password',
          token: 'tok',
        ),
        isA<AuthPasswordChanged>(),
      );
      expect(
        await api.resetPassword(
          email: 'a@b.co',
          code: '123456',
          password: 'a new password',
        ),
        isA<AuthPasswordChanged>(),
      );
      expect(seen.first.url.path, '/api/auth/email-otp/reset-password');
      expect(seen.first.headers['authorization'], 'Bearer tok');
      expect(seen.last.headers.containsKey('authorization'), isFalse);
    });

    test("a refusal keeps the server's status and code", () async {
      Future<AuthResult> answer(int status, String body) => _answering(
        status,
        body,
      ).resetPassword(email: 'a@b.co', code: '000000', password: 'pw', token: 't');

      expect(
        await answer(400, '{"code":"INVALID_OTP","message":"Invalid OTP"}'),
        isA<AuthRejected>()
            .having((r) => r.status, 'status', 400)
            .having((r) => r.code, 'code', 'INVALID_OTP'),
      );
      expect(
        await answer(
          403,
          '{"code":"TOO_MANY_ATTEMPTS","message":"Too many attempts"}',
        ),
        isA<AuthRejected>()
            .having((r) => r.status, 'status', 403)
            .having((r) => r.code, 'code', 'TOO_MANY_ATTEMPTS'),
      );
      expect(
        await answer(429, '{"message":"Too many requests."}'),
        isA<AuthRejected>()
            .having((r) => r.status, 'status', 429)
            .having((r) => r.code, 'code', isNull),
      );
    });
  });

  group('revokeOtherSessions', () {
    test('posts with the bearer and reports success', () async {
      final seen = <http.Request>[];
      final api = _answering(200, '{"status":true}', seen: seen);

      expect(await api.revokeOtherSessions('tok'), RevokeOthers.done);
      expect(seen.single.url.path, '/api/auth/revoke-other-sessions');
      expect(seen.single.headers['authorization'], 'Bearer tok');
    });

    test("only the server's 401 says this session has ended", () async {
      expect(
        await _answering(
          401,
          '{"message":"Unauthorized","code":"UNAUTHORIZED"}',
        ).revokeOtherSessions('tok'),
        RevokeOthers.sessionEnded,
      );
      for (final (status, body) in [(401, '<html/>'), (503, ''), (403, '')]) {
        expect(
          await _answering(status, body).revokeOtherSessions('tok'),
          RevokeOthers.failed,
          reason: '$status',
        );
      }
    });
  });
}
