import 'package:flutter/foundation.dart';

import '../data/local_store.dart';
import 'identity.dart';
import 'spaces.dart';

/// Trust on first use.
///
/// The server distributes public keys, so a malicious server could hand out
/// its own and read a team's notes. This device remembers the fingerprint of
/// every member's key the first time it sees it, per space, and raises a
/// warning that does not go away on its own if one ever changes. A new device
/// trusts what it first sees. Comparing fingerprints out of band is the next
/// step, and the fingerprint is shown for exactly that.
class TrustStore extends ChangeNotifier {
  TrustStore(this._store);

  final LocalStore _store;

  static const String _key = 'trust.v1';

  /// spaceId → userId → fingerprint, as first seen.
  Map<String, Map<String, String>> _pinned = {};

  /// Members whose key changed since it was pinned, until acknowledged.
  final List<TrustWarning> _warnings = [];

  List<TrustWarning> get warnings => List.unmodifiable(_warnings);

  bool get hasWarnings => _warnings.isNotEmpty;

  List<TrustWarning> warningsFor(String spaceId) =>
      _warnings.where((w) => w.spaceId == spaceId).toList(growable: false);

  void load() {
    final stored = _store.read<Map<String, Object?>>(_key);
    if (stored == null) return;
    final pinned = stored['pinned'];
    if (pinned is Map) {
      _pinned = {
        for (final entry in pinned.entries)
          if (entry.value is Map)
            entry.key as String: {
              for (final member in (entry.value as Map).entries)
                if (member.value is String)
                  member.key as String: member.value as String,
            },
      };
    }
    final warnings = stored['warnings'];
    if (warnings is List) {
      _warnings.addAll(
        warnings.map(TrustWarning.fromJson).whereType<TrustWarning>(),
      );
    }
  }

  /// Pins every member's key the first time it appears, and records a
  /// warning for any pinned key that no longer matches. Members without a
  /// key yet are left unpinned until they have one.
  void observe(List<Space> spaces) {
    var changed = false;
    for (final space in spaces) {
      if (!space.isTeam) continue;
      final pins = _pinned.putIfAbsent(space.id, () => {});
      for (final member in space.members) {
        final key = member.x25519Public;
        if (key == null) continue;
        final fingerprint = fingerprintOf(key);
        final pinned = pins[member.userId];
        if (pinned == null) {
          pins[member.userId] = fingerprint;
          changed = true;
        } else if (pinned != fingerprint &&
            !_warnings.any(
              (w) => w.spaceId == space.id && w.userId == member.userId,
            )) {
          _warnings.add(
            TrustWarning(
              spaceId: space.id,
              userId: member.userId,
              email: member.email,
              previous: pinned,
              current: fingerprint,
            ),
          );
          changed = true;
        }
      }
    }
    // Spaces this account has left take their pins with them, so rejoining
    // one later trusts what it sees again rather than warning about a change
    // nobody could have watched.
    final live = {for (final space in spaces) space.id};
    final stale = _pinned.keys.where((id) => !live.contains(id)).toList();
    for (final id in stale) {
      _pinned.remove(id);
      _warnings.removeWhere((w) => w.spaceId == id);
      changed = true;
    }
    if (changed) _save();
  }

  /// The person has looked at the new fingerprint and decided to trust it.
  void acknowledge(TrustWarning warning) {
    _pinned.putIfAbsent(warning.spaceId, () => {})[warning.userId] =
        warning.current;
    _warnings.removeWhere(
      (w) => w.spaceId == warning.spaceId && w.userId == warning.userId,
    );
    _save();
  }

  String? pinnedFingerprint(String spaceId, String userId) =>
      _pinned[spaceId]?[userId];

  void _save() {
    _store.putNow(_key, {
      'pinned': _pinned,
      'warnings': [for (final w in _warnings) w.toJson()],
    });
    notifyListeners();
  }
}

class TrustWarning {
  final String spaceId;
  final String userId;
  final String email;
  final String previous;
  final String current;

  const TrustWarning({
    required this.spaceId,
    required this.userId,
    required this.email,
    required this.previous,
    required this.current,
  });

  Map<String, Object?> toJson() => {
    'spaceId': spaceId,
    'userId': userId,
    'email': email,
    'previous': previous,
    'current': current,
  };

  static TrustWarning? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final spaceId = raw['spaceId'];
    final userId = raw['userId'];
    final email = raw['email'];
    final previous = raw['previous'];
    final current = raw['current'];
    if (spaceId is! String ||
        userId is! String ||
        email is! String ||
        previous is! String ||
        current is! String) {
      return null;
    }
    return TrustWarning(
      spaceId: spaceId,
      userId: userId,
      email: email,
      previous: previous,
      current: current,
    );
  }
}
