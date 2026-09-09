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

  /// Per-space cursors into the op log: the last seq applied. Zero — and the
  /// cursors a protocol-2 build kept, which named rows rather than seqs and
  /// are dropped on load — means the beginning.
  final Map<String, int> _cursors = {};
  String? _personalSpaceId;
  String? _accountId;
  String? _deviceId;
  DateTime? _lastSyncedAt;

  /// The last seq applied from one space's log. Zero before any.
  int cursorFor(String spaceId) => _cursors[spaceId] ?? 0;

  /// Every space with a cursor, for the subscription on connect.
  Map<String, int> get cursors => Map.unmodifiable(_cursors);

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
  /// It names this device on every op it writes — the idempotency key the
  /// server deduplicates a retried push by, and how a device recognises its
  /// own ops when the log echoes them back — and the first twelve hex digits
  /// of it stamp every character this device inserts.
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

  bool get hasSynced => _cursors.isNotEmpty;

  void load() {
    final stored = _store.read<Map<String, Object?>>(_key);
    if (stored == null) return;
    final cursors = stored['opCursors'];
    final personal = stored['personalSpaceId'];
    final accountId = stored['accountId'];
    final deviceId = stored['deviceId'];
    final lastSyncedAt = stored['lastSyncedAt'];
    _cursors.clear();
    if (cursors is Map) {
      for (final entry in cursors.entries) {
        if (entry.key is String && entry.value is int) {
          _cursors[entry.key as String] = entry.value as int;
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

  /// Records which space is the personal one.
  void adoptPersonalSpace(String spaceId) {
    if (_personalSpaceId == spaceId) return;
    _personalSpaceId = spaceId;
    _save();
  }

  /// The log has been applied through [cursor]. Never moves backwards: a
  /// late page from a slower path must not rewind what the socket did.
  void recordCursor(String spaceId, int cursor) {
    if ((_cursors[spaceId] ?? 0) >= cursor) return;
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
    _personalSpaceId = null;
    _save();
  }

  /// Signing out. Keeps [accountId] so signing back in resumes rather than
  /// re-downloading everything.
  void clearCursor() {
    _cursors.clear();
    _personalSpaceId = null;
    _lastSyncedAt = null;
    _save();
  }

  void _save() => _store.put(_key, {
    'opCursors': Map<String, int>.of(_cursors),
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
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
