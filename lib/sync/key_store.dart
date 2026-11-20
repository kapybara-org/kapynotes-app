import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/keyring.dart';
import '../core/platform.dart';
import 'auth_api.dart';

/// Where the master key and the session token live between launches.
///
/// Abstract so tests — and any platform where the native keystore is
/// unavailable — can supply their own. The contract is deliberately small:
/// three strings, scoped to this app, that survive a restart and are not
/// readable by other applications.
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The macOS service name every entry is filed under.
///
/// The real app uses the plugin's default. A build that is not the real app
/// names its own at build time, `--dart-define=KAPYNOTES_KEYCHAIN=kapynotes-dev`,
/// so it never reads, migrates or deletes the installed app's entries.
const String _service = String.fromEnvironment(
  'KAPYNOTES_KEYCHAIN',
  defaultValue: AppleOptions.defaultAccountName,
);

/// Where macOS keeps the master key and session: the data-protection
/// keychain, which hands an entry only to apps whose signature carries its
/// access group.
///
/// The app's one group is the keychain access group in DeveloperID.entitlements,
/// the team prefix and the bundle id (`96V66447C6.com.kapybara.kapynotes` for
/// the real app), so every entry lands there. macOS honours that entitlement
/// only when the Developer ID provisioning profile embedded at export
/// authorises it, so another build, whether ad-hoc, signed by another team or
/// under another bundle id, can't claim the group and sees nothing. The plugin
/// ignores `groupId` on macOS, so there is none here: the default group is
/// the only group.
///
/// A build without the profile, which is every local development build, gets
/// `-34018 errSecMissingEntitlement`, and [ForgivingSecureStore] turns that
/// into a session that lasts until the app quits.
const MacOsOptions macOsKeychain = MacOsOptions(
  usesDataProtectionKeychain: true,
  accountName: _service,
);

/// Where iOS keeps the master key and session: readable once the phone has
/// been unlocked after a restart, so sync can run in the background, and
/// never carried to another device in a backup.
///
/// Under a service name of its own. The keychain tells entries apart by
/// service and account, not by accessibility, so rewriting an entry with a new
/// level replaces it in place, and a failed write would lose it. Builds up to
/// 1.33 filed entries under the plugin's default service at its default
/// level; [MigratingSecureStore] copies each one here, reads it back, and only
/// then deletes the old one.
const IOSOptions iosKeychain = IOSOptions(
  accountName: 'kapynotes.keychain.v2',
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

/// Keychain on Apple platforms, Keystore on Android, libsecret on Linux,
/// DPAPI on Windows.
///
/// Unguarded on purpose: use [platformSecureStore], or [defaultSecureStore]
/// for the forgiving version.
class PlatformSecureStore implements SecureStore {
  const PlatformSecureStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) =>
      _storage.read(key: key, mOptions: macOsKeychain);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value, mOptions: macOsKeychain);

  @override
  Future<void> delete(String key) =>
      _storage.delete(key: key, mOptions: macOsKeychain);
}

/// Where earlier macOS versions kept them: the file-based login keychain.
///
/// Its entries are guarded by a list of trusted apps that grows every time
/// the user approves a keychain prompt, so any build that asks can end up
/// reading the session. Only read, to move entries out, and emptied.
///
/// Through the app's own channel (FileKeychain.swift) rather than the plugin:
/// the plugin leaves the keychain choice unset for the file keychain, which in
/// an app with a keychain access group also reaches the data-protection
/// keychain, so deleting an old entry deleted its new copy too.
class FileKeychainStore implements SecureStore {
  const FileKeychainStore();

  static const MethodChannel _channel = MethodChannel(
    'kapynotes/file_keychain',
  );

  @override
  Future<String?> read(String key) => _channel.invokeMethod<String>('read', {
    'service': _service,
    'account': key,
  });

  @override
  Future<void> write(String key, String value) =>
      throw UnsupportedError('The file keychain is only read and emptied.');

  @override
  Future<void> delete(String key) => _channel.invokeMethod<void>('delete', {
    'service': _service,
    'account': key,
  });
}

/// Moves each entry out of the store an earlier version wrote it to, the
/// first time it is read.
///
/// The old entry is deleted only once the copy reads back the same. If any
/// step fails, the old entry stays where it was and is what the read returns,
/// so the user stays signed in and the next launch tries again.
///
/// A write clears the old copy too, but only after the new one is written: a
/// stale old entry could come back later, and a missing one is worse for the
/// Hidden Notes PIN, where no entry lets anyone set a new PIN. Deletes clear
/// both, so a sign-out can't be undone by migrating the old session back on
/// the next launch.
class MigratingSecureStore implements SecureStore {
  const MigratingSecureStore(this._current, this._legacy, {this.sweep = false});

  final SecureStore _current;
  final SecureStore _legacy;

  /// Whether a read that finds the new copy also deletes an old one left
  /// behind, as a crash between the move's write and its delete leaves it.
  /// Once per key per process.
  final bool sweep;

  static final Set<String> _swept = {};

  @visibleForTesting
  static void debugForgetSwept() => _swept.clear();

  @override
  Future<String?> read(String key) async {
    final String? current;
    try {
      current = await _current.read(key);
    } catch (error) {
      debugPrint(
        'KapyNotes: keystore unreadable, using the old one ($key): $error',
      );
      return _legacy.read(key);
    }
    if (current != null) {
      if (sweep && _swept.add(key)) {
        try {
          await _legacy.delete(key);
        } catch (error) {
          debugPrint('KapyNotes: old keystore entry not cleared ($key): $error');
        }
      }
      return current;
    }

    final legacy = await _legacy.read(key);
    if (legacy == null) return null;
    try {
      await _current.write(key, legacy);
      if (await _current.read(key) == legacy) await _legacy.delete(key);
    } catch (error) {
      debugPrint('KapyNotes: keystore migration failed ($key): $error');
    }
    return legacy;
  }

  @override
  Future<void> write(String key, String value) async {
    await _current.write(key, value);
    await _legacy.delete(key);
  }

  @override
  Future<void> delete(String key) =>
      Future.wait([_current.delete(key), _legacy.delete(key)]);
}

/// The platform's store. On macOS and iOS it also moves entries out of where
/// earlier versions kept them.
SecureStore platformSecureStore() {
  if (AppPlatform.isMacOS) {
    return const MigratingSecureStore(
      PlatformSecureStore(),
      FileKeychainStore(),
    );
  }
  if (AppPlatform.isIOS) {
    return const MigratingSecureStore(
      PlatformSecureStore(FlutterSecureStorage(iOptions: iosKeychain)),
      PlatformSecureStore(),
      sweep: true,
    );
  }
  return const PlatformSecureStore();
}

/// Where the Hidden Notes PIN lives. On iOS it stays where 1.33 kept it, in
/// the old service at WhenUnlocked, so a restored iPhone still asks for the
/// old PIN. Moved to a device-only entry, a restored phone would have no PIN,
/// and whoever opened Hidden Notes would set one and see them.
///
/// Linux only, the store refuses before touching libsecret once the launch has
/// found no keyring, so the pane says so instead of logging the same failure.
/// Every other platform keeps exactly the store it had: off Linux a keystore
/// that refuses once may open on the next try.
SecureStore hiddenNotesSecureStore() {
  if (!AppPlatform.isLinux) {
    return AppPlatform.isIOS
        ? const PlatformSecureStore()
        : platformSecureStore();
  }
  return KeyringGuardedStore(platformSecureStore(), KeyringStatus.instance);
}

/// Moves each of [keys] now rather than on its next read, so nothing waits
/// in an old store that backups carry.
Future<void> moveEntries(SecureStore store, Iterable<String> keys) async {
  for (final key in keys) {
    await store.read(key);
  }
}

/// Turns a broken keystore into an empty one.
///
/// The keystore is the one dependency here that can be absent through no fault
/// of the user: a sandboxed macOS build without a keychain entitlement, a Linux
/// box with no libsecret, a device locked at the wrong moment. Failing soft
/// costs one passphrase prompt per launch. Throwing would cost the launch.
class ForgivingSecureStore implements SecureStore {
  const ForgivingSecureStore(this._inner, {this.status});

  final SecureStore _inner;

  /// When set, a failure is remembered and later calls skip the keystore, so
  /// a missing keyring logs once instead of once per entry.
  final KeyringStatus? status;

  bool get _skip => status != null && !status!.available;

  @override
  Future<String?> read(String key) async {
    if (_skip) return null;
    try {
      return await _inner.read(key);
    } catch (error) {
      _failed('KapyNotes: keystore unreadable ($key): $error');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    if (_skip) return;
    try {
      await _inner.write(key, value);
    } catch (error) {
      // The key stays in memory for this session, so sync keeps working; only
      // the next launch pays for it.
      _failed('KapyNotes: keystore not writable ($key): $error');
    }
  }

  @override
  Future<void> delete(String key) async {
    if (_skip) return;
    try {
      await _inner.delete(key);
    } catch (error) {
      _failed('KapyNotes: keystore not clearable ($key): $error');
    }
  }

  void _failed(String line) {
    // Only Linux can know a keystore is absent rather than momentarily
    // refusing: everywhere else a locked keychain or a denied prompt is
    // transient, and a read may still succeed afterwards.
    if (status != null && AppPlatform.isLinux) {
      status!.markUnavailable();
      return;
    }
    debugPrint(line);
  }
}

/// What the app should use.
SecureStore defaultSecureStore() =>
    ForgivingSecureStore(platformSecureStore(), status: KeyringStatus.instance);

/// Thrown when this launch already knows the keyring is not running.
class MissingKeyring implements Exception {
  const MissingKeyring();

  @override
  String toString() => 'no keyring is running';
}

/// Fails at once when this launch already found no keyring, so a read does not
/// ask libsecret again and log the same failure.
///
/// Linux only, like the status it reads: elsewhere a keystore that refuses
/// once may open on the next try.
///
/// Strict on purpose, unlike [ForgivingSecureStore]: the caller has to refuse
/// rather than carry on as if nothing were stored.
class KeyringGuardedStore implements SecureStore {
  const KeyringGuardedStore(this._inner, this._status);

  final SecureStore _inner;
  final KeyringStatus _status;

  void _require() {
    if (!_status.available) throw const MissingKeyring();
  }

  @override
  Future<String?> read(String key) async {
    _require();
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    _require();
    return _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    _require();
    return _inner.delete(key);
  }
}

/// For tests and for platforms without a keystore. Nothing here outlives the
/// process, which for a test is the point and for a user means one extra
/// unlock per launch — never a lost note.
class InMemorySecureStore implements SecureStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// The master key and session token, cached in memory once read.
///
/// The cache is what keeps this off the hot path: a platform channel round
/// trip per sync would be wasteful, and every sync needs the key. Reading it
/// once per launch is enough.
class KeyStore {
  KeyStore(this._store);

  final SecureStore _store;

  static const String _masterKeyEntry = 'kapynotes.masterKey';
  static const String _tokenEntry = 'kapynotes.sessionToken';
  static const String _userEntry = 'kapynotes.sessionUser';
  static const String _pendingKeyEntry = 'kapynotes.pendingMasterKey';

  /// Every entry this store keeps.
  static const List<String> entries = [_masterKeyEntry, _tokenEntry, _userEntry];

  Uint8List? _masterKey;
  String? _token;
  AccountUser? _user;
  bool _masterKeyRead = false;
  bool _tokenRead = false;
  bool _userRead = false;

  /// The cached master key, or null if this device has never unlocked.
  Future<Uint8List?> readMasterKey() async {
    if (_masterKeyRead) return _masterKey;
    _masterKeyRead = true;
    final stored = await _store.read(_masterKeyEntry);
    if (stored == null) return null;
    try {
      final bytes = base64.decode(stored);
      // A key of the wrong length means something else wrote this entry;
      // treat it as absent rather than handing it to the cipher.
      _masterKey = bytes.length == 32 ? bytes : null;
    } on FormatException catch (error) {
      debugPrint('KapyNotes: unreadable master key entry: $error');
      _masterKey = null;
    }
    return _masterKey;
  }

  Future<void> writeMasterKey(Uint8List key) async {
    _masterKey = key;
    _masterKeyRead = true;
    await _store.write(_masterKeyEntry, base64.encode(key));
  }

  /// A reset's new master key, written before the reset is sent: if the app
  /// stops between the server taking it and this device adopting it, the
  /// next launch can still adopt it. Read once, and only then.
  Future<Uint8List?> readPendingMasterKey() async {
    final stored = await _store.read(_pendingKeyEntry);
    if (stored == null) return null;
    try {
      final bytes = base64.decode(stored);
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> writePendingMasterKey(Uint8List key) =>
      _store.write(_pendingKeyEntry, base64.encode(key));

  Future<void> forgetPendingMasterKey() => _store.delete(_pendingKeyEntry);

  Future<String?> readToken() async {
    if (_tokenRead) return _token;
    _tokenRead = true;
    _token = await _store.read(_tokenEntry);
    return _token;
  }

  Future<void> writeToken(String token) async {
    _token = token;
    _tokenRead = true;
    await _store.write(_tokenEntry, token);
  }

  /// Who the stored token belongs to, as the server last said.
  ///
  /// Kept beside the token because a launch that cannot reach the server still
  /// has to know whose device this is: the account id decides whether the
  /// notes already here belong to this account, and the address is what the
  /// settings pane shows. Without it an offline launch has a valid session and
  /// no idea whose, which is not a state the app can do anything with.
  Future<AccountUser?> readUser() async {
    if (_userRead) return _user;
    _userRead = true;
    final stored = await _store.read(_userEntry);
    if (stored == null) return null;
    try {
      _user = AccountUser.fromJson(jsonDecode(stored));
    } on FormatException catch (error) {
      debugPrint('KapyNotes: unreadable session user entry: $error');
      _user = null;
    }
    return _user;
  }

  Future<void> writeUser(AccountUser user) async {
    _user = user;
    _userRead = true;
    await _store.write(
      _userEntry,
      jsonEncode({
        'id': user.id,
        'email': user.email,
        'emailVerified': user.emailVerified,
        'name': user.name,
        'image': user.image,
      }),
    );
  }

  /// A session the server has ended. Whose it was stays, so the next launch
  /// still says why it is signed out and the same account keeps its notes.
  Future<void> forgetToken() async {
    _token = null;
    _tokenRead = true;
    await _store.delete(_tokenEntry);
  }

  /// Another account signed in on this device: the key it holds is not theirs.
  Future<void> forgetMasterKey() async {
    _masterKey = null;
    _masterKeyRead = true;
    await _store.delete(_masterKeyEntry);
  }

  /// Signing out. Drops the key and the token but never the notes: those are
  /// the user's, they are on their device, and a sign-out is not a delete.
  Future<void> clear() async {
    _masterKey = null;
    _token = null;
    _user = null;
    _masterKeyRead = true;
    _tokenRead = true;
    _userRead = true;
    await _store.delete(_masterKeyEntry);
    await _store.delete(_pendingKeyEntry);
    await _store.delete(_tokenEntry);
    await _store.delete(_userEntry);
  }
}
