import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/task_folds.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'task-folds-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  test('folding is remembered here and is not a change to the note', () {
    const note = '☐ Buy milk\n  Oat if they have it.\n';
    final store = _MemoryStore();
    final folds = TaskFolds(store);

    expect(folds.isFolded('n1', 'a:1', done: false), isFalse);
    expect(folds.isFolded('n1', 'a:1', done: true), isTrue);

    folds.setFolded('n1', 'a:1', folded: true);
    expect(folds.isFolded('n1', 'a:1', done: false), isTrue);
    folds.setFolded('n1', 'a:1', folded: false);
    expect(folds.isFolded('n1', 'a:1', done: true), isFalse);

    expect(store.data.keys, [TaskFolds.storeKey]);
    expect(note, '☐ Buy milk\n  Oat if they have it.\n');
  });

  test('the first hint goes away once details have been used', () {
    final folds = TaskFolds(_MemoryStore());
    expect(folds.hintSeen, isFalse);
    folds.markHintSeen();
    expect(folds.hintSeen, isTrue);
    folds.markHintSeen();
    expect(folds.hintSeen, isTrue);
  });
}
