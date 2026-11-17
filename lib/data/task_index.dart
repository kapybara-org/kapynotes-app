import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../crdt/note_doc.dart';
import '../sync/doc_store.dart';
import 'local_store.dart';
import 'stamped.dart';
import 'task_lines.dart';

/// What a task's line says, as [TaskEntry.words] holds it: SHA-256 of the
/// words after the box, trimmed, first 16 hex digits.
String wordsDigest(String words) =>
    sha256.convert(utf8.encode(words.trim())).toString().substring(0, 16);

/// What every id minted on this device alone starts with: a task met while
/// no account was there to name it. Never sent; see [TaskIndex.rekey].
const String localTaskIdPrefix = 'local-';

/// What the index holds about one task beyond its line: the plaintext of a
/// task record. Mirrors `TaskPayload` in packages/contract.
@immutable
class TaskEntry {
  const TaskEntry({
    required this.id,
    required this.noteId,
    required this.anchor,
    required this.words,
    required this.addedAt,
    this.enteredAt = 0,
    this.touchedAt = 0,
    this.dot = const Stamped(false, 0),
    this.doNow = const Stamped(false, 0),
    this.doneAt = const Stamped(null, 0),
    this.dismissed = const Stamped(false, 0),
    this.extra = const {},
  });

  /// The record id, derived from [noteId] and [anchor] under the account's
  /// key, so every device names this task the same way.
  final String id;
  final String noteId;

  /// `replica:counter` of the line's first character after its box.
  final String anchor;

  /// [wordsDigest] of the line, for finding it again once [anchor] is gone.
  final Stamped<String> words;
  final int addedAt;

  /// When it last went back in at the end; 0 until it first does.
  final int enteredAt;

  /// Last picked, edited or kept; 0 until then.
  final int touchedAt;

  /// Where it sits in the one list: the order it was added in, or went back
  /// in at the end.
  int get position => enteredAt == 0 ? addedAt : enteredAt;
  final Stamped<bool> dot;
  final Stamped<bool> doNow;
  final Stamped<int?> doneAt;
  final Stamped<bool> dismissed;

  /// Fields a later build wrote, kept and written back untouched.
  final Map<String, Object?> extra;

  static const _known = {
    'noteId',
    'anchor',
    'words',
    'addedAt',
    'enteredAt',
    'touchedAt',
    'dot',
    'doNow',
    'doneAt',
    'dismissed',
  };

  TaskEntry copyWith({
    Stamped<String>? words,
    int? enteredAt,
    int? touchedAt,
    Stamped<bool>? dot,
    Stamped<bool>? doNow,
    Stamped<int?>? doneAt,
    Stamped<bool>? dismissed,
  }) => TaskEntry(
    id: id,
    noteId: noteId,
    anchor: anchor,
    words: words ?? this.words,
    addedAt: addedAt,
    enteredAt: enteredAt ?? this.enteredAt,
    touchedAt: touchedAt ?? this.touchedAt,
    dot: dot ?? this.dot,
    doNow: doNow ?? this.doNow,
    doneAt: doneAt ?? this.doneAt,
    dismissed: dismissed ?? this.dismissed,
    extra: extra,
  );

  /// The same task under another record: this one's state, [id], [anchor]
  /// and [words]. For a task whose anchor went and whose line was found again.
  TaskEntry movedTo({
    required String id,
    required String anchor,
    required Stamped<String> words,
  }) => TaskEntry(
    id: id,
    noteId: noteId,
    anchor: anchor,
    words: words,
    addedAt: addedAt,
    enteredAt: enteredAt,
    touchedAt: touchedAt,
    dot: dot,
    doNow: doNow,
    doneAt: doneAt,
    dismissed: dismissed,
    extra: extra,
  );

  /// Field by field, so the result is the same whichever side merges, and
  /// whatever order the edits from two devices arrive in. Identity stays
  /// with this entry: merging two records for one line keeps the older.
  TaskEntry merge(TaskEntry other) => TaskEntry(
    id: id,
    noteId: noteId,
    anchor: anchor,
    words: words.merge(other.words),
    addedAt: addedAt < other.addedAt ? addedAt : other.addedAt,
    enteredAt: enteredAt > other.enteredAt ? enteredAt : other.enteredAt,
    touchedAt: touchedAt > other.touchedAt ? touchedAt : other.touchedAt,
    dot: dot.merge(other.dot),
    doNow: doNow.merge(other.doNow),
    doneAt: doneAt.merge(other.doneAt),
    dismissed: dismissed.merge(other.dismissed),
    extra: mergeExtra(extra, other.extra),
  );

  Map<String, Object?> toPayload() => {
    ...extra,
    'noteId': noteId,
    'anchor': anchor,
    'words': words.toJson(),
    'addedAt': addedAt,
    'enteredAt': enteredAt,
    'touchedAt': touchedAt,
    'dot': dot.toJson(),
    'doNow': doNow.toJson(),
    'doneAt': doneAt.toJson(),
    'dismissed': dismissed.toJson(),
  };

  /// Null for a payload missing anything this build needs.
  static TaskEntry? fromPayload(String id, Object? raw) {
    if (raw is! Map) return null;
    final noteId = raw['noteId'];
    final anchor = raw['anchor'];
    final words = Stamped.fromJson<String>(raw['words']);
    final addedAt = raw['addedAt'];
    final enteredAt = raw['enteredAt'];
    final touchedAt = raw['touchedAt'];
    final dot = Stamped.fromJson<bool>(raw['dot']);
    final doNow = Stamped.fromJson<bool>(raw['doNow']);
    final doneAt = Stamped.fromJson<int?>(raw['doneAt']);
    final dismissed = Stamped.fromJson<bool>(raw['dismissed']);
    if (noteId is! String ||
        anchor is! String ||
        words == null ||
        addedAt is! int ||
        enteredAt is! int ||
        touchedAt is! int ||
        dot == null ||
        doNow == null ||
        doneAt == null ||
        dismissed == null) {
      return null;
    }
    return TaskEntry(
      id: id,
      noteId: noteId,
      anchor: anchor,
      words: words,
      addedAt: addedAt,
      enteredAt: enteredAt,
      touchedAt: touchedAt,
      dot: dot,
      doNow: doNow,
      doneAt: doneAt,
      dismissed: dismissed,
      extra: {
        for (final entry in raw.entries)
          if (entry.key is String && !_known.contains(entry.key))
            entry.key as String: entry.value,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TaskEntry &&
      other.id == id &&
      jsonEncode(other.toPayload()) == jsonEncode(toPayload());

  @override
  int get hashCode => id.hashCode;
}

/// The task index on this device: every task record, the ones still owed to
/// the server, and how far into the account's record stream it has read.
///
/// Every change carries an `updatedAt`, the record's last-writer-wins key on
/// the server. Merging happens here, field by field, never on the server.
class TaskIndex extends ChangeNotifier {
  TaskIndex(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final LocalStore _store;
  final DateTime Function() _now;

  static const String _key = 'tasks.v1';

  final Map<String, TaskEntry> _entries = {};
  final Map<String, int> _updatedAt = {};

  /// Deleted records not yet acknowledged, by id, with when they went.
  final Map<String, int> _stones = {};
  final Set<String> _dirty = {};
  int _cursor = 0;
  bool _scanned = false;

  Iterable<TaskEntry> get entries => _entries.values;
  TaskEntry? byId(String id) => _entries[id];

  /// The last record seq read from the server.
  int get cursor => _cursor;

  /// Whether every note has been read once. After that only changed ones are.
  bool get scanned => _scanned;

  void markScanned() {
    if (_scanned) return;
    _scanned = true;
    _save();
  }

  int _stamp() => _now().millisecondsSinceEpoch;

  void load() {
    final raw = _store.data[_key];
    if (raw is! Map) return;
    final cursor = raw['cursor'];
    _cursor = cursor is int ? cursor : 0;
    _scanned = raw['scanned'] == true;
    final entries = raw['entries'];
    if (entries is List) {
      for (final item in entries) {
        if (item is! Map) continue;
        final id = item['id'];
        final updatedAt = item['updatedAt'];
        if (id is! String || updatedAt is! int) continue;
        final entry = TaskEntry.fromPayload(id, item['payload']);
        if (entry == null) continue;
        _entries[id] = entry;
        _updatedAt[id] = updatedAt;
        if (item['dirty'] == true) _dirty.add(id);
      }
    }
    final stones = raw['stones'];
    if (stones is Map) {
      for (final stone in stones.entries) {
        if (stone.key is String && stone.value is int) {
          _stones[stone.key as String] = stone.value as int;
          _dirty.add(stone.key as String);
        }
      }
    }
  }

  void _save() {
    _store.put(_key, {
      'cursor': _cursor,
      'scanned': _scanned,
      'entries': [
        for (final entry in _entries.values)
          {
            'id': entry.id,
            'updatedAt': _updatedAt[entry.id],
            if (_dirty.contains(entry.id)) 'dirty': true,
            'payload': entry.toPayload(),
          },
      ],
      'stones': _stones,
    });
    notifyListeners();
  }

  /// The next `updatedAt` for [id]: now, or one past the last if the clock
  /// has not moved on, so a local change always outranks what it replaces.
  int _nextUpdate(String id) {
    final now = _stamp();
    final last = _updatedAt[id] ?? 0;
    return now > last ? now : last + 1;
  }

  void _write(TaskEntry entry) {
    _updatedAt[entry.id] = _nextUpdate(entry.id);
    _entries[entry.id] = entry;
    _stones.remove(entry.id);
    _dirty.add(entry.id);
  }

  void _delete(String id) {
    if (_entries.remove(id) == null) return;
    if (id.startsWith(localTaskIdPrefix)) {
      _updatedAt.remove(id);
      _dirty.remove(id);
      return;
    }
    _stones[id] = _nextUpdate(id);
    _updatedAt.remove(id);
    _dirty.add(id);
  }

  /// Records a local change to one task.
  void update(TaskEntry entry) {
    _write(entry);
    _save();
  }

  /// Brings a note's tasks into line with its text.
  ///
  /// Each record of the note is found by its anchor, and waits while that
  /// names a character another device wrote that has not arrived. One of
  /// this device's own the document does not hold is gone for good, as when
  /// another device's copy of the note won its seed. One whose anchor went
  /// with its line looks for an unclaimed line with the same words, since an
  /// edit that rewrote a stretch of the note takes every anchor in it along,
  /// and moves to that line's record; failing that it is deleted. Two that
  /// land on one line (two devices met it before either saw the other's
  /// record) become the older, with both histories merged in. A checklist
  /// line nobody has a record for joins the end of the list, in the order
  /// the lines read. A line ticked or unticked in the note stamps or clears
  /// when it was done.
  void reconcileNote(
    String noteId,
    NoteDoc doc, {
    required String Function(String anchor) idFor,
  }) {
    final now = _stamp();
    final text = doc.text;
    final lines = taskLines(text);
    final digests = [
      for (final line in lines)
        wordsDigest(text.substring(line.textStart, line.end)),
    ];
    final claimed = <int, TaskEntry>{};
    final orphans = <TaskEntry>[];
    var changed = false;

    final mine = _entries.values.where((e) => e.noteId == noteId).toList()
      ..sort((a, b) {
        final byAdded = a.addedAt.compareTo(b.addedAt);
        return byAdded != 0 ? byAdded : a.id.compareTo(b.id);
      });
    for (final entry in mine) {
      final anchor = parseAnchor(entry.anchor);
      if (anchor != null &&
          !doc.knows(anchor) &&
          anchor.id!.replica != doc.replica) {
        continue;
      }
      final index = taskLineIndex(doc, lines, entry.anchor);
      if (index < 0) {
        orphans.add(entry);
        continue;
      }
      final holder = claimed[index];
      if (holder != null) {
        claimed[index] = holder.merge(entry);
        _delete(entry.id);
        changed = true;
        continue;
      }
      claimed[index] = entry;
    }

    for (final orphan in orphans) {
      _delete(orphan.id);
      changed = true;
      final index = [for (var i = 0; i < lines.length; i++) i].firstWhere(
        (i) => !claimed.containsKey(i) && digests[i] == orphan.words.v,
        orElse: () => -1,
      );
      if (index < 0) continue;
      final anchor = anchorKey(doc, lines[index]);
      claimed[index] = orphan.movedTo(
        id: idFor(anchor),
        anchor: anchor,
        words: orphan.words,
      );
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final current = claimed[i];
      if (current == null) {
        if (line.done) continue;
        final anchor = anchorKey(doc, line);
        _write(
          TaskEntry(
            id: idFor(anchor),
            noteId: noteId,
            anchor: anchor,
            words: Stamped(digests[i], now),
            addedAt: now + i,
          ),
        );
        changed = true;
        continue;
      }
      var next = current;
      if (line.done != (current.doneAt.v != null)) {
        next = next.copyWith(doneAt: Stamped(line.done ? now : null, now));
      }
      if (digests[i] != current.words.v) {
        next = next.copyWith(words: Stamped(digests[i], now));
      }
      if (next != _entries[current.id]) {
        _write(next);
        changed = true;
      }
    }
    if (changed) _save();
  }

  /// Brings the tasks of every note whose document changed since the last
  /// call into line with it, and of every note on the first. A note that is
  /// gone, or keeps no document, loses its tasks.
  void reconcileDocs(
    DocStore docs, {
    required bool Function(String noteId) noteIsLive,
    required String Function(String noteId, String anchor) idFor,
  }) {
    final changed = _scanned
        ? docs.takeChanged()
        : {...docs.takeChanged(), for (final r in docs.records) r.noteId};
    for (final noteId in changed) {
      final record = docs.get(noteId);
      if (record == null || !noteIsLive(noteId)) {
        forgetNote(noteId);
      } else {
        reconcileNote(
          noteId,
          record.doc,
          idFor: (anchor) => idFor(noteId, anchor),
        );
      }
    }
    markScanned();
  }

  /// Moves every task whose id is not the one [idFor] gives its line onto
  /// that id, state and all: for the first pass after signing in, when the
  /// ids this device minted on its own give way to the account's. The old
  /// ids go without a stone, since the server never had them.
  void rekey(String Function(String noteId, String anchor) idFor) {
    var changed = false;
    for (final entry in _entries.values.toList()) {
      final id = idFor(entry.noteId, entry.anchor);
      if (id == entry.id) continue;
      _entries.remove(entry.id);
      _updatedAt.remove(entry.id);
      _dirty.remove(entry.id);
      final moved = entry.movedTo(
        id: id,
        anchor: entry.anchor,
        words: entry.words,
      );
      final existing = _entries[id];
      _write(existing == null ? moved : existing.merge(moved));
      changed = true;
    }
    if (changed) _save();
  }

  /// Every task of a note that is gone.
  void forgetNote(String noteId) {
    final ids = [
      for (final entry in _entries.values)
        if (entry.noteId == noteId) entry.id,
    ];
    if (ids.isEmpty) return;
    ids.forEach(_delete);
    _save();
  }

  // -------------------------------------------------------------------------
  // Sync

  /// What the server has not been told, live and deleted, each with the
  /// `updatedAt` to send.
  List<({String id, int updatedAt, TaskEntry? entry})> get owed => [
    for (final id in _dirty)
      (
        id: id,
        updatedAt: _entries.containsKey(id) ? _updatedAt[id]! : _stones[id]!,
        entry: _entries[id],
      ),
  ];

  /// The server took [id] as sent at [updatedAt]. Anything changed since
  /// stays owed.
  void acknowledge(String id, int updatedAt) {
    final current = _entries.containsKey(id) ? _updatedAt[id] : _stones[id];
    if (current != updatedAt) return;
    _dirty.remove(id);
    _stones.remove(id);
    _save();
  }

  /// A live record as the server holds it, from a pull or a lost push.
  void applyRemote(TaskEntry remote, int updatedAt) {
    final id = remote.id;
    final stone = _stones[id];
    if (stone != null && _dirty.contains(id) && stone > updatedAt) return;
    final local = _entries[id];
    if (local == null || !_dirty.contains(id)) {
      final merged = local == null ? remote : remote.merge(local);
      _entries[id] = merged;
      _stones.remove(id);
      if (merged == remote) {
        _updatedAt[id] = updatedAt;
        _dirty.remove(id);
      } else {
        _updatedAt[id] = updatedAt + 1;
        _dirty.add(id);
      }
    } else {
      _entries[id] = local.merge(remote);
      final mine = _updatedAt[id]!;
      _updatedAt[id] = mine > updatedAt ? mine : updatedAt + 1;
    }
    _save();
  }

  /// A deleted record as the server holds it. A newer local change survives
  /// it and goes up again. One this index never held, a tag record's say,
  /// changes nothing.
  void applyRemoteDelete(String id, int updatedAt) {
    if (!_entries.containsKey(id) && !_stones.containsKey(id)) return;
    if (_dirty.contains(id) && (_updatedAt[id] ?? _stones[id]!) > updatedAt) {
      return;
    }
    _entries.remove(id);
    _updatedAt.remove(id);
    _stones.remove(id);
    _dirty.remove(id);
    _save();
  }

  void recordCursor(int cursor) {
    if (cursor == _cursor) return;
    _cursor = cursor;
    _save();
  }

  /// Drops everything: the records belong to the account signed out of.
  void clear() {
    _entries.clear();
    _updatedAt.clear();
    _stones.clear();
    _dirty.clear();
    _cursor = 0;
    _scanned = false;
    _save();
  }
}
