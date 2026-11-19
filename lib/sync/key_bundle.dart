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

  /// Moves only on a reset, which replaces the master key itself. Every sync
  /// request names the one this device's key belongs to.
  final int generation;

  const KeyBundle({
    required this.wrappedMasterKey,
    required this.kdf,
    this.recoveryWrappedMasterKey,
    this.identity,
    this.version = 1,
    this.changes = const KeyChanges(),
    this.generation = 1,
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
    final generation = raw['generation'];
    return KeyBundle(
      wrappedMasterKey: wrapped,
      kdf: kdf,
      recoveryWrappedMasterKey: SealedBox.fromJson(
        raw['recoveryWrappedMasterKey'],
      ),
      identity: WireIdentity.fromJson(raw['identity']),
      version: version is int && version >= 1 ? version : 1,
      changes: KeyChanges.fromJson(raw['changes']),
      generation: generation is int && generation >= 1 ? generation : 1,
    );
  }
}

/// What the server remembers about the last changes to a bundle: enough to
/// tell somebody why their old passphrase stopped working, and nothing more.
class KeyChanges {
  const KeyChanges({this.passphrase, this.recoveryKey, this.reset});

  final KeyChange? passphrase;
  final KeyChange? recoveryKey;
  final KeyChange? reset;

  static KeyChanges fromJson(Object? raw) => raw is Map
      ? KeyChanges(
          passphrase: KeyChange.fromJson(raw['passphrase']),
          recoveryKey: KeyChange.fromJson(raw['recoveryKey']),
          reset: KeyChange.fromJson(raw['reset']),
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

/// What a reset will touch, so the device can say so before it happens.
/// Mirrors `ResetPreview`.
class ResetPreview {
  const ResetPreview({
    this.devices = const [],
    this.personalNoteIds = const {},
    this.orphanedSpaces = const {},
    this.release,
  });

  /// The account's other devices that synced lately, most recent first.
  final List<ResetDevice> devices;

  /// Every note the server holds in the personal space, by id only.
  final Set<String> personalNoteIds;

  /// Team spaces nobody but this account could grant the key in again.
  final Set<String> orphanedSpaces;

  /// The first app release that understands a reset, as the server names
  /// it. Devices on anything older need it to sync again afterwards.
  final String? release;

  static ResetPreview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final devices = raw['devices'];
    final notes = raw['personalNoteIds'];
    final spaces = raw['orphanedSpaces'];
    return ResetPreview(
      devices: [
        if (devices is List)
          for (final device in devices) ?ResetDevice.fromJson(device),
      ]..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt)),
      personalNoteIds: {if (notes is List) ...notes.whereType<String>()},
      orphanedSpaces: {
        if (spaces is List)
          for (final space in spaces)
            if (space is Map && space['spaceId'] is String)
              space['spaceId'] as String,
      },
      release: raw['release'] is String ? raw['release'] as String : null,
    );
  }
}

class ResetDevice {
  const ResetDevice({
    this.name,
    this.platform,
    required this.lastSeenAt,
    this.protocol,
  });

  /// Untrusted text, shown only as plain text.
  final String? name;
  final String? platform;
  final DateTime lastSeenAt;

  /// The sync protocol its last request spoke. Null when unknown.
  final int? protocol;

  static ResetDevice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seen = raw['lastSeenAt'] is String
        ? DateTime.tryParse(raw['lastSeenAt'] as String)
        : null;
    if (seen == null) return null;
    final name = raw['name'];
    final platform = raw['platform'];
    final protocol = raw['protocol'];
    return ResetDevice(
      protocol: protocol is int ? protocol : null,
      name: name is String && name.trim().isNotEmpty ? name : null,
      platform: platform is String && platform.isNotEmpty ? platform : null,
      lastSeenAt: seen.toLocal(),
    );
  }
}

/// The seals from before the last reset, kept for 30 days so a device can
/// tell somebody that what they typed is the old passphrase.
class KeyArchive {
  const KeyArchive({
    required this.wrappedMasterKey,
    required this.kdf,
    this.recoveryWrappedMasterKey,
  });

  final SealedBox wrappedMasterKey;
  final KdfParams kdf;
  final SealedBox? recoveryWrappedMasterKey;

  static KeyArchive? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final wrapped = SealedBox.fromJson(raw['wrappedMasterKey']);
    final kdf = KdfParams.fromJson(raw['kdf']);
    if (wrapped == null || kdf == null) return null;
    return KeyArchive(
      wrappedMasterKey: wrapped,
      kdf: kdf,
      recoveryWrappedMasterKey: SealedBox.fromJson(
        raw['recoveryWrappedMasterKey'],
      ),
    );
  }
}

/// What an emailed code is being asked for. Mirrors `KeyProofAction`.
enum KeyProofAction {
  passphrase('passphrase'),
  recoveryKey('recovery-key'),
  reset('reset');

  const KeyProofAction(this.wire);
  final String wire;
}
