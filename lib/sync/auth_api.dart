import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Who is signed in. Only what the UI needs to show.
class AccountUser {
  final String id;
  final String email;
  final bool emailVerified;

  const AccountUser({
    required this.id,
    required this.email,
    required this.emailVerified,
  });

  static AccountUser? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final email = raw['email'];
    if (id is! String || email is! String) return null;
    return AccountUser(
      id: id,
      email: email,
      emailVerified: raw['emailVerified'] == true,
    );
  }
}

/// The outcome of trying to sign in or sign up.
///
/// Modelled as separate cases rather than an exception because three of them
/// are ordinary things a person does — mistyping a password, not having
/// confirmed their address yet, being on a train — and each needs its own
/// sentence rather than a stack trace.
sealed class AuthResult {
  const AuthResult();
}

class AuthSignedIn extends AuthResult {
  const AuthSignedIn(this.token, this.user);
  final String token;
  final AccountUser user;
}

/// The account exists but the address has not been confirmed. Better Auth
/// sends a fresh confirmation email on each attempt, so the screen can simply
/// say to go and look.
class AuthNeedsVerification extends AuthResult {
  const AuthNeedsVerification(this.email);
  final String email;
}

/// A code is on its way. Nothing more happens until it is typed back.
class AuthCodeSent extends AuthResult {
  const AuthCodeSent(this.email);
  final String email;
}

/// The password was changed. There is no session yet: signing in with the new
/// one is the next step, and doing it explicitly means a reset never silently
/// signs somebody in on a device they only borrowed to type a code.
class AuthPasswordChanged extends AuthResult {
  const AuthPasswordChanged();
}

/// The server said no, and the reason is worth showing.
class AuthRejected extends AuthResult {
  const AuthRejected(this.message);
  final String message;
}

/// Nothing was reached. Distinct from rejection because the answer is "try
/// again", not "check what you typed".
class AuthUnreachable extends AuthResult {
  const AuthUnreachable(this.message);
  final String message;
}

/// The Better Auth endpoints, kept apart from [SyncApi] because signing in and
/// syncing are genuinely different concerns: one proves who you are, the other
/// moves sealed bytes. Collapsing them would invite the server to be trusted
/// with both.
abstract class AuthApi {
  Future<AuthResult> signIn({required String email, required String password});

  /// Asks for a six-digit code. Works for an address that has never signed
  /// up: the code is what creates the account.
  Future<AuthResult> sendCode(String email);

  /// Sends a code for setting a new password. Same shape as signing in,
  /// deliberately: there is nothing about forgetting a password that should
  /// need a browser.
  Future<AuthResult> requestPasswordReset(String email);

  Future<AuthResult> resetPassword({
    required String email,
    required String code,
    required String password,
  });

  /// Exchanges a code for a session. The code proves control of the address,
  /// so this both creates the account and marks the email confirmed.
  Future<AuthResult> signInWithCode({
    required String email,
    required String code,
  });

  /// Best-effort: a token the server has already forgotten is still a token
  /// this device should drop.
  Future<void> signOut(String token);

  /// The account behind a stored token, or null if it is no longer valid.
  Future<AccountUser?> currentUser(String token);
}

class HttpAuthApi implements AuthApi {
  HttpAuthApi({
    required Uri baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _baseUrl = baseUrl,
       _client = client ?? http.Client();

  final Uri _baseUrl;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) => _authenticate('api/auth/sign-in/email', {
    'email': email,
    'password': password,
  }, email);

  @override
  Future<AuthResult> sendCode(String email) async {
    final response = await _post('api/auth/email-otp/send-verification-otp', {
      'email': email,
      'type': 'sign-in',
    });
    if (response is _Failure) return response.result;
    return AuthCodeSent(email);
  }

  @override
  Future<AuthResult> requestPasswordReset(String email) async {
    final response = await _post('api/auth/email-otp/request-password-reset', {
      'email': email,
    });
    return response is _Failure ? response.result : AuthCodeSent(email);
  }

  @override
  Future<AuthResult> resetPassword({
    required String email,
    required String code,
    required String password,
  }) async {
    final response = await _post('api/auth/email-otp/reset-password', {
      'email': email,
      'otp': code,
      'password': password,
    });
    return response is _Failure
        ? response.result
        : const AuthPasswordChanged();
  }

  @override
  Future<AuthResult> signInWithCode({
    required String email,
    required String code,
  }) => _authenticate('api/auth/sign-in/email-otp', {
    'email': email,
    'otp': code,
  }, email);

  @override
  Future<void> signOut(String token) async {
    try {
      await _client
          .post(
            _baseUrl.resolve('api/auth/sign-out'),
            headers: {'authorization': 'Bearer $token'},
          )
          .timeout(timeout);
    } catch (_) {
      // The local key and token are cleared either way. A sign-out that could
      // not reach the server must not leave the app looking signed in.
    }
  }

  @override
  Future<AccountUser?> currentUser(String token) async {
    try {
      final response = await _client
          .get(
            _baseUrl.resolve('api/auth/get-session'),
            headers: {'authorization': 'Bearer $token'},
          )
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      if (body is! Map) return null;
      return AccountUser.fromJson(body['user']);
    } catch (_) {
      return null;
    }
  }

  /// Sign-in and sign-up differ only in the path: both answer with a session
  /// or with a reason there is not one.
  Future<AuthResult> _authenticate(
    String path,
    Map<String, Object?> payload,
    String email,
  ) async {
    final response = await _post(path, payload);
    if (response is _Failure) return response.result;

    final body = (response as _Success).body;
    final user = AccountUser.fromJson(body['user']);
    final token = body['token'];
    if (user == null) return const AuthRejected('The server sent no account.');

    // Sign-up with verification required answers 200 and no token: the
    // account exists, but nothing is signed in until the email is confirmed.
    if (token is! String || token.isEmpty) return AuthNeedsVerification(email);
    return AuthSignedIn(token, user);
  }

  Future<_Response> _post(String path, Map<String, Object?> payload) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            _baseUrl.resolve(path),
            headers: {
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } on TimeoutException {
      return const _Failure(AuthUnreachable('That took too long.'));
    } catch (_) {
      return const _Failure(
        AuthUnreachable('Could not reach KapyNotes. Check your connection.'),
      );
    }

    Map<String, Object?> body = const {};
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, Object?>) body = decoded;
      } on FormatException {
        // Falls through to the status-based reading below.
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _Success(body);
    }
    if (response.statusCode >= 500) {
      return const _Failure(
        AuthUnreachable('KapyNotes is having a problem. Try again shortly.'),
      );
    }
    return _Failure(_rejection(response.statusCode, body));
  }

  /// Better Auth answers 403 for an unconfirmed address and 4xx with a
  /// message otherwise. The message is shown as-is when there is one: it is
  /// written for a person, and second-guessing it tends to lose the detail
  /// that would have helped.
  AuthResult _rejection(int status, Map<String, Object?> body) {
    final code = body['code'];
    final message = body['message'];
    if (status == 403 || (code is String && code.contains('VERIFIED'))) {
      return const AuthRejected(
        'Confirm your email address first — check your inbox.',
      );
    }
    if (message is String && message.isNotEmpty) return AuthRejected(message);
    return const AuthRejected('That did not work. Check your details.');
  }

  void close() => _client.close();
}

sealed class _Response {
  const _Response();
}

class _Success extends _Response {
  const _Success(this.body);
  final Map<String, Object?> body;
}

class _Failure extends _Response {
  const _Failure(this.result);
  final AuthResult result;
}
