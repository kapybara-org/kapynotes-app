import 'dart:convert';

/// A record the server is owed: its kind, its key (the record's own id, or
/// the note's id for a record about one note), the `updatedAt` to send, and
/// the payload, null for a deletion.
typedef OwedRecord = ({
  String kind,
  String key,
  int updatedAt,
  Map<String, Object?>? payload,
});

/// One record on this device: its value, the `updatedAt` the server orders
/// it by, whether it is deleted, and whether the server is owed it.
class RecordSlot<T> {
  RecordSlot(
    this.value,
    this.updatedAt, {
    this.deleted = false,
    this.dirty = false,
  });

  T value;
  int updatedAt;
  bool deleted;
  bool dirty;
}

/// One kind of record on the account's stream, by key, with the bookkeeping
/// `TaskIndex` keeps for tasks. Tags and folders keep theirs in these.
class RecordBook<T> {
  RecordBook({
    required this.keepDeleted,
    required this.merge,
    required this.encode,
    required this.decode,
  });

  /// Whether a deleted record stays once the server has it: a tag does, for
  /// Undo and so a note can tell how long ago it went; a note's tags go with
  /// the note.
  final bool keepDeleted;
  final T Function(T mine, T theirs) merge;
  final Map<String, Object?> Function(T value) encode;
  final T? Function(String key, Object? payload) decode;

  final Map<String, RecordSlot<T>> slots = {};

  T? live(String key) {
    final slot = slots[key];
    return slot == null || slot.deleted ? null : slot.value;
  }

  bool get owes => slots.values.any((slot) => slot.dirty);

  /// The next `updatedAt` after [slot]'s: now, or one past it if the clock
  /// has not moved on, so a local change always outranks what it replaces.
  static int _after(RecordSlot<Object?>? slot, int now) {
    final last = slot?.updatedAt ?? 0;
    return now > last ? now : last + 1;
  }

  void write(String key, T value, int now) {
    slots[key] = RecordSlot(value, _after(slots[key], now), dirty: true);
  }

  void delete(String key, int now) {
    final slot = slots[key]!;
    slot
      ..updatedAt = _after(slot, now)
      ..deleted = true
      ..dirty = true;
  }

  List<OwedRecord> owed(String kind) => [
    for (final entry in slots.entries)
      if (entry.value.dirty)
        (
          kind: kind,
          key: entry.key,
          updatedAt: entry.value.updatedAt,
          payload: entry.value.deleted ? null : encode(entry.value.value),
        ),
  ];

  void acknowledge(String key, int updatedAt) {
    final slot = slots[key];
    if (slot == null || slot.updatedAt != updatedAt) return;
    slot.dirty = false;
    if (slot.deleted && !keepDeleted) slots.remove(key);
  }

  void applyRemote(String key, T remote, int updatedAt) {
    final slot = slots[key];
    if (slot == null) {
      slots[key] = RecordSlot(remote, updatedAt);
      return;
    }
    if (slot.deleted && slot.dirty && slot.updatedAt > updatedAt) return;
    if (slot.deleted || !slot.dirty) {
      final merged = merge(remote, slot.value);
      final same = jsonEncode(encode(merged)) == jsonEncode(encode(remote));
      slot
        ..value = merged
        ..deleted = false
        ..updatedAt = same ? updatedAt : updatedAt + 1
        ..dirty = !same;
      return;
    }
    slot
      ..value = merge(slot.value, remote)
      ..updatedAt = slot.updatedAt > updatedAt ? slot.updatedAt : updatedAt + 1;
  }

  /// Whether it changed anything.
  bool applyRemoteDelete(String key, int updatedAt) {
    final slot = slots[key];
    if (slot == null || (slot.deleted && !slot.dirty)) return false;
    if (slot.dirty && slot.updatedAt > updatedAt) return false;
    if (!keepDeleted) {
      slots.remove(key);
      return true;
    }
    slot
      ..updatedAt = updatedAt
      ..deleted = true
      ..dirty = false;
    return true;
  }

  void forgetAccount() {
    slots.removeWhere((_, slot) => slot.deleted && !keepDeleted);
    for (final slot in slots.values) {
      if (!slot.deleted) slot.dirty = true;
    }
  }

  List<Map<String, Object?>> toJson() => [
    for (final entry in slots.entries)
      {
        'key': entry.key,
        'updatedAt': entry.value.updatedAt,
        if (entry.value.deleted) 'deleted': true,
        if (entry.value.dirty) 'dirty': true,
        'payload': encode(entry.value.value),
      },
  ];

  void load(Object? raw) {
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final key = item['key'];
      final updatedAt = item['updatedAt'];
      if (key is! String || updatedAt is! int) continue;
      final value = decode(key, item['payload']);
      if (value == null) continue;
      slots[key] = RecordSlot(
        value,
        updatedAt,
        deleted: item['deleted'] == true,
        dirty: item['dirty'] == true,
      );
    }
  }
}

/// The fields of [raw] a reader does not know, kept to be written back.
Map<String, Object?> extraOf(Map<Object?, Object?> raw, Set<String> known) => {
  for (final entry in raw.entries)
    if (entry.key is String && !known.contains(entry.key))
      entry.key as String: entry.value,
};
