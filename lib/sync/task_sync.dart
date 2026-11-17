import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/tags.dart';
import '../data/task_index.dart';
import 'doc_store.dart';
import 'sync_api.dart';
import 'vault.dart';

/// Keeps the account's record stream in step with this device: the task
/// index, read from changed notes' checklist lines, and the tags. One pass
/// sends what both owe and takes in what the server has, under one cursor.
/// A payload with a `kind` is a tag's or a note's tags, one without is a
/// task. See `tasks.ts` and `tags.ts` in packages/contract.
///
/// Never a reason for note sync to fail. A server that does not have the
/// stream yet answers 404, and the records wait on this device until it does.
class TaskSync {
  TaskSync({
    required SyncApi api,
    required Vault vault,
    required TaskIndex index,
    required TagStore tags,
    required DocStore docs,
    required bool Function(String noteId) noteIsLive,
    required Iterable<String> Function() deletedNotes,
    this.delay = const Duration(seconds: 1),
  }) : _api = api,
       _vault = vault,
       _index = index,
       _tags = tags,
       _docs = docs,
       _noteIsLive = noteIsLive,
       _deletedNotes = deletedNotes {
    _tags.addListener(_onTags);
  }

  final SyncApi _api;
  final Vault _vault;
  final TaskIndex _index;
  final TagStore _tags;
  final DocStore _docs;
  final bool Function(String noteId) _noteIsLive;

  /// The notes deleted on this device that are gone for good.
  final Iterable<String> Function() _deletedNotes;

  /// Each tagged note's record id under this account's key, both ways.
  final Map<String, String> _noteTagsIds = {};
  final Map<String, String> _noteOfRecord = {};

  /// How long [schedule] waits, so a burst of typing is one pass.
  final Duration delay;

  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  bool _pullOwed = false;
  bool _rekeyed = false;
  bool _disposed = false;

  void _onTags() {
    if (_tags.owes) schedule();
  }

  /// A pass soon, after [delay], for a change on this device: it reads the
  /// notes that changed and sends what that owes, and asks the server for
  /// nothing.
  void schedule() {
    if (_disposed) return;
    _timer ??= Timer(delay, () {
      _timer = null;
      unawaited(_start());
    });
  }

  /// A whole pass now, or straight after the one under way, ending with a
  /// pull: for a sync pass, and for the socket saying the records moved.
  Future<void> run() {
    _pullOwed = true;
    return _start();
  }

  /// The notes that changed read into the index now, with what that owes
  /// sent on the usual schedule.
  Future<void> reconcile() async {
    await _docs.load();
    _reconcile();
    schedule();
  }

  Future<void> _start() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      try {
        await _pass();
      } on SyncException catch (error) {
        debugPrint('KapyNotes: tasks not synced: ${error.message}');
        return;
      }
    } while (_again && !_disposed);
  }

  /// What the server has first, so a line another device already wrote a
  /// record for is not met again as new here; then the notes; then what
  /// that owes. Before any of it, the ids this device gave tasks while
  /// signed out make way for the account's, so a pulled record meets the
  /// task it is about under the same id.
  Future<void> _pass() async {
    _rekey();
    if (_pullOwed) {
      _pullOwed = false;
      await _pull();
    }
    await _docs.load();
    _reconcile();
    _deletedNotes().forEach(_tags.forgetNote);
    await _push();
  }

  void _rekey() {
    if (_rekeyed) return;
    _rekeyed = true;
    _index.rekey(_vault.taskRecordId);
  }

  void _reconcile() {
    _rekey();
    _index.reconcileDocs(
      _docs,
      noteIsLive: _noteIsLive,
      idFor: _vault.taskRecordId,
    );
  }

  /// Sends what the task index and the tags owe. A record that loses comes
  /// back as the server holds it, is merged in with a later `updatedAt`, and
  /// goes up again: a few rounds at most, since only another device writing
  /// the same record in the same moment can make one lose twice.
  Future<void> _push() async {
    for (var round = 0; round < 3 && !_disposed; round++) {
      final owed = [
        for (final item in _index.owed)
          (
            id: item.id,
            updatedAt: item.updatedAt,
            payload: item.entry?.toPayload(),
            acknowledge: () => _index.acknowledge(item.id, item.updatedAt),
          ),
        for (final item in _tags.owed)
          (
            id: item.kind == Tag.kind ? item.key : _noteTagsId(item.key),
            updatedAt: item.updatedAt,
            payload: item.payload,
            acknowledge: () => _tags.acknowledge(item),
          ),
      ];
      if (owed.isEmpty) return;
      for (var i = 0; i < owed.length; i += tasksPushMax) {
        final chunk = owed.sublist(
          i,
          i + tasksPushMax > owed.length ? owed.length : i + tasksPushMax,
        );
        final records = <WireTaskRecord>[];
        for (final item in chunk) {
          final at = DateTime.fromMillisecondsSinceEpoch(
            item.updatedAt,
            isUtc: true,
          );
          final payload = item.payload;
          records.add(
            WireTaskRecord(
              id: item.id,
              updatedAt: at,
              deletedAt: payload == null ? at : null,
              payload: payload == null
                  ? null
                  : await _vault.sealRaw(
                      utf8.encode(jsonEncode(payload)),
                      null,
                    ),
            ),
          );
        }
        final result = await _api.pushTasks(records);
        _index.hold();
        _tags.hold();
        try {
          for (final item in chunk) {
            if (result.applied.contains(item.id)) item.acknowledge();
          }
        } finally {
          _index.release();
          _tags.release();
        }
        for (final conflict in result.conflicts) {
          await _take(conflict);
        }
        _tags.settle();
      }
    }
  }

  Future<void> _pull() async {
    while (!_disposed) {
      final page = await _api.pullTasks(after: _index.cursor);
      _index.hold();
      _tags.hold();
      try {
        for (final record in page.records) {
          await _take(record);
        }
        _index.recordCursor(page.cursor);
      } finally {
        _index.release();
        _tags.release();
      }
      if (!page.hasMore) break;
    }
    _tags.settle();
  }

  /// One record as the server holds it, to the task index or the tags by
  /// its `kind`. Skipped if it cannot be opened, or if a task or a note's
  /// tags does not derive its own id: a payload moved onto another record's
  /// id is not taken for that record.
  Future<void> _take(WireTaskRecord record) async {
    final updatedAt = record.updatedAt.millisecondsSinceEpoch;
    final payload = record.payload;
    if (payload == null) {
      _index.applyRemoteDelete(record.id, updatedAt);
      _tags.applyRemoteDelete(
        record.id,
        updatedAt,
        noteId: _noteOfRecord[record.id] ?? _findNoteOf(record.id),
      );
      return;
    }
    final opened = await _vault.openRaw(payload, null);
    if (opened == null) {
      debugPrint('KapyNotes: task record ${record.id} could not be opened');
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(opened));
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    switch (decoded['kind']) {
      case null:
        final entry = TaskEntry.fromPayload(record.id, decoded);
        if (entry == null ||
            _vault.taskRecordId(entry.noteId, entry.anchor) != record.id) {
          debugPrint('KapyNotes: task record ${record.id} is not one of ours');
          return;
        }
        _index.applyRemote(entry, updatedAt);
      case Tag.kind:
        final tag = Tag.fromPayload(record.id, decoded);
        if (tag == null) {
          debugPrint('KapyNotes: tag record ${record.id} could not be read');
          return;
        }
        _tags.applyRemoteTag(tag, updatedAt);
      case NoteTags.kind:
        final note = NoteTags.fromPayload(decoded);
        if (note == null || _noteTagsId(note.noteId) != record.id) {
          debugPrint('KapyNotes: tags record ${record.id} is not one of ours');
          return;
        }
        _tags.applyRemoteNote(note, updatedAt);
      default:
        _tags.keepUnknown(record.id, updatedAt);
    }
  }

  String _noteTagsId(String noteId) => _noteTagsIds[noteId] ??= () {
    final id = _vault.noteTagsRecordId(noteId);
    _noteOfRecord[id] = noteId;
    return id;
  }();

  /// The note a deleted record held the tags of, if this device has a tags
  /// record for it that has not been named under this account yet.
  String? _findNoteOf(String recordId) {
    for (final noteId in _tags.noteIds) {
      if (_noteTagsId(noteId) == recordId) return noteId;
    }
    return null;
  }

  void dispose() {
    _tags.removeListener(_onTags);
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
