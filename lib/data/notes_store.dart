import 'dart:math';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'note.dart';
import 'note_format.dart';

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
  Note? get lastEditedNote => _notes.isEmpty ? null : _notes.first;

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    await _store.load();
    final raw = _store.read<List<Object?>>(_key);
    if (raw != null) {
      final notes = <({int storedIndex, Note note})>[];
      for (var index = 0; index < raw.length; index++) {
        final note = Note.fromJson(raw[index]);
        if (note != null) notes.add((storedIndex: index, note: note));
      }
      notes.sort((a, b) {
        final recency = b.note.updatedAt.compareTo(a.note.updatedAt);
        return recency != 0 ? recency : a.storedIndex.compareTo(b.storedIndex);
      });
      _notes = List.unmodifiable(notes.map((entry) => entry.note));
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
    final remaining = List<Note>.of(_notes)..removeAt(index);
    // This edit just happened, so moving it directly to the front avoids an
    // O(n log n) sort on every keystroke while preserving newest-first order.
    _notes = [updatedNote, ...remaining];
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
