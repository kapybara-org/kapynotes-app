import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'sync-state-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Document storage whose writes wait until the test lets them land, or fail.
class _HeldStorage extends MemoryDocStorage {
  Completer<void> gate = Completer<void>();
  bool failing = false;

  @override
  Future<void> write(String noteId, Map<String, Object?> json) async {
    await gate.future;
    if (failing) throw const FileSystemLikeException();
    await super.write(noteId, json);
  }
}

class FileSystemLikeException implements Exception {
  const FileSystemLikeException();
}

Map<String, Object?> _saved(LocalStore store) =>
    (store.data['sync.v1'] as Map?)?.cast<String, Object?>() ?? const {};

Map<String, Object?> _savedCursors(LocalStore store) =>
    (_saved(store)['opCursors'] as Map?)?.cast<String, Object?>() ?? const {};

void main() {
  late _MemoryStore store;
  late SyncState state;
  late _HeldStorage storage;
  late DocStore docs;

  setUp(() async {
    store = _MemoryStore();
    state = SyncState(store)..load();
    storage = _HeldStorage();
    docs = DocStore(storage, replica: 'replica')
      ..beforeFlush = state.cursorsToSave;
    await docs.load();
  });

  tearDown(() => docs.dispose());

  test('a cursor reaches disk only once the documents it describes have', () async {
    docs.create('note', 'space');
    state.recordCursor('space', 7);
    expect(state.cursorFor('space'), 7);

    final flushing = docs.flush();
    await Future<void>.delayed(Duration.zero);
    expect(_savedCursors(store)['space'], isNot(7), reason: 'still writing');

    storage.gate.complete();
    await flushing;
    expect(_savedCursors(store)['space'], 7);
  });

  test('a record that failed to write keeps its cursor off disk', () async {
    docs.create('note', 'space');
    state.recordCursor('space', 7);
    storage
      ..failing = true
      ..gate.complete();
    await docs.flush();
    expect(_savedCursors(store)['space'], isNot(7));

    storage.failing = false;
    await docs.flush();
    expect(_savedCursors(store)['space'], 7);
  });

  test('a cursor recorded mid-flush waits for the next one', () async {
    docs.create('note', 'space');
    state.recordCursor('space', 3);
    final flushing = docs.flush();
    await Future<void>.delayed(Duration.zero);
    // Applied while the first flush is writing: its documents are not in it.
    state.recordCursor('space', 9);
    docs.markDirty('note');
    storage.gate.complete();
    await flushing;
    expect(_savedCursors(store)['space'], 3);

    await docs.flush();
    expect(_savedCursors(store)['space'], 9);
  });

  test('the repair starts once, from the beginning of every log followed', () {
    store.data['sync.v1'] = {
      'deviceId': 'device',
      'opCursors': {'a': 5, 'b': 9},
    };
    state.load();

    expect(state.beginLogRepair(), isTrue);
    expect(state.cursorFor('a'), 0);
    expect(state.cursorFor('b'), 0);
    expect(state.owesRepair('a'), isTrue);
    expect(state.owesRepair('b'), isTrue);
    expect(_savedCursors(store), {'a': 0, 'b': 0});
    expect(state.beginLogRepair(), isFalse);

    // A relaunch halfway through carries on rather than starting over.
    final again = SyncState(store)..load();
    expect(again.beginLogRepair(), isFalse);
    expect(again.owesRepair('a'), isTrue);
  });

  test('a device that never synced has nothing to repair', () {
    expect(state.beginLogRepair(), isFalse);
    expect(_saved(store)['repairVersion'], SyncState.logRepairVersion);
  });

  test('forgetting a space saves none of the others ahead of their documents', () async {
    store.data['sync.v1'] = {
      'deviceId': 'device',
      'opCursors': {'a': 1, 'b': 1},
      'repairVersion': SyncState.logRepairVersion,
    };
    state.load();
    state.recordCursor('a', 5);

    state.forgetSpace('b');
    expect(_savedCursors(store), {'a': 1});
    expect(state.cursorFor('a'), 5);
  });
}
