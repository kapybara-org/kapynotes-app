import '../crdt/note_doc.dart';
import 'note.dart';
import 'task_index.dart';
import 'task_lines.dart';

/// A task as Tasks shows it: its record, the note it lives in, and the words
/// on its line.
class TaskItem {
  const TaskItem({
    required this.entry,
    required this.note,
    required this.words,
    required this.line,
  });

  final TaskEntry entry;
  final Note note;
  final String words;

  /// Its line in the note's text, as the board read it.
  final TaskLine line;

  String get id => entry.id;
  bool get dotted => entry.dot.v;
  bool get doNow => entry.doNow.v;
  DateTime? get doneAt => switch (entry.doneAt.v) {
    final at? => DateTime.fromMillisecondsSinceEpoch(at),
    null => null,
  };

  /// When it was last added, put back, picked, edited or kept.
  int get lastTouched => [
    entry.addedAt,
    entry.enteredAt,
    entry.touchedAt,
  ].reduce((a, b) => a > b ? a : b);
}

/// Every task the person can act on, read from the task index and the
/// notes: the one list in its fixed order, and what is done, newest first.
///
/// A note's tasks count while the note is in My notes or a shared space.
/// Archived and hidden notes are left out, and so are drawings.
class TaskBoard {
  TaskBoard._(this.open, this.done, this.home);

  /// The note a task with no note of its own goes into: the oldest of the
  /// person's own notes called [homeTitle], made on first use.
  static const String homeTitle = 'Tasks';

  /// How long a task can sit untouched before it asks whether it is still
  /// wanted.
  static const Duration staleAfter = Duration(days: 14);

  factory TaskBoard.read({
    required Iterable<TaskEntry> entries,
    required List<Note> notes,
    required NoteDoc? Function(String noteId) docOf,
  }) {
    final byNote = <String, List<TaskEntry>>{};
    for (final entry in entries) {
      if (entry.dismissed.v) continue;
      (byNote[entry.noteId] ??= []).add(entry);
    }
    Note? home;
    final open = <TaskItem>[];
    final done = <TaskItem>[];
    for (final note in notes) {
      if (note.isDrawing || note.isArchived || note.isHidden) continue;
      if (!note.isShared &&
          note.title == homeTitle &&
          (home == null || note.createdAt.isBefore(home.createdAt))) {
        home = note;
      }
      final mine = byNote[note.id];
      if (mine == null) continue;
      final doc = docOf(note.id);
      if (doc == null) continue;
      final text = doc.text;
      final lines = taskLines(text);
      final taken = <int>{};
      mine.sort((a, b) => a.addedAt.compareTo(b.addedAt));
      for (final entry in mine) {
        final index = taskLineIndex(doc, lines, entry.anchor);
        if (index < 0 || !taken.add(index)) continue;
        final line = lines[index];
        final item = TaskItem(
          entry: entry,
          note: note,
          words: text.substring(line.textStart, line.end).trim(),
          line: line,
        );
        if (!line.done) {
          open.add(item);
        } else if (entry.doneAt.v != null) {
          done.add(item);
        }
      }
    }
    open.sort((a, b) {
      final byPosition = a.entry.position.compareTo(b.entry.position);
      return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
    });
    done.sort((a, b) => b.entry.doneAt.v!.compareTo(a.entry.doneAt.v!));
    return TaskBoard._(open, done, home);
  }

  /// The one list, in the order tasks were added or went back in at the end.
  final List<TaskItem> open;

  /// Finished tasks, the most recently finished first.
  final List<TaskItem> done;
  final Note? home;

  /// Whether [item] lives in the note for tasks with no note.
  bool isHome(TaskItem item) => item.note.id == home?.id;

  /// The open tasks under a filter: every one, or one note's.
  List<TaskItem> openIn(String? noteId) => noteId == null
      ? open
      : [
          for (final item in open)
            if (item.note.id == noteId) item,
        ];

  /// How many tasks under [noteId] were finished since [since].
  int doneSince(DateTime since, {String? noteId}) => done
      .where(
        (item) =>
            (noteId == null || item.note.id == noteId) &&
            !item.doneAt!.isBefore(since),
      )
      .length;

  TaskItem? byId(String id) {
    for (final item in open) {
      if (item.id == id) return item;
    }
    for (final item in done) {
      if (item.id == id) return item;
    }
    return null;
  }
}
