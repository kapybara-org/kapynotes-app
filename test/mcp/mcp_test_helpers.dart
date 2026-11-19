import 'dart:typed_data';

import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/mcp/mcp_library.dart';
import 'package:kapy_notes/sync/key_store.dart';

class McpTestStore extends LocalStore {
  McpTestStore() : super(fileName: 'mcp-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}
}

class MemorySecrets implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A notes store with one note of each kind an assistant must treat
/// differently, and the library over it.
class McpFixture {
  McpFixture({bool canCreate = true}) {
    library = McpLibrary(
      notes: notes,
      engine: () => engine,
      tags: tags,
      canCreate: () => canCreate,
      isLocked: (note) => locked.contains(note.id),
    );
    plain = notes
        .create(
          body:
              'Trip budget\nflights = 420\nhotel = 300\n☐ Book taxi\n☑ Pack bag',
          authored: false,
        )
        .id;
    hidden = notes
        .create(
          body: 'Secret diary\nnothing to see',
          hidden: true,
          authored: false,
        )
        .id;
    archived = notes
        .create(body: 'Old receipts\n- [ ] file taxes', authored: false)
        .id;
    notes.archive(archived);
    drawing = notes.create().id;
    notes.setDrawingMode(drawing, drawing: true);
    shared = notes
        .create(
          body: 'Team plan\n☐ Ship it',
          spaceId: 'team',
          contentKey: Uint8List(32),
          authored: false,
        )
        .id;
  }

  final store = McpTestStore();
  late final NotesStore notes = NotesStore(store);
  late final TagStore tags = TagStore(store);
  final engine = CalcEngine();

  /// Notes Free holds read-only, past the note limit.
  final locked = <String>{};
  late final McpLibrary library;
  late final String plain;
  late final String hidden;
  late final String archived;
  late final String drawing;
  late final String shared;
}
