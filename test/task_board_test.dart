import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
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

/// A note of [body] whose random id [wanted] accepts, so a test can rely on
/// note createdAt alone for an order the id would break.
Note _createWith(
  NotesStore notes,
  String body,
  bool Function(String id) wanted,
) {
  while (true) {
    final note = notes.create(body: body);
    if (wanted(note.id)) return note;
    notes.delete(note.id);
  }
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
    final deck = _createWith(
      notes,
      deckBody,
      (id) => id.compareTo(room.id) < 0,
    );
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

  test('notes picked up in one reconcile keep each note\'s tasks together, '
      'oldest note first, and a task added later comes after them', () async {
    var clock = DateTime(2026, 11, 19, 8, 55);
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
    const carBody = 'Car\n☐ Call the garage\n☐ Pay the deposit';
    const tripBody = 'Trip\n☐ Book flights\n☐ Learn phrases\n☐ Pack';
    final car = notes.create(body: carBody);
    clock = DateTime(2026, 11, 19, 8, 20);
    final trip = _createWith(notes, tripBody, (id) => id.compareTo(car.id) > 0);
    clock = DateTime(2026, 11, 19, 9);
    await library.reconcileNow();

    List<String> order() => [for (final item in tasks.read().open) item.words];
    var expected = [
      'Book flights',
      'Learn phrases',
      'Pack',
      'Call the garage',
      'Pay the deposit',
    ];
    expect(order(), expected);

    notes.updateBody(trip.id, '$tripBody\n☐ Charge the camera');
    await library.reconcileNow();
    expected = [...expected, 'Charge the camera'];
    expect(order(), expected);

    for (var frame = 0; frame < 4; frame++) {
      clock = clock.add(const Duration(minutes: 1));
      notes.updateBody(car.id, '$carBody\nframe $frame');
      notes.updateBody(trip.id, '$tripBody\n☐ Charge the camera\nframe $frame');
      await library.reconcileNow();
      expect(order(), expected, reason: 'frame $frame');
    }
  });
}
