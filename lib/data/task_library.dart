import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../sync/doc_store.dart';
import '../sync/sync_state.dart';
import 'local_store.dart';
import 'note.dart';
import 'notes_store.dart';
import 'task_index.dart';
import 'task_lines.dart';

/// The tasks on this device, and the documents their anchors are read in,
/// whether or not anything syncs them.
///
/// While an account syncs, its sync keeps both: the documents are its merge
/// state and the index holds its task records. The rest of the time —
/// signed out, locked, or in a build with no sync at all — this keeps them:
/// a note with checklist lines gets a document, each edit is taken into it,
/// and the index follows under ids minted with a key that never leaves the
/// device. It leaves sync's bookkeeping alone but for
/// [DocRecord.offline], which tells sync to send such a document whole.
///
/// Notifies when the index changes.
class TaskLibrary extends ChangeNotifier {
  /// [state] is where the device id comes from that every document's
  /// replica is cut from, shared with sync; null in a build with no sync,
  /// which keeps a replica of its own rather than mint a device id.
  TaskLibrary({
    required NotesStore notes,
    required LocalStore store,
    SyncState? state,
    DocStorage? storage,
    DateTime Function()? now,
  }) : _notes = notes,
       _store = store,
       _state = state,
       _storage = storage,
       index = TaskIndex(store, now: now) {
    index.addListener(notifyListeners);
  }

  static const String _localKey = 'tasks.local.v1';
  static const String _chosenKey = 'tasks.chosenOver.v1';

  final NotesStore _notes;
  final LocalStore _store;
  final SyncState? _state;
  final DocStorage? _storage;

  /// Every task, by id. Read once [load] has finished.
  final TaskIndex index;

  /// Every note's document: what a task's anchor names a line in; see
  /// [taskLineIndex]. Set by [load].
  late final DocStore docs;

  late final List<int> _idKey;
  Future<void>? _loading;
  bool _loaded = false;
  Future<void> Function()? _sync;

  /// Each note as it was last taken in, to tell which changed since.
  Map<String, Note> _seen = const {};

  /// Whether the next pass reads every note, not just the ones that changed:
  /// the first, and the first after sync lets go.
  bool _fresh = true;
  bool _scheduled = false;

  /// The last place on the list when Do now began here, by the task it began
  /// on. Kept on this device and never synced, so a relaunch between
  /// choosing and Done still knows what was already on the list.
  ({String id, int end})? get chosenOver => switch (_store.data[_chosenKey]) {
    {'id': final String id, 'end': final int end} => (id: id, end: end),
    _ => null,
  };

  set chosenOver(({String id, int end})? value) => _store.put(
    _chosenKey,
    value == null ? null : {'id': value.id, 'end': value.end},
  );

  /// Whether [load] has finished, and [docs] and [index] can be read.
  bool get isLoaded => _loaded;

  Future<void> load() => _loading ??= _load();

  /// Reads the store the notes live in, not the notes: whoever loads those
  /// does, and the first pass waits for them. A pass over a note list not
  /// read yet would take every document for a deleted note's.
  Future<void> _load() async {
    await _store.load();
    var local = _store.data[_localKey];
    if (local is! Map ||
        local['key'] is! String ||
        local['replica'] is! String) {
      final random = Random.secure();
      String hex(int bytes) => [
        for (var i = 0; i < bytes; i++)
          random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();
      local = {'key': hex(32), 'replica': hex(6)};
      _store.put(_localKey, local);
    }
    _idKey = utf8.encode(local['key'] as String);
    final state = _state?..load();
    // The replica every character this device writes is stamped with:
    // twelve hex digits of the install id, stable for the life of the
    // install and short enough to ride in every op without weighing on it.
    docs = DocStore(
      _storage ?? FileDocStorage(),
      replica: state?.deviceId.substring(0, 12) ?? local['replica'] as String,
    );
    index.load();
    await docs.load();
    _loaded = true;
    _notes.addListener(_schedule);
    _keep();
    notifyListeners();
  }

  /// Takes every note's latest edits into its document and the index now,
  /// for a screen that has just written a note and reads its tasks back.
  /// Anything that owes the server goes on sync's usual schedule.
  Future<void> reconcileNow() async {
    await load();
    final sync = _sync;
    if (sync != null) return sync();
    _keep();
  }

  /// Hands the documents and the index to an account's sync, which keeps
  /// them from here and answers [reconcileNow] with [reconcile].
  void attachSync(Future<void> Function() reconcile) => _sync = reconcile;

  /// Sync has stopped. Every note is read again on the next pass, since sync
  /// may have left notes it held back untaken.
  void detachSync() {
    _sync = null;
    _fresh = true;
    _schedule();
  }

  void _schedule() {
    if (_scheduled || _sync != null) return;
    _scheduled = true;
    // A microtask, as sync's own reconcile is: after the change, before
    // anything reads the index.
    scheduleMicrotask(() {
      _scheduled = false;
      _keep();
    });
  }

  void _keep() {
    if (_sync != null || !_loaded || !_notes.isLoaded) return;
    final live = <String, Note>{};
    for (final note in _notes.allNotes) {
      live[note.id] = note;
      // A note the server has this revision of matches its document.
      if (identical(_seen[note.id], note) || (_fresh && !note.isDirty)) {
        continue;
      }
      _take(note);
    }
    final gone = _fresh
        ? [for (final record in docs.records) record.noteId]
        : _seen.keys;
    for (final id in gone.where((id) => !live.containsKey(id)).toList()) {
      index.forgetNote(id);
      // One the server holds stays, for sync to send the deletion with.
      if (docs.get(id)?.isLocal ?? false) docs.remove(id);
    }
    _seen = live;
    _fresh = false;
    index.reconcileDocs(docs, noteIsLive: live.containsKey, idFor: _localId);
  }

  void _take(Note note) {
    var record = docs.get(note.id);
    if (record == null) {
      if (taskLines(note.body).isEmpty) return;
      record = docs.create(note.id, note.spaceId ?? '');
    }
    final ops = record.doc.reconcile(
      body: note.body,
      formats: note.formats,
      attachments: note.attachments,
      drawing: note.drawing,
      createdAt: note.createdAt,
      archivedAt: note.archivedAt,
      hiddenAt: note.hiddenAt,
      near: _notes.takeEdit(note.id),
    );
    if (ops.isEmpty) return;
    record.offline = true;
    docs.markDirty(note.id);
  }

  String _localId(String noteId, String anchor) {
    final digest = Hmac(
      sha256,
      _idKey,
    ).convert(utf8.encode('$noteId\n$anchor'));
    return '$localTaskIdPrefix${digest.toString().substring(0, 32)}';
  }

  @override
  void dispose() {
    _notes.removeListener(_schedule);
    index.removeListener(notifyListeners);
    if (_loaded) docs.dispose();
    super.dispose();
  }
}
