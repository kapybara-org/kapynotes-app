import 'dart:math';

import 'package:flutter/foundation.dart';

import '../crdt/text_diff.dart';
import 'local_store.dart';
import 'blob_store.dart';
import 'clean_copies.dart';
import 'note.dart';
import 'note_attachment.dart';
import 'note_drawing.dart';
import 'note_format.dart';
import 'tombstone.dart';
import 'writing_streak.dart';

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
  static const String _pinnedKey = 'pinnedNoteIds.v1';
  static const String _writingDaysKey = 'writingDays.v1';
  static const String _nameHereKey = 'nameHereNoteIds.v1';
  static const String _privateCopiesKey = 'privateCopies.v1';
  static const String _dismissedKey = 'dismissed.v1';
  static const String _dismissalSyncKey = 'dismissalSync.v1';
  static const int _nameHereLimit = 200;

  final LocalStore _store;
  final DateTime Function() _now;

  /// The time the store dates its notes by, for anything that says how long
  /// ago they were changed.
  DateTime now() => _now();
  List<Note> _notes = const [];
  List<Note> _activeNotes = const [];
  List<Note> _archivedNotes = const [];
  List<Note> _hiddenNotes = const [];
  List<Note> _trashedNotes = const [];
  List<Note> _hiddenTrashedNotes = const [];
  List<Tombstone> _tombstones = const [];
  Set<String> _pinnedNoteIds = const {};

  /// Notes deleted while Undo is still on offer: out of every list, but
  /// whole, and written and synced as they were, until [deleteAll] takes
  /// them for good or [undoDelete] puts them back. Nothing of the delete is
  /// written down, so one the app is killed on is there on the next launch.
  Set<String> _deleting = const {};

  /// The days something was written on, as [WritingStreak.dayOf] numbers.
  Set<int> _writingDays = const {};

  bool _loaded = false;
  Future<void>? _loadFuture;

  /// Serialized form of each note, kept against the instance it came from.
  ///
  /// Notes are immutable, so an entry stays valid until the note is replaced.
  /// Without this, every keystroke rebuilt the JSON for every note the user
  /// owns; with it, only the note actually edited is re-encoded.
  final Map<String, ({Note note, Map<String, Object?> json})> _encoded = {};

  /// Notes marked synced whose edit is still only in an outbox in memory.
  /// They are written down as unsynced until [outboxWritten], so a crash
  /// between the two writes leaves the edit to be absorbed again on the next
  /// launch rather than lost.
  final Set<String> _unwritten = {};

  /// Where image bytes live.
  ///
  /// Held here because the store is the only thing that knows the whole set of
  /// live notes, and that set is the only safe input to a sweep. Injectable so
  /// a test can point it at a temporary directory.
  final BlobStore blobs;

  /// Remove noise's cleaned copies of recordings, swept with the blobs for the
  /// same reason.
  final CleanCopies cleanCopies;

  NotesStore(
    this._store, {
    DateTime Function()? now,
    BlobStore? blobs,
    CleanCopies? cleanCopies,
  }) : _now = now ?? DateTime.now,
       blobs = blobs ?? BlobStore(),
       cleanCopies = cleanCopies ?? CleanCopies();

  /// Notes shown in the main list, newest first.
  List<Note> get notes => _activeNotes;

  /// Notes kept out of the main list until restored.
  List<Note> get archivedNotes => _archivedNotes;

  /// Notes kept behind the device-local Hidden Notes credential.
  List<Note> get hiddenNotes => _hiddenNotes;

  /// Notes in Recently deleted, the latest deleted first. A hidden note is
  /// not among them: it waits in [hiddenTrashedNotes], behind Hidden's lock.
  List<Note> get trashedNotes => _trashedNotes;

  /// Hidden notes in Recently deleted, shown only while Hidden is open.
  List<Note> get hiddenTrashedNotes => _hiddenTrashedNotes;

  /// Every recoverable note, for sync, export, and attachment retention.
  List<Note> get allNotes => _notes;
  List<Tombstone> get tombstones => _tombstones;
  Set<String> get pinnedNoteIds => _pinnedNoteIds;

  /// Days in a row, up to today, that something has been written.
  WritingStreak get streak =>
      WritingStreak.from(_writingDays, today: WritingStreak.dayOf(_now()));

  bool get isLoaded => _loaded;
  bool get isEmpty => _activeNotes.isEmpty;

  /// The note whose contents changed most recently.
  Note? get lastEditedNote => _activeNotes.isEmpty ? null : _activeNotes.first;

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

  /// Every shared space this device holds something of: a note in it, or a
  /// note taken out of this account's own notes there.
  Set<String> get spaceIds => {
    for (final note in _notes)
      if (note.spaceId != null) note.spaceId!,
    ..._dismissed.values,
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

    _loadPinnedNoteIds();
    _loadNameHere();
    _loadWritingDays();
    _dropAbandonedBlanks();
    _refreshViews();
    _loaded = true;
    notifyListeners();
  }

  /// Deletes the blank new notes a quit or a crash left behind, before
  /// anything lists or opens them, as the page deletes one left behind while
  /// the app runs: never written in, never pushed, and not filed away on
  /// purpose. Sync confirms the deletion of a note it never sent without
  /// sending it, so these leave nothing on the server.
  void _dropAbandonedBlanks() => deleteAll([
    for (final note in _notes)
      if (note.isBlank &&
          note.syncedAt == null &&
          note.updatedAt == note.createdAt &&
          !note.isShared &&
          !note.isArchived &&
          !note.isTrashed)
        note.id,
  ]);

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

  int activeIndexOf(String id) =>
      _activeNotes.indexWhere((note) => note.id == id);

  bool isPinned(String id) => _pinnedNoteIds.contains(id);

  /// Pins are local organization state rather than note content. Toggling one
  /// therefore does not change the note timestamp, dirty state, or what a
  /// collaborator sees in a shared note.
  bool? togglePinned(String id) {
    final note = byId(id);
    if (note == null || note.isArchived || note.isHidden || note.isTrashed) {
      return null;
    }
    final pinned = !_pinnedNoteIds.contains(id);
    pinAll([id], pinned: pinned);
    return pinned;
  }

  /// Pins or unpins several notes as one change, and says how many changed.
  /// An archived or hidden note is never pinned.
  int pinAll(Iterable<String> ids, {required bool pinned}) {
    final wanted = ids.toSet();
    final updated = Set<String>.of(_pinnedNoteIds);
    var changed = 0;
    for (final note in _notes) {
      if (!wanted.contains(note.id) ||
          note.isArchived ||
          note.isHidden ||
          note.isTrashed) {
        continue;
      }
      if (pinned ? updated.add(note.id) : updated.remove(note.id)) changed++;
    }
    if (changed == 0) return 0;
    _pinnedNoteIds = Set.unmodifiable(updated);
    _store.putNow(_pinnedKey, _pinnedNoteIds.toList(growable: false));
    notifyListeners();
    return changed;
  }

  /// Creates a note at the top of the list and returns it.
  ///
  /// In the personal space unless [spaceId] says otherwise, in which case the
  /// caller brings the content key the note is to be sealed under, because
  /// minting one is the sync layer's job.
  ///
  /// A [body] counts towards the streak as writing unless [authored] is false,
  /// which is for words the app put there rather than the person. With
  /// [drawing] it starts as a blank drawing instead.
  Note create({
    String body = '',
    String? spaceId,
    Uint8List? contentKey,
    int keyGeneration = 1,
    bool authored = true,
    bool hidden = false,
    bool drawing = false,
  }) {
    assert((spaceId == null) == (contentKey == null));
    final now = _now();
    final note = Note(
      id: newId(),
      body: body,
      createdAt: now,
      updatedAt: now,
      hiddenAt: hidden && spaceId == null ? now : null,
      spaceId: spaceId,
      contentKey: contentKey,
      contentKeyGeneration: keyGeneration,
      drawing: drawing ? NoteDrawing.empty : null,
    );
    _notes = [note, ..._notes];
    if (authored && !note.isEmpty) _recordWriting([WritingStreak.dayOf(now)]);
    _persist();
    final nameHere = [..._nameHere, note.id];
    if (nameHere.length > _nameHereLimit) nameHere.removeAt(0);
    _nameHere = List.unmodifiable(nameHere);
    _store.put(_nameHereKey, _nameHere);
    return note;
  }

  /// Notes made on this device that it may still name, oldest first. Kept
  /// on this device and never synced, so each note is named only by the
  /// device that made it, and a note from another device never is.
  List<String> _nameHere = const [];

  /// Whether [id] was made on this device and may still be named here.
  bool namesHere(String id) => _nameHere.contains(id);

  /// [id] is not to be named on this device again: its title is the
  /// person's.
  void stopNamingHere(String id) {
    if (!_nameHere.contains(id)) return;
    _nameHere = List.unmodifiable(_nameHere.where((each) => each != id));
    _store.put(_nameHereKey, _nameHere);
  }

  void _loadNameHere() {
    final raw = _store.data[_nameHereKey];
    if (raw is! List) return;
    final liveIds = _notes.map((note) => note.id).toSet();
    _nameHere = List.unmodifiable(
      raw.whereType<String>().where(liveIds.contains),
    );
  }

  void updateBody(String id, String body) {
    final index = indexOf(id);
    if (index < 0) return;
    final existing = _notes[index];
    if (existing.body == body) return;

    updateDocument(id, body, const []);
  }

  /// [edit] is where in the body the change happened, when the editor knows;
  /// see [takeEdit].
  void updateDocument(
    String id,
    String body,
    List<NoteFormatRange> formats, [
    List<NoteAttachmentRef>? attachments,
    TextEdit? edit,
  ]) => _writeDocument(id, body, formats, attachments, edit, authored: true);

  /// Writes [body] on the person's behalf, as an assistant connected over MCP
  /// does: saved and synced exactly as typing is, but not counted towards the
  /// writing streak, which is the person's own. [formats] and [attachments]
  /// are where they land after [edit]; left out, they stay where they were,
  /// as after an append.
  void updateForAssistant(
    String id,
    String body,
    TextEdit edit, {
    List<NoteFormatRange>? formats,
    List<NoteAttachmentRef>? attachments,
  }) {
    final existing = byId(id);
    if (existing == null) return;
    _writeDocument(
      id,
      body,
      formats ?? existing.formats,
      attachments,
      edit,
      authored: false,
    );
  }

  void _writeDocument(
    String id,
    String body,
    List<NoteFormatRange> formats,
    List<NoteAttachmentRef>? attachments,
    TextEdit? edit, {
    required bool authored,
  }) {
    final index = indexOf(id);
    if (index < 0) return;
    final existing = _notes[index];
    if (existing.body != body) {
      final earlier = _edits[id];
      if (edit == null) {
        _edits.remove(id);
      } else {
        _edits[id] = earlier == null ? edit : composeEdits(earlier, edit);
      }
    }
    final normalized = normalizeNoteFormats(formats, body.length);
    final images = normalizeNoteAttachments(
      attachments ?? existing.attachments,
      body,
    );
    if (existing.body == body &&
        listEquals(existing.formats, normalized) &&
        listEquals(existing.attachments, images)) {
      return;
    }

    final at = _now();
    final updatedNote = existing.copyWith(
      body: body,
      formats: normalized,
      attachments: images,
      updatedAt: at,
    );
    if (authored) _recordWriting([WritingStreak.dayOf(at)]);
    _replace(index, updatedNote, toFront: true);
  }

  /// Where the edits to each note since its document last took it happened,
  /// as one stretch covering them all.
  final Map<String, TextEdit> _edits = {};

  /// Where [id]'s body changed since this was last asked, for the document
  /// taking the change in to diff inside; see [diffTexts]. Null when some
  /// change came without one, and the whole body is diffed.
  TextEdit? takeEdit(String id) => _edits.remove(id);

  /// Gives a blank note left by an older build the [Note.blankBody] a new
  /// note starts with, as it is taken for a new one. The app's own words, so
  /// not writing.
  void startAsNew(String id) {
    final index = indexOf(id);
    if (index < 0) return;
    final existing = _notes[index];
    if (existing.body == Note.blankBody || !existing.isEmpty) return;
    final edit = (
      start: 0,
      oldEnd: existing.body.length,
      newEnd: Note.blankBody.length,
    );
    final earlier = _edits[id];
    _edits[id] = earlier == null ? edit : composeEdits(earlier, edit);
    _replace(
      index,
      existing.copyWith(
        body: Note.blankBody,
        formats: const [],
        updatedAt: _now(),
      ),
      toFront: true,
    );
  }

  /// Takes the title [Note.blankBody] gives off a blank note, as a page
  /// opened on a day with none starts with no title (M11): the counterpart of
  /// [startAsNew]. The app's own words, so not writing.
  void startAsEmpty(String id) {
    final index = indexOf(id);
    if (index < 0) return;
    final existing = _notes[index];
    if (existing.body != Note.blankBody || !existing.isEmpty) return;
    final edit = (start: 0, oldEnd: existing.body.length, newEnd: 0);
    final earlier = _edits[id];
    _edits[id] = earlier == null ? edit : composeEdits(earlier, edit);
    _replace(
      index,
      existing.copyWith(body: '', formats: const [], updatedAt: _now()),
      toFront: true,
    );
  }

  /// Puts [title] in place of [id]'s first line, moving the formats and
  /// attachments after it along. The app's own words, so not writing.
  /// Returns whether the note changed.
  bool retitle(String id, String title) {
    final index = indexOf(id);
    if (index < 0) return false;
    final existing = _notes[index];
    final old = existing.firstLine.length;
    if (existing.firstLine == title) return false;
    final body = '$title${existing.body.substring(old)}';
    final shift = title.length - old;
    int moved(int offset) => offset < old ? 0 : offset + shift;
    final edit = (start: 0, oldEnd: old, newEnd: title.length);
    final earlier = _edits[id];
    _edits[id] = earlier == null ? edit : composeEdits(earlier, edit);
    _replace(
      index,
      existing.copyWith(
        body: body,
        formats: normalizeNoteFormats([
          for (final range in existing.formats)
            if (range.end > old)
              NoteFormatRange(
                start: moved(range.start),
                end: range.end + shift,
                format: range.format,
              ),
        ], body.length),
        attachments: normalizeNoteAttachments([
          for (final ref in existing.attachments)
            if (ref.offset >= old) ref.copyWith(offset: ref.offset + shift),
        ], body),
        updatedAt: _now(),
      ),
      toFront: true,
    );
    return true;
  }

  /// Writes a drawing's canvas and title. A no-op for a written note: a
  /// canvas cannot appear on a note that already has words in it. An
  /// assistant's drawing is not [authored], so the streak stays the person's.
  void updateDrawing(
    String id,
    NoteDrawing drawing, {
    String? title,
    bool authored = true,
  }) {
    final index = indexOf(id);
    if (index < 0) return;
    final existing = _notes[index];
    if (!existing.isDrawing) return;
    final body = title ?? existing.body;
    if (existing.drawing == drawing && existing.body == body) return;
    final at = _now();
    if (authored) _recordWriting([WritingStreak.dayOf(at)]);
    _replace(
      index,
      existing.copyWith(drawing: drawing, body: body, updatedAt: at),
      toFront: true,
    );
  }

  /// Every blob hash any live note refers to — images, previews, recordings,
  /// and the attachments of kinds this build does not understand.
  ///
  /// The complete input a sweep needs. Built from [_notes] rather than tracked
  /// incrementally on purpose: an incremental count is a thing that can drift,
  /// and drift here means deleting something somebody still has in a note.
  ///
  /// Unknown kinds are counted deliberately. Their bytes belong to a newer
  /// build's attachment, and sweeping them would quietly empty a note that
  /// this device merely could not draw.
  Set<String> get liveBlobHashes => {
    for (final note in _notes)
      for (final ref in note.attachments) ...[
        ref.hash,
        if (ref is NoteImageRef && ref.thumbHash != null) ref.thumbHash!,
      ],
  };

  /// Deletes attachment bytes no note refers to any more, and the cleaned
  /// copies of recordings that went with them, and reports the bytes
  /// reclaimed. Safe to call at any time; it reads the live set fresh.
  Future<int> sweepBlobs() async {
    if (!_loaded) return 0;
    final live = liveBlobHashes;
    return await blobs.sweep(live) + await cleanCopies.sweep(live);
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
      Tombstone(
        id: id,
        deletedAt: _now(),
        spaceId: note.spaceId,
        editedAt: note.spaceId == null ? null : note.updatedAt,
      ),
    ]);
    _persist();
  }

  /// Takes notes out of every list as deleting them would, and leaves them
  /// otherwise untouched until [deleteAll] or [undoDelete]: see [_deleting].
  void holdDelete(Iterable<String> ids) {
    _deleting = Set.unmodifiable({..._deleting, ...ids});
    _refreshViews();
    notifyListeners();
  }

  /// Puts notes [holdDelete] took out back where they were, as they are now.
  void undoDelete(Iterable<String> ids) {
    _deleting = Set.unmodifiable(_deleting.difference(ids.toSet()));
    _refreshViews();
    notifyListeners();
  }

  /// Whether [id] is deleted with Undo still on offer: see [holdDelete].
  bool isDeleting(String id) => _deleting.contains(id);

  /// Deletes several notes as one change.
  ///
  /// The same thing [delete] does, once, rather than a write and a rebuild per
  /// note: emptying an archive is the one moment this is asked for in bulk,
  /// and a list of a hundred should cost one save, not a hundred. Notes
  /// [holdDelete] took out go for good here.
  ///
  /// Returns how many were actually there to delete.
  int deleteAll(Iterable<String> ids) {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return 0;
    _deleting = Set.unmodifiable(_deleting.difference(wanted));
    final going = _notes.where((note) => wanted.contains(note.id)).toList();
    if (going.isEmpty) return 0;

    final goingIds = going.map((note) => note.id).toSet();
    _notes = List.unmodifiable(
      _notes.where((note) => !goingIds.contains(note.id)),
    );
    for (final id in goingIds) {
      _encoded.remove(id);
    }
    final at = _now();
    // A tombstone is scoped to the space the note was deleted from, so each
    // one carries its own note's space rather than a shared guess.
    _tombstones = List.unmodifiable([
      ..._tombstones.where(
        (stone) => !going.any(
          (note) => note.id == stone.id && note.spaceId == stone.spaceId,
        ),
      ),
      for (final note in going)
        Tombstone(
          id: note.id,
          deletedAt: at,
          spaceId: note.spaceId,
          editedAt: note.spaceId == null ? null : note.updatedAt,
        ),
    ]);
    _persist();
    return going.length;
  }

  /// Moves a note out of the main list without creating a tombstone.
  void archive(String id) => archiveAll([id]);

  /// Moves several notes out of the main list as one change.
  void archiveAll(Iterable<String> ids) {
    final at = _now();
    _replaceAll(
      ids,
      (note) => note.isArchived || note.isHidden || note.isTrashed
          ? null
          : note.copyWith(archivedAt: at, updatedAt: at),
    );
  }

  /// Takes an archive straight back: [before] is the note as it was just
  /// before, and [index] where it stood among every note, so it returns to
  /// its day and its place in the list. Only the archive is undone: whatever
  /// else reached the note since stays. It goes back unsent, a millisecond
  /// on if its old time is the one the server confirmed, so the server hears
  /// the archive taken back.
  void undoArchive(Note before, int index) {
    final at = indexOf(before.id);
    if (at < 0) return;
    final note = _notes[at];
    if (!note.isArchived || note.isHidden || note.isTrashed) return;
    final back = before.updatedAt;
    final rest = [..._notes]..removeAt(at);
    _notes = [
      ...rest.take(index),
      note.copyWith(
        archivedAt: null,
        updatedAt:
            note.syncedAt?.millisecondsSinceEpoch == back.millisecondsSinceEpoch
            ? back.add(const Duration(milliseconds: 1))
            : back,
      ),
      ...rest.skip(index),
    ];
    _persist();
  }

  /// Returns an archived note to the main list as the most recent change.
  void restore(String id) => restoreAll([id]);

  /// Returns several archived notes to the main list as one change.
  void restoreAll(Iterable<String> ids) {
    final at = _now();
    _replaceAll(
      ids,
      (note) => !note.isArchived || note.isHidden || note.isTrashed
          ? null
          : note.copyWith(archivedAt: null, updatedAt: at),
    );
  }

  /// Moves a personal note behind Hidden Notes without creating a tombstone.
  ///
  /// Shared notes are deliberately refused. Hidden state syncs with the note,
  /// so allowing one collaborator to set it would make the note disappear for
  /// everybody in that space.
  void hide(String id) => hideAll([id]);

  /// Moves several personal notes behind Hidden Notes as one change.
  void hideAll(Iterable<String> ids) {
    final at = _now();
    _replaceAll(
      ids,
      (note) =>
          note.isHidden || note.isArchived || note.isShared || note.isTrashed
          ? null
          : note.copyWith(hiddenAt: at, updatedAt: at),
    );
  }

  /// Returns a hidden note to the ordinary notes list.
  void unhide(String id) => unhideAll([id]);

  /// Returns several hidden notes to the ordinary notes list as one change.
  void unhideAll(Iterable<String> ids) {
    final at = _now();
    _replaceAll(
      ids,
      (note) => note.isHidden && !note.isTrashed
          ? note.copyWith(hiddenAt: null, updatedAt: at)
          : null,
    );
  }

  /// Moves notes to Recently deleted as one change, where they wait
  /// [Note.trashKept] before they go for good; see [emptyExpiredTrash].
  ///
  /// Each note also goes into Archive, at the same time, unless it is there
  /// already: a build from before the trash then keeps it out of the
  /// person's notes, and [putBackAll] knows the archive was only the trash's.
  ///
  /// Returns the notes as they were, each with where it stood among every
  /// note, for [undoTrash].
  List<({Note note, int index})> trashAll(Iterable<String> ids) {
    final wanted = ids.toSet();
    final before = [
      for (var index = 0; index < _notes.length; index++)
        if (wanted.contains(_notes[index].id) && !_notes[index].isTrashed)
          (note: _notes[index], index: index),
    ];
    final at = _now();
    _replaceAll(
      wanted,
      (note) => note.isTrashed
          ? null
          : note.copyWith(
              trashedAt: at,
              archivedAt: note.archivedAt ?? at,
              updatedAt: at,
            ),
    );
    return before;
  }

  /// Takes a [trashAll] straight back, as [undoArchive] takes back an
  /// archive: each note returns to its place in the list, as it was before,
  /// with whatever else reached it since. It goes back unsent, a millisecond
  /// on if its old time is the one the server confirmed, so the server hears
  /// the delete taken back.
  void undoTrash(List<({Note note, int index})> before) {
    final wanted = {for (final entry in before) entry.note.id};
    final rest = [
      for (final note in _notes)
        if (!wanted.contains(note.id)) note,
    ];
    final back = [...before]..sort((a, b) => a.index.compareTo(b.index));
    var changed = false;
    for (final (:note, :index) in back) {
      final current = byId(note.id);
      if (current == null) continue;
      final undone = current.isTrashed
          ? current.copyWith(
              trashedAt: null,
              archivedAt: note.archivedAt,
              updatedAt:
                  current.syncedAt?.millisecondsSinceEpoch ==
                      note.updatedAt.millisecondsSinceEpoch
                  ? note.updatedAt.add(const Duration(milliseconds: 1))
                  : note.updatedAt,
            )
          : current;
      changed = changed || current.isTrashed;
      rest.insert(index.clamp(0, rest.length), undone);
    }
    if (!changed) return;
    _notes = rest;
    _persist();
  }

  /// Puts notes in Recently deleted back where they were, as the most recent
  /// change: among the person's notes, or in Archive if they were archived
  /// before they were deleted.
  void putBackAll(Iterable<String> ids) {
    final at = _now();
    _replaceAll(
      ids,
      (note) => !note.isTrashed
          ? null
          : note.copyWith(
              trashedAt: null,
              archivedAt:
                  note.archivedAt?.millisecondsSinceEpoch ==
                      note.trashedAt!.millisecondsSinceEpoch
                  ? null
                  : note.archivedAt,
              updatedAt: at,
            ),
    );
  }

  /// Deletes for good the notes whose time in Recently deleted is up; see
  /// [Note.trashEndsAt]. Returns how many went.
  int emptyExpiredTrash() {
    final now = _now();
    return deleteAll([
      for (final note in _notes)
        if (!_deleting.contains(note.id) &&
            !(note.trashEndsAt?.isAfter(now) ?? true))
          note.id,
    ]);
  }

  /// The active note to select after the one at [removedIndex] leaves the
  /// main list: the next one down, else the previous, else nothing.
  String? successorTo(int removedIndex) {
    if (_activeNotes.isEmpty) return null;
    final index = removedIndex.clamp(0, _activeNotes.length - 1);
    return _activeNotes[index].id;
  }

  List<Note> search(String query) {
    final trimmed = query.trim();
    final matches = trimmed.isEmpty
        ? _activeNotes
        : _activeNotes.where((note) => note.matches(trimmed)).toList();
    if (_pinnedNoteIds.isEmpty || matches.length < 2) return matches;
    return List.unmodifiable([
      ...matches.where((note) => isPinned(note.id)),
      ...matches.where((note) => !isPinned(note.id)),
    ]);
  }

  List<Note> searchArchived(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return _archivedNotes;
    return _archivedNotes
        .where((note) => note.matches(trimmed))
        .toList(growable: false);
  }

  List<Note> searchHidden(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return _hiddenNotes;
    return _hiddenNotes
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
    if (existing.isHidden && spaceId != null) return null;
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

  /// Rewrites the one ref carrying [hash] in note [id], reading the note's
  /// current list at call time.
  ///
  /// Returns false when the note or the ref is gone, which a caller treats as
  /// "nothing to do", never as an error: an upload or a transcription that
  /// finishes after the user deleted the attachment has simply lost its race,
  /// and that is fine.
  ///
  /// This is the *only* way an asynchronous job may write into a note, and it
  /// takes a transform rather than a list for a reason. Handing over a whole
  /// attachment list means handing over a snapshot read some seconds ago, so a
  /// transcript arriving after the user moved a picture would put the picture
  /// back where it was. Reading `_notes` here — synchronously, on the UI
  /// isolate, at the moment of the write — means two jobs finishing at once
  /// cannot lose each other's fields.
  ///
  /// [touch] is the difference between learning something and changing
  /// something. A server id is not an edit: the text is untouched, so
  /// `updatedAt` must not move and the note must not jump to the top of the
  /// list. A transcript *is* content other devices need, and sync only pushes
  /// dirty notes — so that one bumps `updatedAt`, without reordering.
  bool updateAttachment(
    String id,
    String hash,
    NoteAttachmentRef Function(NoteAttachmentRef current) transform, {
    bool touch = false,
    List<int>? key,
  }) {
    final index = indexOf(id);
    if (index < 0) return false;
    final existing = _notes[index];

    var found = false;
    final updated = [
      for (final ref in existing.attachments)
        if (!found &&
            ref.hash == hash &&
            (key == null || listEquals(ref.key, key)))
          (() {
            found = true;
            return transform(ref);
          })()
        else
          ref,
    ];
    if (!found) return false;

    final normalized = normalizeNoteAttachments(updated, existing.body);
    if (listEquals(existing.attachments, normalized)) return true;

    _replace(
      index,
      existing.copyWith(
        attachments: normalized,
        updatedAt: touch ? _now() : existing.updatedAt,
      ),
    );
    return true;
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
    _notes = List.unmodifiable(
      [
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
                attachments: note.attachments,
                drawing: note.drawing,
                createdAt: note.createdAt,
                updatedAt: at,
                archivedAt: note.archivedAt,
                hiddenAt: note.hiddenAt,
                trashedAt: note.trashedAt,
              );
            }()
          else
            () {
              _encoded.remove(note.id);
              return null;
            }(),
      ].whereType<Note>(),
    );
    _tombstones = List.unmodifiable(
      _tombstones.where((stone) => stone.spaceId != spaceId),
    );
    _undismiss((_, dismissedIn) => dismissedIn == spaceId);
    _persist();
    return kept;
  }

  /// Forgets deletions of this device's that never went up, because a later
  /// edit from somebody else won over them.
  void dropTombstones(List<Tombstone> stones) {
    final keys = {for (final s in stones) _stoneKey(s.spaceId, s.id)};
    _tombstones = List.unmodifiable(
      _tombstones.where((s) => !keys.contains(_stoneKey(s.spaceId, s.id))),
    );
    _persist();
  }

  /// Shared notes this account took out of its own notes without deleting
  /// them for everyone, by id, with the space each was in.
  Map<String, String> get _dismissed => {
    if (_store.data[_dismissedKey] case final Map raw)
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String && value is String) key: value,
  };

  /// Whether this account took the note with [id] in [spaceId] out of its own
  /// notes. Nothing that arrives for it there brings it back.
  bool isDismissed(String id, String? spaceId) =>
      spaceId != null && _dismissed[id] == spaceId;

  /// Turns a deletion of a note in somebody else's shared space into taking
  /// it out of this account's own notes. Only a space's owner deletes a note
  /// for everyone, so [stone] is dropped unsent, and the note stays away
  /// however it changes in that space.
  ///
  /// [joinedAt] is when this account joined the space, as the server said:
  /// a later membership makes the dismissal one of an earlier one.
  void dismiss(Tombstone stone, {DateTime? joinedAt}) {
    final spaceId = stone.spaceId;
    if (spaceId == null) return;
    _tombstones = List.unmodifiable(
      _tombstones.where((s) => !(s.id == stone.id && s.spaceId == spaceId)),
    );
    _putDismissals(
      {..._dismissed, stone.id: spaceId},
      {
        ..._dismissalSync,
        stone.id: _DismissalSync(
          _Standing.owed,
          joinedAt: joinedAt,
          editedAt: stone.editedAt,
        ),
      },
    );
    _persist();
  }

  /// Where each dismissal stands with the server, by note id. One with no
  /// entry, as a build from before left it, is still to send.
  Map<String, _DismissalSync> get _dismissalSync => {
    if (_store.data[_dismissalSyncKey] case final Map raw)
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String) key: ?_DismissalSync.fromJson(value),
  };

  void _putDismissals(
    Map<String, String> dismissed,
    Map<String, _DismissalSync> sync,
  ) {
    _store.put(_dismissedKey, dismissed);
    _store.put(_dismissalSyncKey, {
      for (final MapEntry(:key, :value) in sync.entries)
        if (dismissed.containsKey(key)) key: value.toJson(),
    });
  }

  /// This account's dismissals no server has taken yet: the note, its space
  /// and when the account had joined it then, if known.
  List<({String noteId, String spaceId, DateTime? joinedAt})>
  get unsentDismissals {
    final sync = _dismissalSync;
    return [
      for (final MapEntry(:key, :value) in _dismissed.entries)
        if ((sync[key]?.standing ?? _Standing.owed) == _Standing.owed)
          (noteId: key, spaceId: value, joinedAt: sync[key]?.joinedAt),
    ];
  }

  /// A server that would not take [noteId]'s dismissal: it stays on this
  /// device alone, as before, and is not offered again.
  void keepDismissalLocal(String noteId) {
    final dismissed = _dismissed;
    if (!dismissed.containsKey(noteId)) return;
    final sync = _dismissalSync;
    sync[noteId] = (sync[noteId] ?? const _DismissalSync(_Standing.owed))
        .copyWith(standing: _Standing.local);
    _putDismissals(dismissed, sync);
  }

  /// [spaceId]'s list of the notes this account took out of its own notes,
  /// as the server holds it for every one of its devices. Those not yet kept
  /// away here go, and ones the list no longer carries, which the server had
  /// confirmed before, come back: the account left and was invited in again.
  /// Dismissals still on their way up are left as they are.
  ///
  /// Returns the notes that came back, with their last edit as this device
  /// saw it, so each can take its place again.
  List<({String id, DateTime? editedAt})> applyHidden(
    String spaceId,
    Iterable<String> hidden,
  ) {
    final ids = hidden.toSet();
    final dismissed = _dismissed;
    final sync = _dismissalSync;
    final back = [
      for (final MapEntry(:key, :value) in dismissed.entries)
        if (value == spaceId &&
            !ids.contains(key) &&
            sync[key]?.standing == _Standing.synced)
          (id: key, editedAt: sync[key]!.editedAt),
    ];
    final away = {
      for (final id in ids)
        if (dismissed[id] != spaceId || sync[id]?.standing != _Standing.synced)
          id,
    };
    if (back.isEmpty && away.isEmpty) return const [];
    for (final (:id, editedAt: _) in back) {
      dismissed.remove(id);
      sync.remove(id);
    }
    for (final id in away) {
      dismissed[id] = spaceId;
      final live = byId(id);
      sync[id] = _DismissalSync(
        _Standing.synced,
        editedAt: live != null && live.spaceId == spaceId
            ? live.updatedAt
            : sync[id]?.editedAt,
      );
    }
    _notes = List.unmodifiable(
      _notes.where((note) {
        if (note.spaceId != spaceId || !away.contains(note.id)) return true;
        _encoded.remove(note.id);
        return false;
      }),
    );
    _tombstones = List.unmodifiable(
      _tombstones.where((s) => s.spaceId != spaceId || !away.contains(s.id)),
    );
    _putDismissals(dismissed, sync);
    _persist();
    return back;
  }

  /// A change to a note kept away, remembered so it takes its place by it if
  /// the note ever comes back.
  void _editedWhileDismissed(Note note) {
    final sync = _dismissalSync;
    final known = sync[note.id] ?? const _DismissalSync(_Standing.owed);
    final last = known.editedAt;
    if (last != null && !note.updatedAt.isAfter(last)) return;
    sync[note.id] = known.copyWith(editedAt: note.updatedAt);
    _putDismissals(_dismissed, sync);
  }

  /// Drops the dismissals [gone] matches: the note was deleted for everyone,
  /// or this account left its space, so there is nothing left to keep away.
  void _undismiss(bool Function(String id, String spaceId) gone) {
    final dismissed = _dismissed;
    if (!dismissed.entries.any((e) => gone(e.key, e.value))) return;
    _putDismissals({
      for (final MapEntry(:key, :value) in dismissed.entries)
        if (!gone(key, value)) key: value,
    }, _dismissalSync);
  }

  /// Brings back a dismissal made under an earlier membership of [spaceId],
  /// which the server has already let go of. Returns the note's last edit as
  /// this device saw it.
  DateTime? undismissStale(String noteId, String spaceId) {
    final editedAt = _dismissalSync[noteId]?.editedAt;
    _undismiss((id, inSpace) => id == noteId && inSpace == spaceId);
    return editedAt;
  }

  // -------------------------------------------------------------------------
  // Sync
  // -------------------------------------------------------------------------

  /// Marks [notes] synced once sync has taken their edits into an outbox that
  /// is not on disk yet.
  void markAbsorbed(List<Note> notes) {
    _unwritten.addAll(notes.map((note) => note.id));
    markSynced(notes: notes);
  }

  /// The outbox holding these notes' edits is on disk.
  void outboxWritten(Set<String> ids) {
    final before = _unwritten.length;
    _unwritten.removeAll(ids);
    if (_unwritten.length != before) _persist();
  }

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
      for (final stone in _tombstones)
        _stoneKey(stone.spaceId, stone.id): stone,
    };
    final conflicted = <Note>[];
    final removed = <int>{};
    final written = <int>[];
    final now = _now();

    for (final incoming in notes) {
      if (isDismissed(incoming.id, incoming.spaceId)) continue;
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
        written.addAll(_daysWrittenElsewhere(incoming));
        continue;
      }

      final local = live[index];
      if (!incoming.updatedAt.isAfter(local.updatedAt)) {
        // Local is newer or identical; it will be pushed if it is dirty.
        continue;
      }

      if (local.isDirty &&
          (local.body != incoming.body || local.drawing != incoming.drawing)) {
        conflicted.add(
          Note(
            id: newId(),
            body: local.body,
            formats: local.formats,
            attachments: local.attachments,
            drawing: local.drawing,
            createdAt: local.createdAt,
            updatedAt: now,
            archivedAt: local.archivedAt,
            hiddenAt: local.hiddenAt,
            trashedAt: local.trashedAt,
          ),
        );
      }
      live[index] = incoming.markSynced(incoming.updatedAt);
      written.addAll(_daysWrittenElsewhere(incoming));
    }

    _undismiss(
      (id, spaceId) =>
          tombstones.any((stone) => stone.id == id && stone.spaceId == spaceId),
    );
    for (final incoming in tombstones) {
      final index = byIdIndex[incoming.id];
      if (index != null) {
        final local = live[index];
        // A tombstone from a space the note has since left says nothing
        // about the note where it is now.
        if (local.spaceId != incoming.spaceId) {
          // Nothing to remove, but the record still travels.
        } else if (local.isDirty &&
            local.updatedAt.isAfter(incoming.deletedAt)) {
          // A local edit newer than the remote delete resurrects the note; it
          // is still dirty, so the next push sends it back up. A clean copy
          // goes whatever its clock says.
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
    _recordWriting(written);
    _persist();

    return conflicted.map((note) => note.id).toList(growable: false);
  }

  /// Writes a rendered document into the list, clean: the merge already
  /// happened in the document, so there is nothing left to resolve here.
  ///
  /// Replaces the note if it is held, adds it if not, and re-sorts by
  /// recency so a note somebody else just edited rises the way one edited
  /// here does. A tombstone the server has confirmed for this note in this
  /// space is dropped: the log says the note is live, and the log is later.
  void applyDoc(Note note) {
    if (isDismissed(note.id, note.spaceId)) {
      _editedWhileDismissed(note);
      return;
    }
    final index = indexOf(note.id);
    final remaining = index < 0
        ? List<Note>.of(_notes)
        : (List<Note>.of(_notes)..removeAt(index));
    var at = 0;
    while (at < remaining.length &&
        remaining[at].updatedAt.isAfter(note.updatedAt)) {
      at++;
    }
    remaining.insert(at, note);
    _notes = List.unmodifiable(remaining);
    final key = _stoneKey(note.spaceId, note.id);
    if (_tombstones.any(
      (s) => _stoneKey(s.spaceId, s.id) == key && !s.isDirty,
    )) {
      _tombstones = List.unmodifiable(
        _tombstones.where((s) => _stoneKey(s.spaceId, s.id) != key),
      );
    }
    _recordWriting(_daysWrittenElsewhere(note));
    _persist();
  }

  /// Marks a note as holding edits the document has not absorbed, without
  /// changing its text. For a note whose history turned out to live on the
  /// server: it is reconciled onto that history when it arrives.
  void touch(String id) {
    final index = indexOf(id);
    if (index < 0) return;
    _replace(index, _notes[index].copyWith(updatedAt: _now()));
  }

  /// Keeps a note's local text as a separate personal note.
  ///
  /// Only for the one moment a note's history first reaches a device that
  /// holds an older copy with edits of its own: those words are not lost,
  /// and they are not merged over newer ones either.
  Note keepCopy(Note local) {
    final copy = Note(
      id: newId(),
      body: local.body,
      formats: local.formats,
      attachments: local.attachments,
      drawing: local.drawing,
      createdAt: local.createdAt,
      updatedAt: _now(),
      archivedAt: local.archivedAt,
      hiddenAt: local.hiddenAt,
      trashedAt: local.trashedAt,
    );
    _notes = List.unmodifiable([copy, ..._notes]);
    _persist();
    return copy;
  }

  /// A shared note this device can no longer write to: replaced here by a
  /// personal note with the same words, as [forgetSpace] keeps unsynced
  /// edits. The shared one stays on the server for whoever can still open
  /// it, so no tombstone is left for it.
  Note? keepAsOwn(String id) {
    final note = byId(id);
    if (note == null || note.spaceId == null) return null;
    final copy = keepCopy(note);
    _notes = List.unmodifiable(_notes.where((n) => n.id != id));
    _encoded.remove(id);
    _persist();
    return copy;
  }

  /// A private copy of [source] for leaving its space: the one an earlier
  /// attempt made, while it is still here, or a new one. [made] says which.
  ({Note note, bool made}) privateCopyOf(Note source) {
    final raw = _store.data[_privateCopiesKey];
    final copies = <String, String>{
      if (raw is Map)
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is String && indexOf(value) >= 0)
            key: value,
    };
    final existing = byId(copies[source.id]);
    if (existing != null) return (note: existing, made: false);
    final copy = keepCopy(source);
    _store.put(_privateCopiesKey, {...copies, source.id: copy.id});
    return (note: copy, made: true);
  }

  /// Forgets the copies made of [sourceIds] once their leave is done, so a
  /// later leave copies whatever those notes say by then.
  void forgetPrivateCopies(Iterable<String> sourceIds) {
    final raw = _store.data[_privateCopiesKey];
    if (raw is! Map) return;
    final done = sourceIds.toSet();
    _store.put(_privateCopiesKey, {
      for (final MapEntry(:key, :value) in raw.entries)
        if (!done.contains(key)) key: value,
    });
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
      for (final stone in _tombstones)
        _stoneKey(stone.spaceId, stone.id): stone,
    };
    for (final note in notes) {
      stones.removeWhere(
        (_, stone) =>
            stone.id == note.id && stone.deletedAt.isBefore(note.updatedAt),
      );
    }

    final merged = <Note>[
      for (final note in _notes)
        if (incoming.containsKey(note.id))
          _keepingDrawing(incoming.remove(note.id)!, note)
        else
          note,
      // Whatever is left had no counterpart here.
      ...incoming.values,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    _notes = List.unmodifiable(merged);
    _tombstones = List.unmodifiable(stones.values);
    _persist();
  }

  /// [restored] in place of [existing], keeping [existing]'s canvas when
  /// [restored] brings none. An archive holds no drawings yet, and a drawing
  /// restored from one as a written note would have its canvas erased on
  /// every device the next time it synced.
  static Note _keepingDrawing(Note restored, Note existing) =>
      restored.drawing == null && existing.drawing != null
      ? restored.copyWith(drawing: existing.drawing)
      : restored;

  /// Drops every note and tombstone this device holds.
  ///
  /// Only for signing in as a different person on a device that already has
  /// notes, and only once they have said so. Nothing else in the app removes
  /// notes in bulk, and a sign-out deliberately does not.
  void forgetEverything() {
    _notes = const [];
    _tombstones = const [];
    _encoded.clear();
    // Their streak goes with their notes.
    _writingDays = const {};
    _store.put(_writingDaysKey, const <int>[]);
    _persist();
  }

  Future<void> flush() => _store.flush();

  /// Whether the notes are on disk, on their way there, or failed to get
  /// there last time.
  ValueListenable<StoreWrite> get writes => _store.writes;

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

  /// Changes the notes [ids] names as one edit, as [deleteAll] does: one
  /// save and one rebuild however many there are. Each changed note moves to
  /// the front, the most recent change, in the order they were in. [change]
  /// answers null for a note it leaves as it is.
  void _replaceAll(Iterable<String> ids, Note? Function(Note note) change) {
    final wanted = ids.toSet();
    final changed = <Note>[];
    final rest = <Note>[];
    for (final note in _notes) {
      final replacement = wanted.contains(note.id) ? change(note) : null;
      if (replacement == null) {
        rest.add(note);
      } else {
        changed.add(replacement);
      }
    }
    if (changed.isEmpty) return;
    _notes = [...changed, ...rest];
    _persist();
  }

  static String _stoneKey(String? spaceId, String id) => '${spaceId ?? ''}:$id';

  void _persist() {
    _refreshViews();
    _store.put(_key, {
      'notes': _encodeNotes(),
      'tombstones': _tombstones.map((stone) => stone.toJson()).toList(),
    });
    _prunePinnedNoteIds();
    notifyListeners();
  }

  void _loadPinnedNoteIds() {
    final raw = _store.data[_pinnedKey];
    if (raw is! List) {
      _pinnedNoteIds = const {};
      return;
    }
    final liveIds = _notes.map((note) => note.id).toSet();
    _pinnedNoteIds = Set.unmodifiable(
      raw.whereType<String>().where(liveIds.contains),
    );
  }

  void _prunePinnedNoteIds() {
    if (_pinnedNoteIds.isEmpty) return;
    final liveIds = _notes.map((note) => note.id).toSet();
    final remaining = _pinnedNoteIds.where(liveIds.contains).toSet();
    if (remaining.length == _pinnedNoteIds.length) return;
    _pinnedNoteIds = Set.unmodifiable(remaining);
    _store.putNow(_pinnedKey, _pinnedNoteIds.toList(growable: false));
  }

  /// The record of days written, or — the first time a build that keeps one
  /// opens this store — a start on it from what the notes already show, so
  /// that somebody who has been writing every day does not open the update to
  /// a streak of nothing.
  void _loadWritingDays() {
    final raw = _store.data[_writingDaysKey];
    if (raw is List) {
      _writingDays = Set.unmodifiable(raw.whereType<int>());
      return;
    }
    _recordWriting([for (final note in _notes) ..._daysWrittenElsewhere(note)]);
  }

  /// What a note that arrived from outside this device says about when it was
  /// written. Only a personal note's: the personal space is written by this
  /// person alone, where a shared note's timestamps may be somebody else's
  /// work. Their own edits to a shared note still count on the device they
  /// type them on.
  static Iterable<int> _daysWrittenElsewhere(Note note) =>
      note.spaceId == null ? WritingStreak.daysIn(note) : const <int>[];

  /// Adds [days] to the record. Almost always a day already in it — this runs
  /// on every keystroke — so that case costs a lookup and writes nothing.
  void _recordWriting(Iterable<int> days) {
    if (days.every(_writingDays.contains)) return;
    _writingDays = Set.unmodifiable({..._writingDays, ...days});
    _store.put(_writingDaysKey, _writingDays.toList()..sort());
  }

  void _refreshViews() {
    final shown = _notes.where((note) => !_deleting.contains(note.id));
    _activeNotes = List.unmodifiable(
      shown.where(
        (note) => !note.isArchived && !note.isHidden && !note.isTrashed,
      ),
    );
    _archivedNotes = List.unmodifiable(
      shown.where(
        (note) => note.isArchived && !note.isHidden && !note.isTrashed,
      ),
    );
    _hiddenNotes = List.unmodifiable(
      shown.where((note) => note.isHidden && !note.isTrashed),
    );
    _trashedNotes = List.unmodifiable(
      shown.where((note) => note.isTrashed && !note.isHidden),
    );
    _hiddenTrashedNotes = List.unmodifiable(
      shown.where((note) => note.isTrashed && note.isHidden),
    );
  }

  List<Object?> _encodeNotes() {
    final encoded = List<Object?>.filled(_notes.length, null);
    for (var i = 0; i < _notes.length; i++) {
      final note = _notes[i];
      if (_unwritten.contains(note.id)) {
        encoded[i] = note.toJson()..remove('syncedAt');
        continue;
      }
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

enum _Standing { owed, synced, local }

/// One dismissal's standing with the server: [_Standing.owed] until a
/// space's list carries it, then [_Standing.synced], or [_Standing.local]
/// when the server would not take it and it stays on this device alone.
class _DismissalSync {
  const _DismissalSync(this.standing, {this.joinedAt, this.editedAt});

  final _Standing standing;

  /// When the account had joined the space, as the server said when the
  /// note was taken out here.
  final DateTime? joinedAt;

  /// The note's last edit as this device saw it.
  final DateTime? editedAt;

  _DismissalSync copyWith({_Standing? standing, DateTime? editedAt}) =>
      _DismissalSync(
        standing ?? this.standing,
        joinedAt: joinedAt,
        editedAt: editedAt ?? this.editedAt,
      );

  Map<String, Object?> toJson() => {
    'standing': standing.name,
    'joinedAt': ?joinedAt?.millisecondsSinceEpoch,
    'editedAt': ?editedAt?.millisecondsSinceEpoch,
  };

  static _DismissalSync? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final standing = _Standing.values.asNameMap()[raw['standing']];
    if (standing == null) return null;
    DateTime? at(Object? ms) =>
        ms is int ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true) : null;
    return _DismissalSync(
      standing,
      joinedAt: at(raw['joinedAt']),
      editedAt: at(raw['editedAt']),
    );
  }
}
