import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/sync_service.dart';

import 'account_test.dart' show Device;
import 'fake_server.dart';

/// Another device's recovery key change, landing between a read and a write.
void Function(FakeUser) recoveryChangedOn(String device) => (user) {
  final bundle = user.bundle!;
  user.bundle = KeyBundle(
    wrappedMasterKey: bundle.wrappedMasterKey,
    kdf: bundle.kdf,
    recoveryWrappedMasterKey: bundle.wrappedMasterKey,
    identity: bundle.identity,
    version: bundle.version + 1,
    changes: KeyChanges(
      passphrase: bundle.changes.passphrase,
      recoveryKey: KeyChange(at: DateTime.utc(2026, 11, 18), device: device),
    ),
  );
};

void main() {
  late FakeServer server;
  setUp(() => server = FakeServer());

  Future<Device> unlocked(String passphrase, {bool create = false}) async {
    final d = Device(server)
      ..account.deviceName = (_) async => 'Sanjay’s MacBook';
    await d.boot();
    await d.account.signIn(email: 'a@b.co', password: 'x');
    if (create) {
      await d.account.createPassphrase(passphrase);
    } else {
      expect(await d.account.unlock(passphrase), isTrue);
    }
    return d;
  }

  Future<String> proof(Device d, KeyProofAction action) async {
    expect(await d.account.sendKeyCode(action), isNull);
    final result = await d.account.verifyKeyCode(action, '123 456');
    expect(result.problem, isNull);
    return result.proof!;
  }

  test('a new passphrase opens the same notes, the old one stops, and '
      'unlocked devices carry on', () async {
    final a = await unlocked('first passphrase', create: true);
    final b = await unlocked('first passphrase');

    final change = await a.account.preparePassphrase('second passphrase');
    final result = await a.account.commitKeyChange(
      change!,
      proof: await proof(a, KeyProofAction.passphrase),
    );

    expect(result, isA<KeyChangeDone>());
    final bundle = server.user('user-1').bundle!;
    expect(bundle.version, 2);
    expect(bundle.changes.passphrase?.device, 'Sanjay’s MacBook');
    expect(a.account.keyBundle?.version, 2);

    // Nothing asks b for anything: same master key, same notes.
    await b.account.sync!.syncNow();
    expect(b.account.state, AccountState.ready);
    expect(b.account.sync!.status, isNot(SyncStatus.failed));

    final c = Device(server);
    await c.boot();
    await c.account.signIn(email: 'a@b.co', password: 'x');
    expect(c.account.passphraseChangedSinceUnlock, isNull);
    expect(await c.account.unlock('first passphrase'), isFalse);
    expect(await c.account.unlock('second passphrase'), isTrue);

    // b saw version 1 before the change, so once locked it can say why.
    await b.account.signOut();
    await b.account.signIn(email: 'a@b.co', password: 'x');
    expect(b.account.state, AccountState.locked);
    expect(b.account.passphraseChangedSinceUnlock?.device, 'Sanjay’s MacBook');
    for (final d in [a, b, c]) {
      d.dispose();
    }
  });

  test(
    'a new recovery key opens the account and the old one no longer does',
    () async {
      final a = Device(server)..account.deviceName = (_) async => null;
      await a.boot();
      await a.account.signIn(email: 'a@b.co', password: 'x');
      final old = await a.account.createPassphrase('first passphrase');

      final made = await a.account.prepareRecoveryKey();
      final formatted = made!.key.formatted;
      final result = await a.account.commitKeyChange(
        made,
        proof: await proof(a, KeyProofAction.recoveryKey),
      );
      expect(result, isA<KeyChangeDone>());
      expect(a.account.recoveryKeyUnsaved, isTrue);
      a.account.recoveryKeySaved(made);
      expect(a.account.recoveryKeyUnsaved, isFalse);
      expect(made.key.bytes.every((b) => b == 0), isTrue);
      expect(server.user('user-1').bundle!.changes.recoveryKey?.device, isNull);

      final c = Device(server);
      await c.boot();
      await c.account.signIn(email: 'a@b.co', password: 'x');
      expect(await c.account.unlockWithRecoveryKey(old!.formatted), isFalse);
      expect(await c.account.unlockWithRecoveryKey(formatted), isTrue);
      a.dispose();
      c.dispose();
    },
  );

  test(
    'a recovery key made elsewhere first is reported, never replaced',
    () async {
      final a = await unlocked('first passphrase', create: true);
      final code = await proof(a, KeyProofAction.recoveryKey);
      server.beforeKeyChange = recoveryChangedOn('Sanjay’s iPhone');

      final made = await a.account.prepareRecoveryKey();
      final result = await a.account.commitKeyChange(made!, proof: code);

      expect(result, isA<KeyChangeLostRace>());
      expect((result as KeyChangeLostRace).change.device, 'Sanjay’s iPhone');
      final bundle = server.user('user-1').bundle!;
      expect(bundle.version, 2);
      expect(bundle.changes.recoveryKey?.device, 'Sanjay’s iPhone');
      // Nothing was committed, so nothing is left waiting to be saved, and the
      // proof was not spent on a write that never happened.
      expect(a.account.recoveryKeyUnsaved, isFalse);
      expect(server.user('user-1').proofs, contains(code));
      a.dispose();
    },
  );

  test('a passphrase change crossing a recovery key change elsewhere goes '
      'through on the new version, keeping both', () async {
    final a = await unlocked('first passphrase', create: true);
    final code = await proof(a, KeyProofAction.passphrase);
    server.beforeKeyChange = recoveryChangedOn('Sanjay’s iPhone');

    final change = await a.account.preparePassphrase('second passphrase');
    final result = await a.account.commitKeyChange(change!, proof: code);

    expect(result, isA<KeyChangeDone>());
    final bundle = server.user('user-1').bundle!;
    expect(bundle.version, 3);
    expect(bundle.changes.recoveryKey?.device, 'Sanjay’s iPhone');
    expect(bundle.changes.passphrase?.device, 'Sanjay’s MacBook');
    a.dispose();
  });

  test(
    'a code that is wrong, or a proof that has gone, is said plainly',
    () async {
      final a = await unlocked('first passphrase', create: true);
      expect(await a.account.sendKeyCode(KeyProofAction.passphrase), isNull);
      final wrong = await a.account.verifyKeyCode(
        KeyProofAction.passphrase,
        '000000',
      );
      expect(wrong.problem, KeyCodeProblem.wrong);

      final change = await a.account.preparePassphrase('second passphrase');
      final result = await a.account.commitKeyChange(change!, proof: 'stale');
      expect(result, isA<KeyChangeNeedsCode>());
      expect(server.user('user-1').bundle!.version, 1);

      // A proof for one action is no proof for another.
      final forRecovery = await proof(a, KeyProofAction.recoveryKey);
      expect(
        await a.account.commitKeyChange(change, proof: forRecovery),
        isA<KeyChangeNeedsCode>(),
      );
      a.dispose();
    },
  );

  test('a first recovery key needs no code; replacing one does', () async {
    final a = await unlocked('first passphrase', create: true);
    final user = server.user('user-1');
    final bundle = user.bundle!;
    user.bundle = KeyBundle(
      wrappedMasterKey: bundle.wrappedMasterKey,
      kdf: bundle.kdf,
      identity: bundle.identity,
    );
    await a.account.sync!.syncNow();

    final first = await a.account.prepareRecoveryKey();
    expect(await a.account.commitKeyChange(first!), isA<KeyChangeDone>());
    expect(a.account.hasRecoveryKey, isTrue);

    final second = await a.account.prepareRecoveryKey();
    expect(await a.account.commitKeyChange(second!), isA<KeyChangeNeedsCode>());
    a.dispose();
  });

  test('a change that already landed is recognised when sent again', () async {
    final a = await unlocked('first passphrase', create: true);
    final made = await a.account.prepareRecoveryKey();
    final code = await proof(a, KeyProofAction.recoveryKey);
    expect(
      await a.account.commitKeyChange(made!, proof: code),
      isA<KeyChangeDone>(),
    );
    // The answer never arrived, say, and the person pressed again.
    expect(await a.account.commitKeyChange(made), isA<KeyChangeDone>());
    expect(server.user('user-1').bundle!.version, 2);
    a.dispose();
  });

  test('an older account is offered a recovery key once', () async {
    final a = await unlocked('first passphrase', create: true);
    final user = server.user('user-1');
    final bundle = user.bundle!;
    user.bundle = KeyBundle(
      wrappedMasterKey: bundle.wrappedMasterKey,
      kdf: bundle.kdf,
      identity: bundle.identity,
    );
    expect(a.account.offersRecoveryNudge, isFalse);
    await a.account.signOut();
    await a.account.signIn(email: 'a@b.co', password: 'x');
    expect(await a.account.unlock('first passphrase'), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(a.account.offersRecoveryNudge, isTrue);
    a.account.recoveryNudgeShown();
    expect(a.account.offersRecoveryNudge, isFalse);
    a.dispose();
  });

  test('each device names itself to the server, at most hourly', () async {
    final a = await unlocked('first passphrase', create: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.user('user-1').devices.values, contains('Sanjay’s MacBook'));
    a.dispose();
  });
}
