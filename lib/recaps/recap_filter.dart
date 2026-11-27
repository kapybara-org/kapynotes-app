import 'dart:convert';
import 'dart:typed_data';

/// Which notes one part of a recap could read, kept small enough for the
/// recap's record: a 256-bit Bloom filter, three bits a note. It may say a
/// note was read when it was not, but never the other way round, so a
/// reopened recap leaves out too much rather than too little.
///
/// Records keep it, so its size and hashing never change: FNV-1a, 32-bit,
/// over the id's UTF-8, its halves double-hashed into the bits.
class RecapFilter {
  RecapFilter._(this._bits);

  factory RecapFilter.of(Iterable<String> ids) {
    final bits = Uint8List(bytes);
    for (final id in ids) {
      for (final bit in _bitsOf(id)) {
        bits[bit >> 3] |= 1 << (bit & 7);
      }
    }
    return RecapFilter._(bits);
  }

  /// Null for anything that is not one written by [toBase64].
  static RecapFilter? fromBase64(Object? raw) {
    if (raw is! String) return null;
    try {
      final bits = base64Decode(raw);
      return bits.length == bytes ? RecapFilter._(bits) : null;
    } on FormatException {
      return null;
    }
  }

  /// 256 bits.
  static const int bytes = 32;

  final Uint8List _bits;

  /// Whether [id] may be among the notes: false only when it is not.
  bool mayHold(String id) =>
      _bitsOf(id).every((bit) => _bits[bit >> 3] & (1 << (bit & 7)) != 0);

  /// The notes either holds.
  RecapFilter operator |(RecapFilter other) => RecapFilter._(
    Uint8List.fromList([
      for (var i = 0; i < bytes; i++) _bits[i] | other._bits[i],
    ]),
  );

  String toBase64() => base64Encode(_bits);
}

List<int> _bitsOf(String id) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(id)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  final step = (hash >> 16) | 1;
  return [for (var i = 0; i < 3; i++) (hash + i * step) & 0xff];
}
