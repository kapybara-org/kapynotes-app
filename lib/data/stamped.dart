import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A value and the moment it was set, epoch milliseconds. Merged on its own:
/// the later [at] wins, and a tie goes the same way on every device.
@immutable
class Stamped<T> {
  const Stamped(this.v, this.at);

  final T v;
  final int at;

  Stamped<T> merge(Stamped<T> other) {
    if (other.at != at) return other.at > at ? other : this;
    return jsonEncode(other.v).compareTo(jsonEncode(v)) > 0 ? other : this;
  }

  Map<String, Object?> toJson() => {'v': v, 'at': at};

  static Stamped<T>? fromJson<T>(Object? raw) {
    if (raw is! Map) return null;
    final v = raw['v'];
    final at = raw['at'];
    if (v is! T || at is! int) return null;
    return Stamped<T>(v, at);
  }

  @override
  bool operator ==(Object other) =>
      other is Stamped<T> && other.v == v && other.at == at;

  @override
  int get hashCode => Object.hash(v, at);
}

/// Fields a later build wrote into a record, from both sides of a merge: the
/// greater value where both have one, so either side merging gets the same.
Map<String, Object?> mergeExtra(
  Map<String, Object?> mine,
  Map<String, Object?> theirs,
) => {
  for (final key in {...mine.keys, ...theirs.keys})
    key: !theirs.containsKey(key)
        ? mine[key]
        : !mine.containsKey(key) ||
              jsonEncode(theirs[key]).compareTo(jsonEncode(mine[key])) > 0
        ? theirs[key]
        : mine[key],
};
