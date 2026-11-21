import 'local_store.dart';

/// Which tasks are folded, on this device only.
///
/// Folding is a way of looking at a note, not a change to it. Nothing here is
/// written into the note, and nothing here is synced. A task the person has
/// not chosen for is folded once it is done, and open until then.
class TaskFolds {
  TaskFolds(this._store);

  static TaskFolds? _shared;

  /// The one store for this device. Editors and the Tasks screen share it, so
  /// a fold made in a note is the same fold the next time that note opens.
  static Future<TaskFolds> open() async {
    final held = _shared;
    if (held != null) return held;
    final store = LocalStore(fileName: 'task-folds.json');
    await store.load();
    return _shared = TaskFolds(store);
  }

  static const String storeKey = 'taskFolds.v1';

  /// Set once any way into a task's details has been used, so the first hint
  /// can go away. Device-local, like the folds.
  static const String hintKey = 'taskDetailsHint.v1';

  final LocalStore _store;

  bool isFolded(String noteId, String anchor, {required bool done}) {
    final stored = _map()['$noteId\n$anchor'];
    if (stored is bool) return stored;
    return done;
  }

  /// Remembers [folded] for this device. Does not touch the note.
  void setFolded(String noteId, String anchor, {required bool folded}) {
    final map = _map();
    map['$noteId\n$anchor'] = folded;
    _store.put(storeKey, map);
  }

  bool get hintSeen => _store.data[hintKey] == true;

  void markHintSeen() {
    if (hintSeen) return;
    _store.put(hintKey, true);
  }

  /// Set once "How Tasks works" is put away with Got it. Device-local, like
  /// the hint.
  static const String howKey = 'howTasksWorks.v1';

  bool get howSeen => _store.data[howKey] == true;

  void markHowSeen() {
    if (howSeen) return;
    _store.put(howKey, true);
  }

  Map<String, Object?> _map() {
    final raw = _store.data[storeKey];
    if (raw is! Map) return {};
    return Map<String, Object?>.from(raw);
  }
}
