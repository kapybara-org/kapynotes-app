import 'dart:math';

import '../data/local_store.dart';

/// What sync needs to remember between runs: how far it has read, and whose
/// notes these are.
///
/// Kept in the same JSON store as the other preferences rather than in the
/// notes record, so a cursor update does not rewrite the note list.
class SyncState {
  SyncState(this._store);

  final LocalStore _store;

  static const String _key = 'sync.v1';

  String? _cursor;
  String? _accountId;
  String? _deviceId;
  DateTime? _lastSyncedAt;

  /// Opaque pull cursor. Fed back to the server verbatim.
  String? get cursor => _cursor;

  /// The account these notes belong to.
  ///
  /// Signing in as somebody else on a device that already holds notes is a
  /// question with no safe default — pushing them into the new account leaks
  /// them, wiping them destroys them — so this is recorded and compared, and
  /// the decision is left to the caller rather than made silently here.
  String? get accountId => _accountId;

  /// This install's id, minted once and kept for as long as the app is
  /// installed.
  ///
  /// It exists so the server can skip waking the device that made a change.
  /// Without it every push comes straight back to its own author as a wake-up,
  /// and that author then pulls — its cursor still sits behind the rows it
  /// just wrote — decrypting and re-merging notes it wrote itself, on every
  /// edit.
  ///
  /// Not an identity, and never treated as one: it survives sign-out, because
  /// the device is still the same device, and it is compared only against
  /// itself. Minted lazily so a build with sync switched off never generates
  /// one at all.
  String get deviceId {
    final existing = _deviceId;
    if (existing != null) return existing;
    final minted = _mintDeviceId();
    _deviceId = minted;
    _save();
    return minted;
  }

  DateTime? get lastSyncedAt => _lastSyncedAt;

  bool get hasSynced => _cursor != null;

  void load() {
    final stored = _store.read<Map<String, Object?>>(_key);
    if (stored == null) return;
    final cursor = stored['cursor'];
    final accountId = stored['accountId'];
    final deviceId = stored['deviceId'];
    final lastSyncedAt = stored['lastSyncedAt'];
    _cursor = cursor is String ? cursor : null;
    _accountId = accountId is String ? accountId : null;
    _deviceId = deviceId is String && deviceId.isNotEmpty ? deviceId : null;
    _lastSyncedAt = lastSyncedAt is int
        ? DateTime.fromMillisecondsSinceEpoch(lastSyncedAt)
        : null;
  }

  void recordPull(String cursor) {
    if (_cursor == cursor) return;
    _cursor = cursor;
    _save();
  }

  void recordSync(DateTime at) {
    _lastSyncedAt = at;
    _save();
  }

  void adopt(String accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    // A different account means the old cursor points into somebody else's
    // history. Starting over is the only correct reading of it.
    _cursor = null;
    _save();
  }

  /// Signing out. Keeps [accountId] so signing back in resumes rather than
  /// re-downloading everything.
  void clearCursor() {
    _cursor = null;
    _lastSyncedAt = null;
    _save();
  }

  void _save() => _store.put(_key, {
    'cursor': _cursor,
    'accountId': _accountId,
    // Deliberately outlives both [adopt] and [clearCursor]: signing out or
    // signing in as somebody else does not make this a different device.
    'deviceId': _deviceId,
    'lastSyncedAt': _lastSyncedAt?.millisecondsSinceEpoch,
  });

  /// 16 bytes from the platform CSPRNG, hex. Long enough that two installs
  /// colliding is not a thing that happens, short enough to sit in a header.
  static String _mintDeviceId() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
