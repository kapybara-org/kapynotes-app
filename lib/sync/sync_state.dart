import 'dart:math';

import '../data/local_store.dart';

/// What sync needs to remember between runs: how far it has read in each
/// space, whose notes these are, and which space is the personal one.
///
/// Kept in the same JSON store as the other preferences rather than in the
/// notes record, so a cursor update does not rewrite the note list.
class SyncState {
  SyncState(this._store);

  final LocalStore _store;

  static const String _key = 'sync.v1';

  /// The cursor a build from before spaces kept. It was the personal space's,
  /// and becomes that entry in [_cursors] the moment the personal space's id
  /// is known.
  String? _legacyCursor;
  final Map<String, String> _cursors = {};
  String? _personalSpaceId;
  String? _accountId;
  String? _deviceId;
  DateTime? _lastSyncedAt;

  /// The pull cursor for one space. Fed back to the server verbatim.
  String? cursorFor(String spaceId) =>
      _cursors[spaceId] ??
      (spaceId == _personalSpaceId ? _legacyCursor : null);

  /// The personal space, once a sync has learned which it is.
  String? get personalSpaceId => _personalSpaceId;

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

  bool get hasSynced => _cursors.isNotEmpty || _legacyCursor != null;

  void load() {
    final stored = _store.read<Map<String, Object?>>(_key);
    if (stored == null) return;
    final cursor = stored['cursor'];
    final cursors = stored['cursors'];
    final personal = stored['personalSpaceId'];
    final accountId = stored['accountId'];
    final deviceId = stored['deviceId'];
    final lastSyncedAt = stored['lastSyncedAt'];
    _legacyCursor = cursor is String ? cursor : null;
    _cursors.clear();
    if (cursors is Map) {
      for (final entry in cursors.entries) {
        if (entry.key is String && entry.value is String) {
          _cursors[entry.key as String] = entry.value as String;
        }
      }
    }
    _personalSpaceId = personal is String ? personal : null;
    _accountId = accountId is String ? accountId : null;
    _deviceId = deviceId is String && deviceId.isNotEmpty ? deviceId : null;
    _lastSyncedAt = lastSyncedAt is int
        ? DateTime.fromMillisecondsSinceEpoch(lastSyncedAt)
        : null;
  }

  /// Records which space is the personal one, and hands it the cursor a
  /// pre-spaces build left behind, which was that space's all along.
  void adoptPersonalSpace(String spaceId) {
    if (_personalSpaceId == spaceId) return;
    _personalSpaceId = spaceId;
    final legacy = _legacyCursor;
    if (legacy != null && !_cursors.containsKey(spaceId)) {
      _cursors[spaceId] = legacy;
    }
    _legacyCursor = null;
    _save();
  }

  void recordPull(String spaceId, String cursor) {
    if (_cursors[spaceId] == cursor) return;
    _cursors[spaceId] = cursor;
    _save();
  }

  /// A space this account is no longer in: its cursor means nothing now, and
  /// coming back to it later should start from the beginning.
  void forgetSpace(String spaceId) {
    if (_cursors.remove(spaceId) != null) _save();
  }

  void recordSync(DateTime at) {
    _lastSyncedAt = at;
    _save();
  }

  void adopt(String accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    // A different account means the old cursors point into somebody else's
    // history. Starting over is the only correct reading of it.
    _cursors.clear();
    _legacyCursor = null;
    _personalSpaceId = null;
    _save();
  }

  /// Signing out. Keeps [accountId] so signing back in resumes rather than
  /// re-downloading everything.
  void clearCursor() {
    _cursors.clear();
    _legacyCursor = null;
    _personalSpaceId = null;
    _lastSyncedAt = null;
    _save();
  }

  void _save() => _store.put(_key, {
    'cursor': _legacyCursor,
    'cursors': Map<String, String>.of(_cursors),
    'personalSpaceId': _personalSpaceId,
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
