import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Which notes one part of a recap, or all of it, could read. Made from the
/// notes' ids, it holds them as they are; a recap's record keeps it as a
/// Bloom filter sized to how many it holds ([sized]), which may say a note
/// was read when it was not but never the other way round, so a reopened
/// recap leaves out too much rather than too little.
///
/// Records keep the bits, so the hashing never changes: FNV-1a, 32-bit,
/// over the id's UTF-8, XORed with the filter's salt, spread by
/// MurmurHash3's finalizer into two hashes, once as it is and once XORed
/// with 0x9e3779b9, which are double-hashed into the bits. A part's salt is
/// 0, and the filter of a whole recap's notes ([union]) has [wholeSalt], so
/// its false matches fall apart from the parts'.
class RecapFilter {
  RecapFilter._(this._ids, this.hashes, this._bits, [this._salt = 0]);

  RecapFilter.of(Iterable<String> ids) : this._(ids.toSet(), 0, null);

  /// Every note [filters] hold, while they hold their ids as they are; null
  /// once any is [sized].
  static RecapFilter? union(Iterable<RecapFilter> filters) {
    final ids = <String>{};
    for (final filter in filters) {
      if (filter._ids == null) return null;
      ids.addAll(filter._ids);
    }
    return RecapFilter._(ids, 0, null, wholeSalt);
  }

  static const int wholeSalt = 0x7f4a7c15;

  /// Null for anything that is not one a record wrote. [whole] for the
  /// filter of a whole recap's notes.
  static RecapFilter? fromJson(
    Object? hashes,
    Object? bits, {
    bool whole = false,
  }) {
    if (hashes is! int || hashes < 1 || hashes > maxHashes || bits is! String) {
      return null;
    }
    try {
      final bytes = base64Decode(bits);
      return bytes.isEmpty
          ? null
          : RecapFilter._(null, hashes, bytes, whole ? wholeSalt : 0);
    } on FormatException {
      return null;
    }
  }

  /// Bits a note when there is room: about three false matches in a
  /// thousand.
  static const int bitsPerNote = 12;

  /// The least a filter takes, in bytes. Its size is always a multiple of
  /// three bytes, so its base64 has no padding.
  static const int minBytes = 9;
  static const int maxHashes = 16;

  final Set<String>? _ids;
  final Uint8List? _bits;
  final int _salt;

  /// How many bits each note sets; 0 while it holds the ids as they are.
  final int hashes;

  /// The bytes it takes at [bitsPerNote]: what [sized] gives it where there
  /// is room. One a record wrote keeps its own.
  int get bytes {
    if (_bits case final bits?) return bits.length;
    return max(minBytes, ((_ids!.length * bitsPerNote / 8) / 3).ceil() * 3);
  }

  /// Whether [id] may be among the notes: false only when it is not.
  bool mayHold(String id) {
    if (_ids case final ids?) return ids.contains(id);
    final bits = _bits!;
    return _indices(
      id,
      _salt,
      hashes,
      bits.length * 8,
    ).every((bit) => bits[bit >> 3] & (1 << (bit & 7)) != 0);
  }

  /// As a record keeps it, in [size] bytes, or as it is when it is one.
  RecapFilter sized(int size) {
    final ids = _ids;
    if (ids == null) return this;
    final length = max(minBytes, size ~/ 3 * 3);
    final bits = Uint8List(length);
    final count = length * 8;
    final hashes = ids.isEmpty
        ? 1
        : (count / ids.length * ln2).round().clamp(1, maxHashes);
    for (final id in ids) {
      for (final bit in _indices(id, _salt, hashes, count)) {
        bits[bit >> 3] |= 1 << (bit & 7);
      }
    }
    return RecapFilter._(null, hashes, bits, _salt);
  }

  /// Its bits, once [sized].
  String toBase64() => base64Encode(_bits!);
}

Iterable<int> _indices(String id, int salt, int hashes, int count) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(id)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  hash ^= salt;
  final first = _mix(hash);
  final second = _mix(hash ^ 0x9e3779b9) | 1;
  return [for (var i = 0; i < hashes; i++) (first + i * second) % count];
}

/// MurmurHash3's finalizer, which spreads FNV-1a's bits.
int _mix(int hash) {
  var h = hash;
  h ^= h >> 16;
  h = (h * 0x85ebca6b) & 0xffffffff;
  h ^= h >> 13;
  h = (h * 0xc2b2ae35) & 0xffffffff;
  return h ^ (h >> 16);
}
