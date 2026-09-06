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

  const KeyBundle({
    required this.wrappedMasterKey,
    required this.kdf,
    this.recoveryWrappedMasterKey,
    this.identity,
  });

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
    return KeyBundle(
      wrappedMasterKey: wrapped,
      kdf: kdf,
      recoveryWrappedMasterKey: SealedBox.fromJson(
        raw['recoveryWrappedMasterKey'],
      ),
      identity: WireIdentity.fromJson(raw['identity']),
    );
  }
}
