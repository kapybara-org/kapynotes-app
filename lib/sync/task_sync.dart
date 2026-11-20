import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai/kapy_chat_book.dart';
import '../ai/kapy_chat_records.dart';
import '../data/tags.dart';
import '../data/task_index.dart';
import 'doc_store.dart';
import 'sync_api.dart';
import 'vault.dart';

/// Keeps the account's record stream in step with this device: the task
/// index, read from changed notes' checklist lines, the tags and, for an
/// account with Pro, the Kapy AI chats. One pass sends what they owe and
/// takes in what the server has, under one cursor. A payload with a `kind`
/// is a tag's, a note's tags, a chat or a chat's message, one without is a
/// task. See `tasks.ts`, `tags.ts` and `chats.ts` in packages/contract.
///
/// Chats ride it only while [chatsOn] says so, the plan's answer. Until then
/// nothing of a chat is sent or taken in, and when it turns on the stream is
/// read again from the start, since a pull in between may have passed some
/// by.
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
    KapyChatBook? chats,
    bool Function()? chatsOn,
    this.delay = const Duration(seconds: 1),
  }) : _api = api,
       _vault = vault,
       _index = index,
       _tags = tags,
       _docs = docs,
       _noteIsLive = noteIsLive,
       _deletedNotes = deletedNotes,
       _chats = chats,
       _chatsOn = chatsOn ?? (() => true) {
    _tags.addListener(_onTags);
    _chats
      ?..attach(() => !_disposed && _chatsOn(), run, _chatRecordId)
      ..addListener(_onChats);
  }

  final SyncApi _api;
  final Vault _vault;
  final TaskIndex _index;
  final TagStore _tags;
  final DocStore _docs;
  final bool Function(String noteId) _noteIsLive;
  final KapyChatBook? _chats;
  final bool Function() _chatsOn;

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

  void _onChats() {
    if (_chats?.owes ?? false) schedule();
  }

  /// Whether chats go up and come down in this pass.
  bool get _chatsSync => _chats != null && _chatsOn();

  /// The plan may have changed: a whole pass, with a pull, if it now has
  /// chats to send or take in.
  void planChanged() {
    _chats?.refreshGate();
    if (_chatsSync) unawaited(run());
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

  /// Why the server last refused what this sent, until a pass goes through.
  /// Tasks, tags and chats travel here, so the sync status says so rather
  /// than reading as synced without them.
  String? get refusal => _refusal;
  String? _refusal;

  /// Told when [refusal] changes.
  void Function()? onRefusal;

  void _refused(String? refusal) {
    if (refusal == _refusal) return;
    _refusal = refusal;
    onRefusal?.call();
  }

  Future<void> _loop() async {
    do {
      _again = false;
      try {
        await _pass();
        _refused(null);
      } on SyncRefusedException catch (error) {
        // Not Pro, or a server from before tasks: nothing is wrong to show.
        if (error.code == proRequiredCode || error.status == 404) return;
        _refused(
          error.code == 'too many tasks'
              ? 'Too many tasks to sync. Delete some to sync again.'
              : 'Tasks and tags could not sync (${error.code}).',
        );
        return;
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
    final rewind = (_chats?.skipped ?? false) && _chatsSync;
    if (rewind && _index.cursor > 0) {
      _index.recordCursor(0);
      _pullOwed = true;
    }
    if (_pullOwed) {
      _pullOwed = false;
      await _pull();
      if (rewind) _chats!.clearSkipped();
    }
    await _docs.load();
    _reconcile();
    for (final noteId in _deletedNotes()) {
      if (_docs.neverSent(noteId)) {
        _tags.dropNote(noteId);
      } else {
        _tags.forgetNote(noteId);
      }
    }
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

  /// Sends what the task index and the tags owe, then what the chats owe, in
  /// chunks of their own: a push over the account's limit is refused whole,
  /// and a chunk that held a task or a tag with the chats would take it down
  /// with them. A note's tags wait for the note: none go up for one the
  /// server has never had. A record that loses comes back as the server
  /// holds it, is merged in with a later `updatedAt`, and goes up again: a
  /// few rounds at most, since only another device writing the same record
  /// in the same moment can make one lose twice.
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
          if (item.kind == Tag.kind || !_docs.neverSent(item.key))
            (
              id: item.kind == Tag.kind ? item.key : _noteTagsId(item.key),
              updatedAt: item.updatedAt,
              payload: item.payload,
              acknowledge: () => _tags.acknowledge(item),
            ),
      ];
      final owedChats = [
        if (_chatsSync)
          for (final item in _chats!.owed())
            (
              id: _chatRecordId(item.key),
              updatedAt: item.updatedAt,
              payload: item.payload,
              acknowledge: () => _chats.acknowledge(item),
            ),
      ];
      if (owed.isEmpty && owedChats.isEmpty) return;
      final chunks = [
        for (final list in [owed, owedChats])
          for (var i = 0; i < list.length; i += tasksPushMax)
            list.sublist(
              i,
              i + tasksPushMax > list.length ? list.length : i + tasksPushMax,
            ),
      ];
      for (final chunk in chunks) {
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
        _chats?.hold();
        try {
          for (final item in chunk) {
            if (result.applied.contains(item.id)) item.acknowledge();
          }
        } finally {
          _index.release();
          _tags.release();
          _chats?.release();
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
      if (!_chatsSync && page.records.isNotEmpty) _chats?.markSkipped();
      _index.hold();
      _tags.hold();
      _chats?.hold();
      try {
        for (final record in page.records) {
          await _take(record);
        }
        _index.recordCursor(page.cursor);
      } finally {
        _index.release();
        _tags.release();
        _chats?.release();
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
      if (_chatsSync) {
        final key = _chats!.keyOfRecord(record.id);
        if (key != null) _chats.applyRemoteDelete(key, updatedAt);
      }
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
      case chatKind:
        if (!_chatsSync) return;
        _tags.dropUnknown(record.id);
        final chat = ChatMeta.fromPayload(decoded);
        if (chat == null || _vault.chatRecordId(chat.chatId) != record.id) {
          debugPrint('KapyNotes: chat record ${record.id} is not one of ours');
          return;
        }
        _chats!.applyRemoteChat(chat, updatedAt);
      case chatMessageKind:
        if (!_chatsSync) return;
        _tags.dropUnknown(record.id);
        final part = ChatMessagePart.fromPayload(decoded);
        if (part == null ||
            _vault.chatMessageRecordId(
                  part.chatId,
                  part.messageId,
                  part.part,
                ) !=
                record.id) {
          debugPrint('KapyNotes: chat record ${record.id} is not one of ours');
          return;
        }
        _chats!.applyRemotePart(part, updatedAt);
      default:
        _tags.keepUnknown(record.id, updatedAt);
    }
  }

  /// A chat record's id under this account's key, from its key.
  String _chatRecordId(String key) {
    final parts = key.split(':');
    return parts[0] == 'c'
        ? _vault.chatRecordId(parts[1])
        : _vault.chatMessageRecordId(parts[1], parts[2], int.parse(parts[3]));
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
    _chats
      ?..removeListener(_onChats)
      ..detach();
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
