import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

/// Keychain on Apple platforms, Keystore on Android, libsecret on Linux,
/// DPAPI on Windows.
///
/// Unguarded on purpose — wrap it in [ForgivingSecureStore], which is what
/// [defaultSecureStore] does.
class PlatformSecureStore implements SecureStore {
  const PlatformSecureStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Turns a broken keystore into an empty one.
///
/// The keystore is the one dependency here that can be absent through no fault
/// of the user: a sandboxed macOS build without a keychain entitlement, a Linux
/// box with no libsecret, a device locked at the wrong moment. Failing soft
/// costs one passphrase prompt per launch. Throwing would cost the launch.
class ForgivingSecureStore implements SecureStore {
  const ForgivingSecureStore(this._inner);

  final SecureStore _inner;

  @override
  Future<String?> read(String key) async {
    try {
      return await _inner.read(key);
    } catch (error) {
      debugPrint('KapyNotes: keystore unreadable ($key): $error');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _inner.write(key, value);
    } catch (error) {
      // The key stays in memory for this session, so sync keeps working; only
      // the next launch pays for it.
      debugPrint('KapyNotes: keystore not writable ($key): $error');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _inner.delete(key);
    } catch (error) {
      debugPrint('KapyNotes: keystore not clearable ($key): $error');
    }
  }
}

/// What the app should use.
SecureStore defaultSecureStore() =>
    const ForgivingSecureStore(PlatformSecureStore());

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

  Uint8List? _masterKey;
  String? _token;
  bool _masterKeyRead = false;
  bool _tokenRead = false;

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

  /// Signing out. Drops the key and the token but never the notes: those are
  /// the user's, they are on their device, and a sign-out is not a delete.
  Future<void> clear() async {
    _masterKey = null;
    _token = null;
    _masterKeyRead = true;
    _tokenRead = true;
    await _store.delete(_masterKeyEntry);
    await _store.delete(_tokenEntry);
  }
}
