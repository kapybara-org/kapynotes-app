import 'dart:convert';
import 'dart:typed_data';

import 'package:kapy_notes/sync/auth_api.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/vault.dart';

/// An in-memory stand-in for `server/src/routes/sync.ts`, implementing the same
/// two rules that matter: last-writer-wins on `updatedAt`, and a keyset cursor
/// over `(updatedAt, id)`.
///
/// Having one lets two [SyncService]s talk to the same store, which is the only
/// way to test the cases sync actually gets wrong — an edit on each side, a
/// delete racing an edit, a device that has been offline for a week.
class FakeServer {
  final Map<String, WireNote> rows = {};

  /// On the server, not on the connection: a client that reconnects must find
  /// the same bundle, which is the whole point of publishing it.
  KeyBundle? bundle;

  /// Requests recorded in order, so a test can assert on what was sent.
  final List<String> calls = [];

  /// Set to fail the next call, to exercise the offline and signed-out paths.
  SyncException? failNext;

  /// Notes returned per page, mirroring the real limit being smaller than the
  /// corpus.
  int pageSize = 200;

  PushResult push(List<WireNote> notes) {
    calls.add('push:${notes.length}');
    final applied = <String>{};
    final conflicts = <WireNote>[];

    for (final note in notes) {
      final existing = rows[note.id];
      if (existing == null || existing.updatedAt.isBefore(note.updatedAt)) {
        rows[note.id] = note;
        applied.add(note.id);
      } else {
        // Rejected, and the winning copy rides back with the rejection.
        conflicts.add(existing);
      }
    }

    return PushResult(
      applied: applied,
      conflicts: conflicts,
      serverTime: DateTime.now(),
    );
  }

  PullPage pull(String? cursor) {
    calls.add('pull:${cursor ?? ''}');
    final sorted = rows.values.toList()
      ..sort((a, b) {
        final byTime = a.updatedAt.compareTo(b.updatedAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });

    var start = 0;
    if (cursor != null && cursor.isNotEmpty) {
      final decoded = utf8.decode(base64Url.decode(cursor));
      final split = decoded.indexOf('.');
      final millis = int.parse(decoded.substring(0, split));
      final id = decoded.substring(split + 1);
      start = sorted.indexWhere(
        (n) =>
            n.updatedAt.millisecondsSinceEpoch > millis ||
            (n.updatedAt.millisecondsSinceEpoch == millis && n.id.compareTo(id) > 0),
      );
      if (start < 0) start = sorted.length;
    }

    final end = (start + pageSize).clamp(0, sorted.length);
    final page = sorted.sublist(start, end);
    final last = page.isEmpty ? null : page.last;

    return PullPage(
      notes: page,
      // An empty page echoes the cursor back rather than rewinding.
      cursor: last == null
          ? (cursor ?? '')
          : base64Url.encode(
              utf8.encode('${last.updatedAt.millisecondsSinceEpoch}.${last.id}'),
            ),
      hasMore: end < sorted.length,
    );
  }
}

/// One device's connection to [FakeServer].
class FakeApi implements SyncApi {
  FakeApi(this.server);

  final FakeServer server;

  void _maybeFail() {
    final failure = server.failNext;
    if (failure != null) {
      server.failNext = null;
      throw failure;
    }
  }

  @override
  Future<PullPage> pull({String? cursor, int limit = pullDefaultLimit}) async {
    _maybeFail();
    return server.pull(cursor);
  }

  @override
  Future<PushResult> push(List<WireNote> notes) async {
    _maybeFail();
    return server.push(notes);
  }

  @override
  Future<KeyBundle?> fetchKeyBundle() async => server.bundle;

  @override
  Future<void> createKeyBundle(KeyBundle bundle) async => server.bundle = bundle;

  @override
  Future<void> rotateKeyBundle(KeyBundle bundle) async => server.bundle = bundle;
}

/// Both devices in these tests hold the same master key, which is what having
/// unlocked the same account means.
Vault sharedVault() =>
    Vault.fromMasterKey(Uint8List(Vault.keyLength)..fillRange(0, 32, 42));

/// A signed-in account, without a server to sign in to.
class FakeAuth implements AuthApi {
  FakeAuth({this.id = 'user-1', this.email = 'someone@example.com'});
  String id;
  String email;
  AuthResult? nextResult;
  bool sessionValid = true;
  int signOutCalls = 0;

  AccountUser get _user =>
      AccountUser(id: id, email: email, emailVerified: true);

  @override
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async => nextResult ?? AuthSignedIn('token-$id', _user);

  @override
  Future<AuthResult> signUp({
    required String email,
    required String password,
    required String name,
  }) async => nextResult ?? AuthSignedIn('token-$id', _user);

  /// The code a test types back. Real enough: it is compared, not guessed.
  String code = '123456';
  String? sentCodeTo;

  @override
  Future<AuthResult> sendCode(String email) async {
    sentCodeTo = email;
    return nextResult ?? AuthCodeSent(email);
  }

  @override
  Future<AuthResult> signInWithCode({
    required String email,
    required String code,
  }) async => code == this.code
      ? (nextResult ?? AuthSignedIn('token-$id', _user))
      : const AuthRejected('That code is not right.');

  /// The password the fake currently believes in, so a reset can be seen to
  /// have changed something.
  String password = 'original';

  @override
  Future<AuthResult> requestPasswordReset(String email) async {
    sentCodeTo = email;
    return nextResult ?? AuthCodeSent(email);
  }

  @override
  Future<AuthResult> resetPassword({
    required String email,
    required String code,
    required String password,
  }) async {
    if (code != this.code) return const AuthRejected('That code is not right.');
    this.password = password;
    return const AuthPasswordChanged();
  }

  @override
  Future<void> signOut(String token) async => signOutCalls++;

  @override
  Future<AccountUser?> currentUser(String token) async =>
      sessionValid ? _user : null;
}
