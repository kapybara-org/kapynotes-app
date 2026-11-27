import 'dart:convert';
import 'dart:typed_data';

/// Which notes one part of a recap, or all of it, could read. Made from the
/// notes' ids, it holds them as they are; a recap's record keeps it as a
/// Golomb-coded set sized to its room ([sized]), which may say a note was
/// read when it was not but never the other way round, so a reopened recap
/// leaves out too much rather than too little.
///
/// Records keep the set, so its coding never changes. Each id is hashed with
/// FNV-1a, 32-bit, over its UTF-8, XORed with the filter's salt and spread
/// by MurmurHash3's finalizer, then put in one of [count] × [m] slots, as
/// the hash times the slots shifted right by 32. The slots are sorted and
/// the gaps between them, the first from 0, Rice-coded in k bits, the
/// largest k whose 2^k is at most m × ln 2 (m × 45426 >> 16): the gap's high
/// part as that many 1 bits and a 0, then its low k bits, most significant
/// first. Two bytes come first: the low 16 bits of MurmurHash3's finalizer
/// over FNV-1a of the count, m and every slot, each as four bytes, least
/// significant first. The bits fill the bytes after them from the top,
/// padded with 1 bits to a multiple of three bytes, so the base64 has no
/// padding and no slot can be read out of it. A part's salt is 0, and the
/// filter of a whole recap's notes ([union]) has [wholeSalt], so its false
/// matches fall apart from the parts'.
///
/// A set is read only when it decodes to exactly [count] slots, each inside
/// the slots, that its two bytes check and that code back to the very bytes
/// it came in; anything else reads as no filter at all, which may hold
/// every note.
class RecapFilter {
  RecapFilter._(
    this._ids,
    this._salt,
    this.count,
    this.m,
    this._slots,
    this._bytes,
  );

  RecapFilter.of(Iterable<String> ids) : this._held(ids.toSet(), 0);

  RecapFilter._held(Set<String> ids, int salt)
    : this._(ids, salt, ids.length, 0, null, null);

  /// One that holds every note, for a set too big for its room. A record
  /// writes it with no bits, which reads as no filter at all.
  RecapFilter._all(int count, int salt)
    : this._(null, salt, count, 1, null, Uint8List(0));

  /// Every note [filters] hold, while they hold their ids as they are; null
  /// once any is [sized].
  static RecapFilter? union(Iterable<RecapFilter> filters) {
    final ids = <String>{};
    for (final filter in filters) {
      if (filter._ids == null) return null;
      ids.addAll(filter._ids);
    }
    return RecapFilter._held(ids, wholeSalt);
  }

  static const int wholeSalt = 0x7f4a7c15;

  /// The slots a note takes where there is room: about one false match in a
  /// thousand, for some 11 bits a note.
  static const int roomyM = 1024;

  /// The most a record's set may have, which keeps every slot under 2^31.
  static const int mMax = 1 << 16;

  /// Null for anything that is not a set a record wrote. [whole] for the
  /// filter of a whole recap's notes.
  static RecapFilter? fromJson(
    Object? count,
    Object? m,
    Object? bits, {
    bool whole = false,
  }) {
    if (count is! int ||
        count < 0 ||
        m is! int ||
        m < 1 ||
        m > mMax ||
        bits is! String) {
      return null;
    }
    final slots = count * m;
    if (slots >= 1 << 31) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(bits);
    } on FormatException {
      return null;
    }
    final decoded = _decode(bytes, count, m);
    if (decoded == null) return null;
    return RecapFilter._(null, whole ? wholeSalt : 0, count, m, decoded, bytes);
  }

  final Set<String>? _ids;
  final int _salt;
  final List<int>? _slots;
  final Uint8List? _bytes;

  /// How many notes it holds.
  final int count;

  /// The slots each takes once [sized]; 0 while it holds the ids as they
  /// are.
  final int m;

  /// The bytes it takes at [roomyM]: what [sized] gives it where there is
  /// room. One a record wrote keeps its own.
  int get bytes =>
      _bytes?.length ?? _encode(_slotsAt(roomyM), _ids!.length, roomyM).length;

  /// Whether [id] may be among the notes: false only when it is not.
  bool mayHold(String id) {
    if (_ids case final ids?) return ids.contains(id);
    final slots = _slots;
    if (slots == null) return true;
    final slot = (_hash(id, _salt) * count * m) >> 32;
    var low = 0;
    var high = slots.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (slots[middle] < slot) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low < slots.length && slots[low] == slot;
  }

  /// As a record keeps it, in at most [size] bytes, with the most slots a
  /// note up to [roomyM] that fit, or as it is when it is one. Where not
  /// even one slot a note fits, it holds every note.
  RecapFilter sized(int size) {
    final ids = _ids;
    if (ids == null) return this;
    final hashes = [for (final id in ids) _hash(id, _salt)];
    RecapFilter? at(int m) {
      final slots = [
        for (final hash in hashes) (hash * hashes.length * m) >> 32,
      ]..sort();
      final bytes = _encode(slots, hashes.length, m);
      return bytes.length <= size
          ? RecapFilter._(null, _salt, hashes.length, m, slots, bytes)
          : null;
    }

    if (at(roomyM) case final roomy?) return roomy;
    var fits = at(1);
    if (fits == null) return RecapFilter._all(hashes.length, _salt);
    var low = 1;
    var high = roomyM;
    while (high - low > 1) {
      final middle = (low + high) >> 1;
      if (at(middle) case final it?) {
        low = middle;
        fits = it;
      } else {
        high = middle;
      }
    }
    return fits!;
  }

  /// Its set, once [sized].
  String toBase64() => base64Encode(_bytes!);

  /// How often it says it may hold a note it does not: the share of its
  /// slots taken. 0 while it holds the ids as they are, 1 where it holds
  /// every note.
  double get falseRate {
    if (_ids != null) return 0;
    final slots = _slots;
    if (slots == null) return 1;
    var taken = 0;
    for (final (index, slot) in slots.indexed) {
      if (index == 0 || slots[index - 1] != slot) taken++;
    }
    return taken == 0 ? 0 : taken / (count * m);
  }

  List<int> _slotsAt(int m) =>
      [for (final id in _ids!) (_hash(id, _salt) * _ids.length * m) >> 32]
        ..sort();
}

int _hash(String id, int salt) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(id)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return _mix(hash ^ salt);
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

int _riceBits(int m) {
  final bits = ((m * 45426) >> 16).bitLength - 1;
  return bits < 0 ? 0 : bits;
}

int _check(int count, int m, List<int> slots) {
  var hash = 0x811c9dc5;
  void add(int value) {
    for (var shift = 0; shift < 32; shift += 8) {
      hash = ((hash ^ ((value >> shift) & 0xff)) * 0x01000193) & 0xffffffff;
    }
  }

  add(count);
  add(m);
  slots.forEach(add);
  return _mix(hash) & 0xffff;
}

/// [slots], sorted, as a record keeps them.
Uint8List _encode(List<int> slots, int count, int m) {
  final k = _riceBits(m);
  final check = _check(count, m, slots);
  final out = BytesBuilder(copy: false)
    ..addByte(check >> 8)
    ..addByte(check & 0xff);
  var byte = 0;
  var filled = 0;
  void bit(int value) {
    byte = (byte << 1) | value;
    if (++filled == 8) {
      out.addByte(byte);
      byte = 0;
      filled = 0;
    }
  }

  var previous = 0;
  for (final slot in slots) {
    final gap = slot - previous;
    previous = slot;
    for (var high = gap >> k; high > 0; high--) {
      bit(1);
    }
    bit(0);
    for (var i = k - 1; i >= 0; i--) {
      bit((gap >> i) & 1);
    }
  }
  while (filled > 0) {
    bit(1);
  }
  while (out.length % 3 != 0) {
    out.addByte(0xff);
  }
  return out.takeBytes();
}

/// The [count] slots [bytes] hold, or null unless they decode to exactly
/// that many, each under count × [m], that the check matches and that code
/// back to [bytes] themselves.
List<int>? _decode(Uint8List bytes, int count, int m) {
  final k = _riceBits(m);
  final slots = count * m;
  if (bytes.length < 3) return null;
  final total = bytes.length * 8;
  var at = 16;
  int? bit() {
    if (at >= total) return null;
    final value = (bytes[at >> 3] >> (7 - (at & 7))) & 1;
    at++;
    return value;
  }

  final decoded = <int>[];
  var previous = 0;
  for (var n = 0; n < count; n++) {
    var high = 0;
    while (true) {
      final value = bit();
      if (value == null || high > slots) return null;
      if (value == 0) break;
      high++;
    }
    var low = 0;
    for (var i = 0; i < k; i++) {
      final value = bit();
      if (value == null) return null;
      low = (low << 1) | value;
    }
    previous += (high << k) | low;
    if (previous >= slots) return null;
    decoded.add(previous);
  }
  if ((bytes[0] << 8 | bytes[1]) != _check(count, m, decoded)) return null;
  final again = _encode(decoded, count, m);
  if (again.length != bytes.length) return null;
  for (var i = 0; i < bytes.length; i++) {
    if (again[i] != bytes[i]) return null;
  }
  return decoded;
}
