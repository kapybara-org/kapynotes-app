import '../calc/engine.dart';
import '../crdt/text_diff.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/task_index.dart';
import '../data/task_lines.dart';

/// Something an assistant asked for that it can't have, in one sentence it
/// can show the person.
class McpRefusal implements Exception {
  const McpRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One checklist line, as an assistant sees it.
typedef McpTask = ({
  String id,
  Note note,
  String text,
  bool done,
  TaskLine line,
});

/// Everything an assistant can reach, and the only way it reaches anything.
///
/// The rules live here rather than in the tools so no tool can step around
/// them: Hidden notes do not exist, archived notes are read-only and listed
/// only on request, drawings show by title, notes in shared spaces are
/// read-only, and nothing is ever deleted. A Hidden note's id is refused with
/// exactly the words an unknown id gets, so an assistant can't tell one is
/// there.
class McpLibrary {
  McpLibrary({
    required this.notes,
    required CalcEngine Function() engine,
    bool Function()? canCreate,
  }) : _engine = engine,
       _canCreate = canCreate ?? (() => true);

  final NotesStore notes;
  final CalcEngine Function() _engine;
  final bool Function() _canCreate;

  static const String notFound = 'No note with that id.';
  static final RegExp _glyphBox = RegExp(r'^[ \t]*[☐☑]');
  static const int maxTitle = 200;
  static const int maxNoteText = 100000;
  static const int maxAppend = 20000;
  static const int maxTaskText = 500;
  static const int maxNoteLength = 1000000;

  /// The most of a note one read returns; the rest follows from its offset.
  static const int pageSize = 50000;

  /// Notes in the order the app lists them: pinned first, then the most
  /// recently changed. Archived ones only when asked for.
  List<Note> list({String query = '', bool includeArchived = false}) {
    final trimmed = query.trim();
    final pool = [
      ...notes.notes,
      if (includeArchived) ...notes.archivedNotes,
    ].where((note) => !note.isHidden);
    final matches = trimmed.isEmpty
        ? pool.toList()
        : pool.where((note) => note.matches(trimmed)).toList();
    matches.sort((a, b) {
      final pinned = (notes.isPinned(b.id) ? 1 : 0) -
          (notes.isPinned(a.id) ? 1 : 0);
      return pinned != 0 ? pinned : b.updatedAt.compareTo(a.updatedAt);
    });
    return matches;
  }

  /// The note with [id], unless it is Hidden or gone.
  Note read(String id) {
    final note = notes.byId(id);
    if (note == null || note.isHidden) throw const McpRefusal(notFound);
    return note;
  }

  /// What a note says, with each attachment as a word in brackets in place
  /// of the character that anchors it. A drawing says only its title.
  String bodyOf(Note note) {
    if (note.isDrawing) return '';
    final body = note.body;
    if (note.attachments.isEmpty) return body;
    final out = StringBuffer();
    var from = 0;
    for (final attachment in note.attachments) {
      final at = attachment.offset;
      if (at < from || at >= body.length) continue;
      out
        ..write(body.substring(from, at))
        ..write(_placeholder(attachment.mime));
      from = at + 1;
    }
    out.write(body.substring(from));
    return out.toString();
  }

  static String _placeholder(String mime) => switch (mime.split('/').first) {
    'image' => '[image]',
    'audio' => '[voice note]',
    'video' => '[video]',
    _ => '[file]',
  };

  /// What the calculator answers on each line, keyed by line number from 1.
  Map<int, String> resultsOf(Note note) {
    if (note.isDrawing) return const {};
    return {
      for (final entry in _engine().evaluateDocument(note.body).entries)
        entry.key + 1: entry.value.text,
    };
  }

  /// Checklist lines in every note an assistant can see, archived ones aside.
  List<McpTask> tasks({String? noteId}) {
    final pool = noteId == null
        ? list()
        : [read(noteId)].where((note) => !note.isArchived);
    return [for (final note in pool) ...tasksIn(note)];
  }

  /// The checklist lines in [note], which the caller has already read.
  List<McpTask> tasksIn(Note note) {
    if (note.isDrawing) return const [];
    final seen = <String, int>{};
    return [
      for (final line in taskLines(note.body))
        _task(note, line, seen),
    ];
  }

  McpTask _task(Note note, TaskLine line, Map<String, int> seen) {
    final text = note.body.substring(line.textStart, line.end).trim();
    final digest = wordsDigest(text);
    final n = seen[digest] = (seen[digest] ?? -1) + 1;
    return (
      id: '${note.id}~$digest~$n',
      note: note,
      text: text,
      done: line.done,
      line: line,
    );
  }

  Note create({required String title, String body = ''}) {
    final heading = _clean(title, maxTitle, 'title').trim();
    if (heading.isEmpty) throw const McpRefusal('A note needs a title.');
    final rest = _clean(body, maxNoteText, 'body');
    if (!_canCreate()) {
      throw const McpRefusal(
        'This account is at its note limit, so Kapy Notes can’t add another.',
      );
    }
    final text = rest.isEmpty ? heading : '$heading\n$rest';
    return notes.create(body: text, authored: false);
  }

  Note append(String id, String text) {
    final addition = _clean(text, maxAppend, 'text');
    if (addition.trim().isEmpty) throw const McpRefusal('There’s no text to add.');
    final note = _writable(id);
    final body = note.body;
    final joined = body.isEmpty || body.endsWith('\n')
        ? '$body$addition'
        : '$body\n$addition';
    return _write(note, joined);
  }

  McpTask addTask(String noteId, String text) {
    final words = _clean(text, maxTaskText, 'text').trim();
    if (words.isEmpty || words.contains('\n')) {
      throw const McpRefusal('A task is one line of text.');
    }
    final note = _writable(noteId);
    final existing = taskLines(note.body);
    final markdown = existing.isNotEmpty &&
        !_glyphBox.hasMatch(
          note.body.substring(existing.first.start, existing.first.textStart),
        );
    final line = markdown ? '- [ ] $words' : '☐ $words';
    final body = note.body;
    final joined = body.isEmpty || body.endsWith('\n') ? '$body$line' : '$body\n$line';
    final written = _write(note, joined);
    return tasksIn(written).lastWhere((task) => task.text == words);
  }

  McpTask setTaskDone(String taskId, {required bool done}) {
    final split = taskId.indexOf('~');
    if (split <= 0) throw const McpRefusal('No task with that id.');
    final note = _writable(taskId.substring(0, split));
    final task = tasksIn(note).where((task) => task.id == taskId).firstOrNull;
    if (task == null) {
      throw const McpRefusal('That task changed; list the tasks again.');
    }
    if (task.done == done) return task;
    final body = note.body;
    final boxed = body.substring(task.line.start, task.line.textStart);
    final box = _glyphBox.hasMatch(boxed)
        ? boxed.replaceFirst(done ? '☐' : '☑', done ? '☑' : '☐')
        : boxed.replaceFirst(
            RegExp(done ? r'\[ \]' : r'\[[xX]\]'),
            done ? '[x]' : '[ ]',
          );
    final written = _write(
      note,
      body.replaceRange(task.line.start, task.line.textStart, box),
    );
    return tasksIn(written).firstWhere((each) => each.id == taskId);
  }

  /// The note with [id] if an assistant may change it. Read again at the
  /// moment of writing, so a note hidden since it was listed is refused.
  Note _writable(String id) {
    final note = read(id);
    if (note.isArchived) {
      throw const McpRefusal('Archived notes are read-only.');
    }
    if (note.isShared) {
      throw const McpRefusal('Notes in shared spaces are read-only here.');
    }
    if (note.isDrawing) {
      throw const McpRefusal('Drawings can’t be changed from an assistant.');
    }
    return note;
  }

  Note _write(Note note, String body) {
    if (body.length > maxNoteLength) {
      throw const McpRefusal('That would make the note too long.');
    }
    notes.updateForAssistant(note.id, body, diffTexts(note.body, body));
    return notes.byId(note.id)!;
  }

  /// [text] as it may be written into a note: line breaks as `\n`, and no
  /// control characters or attachment anchors, which would fake a picture.
  static String _clean(String text, int max, String field) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.length > max) {
      throw McpRefusal('The $field is longer than $max characters.');
    }
    for (final unit in normalized.codeUnits) {
      if ((unit < 0x20 && unit != 0x0A && unit != 0x09) ||
          unit == 0x7F ||
          unit == 0xFFFC) {
        throw McpRefusal('The $field has characters a note can’t hold.');
      }
    }
    return normalized;
  }
}
