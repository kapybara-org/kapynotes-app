import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/sync/note_payload.dart';
import 'package:kapy_notes/sync/sealed_box.dart';
import 'package:kapy_notes/sync/vault.dart';

/// Kept small so the suite stays quick. Production accounts use
/// [KdfParams.defaultMemory]; the code path is identical either way.
KdfParams cheapKdf(Uint8List salt) =>
    KdfParams(salt: salt, memory: 256, iterations: 1, parallelism: 1);

NotePayload samplePayload({String body = 'Hello, world'}) => NotePayload(
  body: body,
  formats: [
    NoteFormatRange(start: 0, end: 5, format: NoteFormat.bold),
  ],
  createdAt: 1700000000000,
);

void main() {
  group('sealing', () {
    late Vault vault;

    setUp(() {
      vault = Vault.fromMasterKey(Uint8List(Vault.keyLength)..fillRange(0, 32, 7));
    });

    test('a payload survives a round trip intact', () async {
      final payload = samplePayload(body: 'Lunch: 12 + 30\n**bold** and é 😀');
      final opened = await vault.open(await vault.seal(payload));

      expect(opened, isNotNull);
      expect(opened!.body, payload.body);
      expect(opened.createdAt, payload.createdAt);
      expect(opened.formats.single.format, NoteFormat.bold);
      expect(opened.formats.single.start, 0);
      expect(opened.formats.single.end, 5);
    });

    test('formats and attachments ride inside the envelope', () async {
      final payload = NotePayload(
        body: 'before ${NoteAttachmentRef.placeholder} after',
        attachments: [
          NoteAttachmentRef(
            offset: 7,
            attachmentId: '11111111-1111-4111-8111-111111111111',
            key: Uint8List.fromList(List.filled(32, 3)),
            mime: 'image/webp',
            width: 800,
            height: 600,
            thumbId: '22222222-2222-4222-8222-222222222222',
          ),
        ],
        createdAt: 5,
      );

      final opened = await vault.open(await vault.seal(payload));
      final ref = opened!.attachments.single;
      expect(ref.offset, 7);
      expect(ref.mime, 'image/webp');
      expect(ref.key, hasLength(32));
      expect(ref.thumbId, '22222222-2222-4222-8222-222222222222');
    });

    test('every seal uses a fresh nonce', () async {
      final payload = samplePayload();
      final first = await vault.seal(payload);
      final second = await vault.seal(payload);

      expect(first.nonce, isNot(equals(second.nonce)));
      expect(first.nonce, hasLength(SealedBox.nonceLength));
      // Identical plaintext must not produce identical ciphertext, or the
      // server could tell which notes are duplicates of each other.
      expect(first.cipherText, isNot(equals(second.cipherText)));
    });

    test('a tampered ciphertext does not open', () async {
      final sealed = await vault.seal(samplePayload());
      final tampered = Uint8List.fromList(sealed.cipherText);
      tampered[0] ^= 0xff;

      final opened = await vault.open(
        SealedBox(
          cipherText: tampered,
          nonce: sealed.nonce,
          version: sealed.version,
        ),
      );
      expect(opened, isNull);
    });

    test('another vault cannot open it', () async {
      final sealed = await vault.seal(samplePayload());
      final stranger = Vault.fromMasterKey(
        Uint8List(Vault.keyLength)..fillRange(0, 32, 9),
      );
      expect(await stranger.open(sealed), isNull);
    });

    test('a batch large enough to cross into an isolate round-trips', () async {
      // 64 notes of ~1 KiB each clears the inline threshold, so this exercises
      // the Isolate.run path rather than the inline one.
      final payloads = List.generate(
        64,
        (i) => samplePayload(body: 'note $i ${'x' * 1024}'),
      );

      final sealed = await vault.sealAll(payloads);
      expect(sealed, hasLength(64));

      final opened = await vault.openAll(sealed);
      expect(opened.map((p) => p?.body), payloads.map((p) => p.body));
    });

    test('one bad box does not spoil the batch', () async {
      final good = await vault.sealAll([
        samplePayload(body: 'first'),
        samplePayload(body: 'third'),
      ]);
      final junk = SealedBox(
        cipherText: Uint8List.fromList(List.filled(32, 1)),
        nonce: Uint8List(SealedBox.nonceLength),
        version: 1,
      );

      final opened = await vault.openAll([good[0], junk, good[1]]);
      expect(opened[0]?.body, 'first');
      expect(opened[1], isNull);
      expect(opened[2]?.body, 'third');
    });
  });

  group('key hierarchy', () {
    test('the right passphrase unlocks and the wrong one does not', () async {
      final setup = await Vault.create(passphrase: 'correct horse battery');
      final sealed = await setup.vault.seal(samplePayload(body: 'secret'));

      final good = await Vault.unlockWithPassphrase(
        passphrase: 'correct horse battery',
        kdf: setup.kdf,
        wrappedMasterKey: setup.wrappedMasterKey,
      );
      expect(good, isNotNull);
      expect((await good!.open(sealed))?.body, 'secret');

      final bad = await Vault.unlockWithPassphrase(
        passphrase: 'correct horse batterz',
        kdf: setup.kdf,
        wrappedMasterKey: setup.wrappedMasterKey,
      );
      expect(bad, isNull);
    });

    test('the recovery key opens the same notes', () async {
      final setup = await Vault.create(passphrase: 'forgotten already');
      final sealed = await setup.vault.seal(samplePayload(body: 'still here'));

      final recovered = await Vault.unlockWithRecoveryKey(
        recoveryKey: setup.recoveryKey,
        recoveryWrappedMasterKey: setup.recoveryWrappedMasterKey,
      );
      expect(recovered, isNotNull);
      expect((await recovered!.open(sealed))?.body, 'still here');
    });

    test('a wrong recovery key does not', () async {
      final setup = await Vault.create(passphrase: 'x');
      final wrong = Uint8List(Vault.keyLength)..fillRange(0, 32, 1);
      expect(
        await Vault.unlockWithRecoveryKey(
          recoveryKey: wrong,
          recoveryWrappedMasterKey: setup.recoveryWrappedMasterKey,
        ),
        isNull,
      );
    });

    test('changing the passphrase leaves existing notes readable', () async {
      final setup = await Vault.create(passphrase: 'first pass');
      final sealed = await setup.vault.seal(samplePayload(body: 'unchanged'));

      final rotated = await setup.vault.rewrapForPassphrase('second pass');

      // The new passphrase works...
      final reopened = await Vault.unlockWithPassphrase(
        passphrase: 'second pass',
        kdf: rotated.kdf,
        wrappedMasterKey: rotated.wrappedMasterKey,
      );
      expect((await reopened!.open(sealed))?.body, 'unchanged');

      // ...and the note was never rewritten, which is the whole point of
      // wrapping a master key instead of deriving one.
      expect(
        setup.vault.masterKeyForKeystore,
        reopened.masterKeyForKeystore,
      );
    });

    test('the recovery key still works after a passphrase change', () async {
      final setup = await Vault.create(passphrase: 'first pass');
      final sealed = await setup.vault.seal(samplePayload(body: 'durable'));
      await setup.vault.rewrapForPassphrase('second pass');

      final recovered = await Vault.unlockWithRecoveryKey(
        recoveryKey: setup.recoveryKey,
        recoveryWrappedMasterKey: setup.recoveryWrappedMasterKey,
      );
      expect((await recovered!.open(sealed))?.body, 'durable');
    });
  });

  group('wire format', () {
    test('a sealed box survives JSON', () async {
      final vault = Vault.fromMasterKey(
        Uint8List(Vault.keyLength)..fillRange(0, 32, 4),
      );
      final sealed = await vault.seal(samplePayload(body: 'over the wire'));

      final decoded = SealedBox.fromJson(
        jsonDecode(jsonEncode(sealed.toJson())),
      );
      expect(decoded, isNotNull);
      expect((await vault.open(decoded!))?.body, 'over the wire');
    });

    test('malformed boxes are rejected rather than thrown on', () {
      expect(SealedBox.fromJson(null), isNull);
      expect(SealedBox.fromJson({'ct': 'not base64!!', 'n': 'AA==', 'v': 1}), isNull);
      // A nonce of the wrong width means a different algorithm wrote it.
      expect(
        SealedBox.fromJson({
          'ct': base64.encode(List.filled(32, 0)),
          'n': base64.encode(List.filled(12, 0)),
          'v': 1,
        }),
        isNull,
      );
      // Shorter than the Poly1305 tag: cannot possibly be a sealed box.
      expect(
        SealedBox.fromJson({
          'ct': base64.encode(List.filled(4, 0)),
          'n': base64.encode(List.filled(24, 0)),
          'v': 1,
        }),
        isNull,
      );
    });

    test('kdf params survive JSON', () {
      final params = cheapKdf(Uint8List.fromList(List.filled(16, 2)));
      final decoded = KdfParams.fromJson(
        jsonDecode(jsonEncode(params.toJson())),
      );
      expect(decoded!.memory, params.memory);
      expect(decoded.iterations, params.iterations);
      expect(decoded.salt, params.salt);
    });
  });
}
