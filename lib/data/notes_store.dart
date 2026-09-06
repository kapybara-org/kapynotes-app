import 'dart:math';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'note.dart';
import 'note_format.dart';
import 'tombstone.dart';

/// Owns the note list and its persistence.
///
/// Notes are held newest-first. Every mutation updates memory synchronously
/// and schedules a coalesced disk write, so the UI never waits on I/O.
///
/// Deleted notes leave a [Tombstone] behind rather than vanishing, because a
/// deletion that is merely an absence gets undone by the next device to sync.
/// Live notes and tombstones are kept in separate lists so that reading
/// [notes] — which happens on every rebuild — never has to filter.
///
/// Every note belongs to a space — null for the personal one — and a
/// tombstone is scoped to the space the note was deleted from. A note that
/// moves between spaces leaves a tombstone behind where it was, because the
/// devices pulling that space would otherwise never see it leave.
///
/// Nothing here is encrypted. Notes sit on local disk as plaintext JSON
/// exactly as they always have, so opening the app costs no crypto; sealing
/// happens in the sync layer, on the way out.
class NotesStore extends ChangeNotifier {
  static const String _key = 'notes.v2';
  static const String _legacyKey = 'notes.v1';

  final LocalStore _store;
  final DateTime Function() _now;
  List<Note> _notes = const [];
  List<Tombstone> _tombstones = const [];
  bool _loaded = false;
  Future<void>? _loadFuture;

  /// Serialized form of each note, kept against the instance it came from.
  ///
  /// Notes are immutable, so an entry stays valid until the note is replaced.
  /// Without this, every keystroke rebuilt the JSON for every note the user
  /// owns; with it, only the note actually edited is re-encoded.
  final Map<String, ({Note note, Map<String, Object?> json})> _encoded = {};

  NotesStore(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  List<Note> get notes => _notes;
  List<Tombstone> get tombstones => _tombstones;
  bool get isLoaded => _loaded;
  bool get isEmpty => _notes.isEmpty;

  /// The note whose contents changed most recently.
  Note? get lastEditedNote => _notes.isEmpty ? null : _notes.first;

  /// Notes the server does not yet hold this revision of.
  List<Note> get dirtyNotes =>
      _notes.where((note) => note.isDirty).toList(growable: false);

  /// Deletions the server has not yet acknowledged.
  List<Tombstone> get dirtyTombstones =>
      _tombstones.where((stone) => stone.isDirty).toList(growable: false);

  bool get hasPendingChanges =>
      _notes.any((note) => note.isDirty) ||
      _tombstones.any((stone) => stone.isDirty);

  /// The notes in one space, newest first. Null is the personal space.
  List<Note> notesIn(String? spaceId) =>
      _notes.where((note) => note.spaceId == spaceId).toList(growable: false);

  /// Every shared space that has a note in it locally.
  Set<String> get spaceIds => {
    for (final note in _notes)
      if (note.spaceId != null) note.spaceId!,
  };

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    await _store.load();

    final stored = _store.read<Map<String, Object?>>(_key);
    if (stored != null) {
      _notes = _sortedNotes(stored['notes']);
      _tombstones = _readTombstones(stored['tombstones']);
      _purgeExpiredTombstones();
    } else {
      // A store written by a build that predates sync. Read it, then write the
      // new shape; the rename in LocalStore makes that swap atomic, so there is
      // no moment where neither key holds the notes.
      final legacy = _store.read<List<Object?>>(_legacyKey);
      if (legacy != null) {
        _notes = _sortedNotes(legacy);
        // Every migrated note is left dirty on purpose: the server has never
        // seen any of them, and the first sync should push the lot.
        _store.put(_legacyKey, null);
        _persist();
      }
    }

    _loaded = true;
    notifyListeners();
  }

  List<Note> _sortedNotes(Object? raw) {
    if (raw is! List) return const [];
    final notes = <({int storedIndex, Note note})>[];
    for (var index = 0; index < raw.length; index++) {
      final note = Note.fromJson(raw[index]);
      if (note != null) notes.add((storedIndex: index, note: note));
    }
    notes.sort((a, b) {
      final recency = b.note.updatedAt.compareTo(a.note.updatedAt);
      return recency != 0 ? recency : a.storedIndex.compareTo(b.storedIndex);
    });
    return List.unmodifiable(notes.map((entry) => entry.note));
  }

  List<Tombstone> _readTombstones(Object? raw) {
    if (raw is! List) return const [];
    return List.unmodifiable(
      raw.map(Tombstone.fromJson).whereType<Tombstone>(),
    );
  }

  void _purgeExpiredTombstones() {
    final now = _now();
    if (!_tombstones.any((stone) => stone.isExpired(now))) return;
    _tombstones = List.unmodifiable(
      _tombstones.where((stone) => !stone.isExpired(now)),
    );
  }

  Note? byId(String? id) {
    if (id == null) return null;
    for (final note in _notes) {
      if (note.id == id) return note;
    }
    return null;
  }

  int indexOf(String id) => _notes.indexWhere((note) => note.id == id);

  /// Creates a note at the top of the list and returns it.
  ///
  /// In the personal space unless [spaceId] says otherwise, in which case the
  /// caller brings the content key the note is to be sealed under, because
  /// minting one is the sync layer's job.
  Note create({
    String body = '',
    String? spaceId,
    Uint8List? contentKey,
    int keyGeneration = 1,
  }) {
    assert((spaceId == null) == (contentKey == null));
    final now = _now();
    final note = Note(
      id: newId(),
      body: body,
      createdAt: now,
      updatedAt: now,
      spaceId: spaceId,
      contentKey: contentKey,
      contentKeyGeneration: keyGeneration,
    );
    _notes = [note, ..._notes];
    _persist();
    return note;
  }

  void updateBody(String id, String body) {
    final index = indexOf(id);
    if (index < 0) return;
    final existing = _notes[index];
    if (existing.body == body) return;

    updateDocument(id, body, const []);
  }

  void updateDocument(String id, String body, List<NoteFormatRange> formats) {
    final index = indexOf(id);
    if (index < 0) return;
    final existing = _notes[index];
    final normalized = normalizeNoteFormats(formats, body.length);
    if (existing.body == body && listEquals(existing.formats, normalized)) {
      return;
    }

    final updatedNote = existing.copyWith(
      body: body,
      formats: normalized,
      updatedAt: _now(),
    );
    _replace(index, updatedNote, toFront: true);
  }

  /// Removes a note from view and records that it was deleted, in the space
  /// it was in.
  void delete(String id) {
    final index = indexOf(id);
    if (index < 0) return;
    final note = _notes[index];
    _notes = List<Note>.of(_notes)..removeAt(index);
    _encoded.remove(id);
    _tombstones = List.unmodifiable([
      ..._tombstones.where(
        (stone) => !(stone.id == id && stone.spaceId == note.spaceId),
      ),
      Tombstone(id: id, deletedAt: _now(), spaceId: note.spaceId),
    ]);
    _persist();
  }

  /// The note that should be selected after the one at [removedIndex] is
  /// deleted: the next one down, else the previous, else nothing.
  String? successorTo(int removedIndex) {
    if (_notes.isEmpty) return null;
    final index = removedIndex.clamp(0, _notes.length - 1);
    return _notes[index].id;
  }

  List<Note> search(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return _notes;
    return _notes
        .where((note) => note.matches(trimmed))
        .toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // Spaces
  // -------------------------------------------------------------------------

  /// Moves a note to another space: a tombstone stays behind where it was,
  /// and the note goes on under a new key, dirty, as a write.
  ///
  /// The caller brings the key — a fresh content key for a team space, null
  /// for the personal one — because whether a key is needed and how it is
  /// minted are the sync layer's business, and the old key must never be
  /// carried across: it is wrapped to a space key other people hold.
  Note? moveToSpace(
    String id, {
    required String? spaceId,
    required Uint8List? contentKey,
    int keyGeneration = 1,
  }) {
    assert((spaceId == null) == (contentKey == null));
    final index = indexOf(id);
    if (index < 0) return null;
    final existing = _notes[index];
    if (existing.spaceId == spaceId) return existing;

    final at = _now();
    final moved = existing.movedTo(
      spaceId: spaceId,
      contentKey: contentKey,
      contentKeyEpoch: 1,
      contentKeyGeneration: keyGeneration,
      at: at,
    );
    _tombstones = List.unmodifiable([
      ..._tombstones.where(
        (stone) => !(stone.id == id && stone.spaceId == existing.spaceId),
      ),
      Tombstone(id: id, deletedAt: at, spaceId: existing.spaceId),
    ]);
    _replace(index, moved, toFront: true);
    return moved;
  }

  /// Replaces a note's content key in place, without touching its text or
  /// its timestamp. For a rotation on the way out — the note is already
  /// dirty — and for adopting the key the server now holds for it.
  void adoptKey(
    String id, {
    required Uint8List contentKey,
    required int contentKeyEpoch,
    required int contentKeyGeneration,
  }) {
    final index = indexOf(id);
    if (index < 0) return;
    _replace(
      index,
      _notes[index].withKey(
        contentKey: contentKey,
        contentKeyEpoch: contentKeyEpoch,
        contentKeyGeneration: contentKeyGeneration,
      ),
    );
  }

  /// Notes that came home when a space ended: personal, keyless, and already
  /// on the server as of [at]. No tombstones are left in the old space, which
  /// no longer exists.
  void bringHome(Iterable<String> ids, {required DateTime at}) {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return;
    String? oldSpace;
    _notes = List.unmodifiable([
      for (final note in _notes)
        if (wanted.contains(note.id))
          () {
            oldSpace ??= note.spaceId;
            return note
                .movedTo(
                  spaceId: null,
                  contentKey: null,
                  contentKeyEpoch: 1,
                  contentKeyGeneration: 1,
                  at: at,
                )
                .markSynced(at);
          }()
        else
          note,
    ]);
    if (oldSpace != null) {
      _tombstones = List.unmodifiable(
        _tombstones.where((stone) => stone.spaceId != oldSpace),
      );
    }
    _persist();
  }

  /// A space this account is no longer in. Its notes go, except ones with
  /// unsynced edits: those are the user's work, and they come home to the
  /// personal space as their own notes rather than being thrown away.
  ///
  /// Returns the ids of the notes kept.
  List<String> forgetSpace(String spaceId) {
    final kept = <String>[];
    final at = _now();
    _notes = List.unmodifiable([
      for (final note in _notes)
        if (note.spaceId != spaceId)
          note
        else if (note.isDirty)
          () {
            kept.add(note.id);
            _encoded.remove(note.id);
            return Note(
              id: newId(),
              body: note.body,
              formats: note.formats,
              createdAt: note.createdAt,
              updatedAt: at,
            );
          }()
        else
          () {
            _encoded.remove(note.id);
            return null;
          }(),
    ].whereType<Note>());
    _tombstones = List.unmodifiable(
      _tombstones.where((stone) => stone.spaceId != spaceId),
    );
    _persist();
    return kept;
  }

  // -------------------------------------------------------------------------
  // Sync
  // -------------------------------------------------------------------------

  /// Records that the server accepted these exact revisions.
  ///
  /// Matching on the pushed [Note] instance rather than just the id is what
  /// keeps an edit made mid-push from being marked clean: if the note has
  /// moved on, the entry here no longer matches and it stays dirty.
  void markSynced({
    List<Note> notes = const [],
    List<Tombstone> tombstones = const [],
  }) {
    if (notes.isEmpty && tombstones.isEmpty) return;

    if (notes.isNotEmpty) {
      final pushed = {
        for (final note in notes)
          note.id: note.updatedAt.millisecondsSinceEpoch,
      };
      _notes = List.unmodifiable([
        for (final note in _notes)
          if (pushed[note.id] == note.updatedAt.millisecondsSinceEpoch)
            note.markSynced(note.updatedAt)
          else
            note,
      ]);
    }

    if (tombstones.isNotEmpty) {
      final pushed = {
        for (final stone in tombstones)
          _stoneKey(stone.spaceId, stone.id):
              stone.deletedAt.millisecondsSinceEpoch,
      };
      _tombstones = List.unmodifiable([
        for (final stone in _tombstones)
          if (pushed[_stoneKey(stone.spaceId, stone.id)] ==
              stone.deletedAt.millisecondsSinceEpoch)
            stone.markSynced(stone.deletedAt)
          else
            stone,
      ]);
    }

    _persist();
  }

  /// Merges what a pull returned into local state, last-writer-wins on
  /// timestamp.
  ///
  /// When the remote copy wins over a note that also changed locally, the
  /// local text is kept as a separate note rather than discarded. LWW on a
  /// whole body means one side loses; it does not have to mean one side is
  /// destroyed. The copy lands in the personal space — it is this person's
  /// recovery of their own words. Returns the ids of any copies created.
  ///
  /// A tombstone applies only to the note in the space it names: a note that
  /// moved has a tombstone behind it and a live copy ahead of it, and the one
  /// must not take out the other.
  List<String> applyRemote({
    List<Note> notes = const [],
    List<Tombstone> tombstones = const [],
  }) {
    if (notes.isEmpty && tombstones.isEmpty) return const [];

    final byIdIndex = {for (var i = 0; i < _notes.length; i++) _notes[i].id: i};
    final live = List<Note>.of(_notes);
    final stones = {
      for (final stone in _tombstones) _stoneKey(stone.spaceId, stone.id): stone,
    };
    final conflicted = <Note>[];
    final removed = <int>{};
    final now = _now();

    for (final incoming in notes) {
      final index = byIdIndex[incoming.id];
      final stoneKey = _stoneKey(incoming.spaceId, incoming.id);
      final localStone = stones[stoneKey];

      // A local delete in this space that is newer than the remote edit
      // wins, and stays pending so the delete still gets pushed.
      if (localStone != null &&
          !localStone.deletedAt.isBefore(incoming.updatedAt)) {
        continue;
      }
      stones.remove(stoneKey);

      if (index == null) {
        live.add(incoming.markSynced(incoming.updatedAt));
        continue;
      }

      final local = live[index];
      if (!incoming.updatedAt.isAfter(local.updatedAt)) {
        // Local is newer or identical; it will be pushed if it is dirty.
        continue;
      }

      if (local.isDirty && local.body != incoming.body) {
        conflicted.add(
          Note(
            id: newId(),
            body: local.body,
            formats: local.formats,
            createdAt: local.createdAt,
            updatedAt: now,
          ),
        );
      }
      live[index] = incoming.markSynced(incoming.updatedAt);
    }

    for (final incoming in tombstones) {
      final index = byIdIndex[incoming.id];
      if (index != null) {
        final local = live[index];
        // A tombstone from a space the note has since left says nothing
        // about the note where it is now.
        if (local.spaceId != incoming.spaceId) {
          // Nothing to remove, but the record still travels.
        } else if (local.updatedAt.isAfter(incoming.deletedAt)) {
          // A local edit newer than the remote delete resurrects the note; it
          // is still dirty, so the next push sends it back up.
          continue;
        } else {
          removed.add(index);
          _encoded.remove(local.id);
        }
      }
      final key = _stoneKey(incoming.spaceId, incoming.id);
      final existing = stones[key];
      if (existing == null || existing.deletedAt.isBefore(incoming.deletedAt)) {
        stones[key] = incoming.markSynced(incoming.deletedAt);
      }
    }

    final merged = <Note>[
      for (var i = 0; i < live.length; i++)
        if (!removed.contains(i)) live[i],
      ...conflicted,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    _notes = List.unmodifiable(merged);
    _tombstones = List.unmodifiable(stones.values);
    _purgeExpiredTombstones();
    _persist();

    return conflicted.map((note) => note.id).toList(growable: false);
  }

  /// Writes notes an import decided to apply.
  ///
  /// Every one lands dirty — `syncedAt` stays null — because the server has
  /// never seen this revision. That is the whole of import's relationship with
  /// sync: it puts notes in the store, and the next pass pushes them under the
  /// same last-writer-wins rules as a note somebody typed.
  ///
  /// A tombstone older than the note being written is dropped, exactly as
  /// [applyRemote] drops one, or the restored note would be deleted again by
  /// its own pending deletion.
  void importNotes(List<Note> notes) {
    if (notes.isEmpty) return;

    final incoming = {for (final note in notes) note.id: note};
    final stones = {
      for (final stone in _tombstones) _stoneKey(stone.spaceId, stone.id): stone,
    };
    for (final note in notes) {
      stones.removeWhere(
        (_, stone) =>
            stone.id == note.id && stone.deletedAt.isBefore(note.updatedAt),
      );
    }

    final merged = <Note>[
      for (final note in _notes)
        if (incoming.containsKey(note.id)) incoming.remove(note.id)! else note,
      // Whatever is left had no counterpart here.
      ...incoming.values,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    _notes = List.unmodifiable(merged);
    _tombstones = List.unmodifiable(stones.values);
    _persist();
  }

  /// Drops every note and tombstone this device holds.
  ///
  /// Only for signing in as a different person on a device that already has
  /// notes, and only once they have said so. Nothing else in the app removes
  /// notes in bulk, and a sign-out deliberately does not.
  void forgetEverything() {
    _notes = const [];
    _tombstones = const [];
    _encoded.clear();
    _persist();
  }

  Future<void> flush() => _store.flush();

  void _replace(int index, Note replacement, {bool toFront = false}) {
    if (toFront) {
      final remaining = List<Note>.of(_notes)..removeAt(index);
      // This edit just happened, so moving it directly to the front avoids an
      // O(n log n) sort on every keystroke while preserving newest-first order.
      _notes = [replacement, ...remaining];
    } else {
      final copy = List<Note>.of(_notes);
      copy[index] = replacement;
      _notes = List.unmodifiable(copy);
    }
    _persist();
  }

  static String _stoneKey(String? spaceId, String id) => '${spaceId ?? ''}:$id';

  void _persist() {
    _store.put(_key, {
      'notes': _encodeNotes(),
      'tombstones': _tombstones.map((stone) => stone.toJson()).toList(),
    });
    notifyListeners();
  }

  List<Object?> _encodeNotes() {
    final encoded = List<Object?>.filled(_notes.length, null);
    for (var i = 0; i < _notes.length; i++) {
      final note = _notes[i];
      final cached = _encoded[note.id];
      if (cached != null && identical(cached.note, note)) {
        encoded[i] = cached.json;
      } else {
        final json = note.toJson();
        _encoded[note.id] = (note: note, json: json);
        encoded[i] = json;
      }
    }
    // Notes deleted or merged away would otherwise hold their bodies alive.
    if (_encoded.length > _notes.length) {
      final live = {for (final note in _notes) note.id};
      _encoded.removeWhere((id, _) => !live.contains(id));
    }
    return encoded;
  }

  // IDs never leave local storage as credentials. Avoid a secure-entropy
  // platform call when creating the first note on a fresh mobile install.
  static final Random _random = Random();

  /// A UUID-v4-shaped identifier. Avoids a dependency for something this small.
  static String newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }
}
