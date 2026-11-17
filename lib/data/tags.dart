import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'notes_store.dart';
import 'stamped.dart';

/// The colours a tag can take, in palette order. A tag stores one of these
/// keys, never a colour, so the theme decides how each looks in dark and light.
const List<String> tagColours = [
  'mustard',
  'rust',
  'olive',
  'teal',
  'sage',
  'slate',
  'plum',
  'rose',
];

/// A tag with no colour: the plain card, and a ring for its dot.
const String noTagColour = 'none';

/// The longest a tag's name may be, in characters.
const int tagNameMax = 32;

/// The most tags one note carries.
const int noteTagsMax = 20;

/// One of the person's tags: the plaintext of a tag record, whose id is the
/// tag's own. Mirrors `TagPayload` in packages/contract.
@immutable
class Tag {
  const Tag({
    required this.id,
    required this.name,
    required this.colour,
    required this.order,
    required this.createdAt,
    this.extra = const {},
  });

  static const String kind = 'tag';

  final String id;
  final Stamped<String> name;

  /// One of [tagColours] or [noTagColour]. A key from a later build is kept.
  final Stamped<String> colour;

  /// Where it sits in the person's list. A tie goes to the lower id.
  final Stamped<int> order;
  final int createdAt;

  /// Fields a later build wrote, kept and written back untouched.
  final Map<String, Object?> extra;

  static const _known = {'id', 'kind', 'name', 'colour', 'order', 'createdAt'};

  Tag copyWith({
    Stamped<String>? name,
    Stamped<String>? colour,
    Stamped<int>? order,
  }) => Tag(
    id: id,
    name: name ?? this.name,
    colour: colour ?? this.colour,
    order: order ?? this.order,
    createdAt: createdAt,
    extra: extra,
  );

  /// Field by field, the same whichever side merges.
  Tag merge(Tag other) => Tag(
    id: id,
    name: name.merge(other.name),
    colour: colour.merge(other.colour),
    order: order.merge(other.order),
    createdAt: createdAt < other.createdAt ? createdAt : other.createdAt,
    extra: mergeExtra(extra, other.extra),
  );

  Map<String, Object?> toPayload() => {
    ...extra,
    'id': id,
    'kind': kind,
    'name': name.toJson(),
    'colour': colour.toJson(),
    'order': order.toJson(),
    'createdAt': createdAt,
  };

  /// Null for a payload missing anything this build needs, or sealed for
  /// another tag: a payload names its own id, so one moved or replayed onto
  /// another record is refused. A name past [tagNameMax] runes is cut, so
  /// every list, merge and save here sees the same name.
  static Tag? fromPayload(String id, Object? raw) {
    if (raw is! Map || raw['id'] != id) return null;
    final name = Stamped.fromJson<String>(raw['name']);
    final colour = Stamped.fromJson<String>(raw['colour']);
    final order = Stamped.fromJson<int>(raw['order']);
    final createdAt = raw['createdAt'];
    if (name == null || colour == null || order == null || createdAt is! int) {
      return null;
    }
    return Tag(
      id: id,
      name: Stamped(
        String.fromCharCodes(name.v.runes.take(tagNameMax)),
        name.at,
      ),
      colour: colour,
      order: order,
      createdAt: createdAt,
      extra: _extraOf(raw, _known),
    );
  }
}

/// Which tags one note carries: the plaintext of a note's tags record, whose
/// id derives from [noteId] (`Vault.noteTagsRecordId`). Mirrors
/// `NoteTagsPayload` in packages/contract.
///
/// Each tag is on or off with its own stamp, so a tag added on one device and
/// another taken off on a second both hold; [order] is how they read.
@immutable
class NoteTags {
  const NoteTags({
    required this.noteId,
    this.tags = const {},
    this.order = const Stamped(<String>[], 0),
    this.extra = const {},
  });

  static const String kind = 'noteTags';

  final String noteId;
  final Map<String, Stamped<bool>> tags;
  final Stamped<List<String>> order;

  /// Fields a later build wrote, kept and written back untouched.
  final Map<String, Object?> extra;

  static const _known = {'kind', 'noteId', 'tags', 'order'};

  /// The ids that are on, in reading order: [order] first, then any other by
  /// when it went on.
  List<String> get onIds {
    final on = {
      for (final entry in tags.entries)
        if (entry.value.v) entry.key,
    };
    final read = [
      for (final id in order.v)
        if (on.remove(id)) id,
    ];
    final rest = on.toList()
      ..sort((a, b) {
        final byAdded = tags[a]!.at.compareTo(tags[b]!.at);
        return byAdded != 0 ? byAdded : a.compareTo(b);
      });
    return read..addAll(rest);
  }

  /// Tag by tag, then the order, the same whichever side merges.
  NoteTags merge(NoteTags other) => NoteTags(
    noteId: noteId,
    tags: {
      for (final id in {...tags.keys, ...other.tags.keys})
        id: tags[id] == null
            ? other.tags[id]!
            : tags[id]!.merge(other.tags[id] ?? tags[id]!),
    },
    order: order.merge(other.order),
    extra: mergeExtra(extra, other.extra),
  );

  Map<String, Object?> toPayload() => {
    ...extra,
    'kind': kind,
    'noteId': noteId,
    'tags': {for (final entry in tags.entries) entry.key: entry.value.toJson()},
    'order': order.toJson(),
  };

  /// Null for a payload missing anything this build needs.
  static NoteTags? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final noteId = raw['noteId'];
    final tags = raw['tags'];
    final order = raw['order'];
    if (noteId is! String || tags is! Map || order is! Map) return null;
    final ids = order['v'];
    final at = order['at'];
    if (ids is! List || at is! int || ids.any((id) => id is! String)) {
      return null;
    }
    final stamps = <String, Stamped<bool>>{};
    for (final entry in tags.entries) {
      final stamp = Stamped.fromJson<bool>(entry.value);
      if (entry.key is! String || stamp == null) return null;
      stamps[entry.key as String] = stamp;
    }
    return NoteTags(
      noteId: noteId,
      tags: stamps,
      order: Stamped(List.unmodifiable(ids.cast<String>()), at),
      extra: _extraOf(raw, _known),
    );
  }
}

/// A record the server is owed: its kind, its key (a tag's id, or the note's
/// id for a note's tags), the `updatedAt` to send, and the payload, null for
/// a deletion.
typedef OwedTagRecord = ({
  String kind,
  String key,
  int updatedAt,
  Map<String, Object?>? payload,
});

/// The person's tags and which notes carry them. Kept on this device signed
/// in or not, and synced on the account's record stream beside the task
/// index, as one record per tag and one per tagged note (see `TaskSync`).
///
/// Every field carries its own stamp and merges here, never on the server,
/// which orders whole records by `updatedAt`.
class TagStore extends ChangeNotifier {
  TagStore(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final LocalStore _store;
  final DateTime Function() _now;

  static const String _key = 'tags.v1';

  /// How long a note keeps its place for a deleted tag, so Undo can put the
  /// tag back where it was. Its record drops the entry the next time it is
  /// written after that.
  static const Duration deletedTagKept = Duration(days: 30);

  /// The longest note's tags payload a record can carry: 4096 base64
  /// characters of ciphertext (`TASK_PAYLOAD_MAX_CHARS`) less the 16-byte tag.
  static const int _payloadMax = 4096 ~/ 4 * 3 - 16;

  final _tags = _Book<Tag>(
    keepDeleted: true,
    merge: (mine, theirs) => mine.merge(theirs),
    encode: (tag) => tag.toPayload(),
    decode: Tag.fromPayload,
  );

  /// Keyed by note id.
  final _notes = _Book<NoteTags>(
    keepDeleted: false,
    merge: (mine, theirs) => mine.merge(theirs),
    encode: (note) => note.toPayload(),
    decode: (noteId, raw) {
      final note = NoteTags.fromPayload(raw);
      return note?.noteId == noteId ? note : null;
    },
  );

  /// Records of a kind a later build writes, by record id, with the
  /// 'updatedAt' the server orders them by. Only that: what such a record
  /// holds is never kept, so a stream of them cannot grow this file.
  final Map<String, int> _unknown = {};

  int _stamp() => _now().millisecondsSinceEpoch;

  Future<bool>? _loading;

  /// Reads what this device holds, once. False when it held nothing yet,
  /// which a build from before tags leaves behind; the record is written at
  /// once, so that is false only the first time.
  Future<bool> load() => _loading ??= _load();

  Future<bool> _load() async {
    await _store.load();
    final raw = _store.data[_key];
    if (raw is! Map) {
      _store.put(_key, _toJson());
      return false;
    }
    _tags.load(raw['tags']);
    _notes.load(raw['notes']);
    final unknown = raw['unknown'];
    if (unknown is List) {
      for (final item in unknown) {
        if (item is! Map) continue;
        final id = item['id'];
        final updatedAt = item['updatedAt'];
        if (id is String && updatedAt is int) _unknown[id] = updatedAt;
      }
    }
    return true;
  }

  Map<String, Object?> _toJson() => {
    'tags': _tags.toJson(),
    'notes': _notes.toJson(),
    'unknown': [
      for (final entry in _unknown.entries)
        {'id': entry.key, 'updatedAt': entry.value},
    ],
  };

  bool _held = false;
  bool _pending = false;

  /// Keeps what is changed in memory and unsaved until [release], so a pull
  /// of many records writes once instead of once per record.
  void hold() => _held = true;

  void release() {
    _held = false;
    if (_pending) _save();
  }

  void _save() {
    if (_held) {
      _pending = true;
      return;
    }
    _pending = false;
    _store.put(_key, _toJson());
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Tags

  /// Every live tag, in the person's order.
  List<Tag> get tags =>
      [
        for (final slot in _tags.slots.values)
          if (!slot.deleted) slot.value,
      ]..sort((a, b) {
        final byOrder = a.order.v.compareTo(b.order.v);
        return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
      });

  /// A live tag.
  Tag? byId(String id) => _tags.live(id);

  /// The live tag with this name ignoring case, or a new one with the least
  /// used colour at the end of the list. Null for a name that is empty or
  /// longer than [tagNameMax] once trimmed.
  Tag? create(String name) {
    final trimmed = _validName(name);
    if (trimmed == null) return null;
    final existing = named(trimmed);
    if (existing != null) return existing;
    final now = _stamp();
    final live = tags;
    final uses = {for (final colour in tagColours) colour: 0};
    for (final tag in live) {
      uses.update(tag.colour.v, (n) => n + 1, ifAbsent: () => 0);
    }
    final tag = Tag(
      id: NotesStore.newId(),
      name: Stamped(trimmed, now),
      colour: Stamped(
        tagColours.reduce((best, c) => uses[c]! < uses[best]! ? c : best),
        now,
      ),
      order: Stamped(live.isEmpty ? 0 : live.last.order.v + 1, now),
      createdAt: now,
    );
    _tags.write(tag.id, tag, now);
    _save();
    return tag;
  }

  /// False, changing nothing, for a name that is empty, too long or another
  /// live tag's.
  bool rename(String id, String name) {
    final tag = _tags.live(id);
    final trimmed = _validName(name);
    if (tag == null || trimmed == null) return false;
    if (named(trimmed)?.id case final other? when other != id) return false;
    if (tag.name.v != trimmed) {
      _update(tag.copyWith(name: Stamped(trimmed, _stamp())));
    }
    return true;
  }

  /// [colour] is one of [tagColours] or [noTagColour].
  void recolour(String id, String colour) {
    final tag = _tags.live(id);
    if (tag == null || tag.colour.v == colour) return;
    if (colour != noTagColour && !tagColours.contains(colour)) return;
    _update(tag.copyWith(colour: Stamped(colour, _stamp())));
  }

  /// Puts every live tag in the order of [ids].
  void reorder(List<String> ids) {
    final now = _stamp();
    for (var i = 0; i < ids.length; i++) {
      final tag = _tags.live(ids[i]);
      if (tag == null || tag.order.v == i) continue;
      _tags.write(tag.id, tag.copyWith(order: Stamped(i, now)), now);
    }
    _save();
  }

  /// Deletes a tag and nothing else: each note keeps its place for it, and
  /// reads past it, so [restore] puts it back on the same notes in the same
  /// position.
  void delete(String id) {
    if (_tags.live(id) == null) return;
    _tags.delete(id, _stamp());
    _save();
  }

  /// Undoes [delete], on every device.
  void restore(String id) {
    final slot = _tags.slots[id];
    if (slot == null || !slot.deleted) return;
    _tags.write(id, slot.value, _stamp());
    _merge();
    _save();
  }

  void _update(Tag tag) {
    _tags.write(tag.id, tag, _stamp());
    _save();
  }

  static String? _validName(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty || trimmed.runes.length > tagNameMax
        ? null
        : trimmed;
  }

  /// Live tags, earliest created first; a tie goes to the lower id.
  List<Tag> _byAge() =>
      [
        for (final slot in _tags.slots.values)
          if (!slot.deleted) slot.value,
      ]..sort((a, b) {
        final byAge = a.createdAt.compareTo(b.createdAt);
        return byAge != 0 ? byAge : a.id.compareTo(b.id);
      });

  /// The live tag called [name], ignoring case and the space around it.
  Tag? named(String name) {
    final wanted = name.trim().toLowerCase();
    for (final tag in _byAge()) {
      if (tag.name.v.trim().toLowerCase() == wanted) return tag;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Notes

  /// The live tags [noteId] carries, in its order. The first colours it.
  List<Tag> tagsOf(String noteId) => [
    for (final id in _notes.live(noteId)?.onIds ?? const <String>[])
      ?_tags.live(id),
  ];

  /// Sets the tags [noteId] carries, in this order. False, changing nothing,
  /// for more than [noteTagsMax], a repeat, or a tag that is not live.
  bool setTags(String noteId, List<String> tagIds) {
    if (tagIds.length > noteTagsMax ||
        tagIds.toSet().length != tagIds.length ||
        tagIds.any((id) => _tags.live(id) == null)) {
      return false;
    }
    final current = _notes.live(noteId) ?? NoteTags(noteId: noteId);
    final now = _stamp();
    final wanted = tagIds.toSet();
    final stamps = {...current.tags};
    for (final id in tagIds) {
      if (stamps[id]?.v != true) stamps[id] = Stamped(true, now);
    }
    final onIds = current.onIds;
    for (final id in onIds) {
      if (!wanted.contains(id) && _tags.live(id) != null) {
        stamps[id] = Stamped(false, now);
      }
    }
    // A deleted tag keeps its place among the live ones, for Undo.
    final order = <String>[];
    var next = 0;
    for (final id in onIds) {
      if (_tags.live(id) == null) {
        order.add(id);
      } else if (next < tagIds.length) {
        order.add(tagIds[next++]);
      }
    }
    order.addAll(tagIds.skip(next));
    final note = NoteTags(
      noteId: noteId,
      tags: stamps,
      order: listEquals(order, current.order.v)
          ? current.order
          : Stamped(List.unmodifiable(order), now),
      extra: current.extra,
    );
    if (jsonEncode(note.toPayload()) == jsonEncode(current.toPayload())) {
      return true;
    }
    _putNote(note, now);
    _save();
    return true;
  }

  /// Adds a tag at the end of [noteId]'s. False at [noteTagsMax] tags.
  bool addTag(String noteId, String tagId) {
    final ids = [for (final tag in tagsOf(noteId)) tag.id];
    return ids.contains(tagId) || setTags(noteId, [...ids, tagId]);
  }

  void removeTag(String noteId, String tagId) => setTags(noteId, [
    for (final tag in tagsOf(noteId))
      if (tag.id != tagId) tag.id,
  ]);

  /// A note deleted for good takes its tags record with it.
  void forgetNote(String noteId) {
    if (_notes.live(noteId) == null) return;
    _notes.delete(noteId, _stamp());
    _save();
  }

  /// Writes a note's tags, first dropping its entries for tags deleted more
  /// than [deletedTagKept] ago, then, while the payload is too long to send,
  /// the oldest entries that show nothing: a tag taken off, or one that is
  /// not live.
  void _putNote(NoteTags note, int now) {
    final cutoff = now - deletedTagKept.inMilliseconds;
    bool expired(String id) {
      final slot = _tags.slots[id];
      return slot != null && slot.deleted && slot.updatedAt < cutoff;
    }

    final stamps = {
      for (final entry in note.tags.entries)
        if (!expired(entry.key)) entry.key: entry.value,
    };
    NoteTags trimmed() => NoteTags(
      noteId: note.noteId,
      tags: stamps,
      order: Stamped(
        List.unmodifiable(note.order.v.where(stamps.containsKey)),
        note.order.at,
      ),
      extra: note.extra,
    );

    while (utf8.encode(jsonEncode(trimmed().toPayload())).length >
        _payloadMax) {
      final spare = stamps.entries
          .where((e) => !e.value.v || _tags.live(e.key) == null)
          .fold<MapEntry<String, Stamped<bool>>?>(
            null,
            (oldest, e) =>
                oldest == null || e.value.at < oldest.value.at ? e : oldest,
          );
      if (spare == null) break;
      stamps.remove(spare.key);
    }
    _notes.write(note.noteId, trimmed(), now);
  }

  // -------------------------------------------------------------------------
  // Two tags of one name

  /// Makes one tag of any two live ones whose names match ignoring case,
  /// which the same name created on two devices offline leaves behind. The
  /// earliest created stays, the lower id on a tie; each note moves from the
  /// other onto it in the same position, and the other is deleted. Every
  /// device chooses the same and writes the same, so they agree. For sync to
  /// call once what the server had is in.
  void settle() {
    if (_merge()) _save();
  }

  bool _merge() {
    final keepers = <String, String>{};
    final into = <String, String>{};
    for (final tag in _byAge()) {
      final name = tag.name.v.trim().toLowerCase();
      final keeper = keepers[name];
      if (keeper == null) {
        keepers[name] = tag.id;
      } else {
        into[tag.id] = keeper;
      }
    }
    if (into.isEmpty) return false;
    final now = _stamp();
    for (final slot in _notes.slots.values.toList()) {
      final note = slot.value;
      final onIds = note.onIds;
      if (slot.deleted || !onIds.any(into.containsKey)) continue;
      final stamps = {...note.tags};
      final order = <String>[];
      for (final id in onIds) {
        final keeper = into[id];
        if (keeper != null) {
          final moved = stamps[id]!;
          stamps[id] = Stamped(false, moved.at + 1);
          stamps[keeper] = stamps[keeper]?.merge(moved) ?? moved;
        }
        final target = keeper ?? id;
        if (!order.contains(target)) order.add(target);
      }
      _putNote(
        NoteTags(
          noteId: note.noteId,
          tags: stamps,
          order: Stamped(List.unmodifiable(order), note.order.at + 1),
          extra: note.extra,
        ),
        now,
      );
    }
    for (final id in into.keys) {
      _tags.delete(id, now);
    }
    return true;
  }

  // -------------------------------------------------------------------------
  // Sync

  /// The notes this device has a tags record for.
  Iterable<String> get noteIds => _notes.slots.keys;

  /// Whether the server is owed anything.
  bool get owes => _tags.owes || _notes.owes;

  /// What the server has not been told, live and deleted.
  List<OwedTagRecord> get owed => [
    ..._tags.owed(Tag.kind),
    ..._notes.owed(NoteTags.kind),
  ];

  /// The server took the record as sent. Anything changed since stays owed.
  void acknowledge(OwedTagRecord record) {
    (record.kind == Tag.kind ? _tags : _notes).acknowledge(
      record.key,
      record.updatedAt,
    );
    _save();
  }

  /// A live tag record as the server holds it, from a pull or a lost push.
  void applyRemoteTag(Tag tag, int updatedAt) {
    _tags.applyRemote(tag.id, tag, updatedAt);
    _save();
  }

  /// A live note's tags record as the server holds it.
  void applyRemoteNote(NoteTags note, int updatedAt) {
    _notes.applyRemote(note.noteId, note, updatedAt);
    _save();
  }

  /// A record of a kind this build does not know: its id and time, which
  /// ordering and a later delete need, and nothing it holds.
  void keepUnknown(String id, int updatedAt) {
    if ((_unknown[id] ?? -1) >= updatedAt) return;
    _unknown[id] = updatedAt;
    _save();
  }

  /// A deleted record as the server holds it: a tag by its id, a note's tags
  /// by [noteId] where the record id is known to be that note's. A newer
  /// local change survives it and goes up again.
  void applyRemoteDelete(String id, int updatedAt, {String? noteId}) {
    final changed =
        _tags.applyRemoteDelete(id, updatedAt) ||
        (noteId != null && _notes.applyRemoteDelete(noteId, updatedAt)) ||
        _unknown.remove(id) != null;
    if (changed) _save();
  }

  /// Signing out: the tags stay, and everything live is owed to the next
  /// account, whose record ids are its own. Records of unknown kinds were
  /// the account's, and go.
  void forgetAccount() {
    _tags.forgetAccount();
    _notes.forgetAccount();
    _unknown.clear();
    _save();
  }

  /// Drops everything, for notes let go of on signing in as someone else.
  void clear() {
    _tags.slots.clear();
    _notes.slots.clear();
    _unknown.clear();
    _save();
  }
}

/// One record on this device: its value, the `updatedAt` the server orders
/// it by, whether it is deleted, and whether the server is owed it.
class _Slot<T> {
  _Slot(this.value, this.updatedAt, {this.deleted = false, this.dirty = false});

  T value;
  int updatedAt;
  bool deleted;
  bool dirty;
}

/// One kind of record, by key, with the bookkeeping `TaskIndex` keeps for
/// tasks.
class _Book<T> {
  _Book({
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

  final Map<String, _Slot<T>> slots = {};

  T? live(String key) {
    final slot = slots[key];
    return slot == null || slot.deleted ? null : slot.value;
  }

  bool get owes => slots.values.any((slot) => slot.dirty);

  /// The next `updatedAt` after [slot]'s: now, or one past it if the clock
  /// has not moved on, so a local change always outranks what it replaces.
  static int _after(_Slot<Object?>? slot, int now) {
    final last = slot?.updatedAt ?? 0;
    return now > last ? now : last + 1;
  }

  void write(String key, T value, int now) {
    slots[key] = _Slot(value, _after(slots[key], now), dirty: true);
  }

  void delete(String key, int now) {
    final slot = slots[key]!;
    slot
      ..updatedAt = _after(slot, now)
      ..deleted = true
      ..dirty = true;
  }

  List<OwedTagRecord> owed(String kind) => [
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
      slots[key] = _Slot(remote, updatedAt);
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
      slots[key] = _Slot(
        value,
        updatedAt,
        deleted: item['deleted'] == true,
        dirty: item['dirty'] == true,
      );
    }
  }
}

Map<String, Object?> _extraOf(Map<Object?, Object?> raw, Set<String> known) => {
  for (final entry in raw.entries)
    if (entry.key is String && !known.contains(entry.key))
      entry.key as String: entry.value,
};
