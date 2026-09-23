import 'dart:math';

import 'package:flutter/foundation.dart' show mapEquals, setEquals;

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

  /// The cursors as last written to disk. Never ahead of the merge state on
  /// disk — see [cursorsToSave] — so a launch after a crash starts from a
  /// point its documents really reached, and is handed the rest again.
  final Map<String, int> _savedCursors = {};

  /// Spaces whose log this device still owes one full read, and whose notes
  /// it still owes the server one complete copy of. See [beginLogRepair].
  final Set<String> _repairOwed = {};
  final Set<String> _savedRepairOwed = {};
  int _repairVersion = 0;

  /// Bumped by anything that rewrites the saved cursors directly, so a
  /// [cursorsToSave] taken before it cannot put the old ones back.
  int _generation = 0;

  String? _personalSpaceId;
  String? _accountId;
  String? _deviceId;
  DateTime? _lastSyncedAt;

  /// The one-off repair this build runs. Builds before it could skip ops
  /// while applying the log, or lose them on the way up, so a device that
  /// ran one reads every log again from the start and republishes what it
  /// holds. See [beginLogRepair].
  static const int logRepairVersion = 1;

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
    final owed = stored['repairOwed'];
    final repairVersion = stored['repairVersion'];
    _cursors.clear();
    if (cursors is Map) {
      for (final entry in cursors.entries) {
        if (entry.key is String && entry.value is int) {
          _cursors[entry.key as String] = entry.value as int;
        }
      }
    }
    _savedCursors
      ..clear()
      ..addAll(_cursors);
    _repairOwed.clear();
    if (owed is List) _repairOwed.addAll(owed.whereType<String>());
    _savedRepairOwed
      ..clear()
      ..addAll(_repairOwed);
    _repairVersion = repairVersion is int ? repairVersion : 0;
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
  ///
  /// Held in memory only. It reaches disk through [cursorsToSave], once the
  /// documents it describes have.
  void recordCursor(String spaceId, int cursor) {
    if ((_cursors[spaceId] ?? 0) >= cursor) return;
    _cursors[spaceId] = cursor;
  }

  /// What to save once the document store has written everything it holds
  /// now: the cursors as they stand at this moment. Taken as a flush begins
  /// and run when it ends, so the cursors on disk only ever describe
  /// documents that are on disk too.
  void Function() cursorsToSave() {
    final generation = _generation;
    final cursors = Map<String, int>.of(_cursors);
    final owed = Set<String>.of(_repairOwed);
    return () {
      if (generation != _generation) return;
      if (mapEquals(cursors, _savedCursors) &&
          setEquals(owed, _savedRepairOwed)) {
        return;
      }
      _savedCursors
        ..clear()
        ..addAll(cursors);
      _savedRepairOwed
        ..clear()
        ..addAll(owed);
      _save();
    };
  }

  /// Starts the one full read of every log this device has followed, unless
  /// it has had it: sets each of their cursors back to the beginning, and
  /// marks each as owing the server a complete copy of its notes once read.
  /// True if it started one now.
  ///
  /// Builds before [logRepairVersion] could apply a page of the log and skip
  /// the rest of it, or add words to a push the server had already taken,
  /// so their devices can disagree about a note forever. Ops are idempotent:
  /// reading the log again costs a download and changes nothing that was
  /// right, and hands over whatever was skipped that the server still holds.
  bool beginLogRepair() {
    if (_repairVersion >= logRepairVersion) return false;
    _repairVersion = logRepairVersion;
    _repairOwed.addAll(_cursors.keys);
    _cursors.updateAll((_, _) => 0);
    _rewriteSaved();
    return _repairOwed.isNotEmpty;
  }

  /// Whether [spaceId] still owes the server a complete copy of its notes.
  bool owesRepair(String spaceId) => _repairOwed.contains(spaceId);

  /// [spaceId]'s notes have been queued for the server in full.
  void repairDone(String spaceId) => _repairOwed.remove(spaceId);

  /// A space this account is no longer in: its cursor means nothing now, and
  /// coming back to it later should start from the beginning.
  void forgetSpace(String spaceId) {
    final forgot = _cursors.remove(spaceId) != null;
    final owed = _repairOwed.remove(spaceId);
    if (!forgot && !owed) return;
    // Only this space: the others' cursors in memory can be ahead of their
    // records on disk, and stay unsaved until those are written.
    _generation++;
    _savedCursors.remove(spaceId);
    _savedRepairOwed.remove(spaceId);
    _save();
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
    _repairOwed.clear();
    _personalSpaceId = null;
    _rewriteSaved();
  }

  /// Signing out. Keeps [accountId] so signing back in resumes rather than
  /// re-downloading everything.
  void clearCursor() {
    _cursors.clear();
    _repairOwed.clear();
    _personalSpaceId = null;
    _lastSyncedAt = null;
    _rewriteSaved();
  }

  /// Saves the cursors as they are in memory, now. Only for a change that
  /// has just moved every one of them back to the start or away, which can
  /// never describe more than the documents on disk hold.
  void _rewriteSaved() {
    _generation++;
    _savedCursors
      ..clear()
      ..addAll(_cursors);
    _savedRepairOwed
      ..clear()
      ..addAll(_repairOwed);
    _save();
  }

  void _save() => _store.put(_key, {
    'opCursors': Map<String, int>.of(_savedCursors),
    if (_savedRepairOwed.isNotEmpty) 'repairOwed': _savedRepairOwed.toList(),
    if (_repairVersion > 0) 'repairVersion': _repairVersion,
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
