import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../crdt/crdt.dart';

/// Where a note's merge state lives between runs.
///
/// The note list on disk is the rendered text — what the user reads and what
/// every other part of the app already knows how to handle. Beside it, one
/// record per note holds what sync needs and nothing else does: the CRDT
/// document with its character identities and tombstones, the per-device op
/// counter, and the outbox of changes the server has not acknowledged. The
/// two are kept apart so a keystroke rewrites one small file rather than
/// every note the user owns, and so a build that never syncs pays for none
/// of it.
///
/// Records are plaintext on local disk, as the notes themselves are; sealing
/// happens on the way out.
abstract class DocStorage {
  Future<List<String>> list();
  Future<Map<String, Object?>?> read(String noteId);
  Future<void> write(String noteId, Map<String, Object?> json);
  Future<void> delete(String noteId);
}

/// One JSON file per note under the app's support directory.
class FileDocStorage implements DocStorage {
  FileDocStorage({Directory? directory, String folder = 'kapy-docs'})
    : _directory = directory,
      _folder = folder;

  Directory? _directory;
  final String _folder;

  Future<Directory> _dir() async {
    final existing = _directory;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_folder');
    await dir.create(recursive: true);
    return _directory = dir;
  }

  File _file(Directory dir, String noteId) => File('${dir.path}/$noteId.json');

  @override
  Future<List<String>> list() async {
    final dir = await _dir();
    final ids = <String>[];
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      ids.add(entry.uri.pathSegments.last.replaceAll('.json', ''));
    }
    return ids;
  }

  @override
  Future<Map<String, Object?>?> read(String noteId) async {
    final file = _file(await _dir(), noteId);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String noteId, Map<String, Object?> json) async {
    final dir = await _dir();
    final file = _file(dir, noteId);
    // Write-then-rename, as the note list does: a crash mid-write leaves the
    // previous record rather than half of the new one.
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> delete(String noteId) async {
    final file = _file(await _dir(), noteId);
    if (await file.exists()) await file.delete();
  }
}

/// In memory, for tests and for a build that has nowhere to write.
class MemoryDocStorage implements DocStorage {
  final Map<String, Map<String, Object?>> files = {};

  @override
  Future<List<String>> list() async => files.keys.toList();

  @override
  Future<Map<String, Object?>?> read(String noteId) async {
    final stored = files[noteId];
    return stored == null
        ? null
        : jsonDecode(jsonEncode(stored)) as Map<String, Object?>;
  }

  @override
  Future<void> write(String noteId, Map<String, Object?> json) async {
    files[noteId] = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  }

  @override
  Future<void> delete(String noteId) async {
    files.remove(noteId);
  }
}

/// One change waiting for the server's acknowledgement.
///
/// Held as plaintext rather than sealed, so a content key that rotates
/// between the edit and the send — the server answers `content-key-epoch`
/// — costs a re-seal and not a lost edit. Exactly one of [ops] and
/// [snapshot] is set, or neither for a bare tombstone.
class OutboxEntry {
  OutboxEntry({
    required this.id,
    required this.spaceId,
    this.ops,
    this.deviceSeq,
    this.snapshot,
    this.covers = 0,
    this.deleted,
    this.from,
    this.seed = false,
  });

  final String id;
  final String spaceId;

  /// Plaintext atomic ops, as the engine emitted them.
  final List<Object?>? ops;

  /// The per-device counter this batch of ops takes.
  final int? deviceSeq;

  /// A plaintext snapshot of the whole document.
  final Map<String, Object?>? snapshot;

  /// The space cursor the snapshot was taken at.
  final int covers;
  final bool? deleted;
  final String? from;
  final bool seed;

  /// Sent and not yet answered. Cleared on disconnect so it goes again.
  bool inFlight = false;

  Map<String, Object?> toJson() => {
    'id': id,
    'spaceId': spaceId,
    if (ops != null) 'ops': ops,
    if (deviceSeq != null) 'deviceSeq': deviceSeq,
    if (snapshot != null) 'snapshot': snapshot,
    if (covers != 0) 'covers': covers,
    if (deleted != null) 'deleted': deleted,
    if (from != null) 'from': from,
    if (seed) 'seed': true,
  };

  static OutboxEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final spaceId = raw['spaceId'];
    if (id is! String || spaceId is! String) return null;
    final ops = raw['ops'];
    final snapshot = raw['snapshot'];
    return OutboxEntry(
      id: id,
      spaceId: spaceId,
      ops: ops is List ? List<Object?>.of(ops) : null,
      deviceSeq: raw['deviceSeq'] is int ? raw['deviceSeq'] as int : null,
      snapshot: snapshot is Map
          ? Map<String, Object?>.of(snapshot.cast())
          : null,
      covers: raw['covers'] is int ? raw['covers'] as int : 0,
      deleted: raw['deleted'] is bool ? raw['deleted'] as bool : null,
      from: raw['from'] is String ? raw['from'] as String : null,
      seed: raw['seed'] == true,
    );
  }
}

/// Everything sync keeps about one note.
class DocRecord {
  DocRecord({
    required this.noteId,
    required NoteDoc doc,
    required String replica,
    required this.spaceId,
    this.deviceSeq = 0,
    this.opsSinceSnapshot = 0,
    this.ownOpsSinceSnapshot = 0,
    this.seeded = false,
    List<OutboxEntry>? outbox,
  }) : _doc = doc,
       _replica = replica,
       outbox = outbox ?? [];

  DocRecord._compact({
    required this.noteId,
    required String snapshotJson,
    required String replica,
    required this.spaceId,
    this.deviceSeq = 0,
    this.opsSinceSnapshot = 0,
    this.ownOpsSinceSnapshot = 0,
    this.seeded = false,
    List<OutboxEntry>? outbox,
  }) : _snapshotJson = snapshotJson,
       _replica = replica,
       outbox = outbox ?? [];

  final String noteId;
  final String _replica;
  NoteDoc? _doc;
  String? _snapshotJson;
  void Function(DocRecord record)? onAccess;

  /// Materializes the CRDT graph only while this note is being worked on.
  NoteDoc get doc {
    var value = _doc;
    if (value == null) {
      try {
        final raw = jsonDecode(_snapshotJson!);
        if (raw is! Map) throw const FormatException('snapshot is not a map');
        value = NoteDoc.fromSnapshot(
          Map<String, Object?>.of(raw.cast()),
          replica: _replica,
        );
      } catch (error) {
        // The rendered note is still the source the user sees. Starting an
        // empty merge document lets the next reconcile rebuild its history,
        // matching the old behavior of dropping an unreadable record.
        debugPrint('KapyNotes: doc record for $noteId unreadable: $error');
        value = NoteDoc(replica: _replica);
      }
      _doc = value;
      _snapshotJson = null;
    }
    onAccess?.call(this);
    return value;
  }

  set doc(NoteDoc value) {
    _doc = value;
    _snapshotJson = null;
    onAccess?.call(this);
  }

  bool get isMaterialized => _doc != null;

  /// Replaces the object-heavy character graph with compact JSON. The next
  /// access restores it synchronously, so recent notes stay instant while old
  /// notes stop occupying RAM twice alongside their rendered text.
  void compact() {
    final value = _doc;
    if (value == null) return;
    _snapshotJson = jsonEncode(value.toSnapshot());
    _doc = null;
  }

  /// The space the server holds this note in — the one the log lives in.
  /// A local note whose space differs is one that has been moved and not
  /// yet told the server.
  String spaceId;

  /// Counts up per batch of ops this device sends for this note.
  int deviceSeq;

  /// Ops applied since the last snapshot anyone wrote, and how many of them
  /// were this device's. Both drive when it is this device's turn to write
  /// the next one.
  int opsSinceSnapshot;
  int ownOpsSinceSnapshot;

  /// True once the server is known to hold this note's history — after a
  /// seed was acknowledged, or after any of it arrived from the server.
  bool seeded;

  final List<OutboxEntry> outbox;

  /// Content keys by epoch, so an op sealed under a key that has since
  /// rotated can still be opened for as long as this session holds it.
  final Map<int, Uint8List> keys = {};

  /// The space generation the newest key in [keys] was minted under.
  int? keyGeneration;

  /// The content-key epoch the server last accepted a write under, or saw
  /// one arrive under. A local key ahead of it is a rotation on its way up,
  /// and a rotation has to carry a snapshot.
  int serverEpoch = 0;

  bool get hasPending => outbox.isNotEmpty;

  Map<String, Object?> toJson() => {
    'v': 1,
    'spaceId': spaceId,
    'deviceSeq': deviceSeq,
    'opsSinceSnapshot': opsSinceSnapshot,
    'ownOpsSinceSnapshot': ownOpsSinceSnapshot,
    'seeded': seeded,
    'serverEpoch': serverEpoch,
    'doc': _snapshotForWrite(),
    'outbox': outbox.map((entry) => entry.toJson()).toList(),
  };

  Map<String, Object?> _snapshotForWrite() {
    final value = _doc;
    if (value != null) return value.toSnapshot();
    final raw = jsonDecode(_snapshotJson!);
    if (raw is! Map) throw const FormatException('snapshot is not a map');
    return Map<String, Object?>.of(raw.cast());
  }

  static DocRecord? fromJson(
    String noteId,
    Map<String, Object?> raw, {
    required String replica,
  }) {
    final spaceId = raw['spaceId'];
    final doc = raw['doc'];
    if (spaceId is! String || doc is! Map) return null;
    final outbox = raw['outbox'];
    try {
      return DocRecord._compact(
          noteId: noteId,
          snapshotJson: jsonEncode(Map<String, Object?>.of(doc.cast())),
          replica: replica,
          spaceId: spaceId,
          deviceSeq: raw['deviceSeq'] is int ? raw['deviceSeq'] as int : 0,
          opsSinceSnapshot: raw['opsSinceSnapshot'] is int
              ? raw['opsSinceSnapshot'] as int
              : 0,
          ownOpsSinceSnapshot: raw['ownOpsSinceSnapshot'] is int
              ? raw['ownOpsSinceSnapshot'] as int
              : 0,
          seeded: raw['seeded'] == true,
          outbox: outbox is List
              ? outbox
                    .map(OutboxEntry.fromJson)
                    .whereType<OutboxEntry>()
                    .toList()
              : null,
        )
        ..serverEpoch = raw['serverEpoch'] is int
            ? raw['serverEpoch'] as int
            : 0;
    } catch (error) {
      debugPrint('KapyNotes: doc record for $noteId unreadable: $error');
      return null;
    }
  }
}

/// The records, loaded once and written back as they change.
///
/// Writes are coalesced per note: a burst of typing rewrites the record once
/// a quarter of a second, not once a keystroke, and [flush] is what the app
/// calls on its way to the background.
class DocStore {
  DocStore(
    this._storage, {
    required String replica,
    this.writeDelay = const Duration(milliseconds: 250),
    this.maxHotRecords = 8,
  }) : assert(maxHotRecords > 0),
       _replica = replica;

  final DocStorage _storage;
  final String _replica;
  final Duration writeDelay;
  final int maxHotRecords;

  final Map<String, DocRecord> _records = {};
  final LinkedHashSet<String> _hot = LinkedHashSet<String>();
  final Set<String> _dirty = {};
  Timer? _timer;
  Future<void>? _loading;
  bool _loaded = false;

  String get replica => _replica;
  bool get isLoaded => _loaded;
  Iterable<DocRecord> get records => _records.values;
  int get materializedCount =>
      _records.values.where((record) => record.isMaterialized).length;

  /// Ops waiting for the server, across every note.
  int get pendingCount =>
      _records.values.fold(0, (sum, record) => sum + record.outbox.length);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      for (final noteId in await _storage.list()) {
        final raw = await _storage.read(noteId);
        if (raw == null) continue;
        final record = DocRecord.fromJson(noteId, raw, replica: _replica);
        if (record != null) {
          record.onAccess = _recordAccessed;
          _records[noteId] = record;
        }
      }
    } catch (error) {
      debugPrint('KapyNotes: doc store unreadable: $error');
    }
    _loaded = true;
  }

  DocRecord? get(String noteId) => _records[noteId];

  /// A fresh, empty document for a note the store has never seen.
  DocRecord create(String noteId, String spaceId) {
    final record = DocRecord(
      noteId: noteId,
      doc: NoteDoc(replica: _replica),
      replica: _replica,
      spaceId: spaceId,
    );
    record.onAccess = _recordAccessed;
    _records[noteId] = record;
    _recordAccessed(record);
    markDirty(noteId);
    return record;
  }

  /// Forgets a note's merge state. For a note that is gone for good, or one
  /// whose history turned out to live on the server already.
  void remove(String noteId) {
    if (_records.remove(noteId) == null) return;
    _hot.remove(noteId);
    _dirty.remove(noteId);
    unawaited(_storage.delete(noteId));
  }

  void markDirty(String noteId) {
    _dirty.add(noteId);
    _timer ??= Timer(writeDelay, () => unawaited(flush()));
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_dirty.isEmpty) return;
    final ids = _dirty.toList();
    _dirty.clear();
    for (final id in ids) {
      final record = _records[id];
      if (record == null) continue;
      try {
        await _storage.write(id, record.toJson());
      } catch (error) {
        debugPrint('KapyNotes: doc record for $id not written: $error');
        _dirty.add(id);
      }
    }
    _trimHotRecords();
  }

  void _recordAccessed(DocRecord record) {
    _hot.remove(record.noteId);
    _hot.add(record.noteId);
    _trimHotRecords();
  }

  void _trimHotRecords() {
    while (_hot.length > maxHotRecords) {
      final id = _hot.first;
      _hot.remove(id);
      _records[id]?.compact();
    }
  }

  /// Drops every record. For signing in as somebody else.
  Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    _dirty.clear();
    final ids = _records.keys.toList();
    _records.clear();
    _hot.clear();
    for (final id in ids) {
      await _storage.delete(id);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
