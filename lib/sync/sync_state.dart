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

  DateTime? get lastSyncedAt => _lastSyncedAt;

  bool get hasSynced => _cursor != null;

  void load() {
    final stored = _store.read<Map<String, Object?>>(_key);
    if (stored == null) return;
    final cursor = stored['cursor'];
    final accountId = stored['accountId'];
    final lastSyncedAt = stored['lastSyncedAt'];
    _cursor = cursor is String ? cursor : null;
    _accountId = accountId is String ? accountId : null;
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
    'lastSyncedAt': _lastSyncedAt?.millisecondsSinceEpoch,
  });
}
