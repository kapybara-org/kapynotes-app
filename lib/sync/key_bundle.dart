import 'identity.dart';
import 'sealed_box.dart';

/// Everything a new device needs to reach the master key — and nothing that
/// would let the server do the same. Mirrors `KeyBundle` in the contract.
class KeyBundle {
  /// Master key sealed under the Argon2id-derived passphrase key.
  final SealedBox wrappedMasterKey;
  final KdfParams kdf;

  /// Master key sealed directly under the recovery key. Null only for accounts
  /// created before recovery keys existed.
  final SealedBox? recoveryWrappedMasterKey;

  /// The identity keypairs, sealed under the master key. Null for an account
  /// that has not published them yet; the next unlock does.
  final WireIdentity? identity;

  /// Moves on every write, and every write names the one it read, so a key
  /// another device has just changed is never silently replaced.
  final int version;

  /// When the passphrase and the recovery key last changed, and on what.
  final KeyChanges changes;

  const KeyBundle({
    required this.wrappedMasterKey,
    required this.kdf,
    this.recoveryWrappedMasterKey,
    this.identity,
    this.version = 1,
    this.changes = const KeyChanges(),
  });

  /// First-run setup's body. The version and the history are the server's.
  Map<String, Object?> toJson() => {
    'wrappedMasterKey': wrappedMasterKey.toJson(),
    'kdf': kdf.toJson(),
    'recoveryWrappedMasterKey': recoveryWrappedMasterKey?.toJson(),
    'identity': identity?.toJson(),
  };

  static KeyBundle? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final wrapped = SealedBox.fromJson(raw['wrappedMasterKey']);
    final kdf = KdfParams.fromJson(raw['kdf']);
    if (wrapped == null || kdf == null) return null;
    final version = raw['version'];
    return KeyBundle(
      wrappedMasterKey: wrapped,
      kdf: kdf,
      recoveryWrappedMasterKey: SealedBox.fromJson(
        raw['recoveryWrappedMasterKey'],
      ),
      identity: WireIdentity.fromJson(raw['identity']),
      version: version is int && version >= 1 ? version : 1,
      changes: KeyChanges.fromJson(raw['changes']),
    );
  }
}

/// What the server remembers about the last changes to a bundle: enough to
/// tell somebody why their old passphrase stopped working, and nothing more.
class KeyChanges {
  const KeyChanges({this.passphrase, this.recoveryKey});

  final KeyChange? passphrase;
  final KeyChange? recoveryKey;

  static KeyChanges fromJson(Object? raw) => raw is Map
      ? KeyChanges(
          passphrase: KeyChange.fromJson(raw['passphrase']),
          recoveryKey: KeyChange.fromJson(raw['recoveryKey']),
        )
      : const KeyChanges();
}

class KeyChange {
  const KeyChange({required this.at, this.device});

  final DateTime at;

  /// The name the changing device gave itself. Untrusted text: shown only as
  /// plain text, never parsed.
  final String? device;

  static KeyChange? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'] is String
        ? DateTime.tryParse(raw['at']! as String)
        : null;
    if (at == null) return null;
    final device = raw['device'];
    return KeyChange(
      at: at,
      device: device is String && device.trim().isNotEmpty ? device : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KeyChange && other.at == at && other.device == device;

  @override
  int get hashCode => Object.hash(at, device);
}

/// What an emailed code is being asked for. Mirrors `KeyProofAction`.
enum KeyProofAction {
  passphrase('passphrase'),
  recoveryKey('recovery-key');

  const KeyProofAction(this.wire);
  final String wire;
}
