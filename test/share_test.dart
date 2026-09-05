import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/sync/sealed_box.dart';
import 'package:kapy_notes/sync/share_api.dart';
import 'package:kapy_notes/sync/share_link.dart';
import 'package:kapy_notes/sync/share_secrets.dart';
import 'package:kapy_notes/sync/share_service.dart';

import 'app_test.dart' show MemoryStore;

/// Records what the app asked the server to store, so a test can open it the
/// way the web page would.
class FakeShareApi implements ShareApi {
  final List<ShareState> shares = [];
  final List<SealedBox> published = [];
  int revocations = 0;
  var _tokens = 0;

  ShareState? _byToken(String token) =>
      shares.where((share) => share.token == token).firstOrNull;

  @override
  Future<List<ShareState>> list() async => List.of(shares);

  @override
  Future<ShareState> publish({
    required String noteId,
    required SealedBox sealed,
    required ShareVisibility visibility,
    required ShareExpiry expiry,
  }) async {
    published.add(sealed);
    // Mirrors the server's upsert-on-note: republishing keeps the token.
    final existing = shares.where((s) => s.noteId == noteId).firstOrNull;
    final state = ShareState(
      token: existing?.token ?? 'tok${++_tokens}',
      noteId: noteId,
      visibility: visibility,
      expiresAt: expiry == ShareExpiry.forever
          ? null
          : DateTime.now().add(const Duration(hours: 1)),
      updatedAt: DateTime.now(),
    );
    shares
      ..removeWhere((s) => s.noteId == noteId)
      ..add(state);
    return state;
  }

  @override
  Future<ShareState> update(
    String token, {
    ShareVisibility? visibility,
    ShareExpiry? expiry,
    SealedBox? sealed,
  }) async {
    final current = _byToken(token)!;
    if (sealed != null) published.add(sealed);
    final next = ShareState(
      token: token,
      noteId: current.noteId,
      visibility: visibility ?? current.visibility,
      expiresAt: expiry == null
          ? current.expiresAt
          : expiry == ShareExpiry.forever
          ? null
          : DateTime.now().add(const Duration(hours: 1)),
      updatedAt: DateTime.now(),
    );
    shares
      ..removeWhere((s) => s.token == token)
      ..add(next);
    return next;
  }

  @override
  Future<void> revoke(String token) async {
    revocations++;
    shares.removeWhere((share) => share.token == token);
  }
}

/// Opens a share the way the browser does: key from the link, nothing else.
Future<Map<String, Object?>> openAsVisitor(SealedBox box, Uint8List key) async {
  final split = box.cipherText.length - SealedBox.macLength;
  final clear = await Xchacha20.poly1305Aead().decrypt(
    SecretBox(
      Uint8List.sublistView(box.cipherText, 0, split),
      nonce: box.nonce,
      mac: Mac(Uint8List.sublistView(box.cipherText, split)),
    ),
    secretKey: SecretKey(key),
  );
  return jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
}

Note noteWith(String body) => Note(
  id: '0195f0d0-1111-4222-8333-444455556666',
  body: body,
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 2),
);

void main() {
  late FakeShareApi api;
  late ShareSecrets secrets;
  late ShareService service;

  setUp(() {
    api = FakeShareApi();
    secrets = ShareSecrets(MemoryStore())..load();
    service = ShareService(
      api: api,
      secrets: secrets,
      engine: () => CalcEngine(ratesPerUsd: const {'EUR': 0.86}),
      siteOrigin: Uri.parse('https://kapynotes.com/'),
    );
  });

  group('the link', () {
    test('carries the token and the key in the fragment, and nothing in the '
        'path that could reach a server log', () async {
      final share = await service.publish(noteWith('2 + 2'));
      final link = share.link!;

      expect(link.path, '/s');
      expect(link.query, isEmpty);
      expect(link.fragment, contains('.'));

      final [token, key] = link.fragment.split('.');
      expect(token, api.shares.single.token);
      // 32 bytes, base64url, padding stripped.
      expect(base64Url.decode(base64Url.normalize(key)), hasLength(32));
      expect(key, isNot(contains('=')));
      expect(link.toString(), startsWith('https://kapynotes.com/s#'));
    });

    test('is not openable with the account key', () async {
      // The share key must be its own: one that opens every note has no
      // business in a URL.
      final share = await service.publish(noteWith('2 + 2'));
      final key = base64Url.decode(
        base64Url.normalize(share.link!.fragment.split('.')[1]),
      );
      expect(key, isNot(equals(Uint8List(32))));
    });

    test('a second share of a different note gets a different key', () async {
      await service.publish(noteWith('one'));
      final first = service.forNote(noteWith('one').id).link!.fragment;
      secrets.forget(noteWith('one').id);
      await service.publish(noteWith('one'));
      final second = service.forNote(noteWith('one').id).link!.fragment;
      expect(first, isNot(second));
    });
  });

  group('what a visitor actually receives', () {
    test('is the note, its formats, and the results this device computed',
        () async {
      final share = await service.publish(
        noteWith('Trip\namount = 412 eur\namount * 2'),
      );
      final key = base64Url.decode(
        base64Url.normalize(share.link!.fragment.split('.')[1]),
      );

      final opened = await openAsVisitor(api.published.single, key);
      expect(opened['title'], 'Trip');
      expect(opened['body'], contains('amount = 412 eur'));

      // The web page has no calculator, so the arithmetic has to travel.
      final results = (opened['results']! as List).cast<Map<String, Object?>>();
      expect(results, isNotEmpty);
      expect(results.map((r) => r['line']), isNot(contains(0)));
      expect(results.every((r) => (r['text']! as String).isNotEmpty), isTrue);
    });

    test('never contains an attachment key', () async {
      final share = await service.publish(noteWith('note with an image'));
      final key = base64Url.decode(
        base64Url.normalize(share.link!.fragment.split('.')[1]),
      );
      final opened = await openAsVisitor(api.published.single, key);
      expect(opened.containsKey('attachments'), isFalse);
    });

    test('cannot be opened with the wrong key', () async {
      await service.publish(noteWith('secret'));
      final wrong = Uint8List(32)..[0] = 9;
      expect(
        () => openAsVisitor(api.published.single, wrong),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('the controls', () {
    test('pausing keeps the same link so it need not be re-sent', () async {
      final published = await service.publish(noteWith('2 + 2'));
      final paused = await service.setVisibility(
        noteWith('2 + 2').id,
        ShareVisibility.private,
      );

      expect(paused.link, published.link);
      expect(paused.state!.visibility, ShareVisibility.private);
      expect(paused.state!.isLive, isFalse);
    });

    test('an expiry makes the link stop being live once it passes', () async {
      await service.publish(noteWith('2 + 2'));
      final expiring = await service.setExpiry(
        noteWith('2 + 2').id,
        ShareExpiry.hour,
      );
      expect(expiring.state!.expiresAt, isNotNull);
      expect(expiring.state!.isLive, isTrue);

      final past = ShareState(
        token: 't',
        noteId: 'n',
        visibility: ShareVisibility.public,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        updatedAt: DateTime.now(),
      );
      expect(past.hasExpired, isTrue);
      expect(past.isLive, isFalse);
    });

    test('forever means no expiry at all, not a distant one', () async {
      final share = await service.publish(
        noteWith('2 + 2'),
        expiry: ShareExpiry.forever,
      );
      expect(share.state!.expiresAt, isNull);
      expect(share.state!.isLive, isTrue);
    });

    test('republishing reuses the token and the key, so the link survives '
        'an edit', () async {
      final first = await service.publish(noteWith('2 + 2'));
      final second = await service.republish(noteWith('2 + 2\n3 + 3'));

      expect(second.link, first.link);
      expect(api.published, hasLength(2));

      final key = base64Url.decode(
        base64Url.normalize(second.link!.fragment.split('.')[1]),
      );
      final opened = await openAsVisitor(api.published.last, key);
      expect(opened['body'], contains('3 + 3'));
    });

    test('revoking takes the link down and forgets its key', () async {
      final note = noteWith('2 + 2');
      await service.publish(note);
      await service.revoke(note.id);

      expect(api.revocations, 1);
      expect(api.shares, isEmpty);
      expect(secrets.canRebuild(note.id), isFalse);
      expect(service.forNote(note.id).isShared, isFalse);
    });
  });

  group('a note shared from another device', () {
    test('reads as shared but unrebuildable, not as unshared', () async {
      final note = noteWith('2 + 2');
      await service.publish(note);
      // What a second device sees: the server's row, none of the key.
      secrets.forget(note.id);

      final seen = service.forNote(note.id);
      expect(seen.isShared, isTrue);
      expect(seen.isOrphaned, isTrue);
      expect(seen.link, isNull);
    });

    test('replacing the link mints a new key and invalidates the old one',
        () async {
      final note = noteWith('2 + 2');
      final original = await service.publish(note);
      final originalKey = base64Url.decode(
        base64Url.normalize(original.link!.fragment.split('.')[1]),
      );
      secrets.forget(note.id);

      final replaced = await service.replaceLink(note);
      expect(replaced.link, isNot(original.link));

      // The point of replacing: whoever held the old URL is now locked out.
      expect(
        () => openAsVisitor(api.published.last, originalKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('secrets on disk', () {
    test('survive a restart', () {
      final store = MemoryStore();
      final key = ShareSecret.newKey();
      ShareSecrets(store)
        ..load()
        ..remember('note-1', ShareSecret(token: 'tok', key: key));

      final reloaded = ShareSecrets(store)..load();
      expect(reloaded.forNote('note-1')!.token, 'tok');
      expect(reloaded.forNote('note-1')!.key, key);
    });

    test('a malformed entry is dropped rather than crashing the list', () {
      final store = MemoryStore();
      store.data['shares.v1'] = {
        'good': {'token': 't', 'key': base64.encode(ShareSecret.newKey())},
        'short-key': {'token': 't', 'key': base64.encode(Uint8List(8))},
        'nonsense': 42,
      };
      final secrets = ShareSecrets(store)..load();
      expect(secrets.canRebuild('good'), isTrue);
      expect(secrets.canRebuild('short-key'), isFalse);
      expect(secrets.canRebuild('nonsense'), isFalse);
    });
  });
}
