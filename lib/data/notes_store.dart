import 'dart:math';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'note.dart';

/// Owns the note list and its persistence.
///
/// Notes are held newest-first. Every mutation updates memory synchronously
/// and schedules a coalesced disk write, so the UI never waits on I/O.
class NotesStore extends ChangeNotifier {
  static const String _key = 'notes.v1';

  final LocalStore _store;
  final DateTime Function() _now;
  List<Note> _notes = const [];
  bool _loaded = false;
  Future<void>? _loadFuture;

  NotesStore(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  List<Note> get notes => _notes;
  bool get isLoaded => _loaded;
  bool get isEmpty => _notes.isEmpty;

  /// The note whose contents changed most recently.
  ///
  /// Creation order is intentionally kept separate from edit recency so the
  /// sidebar stays stable while the user types.
  Note? get lastEditedNote {
    if (_notes.isEmpty) return null;

    var latest = _notes.first;
    for (final note in _notes.skip(1)) {
      if (note.updatedAt.isAfter(latest.updatedAt)) latest = note;
    }
    return latest;
  }

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    await _store.load();
    final raw = _store.read<List<Object?>>(_key);
    if (raw != null) {
      _notes = raw.map(Note.fromJson).whereType<Note>().toList(growable: false);
    }
    _loaded = true;
    notifyListeners();
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
  Note create({String body = ''}) {
    final now = _now();
    final note = Note(id: _newId(), body: body, createdAt: now, updatedAt: now);
    _notes = [note, ..._notes];
    _persist();
    return note;
  }

  void updateBody(String id, String body) {
    final index = indexOf(id);
    if (index < 0) return;
    final existing = _notes[index];
    if (existing.body == body) return;

    final updated = List<Note>.of(_notes);
    updated[index] = existing.copyWith(body: body, updatedAt: _now());
    _notes = updated;
    _persist();
  }

  void delete(String id) {
    final index = indexOf(id);
    if (index < 0) return;
    _notes = List<Note>.of(_notes)..removeAt(index);
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

  Future<void> flush() => _store.flush();

  void _persist() {
    _store.put(_key, _notes.map((note) => note.toJson()).toList());
    notifyListeners();
  }

  // IDs never leave local storage as credentials. Avoid a secure-entropy
  // platform call when creating the first note on a fresh mobile install.
  static final Random _random = Random();

  /// A UUID-v4-shaped identifier. Avoids a dependency for something this small.
  static String _newId() {
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
