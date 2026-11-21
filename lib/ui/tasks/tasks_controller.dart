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
import 'task_choice.dart';

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
  ///
  /// Each request carries a number, so asking for the task that is already
  /// asked for still notifies, and a screen that opens after the ask finds it
  /// waiting. See [TasksScreenState._takeSheetRequest].
  final ValueNotifier<({String id, int seq})?> sheetRequest = ValueNotifier(
    null,
  );
  int _sheetSeq = 0;

  void requestSheet(String taskId) =>
      sheetRequest.value = (id: taskId, seq: ++_sheetSeq);
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
  /// back in at the end of the list. False when the box can't be written: a
  /// note shared to view only, or one whose text and document disagree.
  Future<bool> setDone(TaskItem item, {required bool done}) async {
    final current = await _current(item);
    if (current == null) return false;
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
    return true;
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
  /// index holds it, and adds nothing to a note this person cannot change.
  Future<String?> add(String words, {String? noteId}) async {
    final text = words.trim();
    if (text.isEmpty) return null;
    final from = _stamp();
    final target = noteId == null ? read().home : notes.byId(noteId);
    if (target != null && !canEdit(target)) return null;
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

  /// Back in at the end of the list, without its dot. Returns its new place.
  int sendToEnd(TaskItem item) {
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
    return at;
  }

  /// Chosen: a dot, so it waits in Up next or is your choice so far.
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

  /// Take out of Up next: the dot goes, and the task stays where it is on
  /// the list. A Do now another device left on it goes too, or it would come
  /// back the moment the newer Do now was done.
  void takeOutOfUpNext(TaskItem item) {
    final at = _stamp();
    _change(
      item,
      (entry) => entry.copyWith(
        dot: Stamped(false, at),
        doNow: Stamped(false, at),
        touchedAt: at,
      ),
    );
  }

  /// Every dot and Do now cleared, for a fresh round.
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

  // Where the pair has got to, held in memory like main's question position:
  // nothing here is stored or synced. See [TaskChoice].
  int? _seenUpTo;
  int? _since;
  String? _justDone;
  DateTime? _keptGoing;

  /// The task just finished, while the pair asks about tasks that joined
  /// since you chose.
  TaskItem? get justDone =>
      _since == null || _justDone == null ? null : read().byId(_justDone!);

  /// Today under [noteId] as Tasks shows it.
  /// Whether a task's note waits for a later day: such a task is off
  /// today's list, the pair and Up next. Set by the page from its days.
  bool Function(TaskItem item)? waits;

  /// Today's open tasks, in list order, without those that wait for a day.
  List<TaskItem> openIn(String? noteId) => [
    for (final item in read().openIn(noteId))
      if (!(waits?.call(item) ?? false)) item,
  ];

  TaskChoice choiceIn(String? noteId) {
    final board = read();
    final at = now();
    final today = DateTime(at.year, at.month, at.day);
    return TaskChoice.read(
      openIn(noteId),
      seenUpTo: _seenUpTo,
      since: _since,
      evening:
          at.hour >= 18 &&
          _keptGoing != today &&
          board.doneSince(today, noteId: noteId) > 0,
    );
  }

  /// Forgets where the pair had got to, as when the filter changes.
  void forgetPair() {
    _seenUpTo = null;
    _since = null;
    _justDone = null;
  }

  /// ← or a click on the left card: your choice so far stays.
  void keepChoice(PairStage pair) {
    if (!pair.chosen) dot(pair.left);
    _seenUpTo = pair.right.entry.position;
    if (pair.pairsLeft == 0) return startWith(pair.left);
    notifyListeners();
  }

  /// → or a click on the right card: it becomes your choice so far, and the
  /// old choice waits at the top of Up next.
  void takeNext(PairStage pair) {
    if (!pair.chosen) dot(pair.left);
    dot(pair.right);
    _seenUpTo = pair.right.entry.position;
    if (pair.pairsLeft == 0) return startWith(pair.right);
    notifyListeners();
  }

  /// Start with your choice so far: it becomes Do now, earlier picks stay in
  /// Up next, and the tasks not yet shown stay on the list.
  void startWith(TaskItem item) {
    forgetPair();
    doNow(item);
  }

  /// Done on Do now. The pair comes back only for tasks that joined the list
  /// since you chose; with none, the first task in Up next is Do now. When
  /// the tick can't be written, nothing moves on.
  Future<void> finish(TaskItem item, {String? noteId}) async {
    final since = item.entry.doNow.v ? item.entry.doNow.at : _stamp();
    if (!await setDone(item, done: true)) return;
    _seenUpTo = null;
    _since = since;
    _justDone = item.id;
    _settle(noteId);
  }

  /// Not finished: Do now goes to the end of the list, and the first task in
  /// Up next takes its place without asking.
  void notFinished(TaskItem item, {String? noteId}) {
    _seenUpTo = null;
    _since = sendToEnd(item);
    _justDone = null;
    _settle(noteId);
  }

  /// Choose again: every choice cleared, from the first pair.
  void chooseAgain({String? noteId}) {
    forgetPair();
    clearPicks(openIn(noteId));
    notifyListeners();
  }

  /// Keep going, in the evening: the first pair comes back for today.
  void keepGoing() {
    final at = now();
    _keptGoing = DateTime(at.year, at.month, at.day);
    forgetPair();
    notifyListeners();
  }

  /// Do now, from a row's menu. Whatever was Do now waits in Up next.
  void makeDoNow(TaskItem item) => startWith(item);

  /// Move to the end, from a row's menu.
  void moveToEnd(TaskItem item) => sendToEnd(item);

  /// With nothing chosen any more, a new round starts at the first pair;
  /// with only your last pick left to do, it is Do now.
  void _settle(String? noteId) {
    final open = openIn(noteId);
    if (!open.any((item) => item.dotted || item.doNow)) {
      forgetPair();
      notifyListeners();
      return;
    }
    if (choiceIn(noteId).stage case DoNowStage(:final item) when !item.doNow) {
      startWith(item);
      return;
    }
    notifyListeners();
  }
}
