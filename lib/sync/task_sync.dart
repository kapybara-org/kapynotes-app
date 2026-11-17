import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/task_index.dart';
import 'doc_store.dart';
import 'sync_api.dart';
import 'vault.dart';

/// Keeps the task index in step with the notes and with the account's other
/// devices: reads changed notes' checklist lines, sends what is owed, and
/// takes in what the server has. See `tasks.ts` in packages/contract.
///
/// Never a reason for note sync to fail. A server that does not have the
/// index yet answers 404, and the records wait on this device until it does.
class TaskSync {
  TaskSync({
    required SyncApi api,
    required Vault vault,
    required TaskIndex index,
    required DocStore docs,
    required bool Function(String noteId) noteIsLive,
    this.delay = const Duration(seconds: 1),
  }) : _api = api,
       _vault = vault,
       _index = index,
       _docs = docs,
       _noteIsLive = noteIsLive;

  final SyncApi _api;
  final Vault _vault;
  final TaskIndex _index;
  final DocStore _docs;
  final bool Function(String noteId) _noteIsLive;

  /// How long [schedule] waits, so a burst of typing is one pass.
  final Duration delay;

  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  bool _pullOwed = false;
  bool _disposed = false;

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
  /// that owes.
  Future<void> _pass() async {
    if (_pullOwed) {
      _pullOwed = false;
      await _pull();
    }
    await _docs.load();
    final changed = _index.scanned
        ? _docs.takeChanged()
        : {..._docs.takeChanged(), for (final r in _docs.records) r.noteId};
    for (final noteId in changed) {
      final record = _docs.get(noteId);
      if (record == null || !_noteIsLive(noteId)) {
        _index.forgetNote(noteId);
      } else {
        _index.reconcileNote(
          noteId,
          record.doc,
          idFor: (anchor) => _vault.taskRecordId(noteId, anchor),
        );
      }
    }
    _index.markScanned();
    await _push();
  }

  /// Sends what is owed. A record that loses comes back as the server holds
  /// it, is merged in with a later `updatedAt`, and goes up again: a few
  /// rounds at most, since only another device writing the same task in the
  /// same moment can make one lose twice.
  Future<void> _push() async {
    for (var round = 0; round < 3 && !_disposed; round++) {
      final owed = _index.owed;
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
          final entry = item.entry;
          records.add(
            WireTaskRecord(
              id: item.id,
              updatedAt: at,
              deletedAt: entry == null ? at : null,
              payload: entry == null
                  ? null
                  : await _vault.sealRaw(
                      utf8.encode(jsonEncode(entry.toPayload())),
                      null,
                    ),
            ),
          );
        }
        final result = await _api.pushTasks(records);
        for (final item in chunk) {
          if (result.applied.contains(item.id)) {
            _index.acknowledge(item.id, item.updatedAt);
          }
        }
        for (final conflict in result.conflicts) {
          await _take(conflict);
        }
      }
    }
  }

  Future<void> _pull() async {
    while (!_disposed) {
      final page = await _api.pullTasks(after: _index.cursor);
      for (final record in page.records) {
        await _take(record);
      }
      _index.recordCursor(page.cursor);
      if (!page.hasMore) return;
    }
  }

  /// One record as the server holds it. Skipped if it cannot be opened, or
  /// if what it says does not derive its own id: a payload moved onto
  /// another record's id is not taken for that task.
  Future<void> _take(WireTaskRecord record) async {
    final updatedAt = record.updatedAt.millisecondsSinceEpoch;
    final payload = record.payload;
    if (payload == null) {
      _index.applyRemoteDelete(record.id, updatedAt);
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
    final entry = TaskEntry.fromPayload(record.id, decoded);
    if (entry == null ||
        _vault.taskRecordId(entry.noteId, entry.anchor) != record.id) {
      debugPrint('KapyNotes: task record ${record.id} is not one of ours');
      return;
    }
    _index.applyRemote(entry, updatedAt);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
