import 'dart:math';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'note.dart';
import 'notes_store.dart';
import 'record_book.dart';
import 'stamped.dart';

/// The longest a folder's name may be, in characters.
const int folderNameMax = 64;

/// The deepest a folder may be filed: this many levels below My notes.
const int folderDepthMax = 10;

/// The most folders and filed notes an account holds, together: room for a
/// library of 20,000 notes, every one filed, and 5,000 folders. An action
/// that would pass it changes nothing. Mirrors `FOLDER_RECORDS_MAX` in
/// packages/contract, which the server's live cap was raised by.
const int folderRecordsMax = 25000;

/// Why a change to the folders was refused.
enum FolderRefusal {
  /// The name is empty once trimmed.
  emptyName,

  /// The name is longer than [folderNameMax].
  longName,

  /// Another live folder in the same place has the name, ignoring case.
  nameTaken,

  /// It would sit deeper than [folderDepthMax].
  tooDeep,

  /// A folder can't go into itself or one of its own folders.
  intoItself,

  /// The folder, or the one it would go into, is deleted or unknown.
  gone,

  /// It would pass [folderRecordsMax].
  full,
}

/// One folder as the person sees it: where it sits once deleted folders and
/// loops are read past.
@immutable
class Folder {
  const Folder({
    required this.id,
    required this.name,
    required this.parentId,
    required this.depth,
    required this.createdAt,
  });

  final String id;
  final String name;

  /// The folder it sits in, or null at the top of My notes.
  final String? parentId;

  /// 1 for a folder at the top.
  final int depth;
  final int createdAt;
}

/// The latest stamp a folder record may carry: JavaScript's largest safe
/// integer, where the contract's integers stop. Real stamps are milliseconds
/// since 1970, so only a corrupt record comes near it. A reader refuses a
/// record past it, and no change is stamped past it, so one past a stamp can
/// never wrap or lose precision.
const int _stampMax = 9007199254740991;

/// [raw] as a stamp a device could have written, or null.
Stamped<T>? _stamped<T>(Object? raw) {
  final stamped = Stamped.fromJson<T>(raw);
  if (stamped == null || stamped.at < 0 || stamped.at > _stampMax) return null;
  return stamped;
}

/// One past [at], short of [_stampMax].
int _past(int at) => at < _stampMax ? at + 1 : _stampMax;

/// Control characters, line breaks among them, as spaces, and trimmed.
String _spaced(String name) => name
    .replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f\u2028\u2029]'), ' ')
    .trim();

/// The plaintext of a folder's record, whose id is the folder's own. Mirrors
/// `FolderPayload` in packages/contract.
@immutable
class FolderRecord {
  const FolderRecord({
    required this.id,
    required this.name,
    required this.parent,
    required this.deleted,
    required this.createdAt,
    this.extra = const {},
  });

  static const String kind = 'folder';

  final String id;
  final Stamped<String> name;

  /// The folder it was put in, or null for the top.
  final Stamped<String?> parent;

  /// Deleted, with the record kept so what was in it still finds its place.
  final Stamped<bool> deleted;
  final int createdAt;

  /// Fields a later build wrote, kept and written back untouched.
  final Map<String, Object?> extra;

  static const _known = {
    'id',
    'kind',
    'name',
    'parent',
    'deleted',
    'createdAt',
  };

  FolderRecord copyWith({
    Stamped<String>? name,
    Stamped<String?>? parent,
    Stamped<bool>? deleted,
  }) => FolderRecord(
    id: id,
    name: name ?? this.name,
    parent: parent ?? this.parent,
    deleted: deleted ?? this.deleted,
    createdAt: createdAt,
    extra: extra,
  );

  /// Field by field, the same whichever side merges.
  FolderRecord merge(FolderRecord other) => FolderRecord(
    id: id,
    name: name.merge(other.name),
    parent: parent.merge(other.parent),
    deleted: deleted.merge(other.deleted),
    createdAt: createdAt < other.createdAt ? createdAt : other.createdAt,
    extra: mergeExtra(extra, other.extra),
  );

  Map<String, Object?> toPayload() => {
    ...extra,
    'id': id,
    'kind': kind,
    'name': name.toJson(),
    'parent': parent.toJson(),
    'deleted': deleted.toJson(),
    'createdAt': createdAt,
  };

  /// Null for a payload missing anything this build needs, or sealed for
  /// another folder: a payload names its own id, so one moved or replayed
  /// onto another record is refused. The name is read as a device writes
  /// one, cut to [folderNameMax], so every device sees the same.
  static FolderRecord? fromPayload(String id, Object? raw) {
    if (raw is! Map || raw['id'] != id) return null;
    final name = _stamped<String>(raw['name']);
    final parent = _stamped<String?>(raw['parent']);
    final deleted = _stamped<bool>(raw['deleted']);
    final createdAt = raw['createdAt'];
    if (name == null ||
        parent == null ||
        deleted == null ||
        createdAt is! int) {
      return null;
    }
    final read = String.fromCharCodes(
      _spaced(name.v).runes.take(folderNameMax),
    ).trim();
    if (read.isEmpty) return null;
    return FolderRecord(
      id: id,
      name: Stamped(read, name.at),
      parent: parent,
      deleted: deleted,
      createdAt: createdAt,
      extra: extraOf(raw, _known),
    );
  }
}

/// Where one note is filed: the plaintext of its placement record, whose id
/// derives from [noteId] (`Vault.noteFolderRecordId`). Mirrors
/// `NoteFolderPayload` in packages/contract. A note in no folder has none.
@immutable
class NoteFolder {
  const NoteFolder({
    required this.noteId,
    required this.folder,
    this.extra = const {},
  });

  static const String kind = 'noteFolder';

  final String noteId;
  final Stamped<String> folder;

  /// Fields a later build wrote, kept and written back untouched.
  final Map<String, Object?> extra;

  static const _known = {'kind', 'noteId', 'folder'};

  /// The later move wins, the same whichever side merges.
  NoteFolder merge(NoteFolder other) => NoteFolder(
    noteId: noteId,
    folder: folder.merge(other.folder),
    extra: mergeExtra(extra, other.extra),
  );

  Map<String, Object?> toPayload() => {
    ...extra,
    'kind': kind,
    'noteId': noteId,
    'folder': folder.toJson(),
  };

  /// Null for a payload missing anything this build needs.
  static NoteFolder? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final noteId = raw['noteId'];
    final folder = _stamped<String>(raw['folder']);
    if (noteId is! String || folder == null) return null;
    return NoteFolder(
      noteId: noteId,
      folder: folder,
      extra: extraOf(raw, _known),
    );
  }
}

/// The folders as every device reads them from the same records: each live
/// folder in its place past deleted folders and loops, and the folder each
/// filed note sits in. Built once per change, so every read is a lookup.
@immutable
class FolderTree {
  const FolderTree._(
    this._folders,
    this._children,
    this._nearest,
    this._placed,
    this._cut,
  );

  /// From the folder records held, deleted ones included, and each filed
  /// note's folder.
  ///
  /// A parent this device does not hold reads as the top. Every loop two
  /// devices' moves made is broken where its earliest move was made, the
  /// lower id on a tie, so that folder reads as being at the top. Nothing
  /// writes it there but a move of another folder in the loop (see
  /// [FolderStore.move]). Then anything whose folder is deleted reads as
  /// being in the nearest live folder above it.
  factory FolderTree._read(
    Map<String, FolderRecord> records,
    Map<String, String> placed,
  ) {
    final up = <String, String?>{
      for (final record in records.values)
        record.id: records.containsKey(record.parent.v)
            ? record.parent.v
            : null,
    };
    String earlier(String a, String b) {
      final byTime = records[a]!.parent.at.compareTo(records[b]!.parent.at);
      return byTime < 0 || (byTime == 0 && a.compareTo(b) < 0) ? a : b;
    }

    final cut = <String>{};
    final done = <String>{};
    for (final start in records.keys) {
      final path = <String>[];
      final onPath = <String>{};
      for (String? at = start; at != null && !done.contains(at); at = up[at]) {
        if (!onPath.add(at)) {
          final earliest = path.sublist(path.indexOf(at)).reduce(earlier);
          up[earliest] = null;
          cut.add(earliest);
          break;
        }
        path.add(at);
      }
      done.addAll(path);
    }

    final nearest = <String, String?>{};
    for (final id in records.keys) {
      final chain = <String>[];
      String? at = id;
      while (at != null && !nearest.containsKey(at)) {
        if (!records[at]!.deleted.v) {
          nearest[at] = at;
          break;
        }
        chain.add(at);
        at = up[at];
      }
      final found = at == null ? null : nearest[at];
      for (final link in chain) {
        nearest[link] = found;
      }
    }

    final parentOf = <String, String?>{
      for (final record in records.values)
        if (!record.deleted.v)
          record.id: switch (up[record.id]) {
            final above? => nearest[above],
            null => null,
          },
    };
    final depth = <String, int>{};
    for (final id in parentOf.keys) {
      final chain = <String>[];
      String? at = id;
      while (at != null && !depth.containsKey(at)) {
        chain.add(at);
        at = parentOf[at];
      }
      var level = at == null ? 0 : depth[at]!;
      for (final link in chain.reversed) {
        depth[link] = ++level;
      }
    }

    final folders = <String, Folder>{
      for (final id in parentOf.keys)
        id: Folder(
          id: id,
          name: records[id]!.name.v,
          parentId: parentOf[id],
          depth: depth[id]!,
          createdAt: records[id]!.createdAt,
        ),
    };
    final children = <String?, List<Folder>>{};
    for (final folder in folders.values) {
      (children[folder.parentId] ??= []).add(folder);
    }
    for (final list in children.values) {
      list.sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        if (byName != 0) return byName;
        final byAge = a.createdAt.compareTo(b.createdAt);
        return byAge != 0 ? byAge : a.id.compareTo(b.id);
      });
    }
    return FolderTree._(folders, children, nearest, placed, cut);
  }

  final Map<String, Folder> _folders;
  final Map<String?, List<Folder>> _children;
  final Map<String, String?> _nearest;
  final Map<String, String> _placed;

  /// The folders read at the top to break a loop.
  final Set<String> _cut;

  /// Every live folder, at any depth, in no order.
  Iterable<Folder> get folders => _folders.values;

  /// The folders at the top of My notes, by name.
  List<Folder> get top => childrenOf(null);

  /// A folder's own folders, by name, ignoring case. Null is the top.
  List<Folder> childrenOf(String? folderId) => _children[folderId] ?? const [];

  /// A live folder, or null for a deleted or unknown one.
  Folder? byId(String folderId) => _folders[folderId];

  /// The top first, ending with the folder itself; empty when it isn't live.
  List<Folder> pathOf(String folderId) {
    final path = <Folder>[];
    for (
      var folder = _folders[folderId];
      folder != null;
      folder = _folders[folder.parentId]
    ) {
      path.add(folder);
    }
    return path.reversed.toList();
  }

  /// The folder a note sits in, or null for "Not in a folder".
  String? folderOf(String noteId) => _nearest[_placed[noteId]];

  /// [pathOf] the note's folder; empty for a note in My notes itself.
  List<Folder> pathOfNote(String noteId) => switch (folderOf(noteId)) {
    final folderId? => pathOf(folderId),
    null => const [],
  };

  /// Whether [folderId] is [ancestorId] or anywhere inside it.
  bool isWithin(String folderId, String ancestorId) {
    for (String? at = folderId; at != null; at = _folders[at]?.parentId) {
      if (at == ancestorId) return true;
    }
    return false;
  }

  /// The notes of [notes] that sit in [folderId], null being "Not in a
  /// folder", in the order given. [deep] adds every folder's inside it, and
  /// with null every note. Folders hold notes only, so a drawing is never
  /// listed, even one an assistant or another client filed.
  List<Note> notesIn(
    Iterable<Note> notes,
    String? folderId, {
    bool deep = false,
  }) => [
    for (final note in notes)
      if (!note.isDrawing && _holds(folderId, folderOf(note.id), deep)) note,
  ];

  bool _holds(String? folderId, String? noteFolder, bool deep) {
    if (!deep) return noteFolder == folderId;
    if (folderId == null) return true;
    return noteFolder != null && isWithin(noteFolder, folderId);
  }

  /// How many levels [folderId] holds, itself included.
  int _levels(String folderId) {
    var most = 0;
    for (final child in childrenOf(folderId)) {
      final levels = _levels(child.id);
      if (levels > most) most = levels;
    }
    return most + 1;
  }
}

/// The person's folders and where each note is filed. Kept on this device
/// signed in or not, and synced on the account's record stream beside the
/// tasks and tags, as one record per folder and one per filed note (see
/// `TaskSync`). Every field carries its own stamp and merges here, never on
/// the server, which orders whole records by `updatedAt`.
class FolderStore extends ChangeNotifier {
  FolderStore(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final LocalStore _store;
  final DateTime Function() _now;

  static const String _key = 'folders.v1';

  /// How long a deleted folder keeps its record, so Undo can bring it back
  /// with what was in it. Then [prune] lets it go.
  static const Duration deletedFolderKept = Duration(days: 30);

  final _folders = RecordBook<FolderRecord>(
    keepDeleted: false,
    merge: (mine, theirs) => mine.merge(theirs),
    encode: (folder) => folder.toPayload(),
    decode: FolderRecord.fromPayload,
  );

  /// Keyed by note id. A note taken out of every folder keeps its record,
  /// deleted, while that delete is ahead of this device's clock, so filing it
  /// again is stamped past it (see [_letGo]).
  final _notes = RecordBook<NoteFolder>(
    keepDeleted: true,
    merge: (mine, theirs) => mine.merge(theirs),
    encode: (note) => note.toPayload(),
    decode: (noteId, raw) {
      final note = NoteFolder.fromPayload(raw);
      return note?.noteId == noteId ? note : null;
    },
  );

  int _stamp() => _now().millisecondsSinceEpoch;

  /// [v] stamped [now], or just after [replaced] when this device's clock is
  /// behind it: a change made over a value outranks it, so a device with a
  /// slow clock can still undo or move what one with a fast clock wrote.
  static Stamped<T> _over<T>(Stamped<T> replaced, T v, int now) =>
      Stamped(v, now > replaced.at ? now : _past(replaced.at));

  /// The folders as they read now, rebuilt on the first read after a change.
  FolderTree get tree => _tree ??= FolderTree._read(
    {
      for (final MapEntry(:key, value: slot) in _folders.slots.entries)
        if (!slot.deleted) key: slot.value,
    },
    {
      for (final MapEntry(:key, value: slot) in _notes.slots.entries)
        if (!slot.deleted) key: slot.value.folder.v,
    },
  );
  FolderTree? _tree;

  /// How many more folders or newly filed notes fit in [folderRecordsMax].
  /// A deleted folder counts until [prune] lets it go.
  int get room {
    final live =
        _folders.slots.values.where((slot) => !slot.deleted).length +
        _notes.slots.values.where((slot) => !slot.deleted).length;
    return live >= folderRecordsMax ? 0 : folderRecordsMax - live;
  }

  Future<bool>? _loading;

  /// Reads what this device holds, once. False when it held nothing yet,
  /// which a build from before folders leaves behind; the record is written
  /// at once, so that is false only the first time.
  Future<bool> load() => _loading ??= _load();

  Future<bool> _load() async {
    await _store.load();
    final raw = _store.data[_key];
    if (raw is! Map) {
      _store.put(_key, _toJson());
      return false;
    }
    _folders.load(raw['folders']);
    _notes.load(raw['notes']);
    _tree = null;
    notifyListeners();
    return true;
  }

  Map<String, Object?> _toJson() => {
    'folders': _folders.toJson(),
    'notes': _notes.toJson(),
  };

  bool _held = false;
  bool _unsaved = false;
  bool _untold = false;

  /// Defers the file write and the telling until [release], so a pull of
  /// many records writes once and rebuilds the tree once.
  void hold() => _held = true;

  void release() {
    _held = false;
    if (_unsaved) _save();
    if (_untold) {
      _untold = false;
      notifyListeners();
    }
  }

  void _save() {
    _unsaved = _held;
    if (!_held) _store.put(_key, _toJson());
  }

  /// Something the person can see changed.
  void _changed() {
    _tree = null;
    _save();
    if (_held) {
      _untold = true;
    } else {
      notifyListeners();
    }
  }

  // -------------------------------------------------------------------------
  // Checks, for a field or a drop target before anything is written

  /// Why a folder named [name] can't be made in [parentId] (null: the top),
  /// or null when it can.
  FolderRefusal? checkCreate(String name, {String? parentId}) =>
      _nameRefusal(name, parentId, null) ??
      _placeRefusal(parentId, 1) ??
      (room < 1 ? FolderRefusal.full : null);

  /// Why [folderId] can't be called [name], or null when it can.
  FolderRefusal? checkRename(String folderId, String name) {
    final folder = tree.byId(folderId);
    if (folder == null) return FolderRefusal.gone;
    return _nameRefusal(name, folder.parentId, folderId);
  }

  /// Why [folderId] can't move into [parentId] (null: the top), or null.
  FolderRefusal? checkMove(String folderId, {String? parentId}) {
    final tree = this.tree;
    final folder = tree.byId(folderId);
    if (folder == null) return FolderRefusal.gone;
    if (parentId != null && tree.isWithin(parentId, folderId)) {
      return FolderRefusal.intoItself;
    }
    if (parentId == folder.parentId) return null;
    return _placeRefusal(
          parentId,
          tree._levels(folderId),
          from: folder.depth - 1,
        ) ??
        _nameRefusal(folder.name, parentId, folderId);
  }

  /// Why [noteIds] can't be filed in [folderId], or null when they can.
  /// Null [folderId] takes them out of every folder, which always can.
  FolderRefusal? checkFile(Iterable<String> noteIds, String? folderId) {
    if (folderId == null) return null;
    if (tree.byId(folderId) == null) return FolderRefusal.gone;
    final adds = noteIds.toSet().where((id) => _notes.live(id) == null).length;
    return adds > room ? FolderRefusal.full : null;
  }

  FolderRefusal? _nameRefusal(String name, String? parentId, String? self) {
    final spaced = _spaced(name);
    if (spaced.isEmpty) return FolderRefusal.emptyName;
    if (spaced.runes.length > folderNameMax) return FolderRefusal.longName;
    final wanted = spaced.toLowerCase();
    for (final sibling in tree.childrenOf(parentId)) {
      if (sibling.id != self && sibling.name.toLowerCase() == wanted) {
        return FolderRefusal.nameTaken;
      }
    }
    return null;
  }

  /// Whether [levels] of folders fit in [parentId]. Moving them from a place
  /// [from] levels below My notes to one no deeper always fits: two devices'
  /// moves can leave folders deeper than [folderDepthMax], and they must
  /// still be able to come back up.
  FolderRefusal? _placeRefusal(String? parentId, int levels, {int from = -1}) {
    final above = parentId == null ? 0 : tree.byId(parentId)?.depth;
    if (above == null) return FolderRefusal.gone;
    return above > from && above + levels > folderDepthMax
        ? FolderRefusal.tooDeep
        : null;
  }

  // -------------------------------------------------------------------------
  // Changes

  /// A new folder named [name] in [parentId] (null: the top), or null when
  /// [checkCreate] refuses it.
  Folder? create(String name, {String? parentId}) {
    if (checkCreate(name, parentId: parentId) != null) return null;
    final now = _stamp();
    final folder = FolderRecord(
      id: NotesStore.newId(),
      name: Stamped(_spaced(name), now),
      parent: Stamped(parentId, now),
      deleted: Stamped(false, now),
      createdAt: now,
    );
    _folders.write(folder.id, folder, now);
    _changed();
    return tree.byId(folder.id);
  }

  FolderRefusal? rename(String folderId, String name) {
    final refusal = checkRename(folderId, name);
    if (refusal != null) return refusal;
    final folder = _folders.live(folderId)!;
    if (folder.name.v != _spaced(name)) {
      _write(
        folder.copyWith(name: _over(folder.name, _spaced(name), _stamp())),
      );
    }
    return null;
  }

  /// Moves a folder, with everything in it, into [parentId] (null: the top).
  /// If it is in a loop two devices made, the folder that loop is broken at
  /// is written at the top as well, where it reads, stamped just past the
  /// move the break overrules: so opening the loop doesn't take that folder
  /// back in, and any later move of it still wins.
  FolderRefusal? move(String folderId, {String? parentId}) {
    final refusal = checkMove(folderId, parentId: parentId);
    if (refusal != null) return refusal;
    final folder = _folders.live(folderId)!;
    if (folder.parent.v == parentId) return null;
    final now = _stamp();
    for (final cut in tree._cut) {
      var at = _folders.live(cut)!.parent.v;
      while (at != null && at != cut && at != folderId) {
        at = _folders.live(at)?.parent.v;
      }
      if (cut == folderId || at != folderId) continue;
      final looped = _folders.live(cut)!;
      final top = Stamped<String?>(null, _past(looped.parent.at));
      _folders.write(cut, looped.copyWith(parent: top), now);
    }
    _write(folder.copyWith(parent: _over(folder.parent, parentId, now)));
    return null;
  }

  /// One write: the folder's notes and folders read as being in its parent
  /// straight away, and nothing in it is deleted. [restore] undoes it.
  void delete(String folderId) {
    final folder = _folders.live(folderId);
    if (folder == null || folder.deleted.v) return;
    _write(folder.copyWith(deleted: _over(folder.deleted, true, _stamp())));
  }

  /// Undoes [delete], on every device, with whatever still points at it.
  void restore(String folderId) {
    final folder = _folders.live(folderId);
    if (folder == null || !folder.deleted.v) return;
    _write(folder.copyWith(deleted: _over(folder.deleted, false, _stamp())));
  }

  void _write(FolderRecord folder) {
    _folders.write(folder.id, folder, _stamp());
    _changed();
  }

  /// Files [noteIds] in [folderId], or takes them out of every folder with
  /// null: one write for each note that moves, and none at all when
  /// [checkFile] refuses. A filing is stamped past all this device holds for
  /// the note, the delete that took it out included, so it outranks what it
  /// replaces on every device, however far ahead the clock that wrote that.
  FolderRefusal? file(Iterable<String> noteIds, String? folderId) {
    final ids = noteIds.toSet();
    final refusal = checkFile(ids, folderId);
    if (refusal != null) return refusal;
    final now = _stamp();
    var moved = false;
    for (final noteId in ids) {
      final placed = _notes.live(noteId);
      if (folderId == null) {
        if (placed == null) continue;
        _notes.delete(noteId, now);
      } else {
        if (placed?.folder.v == folderId) continue;
        final slot = _notes.slots[noteId];
        final held = slot == null
            ? 0
            : max(slot.updatedAt, slot.value.folder.at);
        _notes.write(
          noteId,
          NoteFolder(
            noteId: noteId,
            folder: Stamped(folderId, now > held ? now : _past(held)),
            extra: slot?.value.extra ?? const {},
          ),
          now,
        );
      }
      moved = true;
    }
    if (moved) _changed();
    return null;
  }

  /// Lets go of the records of folders deleted more than [deletedFolderKept]
  /// ago, so they stop counting against [folderRecordsMax]. First, what
  /// still reads past one into a live folder is written there, stamped just
  /// past what it replaces, so any real change made since still wins; what
  /// reads at the top goes on reading there unwritten. For sync to call once
  /// what the server had is in.
  void prune() {
    final cutoff = _stamp() - deletedFolderKept.inMilliseconds;
    final gone = {
      for (final MapEntry(:key, value: slot) in _folders.slots.entries)
        if (!slot.deleted &&
            slot.value.deleted.v &&
            slot.value.deleted.at < cutoff)
          key,
    };
    if (gone.isEmpty) return;
    final nearest = tree._nearest;
    final now = _stamp();
    for (final MapEntry(:key, value: slot) in _folders.slots.entries.toList()) {
      final parent = slot.value.parent;
      final into = nearest[parent.v];
      if (slot.deleted ||
          gone.contains(key) ||
          !gone.contains(parent.v) ||
          into == null) {
        continue;
      }
      _folders.write(
        key,
        slot.value.copyWith(parent: Stamped(into, _past(parent.at))),
        now,
      );
    }
    for (final MapEntry(:key, value: slot) in _notes.slots.entries.toList()) {
      final folder = slot.value.folder;
      final into = nearest[folder.v];
      if (slot.deleted || !gone.contains(folder.v) || into == null) continue;
      _notes.write(
        key,
        NoteFolder(
          noteId: key,
          folder: Stamped(into, _past(folder.at)),
          extra: slot.value.extra,
        ),
        now,
      );
    }
    for (final id in gone) {
      _folders.delete(id, now);
    }
    _changed();
  }

  /// A note deleted for good takes its placement with it, and once the
  /// server has that, nothing of it stays: the note is never filed again.
  void forgetNote(String noteId) {
    final slot = _notes.slots[noteId];
    if (slot == null || (slot.deleted && slot.dirty)) return;
    if (slot.deleted) {
      _notes.slots.remove(noteId);
      _save();
    } else {
      _notes.delete(noteId, _stamp());
      _changed();
    }
  }

  /// Lets go of [noteId]'s placement once it is a delete the server has and
  /// this device's clock has passed: a filing made from then on outranks it
  /// by its own time.
  void _letGo(String noteId) {
    final slot = _notes.slots[noteId];
    if (slot != null &&
        slot.deleted &&
        !slot.dirty &&
        slot.updatedAt < _stamp()) {
      _notes.slots.remove(noteId);
    }
  }

  // -------------------------------------------------------------------------
  // Sync

  /// The notes this device holds a placement record for, taken-out ones
  /// included.
  Iterable<String> get noteIds => _notes.slots.keys;

  /// Whether the server is owed anything.
  bool get owes => _folders.owes || _notes.owes;

  /// What the server has not been told, live and deleted.
  List<OwedRecord> get owed => [
    ..._folders.owed(FolderRecord.kind),
    ..._notes.owed(NoteFolder.kind),
  ];

  /// The server took the record as sent. Anything changed since stays owed.
  void acknowledge(OwedRecord record) {
    if (record.kind == FolderRecord.kind) {
      _folders.acknowledge(record.key, record.updatedAt);
    } else {
      _notes.acknowledge(record.key, record.updatedAt);
      _letGo(record.key);
    }
    _save();
  }

  /// A live folder record as the server holds it, from a pull or a lost push.
  void applyRemoteFolder(FolderRecord folder, int updatedAt) {
    _folders.applyRemote(folder.id, folder, updatedAt);
    _changed();
  }

  /// A live placement as the server holds it.
  void applyRemoteNote(NoteFolder note, int updatedAt) {
    _notes.applyRemote(note.noteId, note, updatedAt);
    _changed();
  }

  /// A deleted record as the server holds it: a folder by its id, a
  /// placement by [noteId] where the record id is known to be that note's. A
  /// newer local change survives it and goes up again.
  void applyRemoteDelete(String id, int updatedAt, {String? noteId}) {
    if (_folders.applyRemoteDelete(id, updatedAt)) {
      _changed();
    } else if (noteId != null && _notes.applyRemoteDelete(noteId, updatedAt)) {
      _letGo(noteId);
      _changed();
    }
  }

  /// Signing out: the folders stay, and everything live is owed to the next
  /// account, whose record ids are its own. A taken-out placement was this
  /// account's record, and goes.
  void forgetAccount() {
    _folders.forgetAccount();
    _notes.slots.removeWhere((_, slot) => slot.deleted);
    _notes.forgetAccount();
    _save();
  }

  /// Drops everything, for notes let go of on signing in as someone else.
  void clear() {
    _folders.slots.clear();
    _notes.slots.clear();
    _changed();
  }
}
