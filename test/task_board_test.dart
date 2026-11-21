import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'task-board-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  test('tasks picked up in one reconcile keep their order, frame after frame '
      'and when their ids change', () async {
    var clock = DateTime(2026, 11, 19, 8, 20);
    final store = _MemoryStore();
    final notes = NotesStore(store, now: () => clock);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => clock,
    );
    await notes.load();
    await library.load();
    final tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => true,
      now: () => clock,
    );
    addTearDown(() {
      tasks.dispose();
      library.dispose();
    });
    const roomBody = 'Quote for the deck\n☐ Book the room';
    const deckBody = 'Call with Arjun\n☐ Send the deck';
    final room = notes.create(body: roomBody);
    clock = DateTime(2026, 11, 19, 8, 55);
    final deck = notes.create(body: deckBody);
    clock = DateTime(2026, 11, 19, 9);
    await library.reconcileNow();

    List<String> order() => [for (final item in tasks.read().open) item.words];
    const expected = ['Book the room', 'Send the deck'];
    expect(order(), expected);

    for (var frame = 0; frame < 4; frame++) {
      clock = clock.add(const Duration(minutes: 1));
      final first = frame.isEven ? deck.id : room.id;
      library.index.rekey(
        (noteId, anchor) => '${noteId == first ? 'a' : 'b'}$frame-$anchor',
      );
      notes.updateBody(room.id, '$roomBody\nframe $frame');
      await library.reconcileNow();
      expect(order(), expected, reason: 'frame $frame');
    }
  });
}
