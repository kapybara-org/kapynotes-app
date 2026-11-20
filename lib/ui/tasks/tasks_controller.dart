import 'package:flutter/foundation.dart';

import '../../data/note.dart';
import '../../data/note_attachment.dart';
import '../../data/notes_store.dart';
import '../../data/stamped.dart';
import '../../crdt/note_doc.dart';
import '../../data/task_board.dart';
import '../../data/task_details.dart';
import '../../data/task_index.dart';
import '../../data/task_library.dart';
import '../../data/task_lines.dart';
import '../editor/editor_formatting.dart';

/// What Tasks does to tasks: everything that writes, kept apart from how it
/// looks. A task's box and words live in its note, so ticking, adding and
/// removing write the note; its place in the list, its dot and Do now live
/// in the task index.
///
/// Notifies when the notes or the index change, and reads the board once
/// per change for everything that shows it.
class TasksController extends ChangeNotifier {
  /// The task the menu bar asked the Tasks screen to open a sheet for.
  /// Cleared once the screen has taken it. Not a change to any note.
  final ValueNotifier<String?> sheetRequest = ValueNotifier(null);

  void requestSheet(String taskId) => sheetRequest.value = taskId;
  TasksController({
    required this.notes,
    required this.library,
    required this.canEdit,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    _sources.addListener(_changed);
  }

  final NotesStore notes;
  final TaskLibrary library;
  final bool Function(Note note) canEdit;
  final DateTime Function() now;

  late final Listenable _sources = Listenable.merge([notes, library]);
  TaskBoard? _board;

  TaskIndex get index => library.index;

  NoteDoc? docOf(String noteId) =>
      library.isLoaded ? library.docs.get(noteId)?.doc : null;

  Future<void> reconcileNow() => library.reconcileNow();

  void _changed() {
    _board = null;
    notifyListeners();
  }

  @override
  void dispose() {
    sheetRequest.dispose();
    _sources.removeListener(_changed);
    super.dispose();
  }

  TaskBoard read() => _board ??= TaskBoard.read(
    entries: index.entries,
    notes: notes.notes,
    docOf: docOf,
  );

  int _stamp() => now().millisecondsSinceEpoch;

  /// The record as the index holds it now, changed by [change].
  void _change(TaskItem item, TaskEntry Function(TaskEntry entry) change) {
    final entry = index.byId(item.id);
    if (entry != null) index.update(change(entry));
  }

  /// [item]'s note and line as they are now, once the index has caught up
  /// with the note. Null when the task has gone, or when the note's text and
  /// its document disagree and a write would land in the wrong place.
  Future<(Note, TaskLine)?> _current(TaskItem item) async {
    await reconcileNow();
    final note = notes.byId(item.note.id);
    final doc = docOf(item.note.id);
    final entry = index.byId(item.id);
    if (note == null || doc == null || entry == null) return null;
    if (doc.text != note.body || !canEdit(note)) return null;
    final lines = taskLines(note.body);
    final at = taskLineIndex(doc, lines, entry.anchor);
    return at < 0 ? null : (note, lines[at]);
  }

  /// Replaces [start]..[end] of [note]'s text with [replacement], carrying
  /// its styles and pictures across.
  void _rewrite(Note note, int start, int end, String replacement) {
    final body = note.body.replaceRange(start, end, replacement);
    notes.updateDocument(
      note.id,
      body,
      rebaseNoteFormats(
        oldText: note.body,
        newText: body,
        formats: note.formats,
        insertedFormats: const {},
      ),
      rebaseNoteAttachments(
        oldText: note.body,
        newText: body,
        attachments: note.attachments,
        selectionStart: start,
        selectionEnd: end,
      ),
      (start: start, oldEnd: end, newEnd: start + replacement.length),
    );
  }

  /// Ticks or unticks [item]'s box in its note. Unticked from Done, it goes
  /// back in at the end of the list.
  Future<void> setDone(TaskItem item, {required bool done}) async {
    final current = await _current(item);
    if (current == null) return;
    final (note, line) = current;
    final head = note.body.substring(line.start, line.textStart);
    final glyph = head.indexOf(RegExp('[☐☑]'));
    final box = glyph >= 0 ? glyph : head.indexOf('[') + 1;
    final mark = glyph >= 0 ? (done ? '☑' : '☐') : (done ? 'x' : ' ');
    _rewrite(note, line.start + box, line.start + box + 1, mark);
    final at = _stamp();
    _change(
      item,
      (entry) => entry.copyWith(
        doneAt: Stamped(done ? at : null, at),
        dot: Stamped(false, at),
        doNow: Stamped(false, at),
        enteredAt: done ? null : at,
        touchedAt: at,
      ),
    );
    await reconcileNow();
  }

  /// Opens an empty details line under [item], so Add details has somewhere
  /// to write. A task that already has details is left as it is.
  Future<void> openDetails(TaskItem item) async {
    final current = await _current(item);
    if (current == null) return;
    final (note, line) = current;
    if (taskBlockOf(note.body, line)?.details != null) return;
    final indent = ' ' * (line.textStart - line.start);
    if (line.end >= note.body.length) {
      _rewrite(note, line.end, line.end, '\n$indent');
    } else if (note.body[line.end] == '\n') {
      _rewrite(note, line.end + 1, line.end + 1, '$indent\n');
    } else {
      _rewrite(note, line.end, line.end, '\n$indent');
    }
    await reconcileNow();
  }

  /// Writes [plain] as the words under [item], in its note. Pictures already
  /// there stay. An empty [plain] takes an empty block away and leaves a note
  /// that had no details exactly as it was.
  Future<void> setDetails(TaskItem item, String plain) async {
    final current = await _current(item);
    if (current == null) return;
    final (note, line) = current;
    final body = replaceTaskDetails(note.body, line, plain);
    if (body == note.body) return;
    var start = 0;
    final oldLen = note.body.length;
    final newLen = body.length;
    while (start < oldLen &&
        start < newLen &&
        note.body.codeUnitAt(start) == body.codeUnitAt(start)) {
      start++;
    }
    var tail = 0;
    while (tail < oldLen - start &&
        tail < newLen - start &&
        note.body.codeUnitAt(oldLen - 1 - tail) ==
            body.codeUnitAt(newLen - 1 - tail)) {
      tail++;
    }
    _rewrite(note, start, oldLen - tail, body.substring(start, newLen - tail));
    await reconcileNow();
  }

  /// Adds a task at the end of [noteId]'s text, or of the note for tasks
  /// with no note, made on first use. Returns the new task's id once the
  /// index holds it.
  Future<String?> add(String words, {String? noteId}) async {
    final text = words.trim();
    if (text.isEmpty) return null;
    final from = _stamp();
    final target = noteId == null ? read().home : notes.byId(noteId);
    final String id;
    if (target == null) {
      id = notes
          .create(body: '${TaskBoard.homeTitle}\n$uncheckedPrefix$text')
          .id;
    } else {
      final body = target.body;
      final glue = body.isEmpty || body.endsWith('\n') ? '' : '\n';
      _rewrite(target, body.length, body.length, '$glue$uncheckedPrefix$text');
      id = target.id;
    }
    await reconcileNow();
    final added = [
      for (final item in read().open)
        if (item.note.id == id && item.entry.addedAt >= from) item,
    ];
    return added.isEmpty ? null : added.last.id;
  }

  /// Takes [item]'s line out of its note, and returns what puts it back
  /// where it was, in its old place in the list. A task in a note this
  /// person cannot change is only dismissed from Tasks.
  Future<Future<void> Function()?> remove(TaskItem item) async {
    final current = await _current(item);
    if (current == null) {
      final note = notes.byId(item.note.id);
      if (note == null || canEdit(note)) return null;
      _change(item, (e) => e.copyWith(dismissed: Stamped(true, _stamp())));
      return () async =>
          _change(item, (e) => e.copyWith(dismissed: Stamped(false, _stamp())));
    }
    final (note, line) = current;
    final last = line.end >= note.body.length;
    final start = last && line.start > 0 ? line.start - 1 : line.start;
    final end = last ? line.end : line.end + 1;
    final removed = note.body.substring(start, end);
    final before = index.byId(item.id)!;
    _rewrite(note, start, end, '');
    await reconcileNow();
    return () async {
      final now = notes.byId(note.id);
      if (now == null) return;
      final from = _stamp();
      final at = start.clamp(0, now.body.length);
      _rewrite(now, at, at, removed);
      await reconcileNow();
      for (final back in read().open) {
        if (back.note.id != note.id || back.entry.addedAt < from) continue;
        if (back.entry.words.v != before.words.v) continue;
        index.update(
          before.movedTo(
            id: back.id,
            anchor: back.entry.anchor,
            words: back.entry.words,
          ),
        );
        return;
      }
    };
  }

  /// Not finished: back in at the end of the list, without its dot.
  void sendToEnd(TaskItem item) {
    final at = _stamp();
    _change(
      item,
      (entry) => entry.copyWith(
        enteredAt: at,
        touchedAt: at,
        dot: Stamped(false, at),
        doNow: Stamped(false, at),
      ),
    );
  }

  /// Picked while scanning: a dot, and the question moves on to it.
  void dot(TaskItem item) {
    final at = _stamp();
    _change(
      item,
      (entry) => entry.copyWith(dot: Stamped(true, at), touchedAt: at),
    );
  }

  /// The end of a pass: [item] is Do now, with its dot. Any other task left
  /// as Do now, in whichever note, is cleared, whatever the view shows.
  void doNow(TaskItem item) {
    final at = _stamp();
    for (final other in read().open) {
      if (other.entry.doNow.v && other.id != item.id) {
        _change(other, (entry) => entry.copyWith(doNow: Stamped(false, at)));
      }
    }
    _change(
      item,
      (entry) => entry.copyWith(
        dot: Stamped(true, at),
        doNow: Stamped(true, at),
        touchedAt: at,
      ),
    );
  }

  /// One task's pick taken back: neither dotted nor Do now. The others stay
  /// picked, but a Do now another device left on one of them is cleared too,
  /// or it would show again the moment this one went.
  void clearPick(TaskItem item) {
    final at = _stamp();
    for (final other in read().open) {
      if (other.entry.doNow.v && other.id != item.id) {
        _change(other, (entry) => entry.copyWith(doNow: Stamped(false, at)));
      }
    }
    _change(
      item,
      (entry) => entry.copyWith(
        dot: Stamped(false, at),
        doNow: Stamped(false, at),
        touchedAt: at,
      ),
    );
  }

  /// Pick again: every dot and Do now cleared, for a fresh pass.
  void clearPicks(Iterable<TaskItem> open) {
    final at = _stamp();
    for (final item in open) {
      if (!item.dotted && !item.doNow) continue;
      _change(
        item,
        (entry) =>
            entry.copyWith(dot: Stamped(false, at), doNow: Stamped(false, at)),
      );
    }
  }

  /// Still wanted: it stops asking for another [TaskBoard.staleAfter].
  void keep(TaskItem item) =>
      _change(item, (entry) => entry.copyWith(touchedAt: _stamp()));
}
