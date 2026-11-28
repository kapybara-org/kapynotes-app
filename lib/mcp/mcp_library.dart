import '../calc/engine.dart';
import '../crdt/text_diff.dart';
import '../data/folders.dart';
import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/note_drawing.dart';
import '../data/note_format.dart';
import '../data/notes_store.dart';
import '../data/task_index.dart';
import '../data/tags.dart';
import '../data/task_lines.dart';
import 'mcp_drawing.dart';

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

/// One change [McpLibrary.edit] makes.
sealed class McpEdit {
  const McpEdit();
}

/// Puts [replacement] in place of [find]: its only occurrence, the
/// [occurrence]th from 1, or every one when [occurrence] is 0.
class McpReplace extends McpEdit {
  const McpReplace({
    required this.find,
    required this.replacement,
    this.occurrence,
  });

  final String find;
  final String replacement;
  final int? occurrence;
}

/// Puts [text] between [start] and [end], offsets in the text read_note
/// gives, or at [start] when [end] is null. [expected], when given, must be
/// what is there now.
class McpSplice extends McpEdit {
  const McpSplice({
    required this.start,
    this.end,
    required this.text,
    this.expected,
  });

  final int start;
  final int? end;
  final String text;
  final String? expected;
}

typedef _Region = ({int start, int end, String text});

/// Everything an assistant can reach, and the only way it reaches anything.
///
/// The rules live here rather than in the tools so no tool can step around
/// them: Hidden notes do not exist, archived notes are read-only and listed
/// only on request, drawings show by title, notes in shared spaces are
/// read-only, notes Free holds read-only past its limit stay so, and nothing
/// is ever deleted. A Hidden note's id is refused with
/// exactly the words an unknown id gets, so an assistant can't tell one is
/// there.
class McpLibrary {
  McpLibrary({
    required this.notes,
    required CalcEngine Function() engine,
    this.tags,
    this.folders,
    bool Function()? canCreate,
    bool Function(Note note)? isLocked,
    bool Function(Note note)? sharedWithMe,
  }) : _engine = engine,
       _canCreate = canCreate ?? (() => true),
       _isLocked = isLocked ?? ((_) => false),
       _sharedWithMe = sharedWithMe ?? ((note) => note.isShared);

  final NotesStore notes;

  /// The person's tags, or null in a build without them.
  final TagStore? tags;

  /// The person's folders, or null in a build without them. They stay on the
  /// account and never enter a shared space.
  final FolderStore? folders;
  final CalcEngine Function() _engine;
  final bool Function() _canCreate;
  final bool Function(Note note) _isLocked;
  final bool Function(Note note) _sharedWithMe;

  static const String notFound = 'No note with that id.';
  static final RegExp _glyphBox = RegExp(r'^[ \t]*[☐☑]');
  static const int maxTitle = 200;
  static const int maxNoteText = 100000;
  static const int maxAppend = 20000;
  static const int maxTaskText = 500;
  static const int maxNoteLength = 1000000;
  static const int maxEdits = 50;

  /// The most of a note one read returns; the rest follows from its offset.
  static const int pageSize = 50000;

  /// Notes in the order the app lists them: pinned first, then the most
  /// recently changed. Archived ones only when asked for, or only them.
  /// [tag] and [pinned] narrow it further.
  List<Note> list({
    String query = '',
    bool includeArchived = false,
    bool archivedOnly = false,
    String? tag,
    bool? pinned,
  }) {
    final trimmed = query.trim();
    final tagged = tag == null ? null : _tag(tag).id;
    final pool =
        [
          if (!archivedOnly) ...notes.notes,
          if (includeArchived || archivedOnly) ...notes.archivedNotes,
        ].where(
          (note) =>
              !note.isHidden &&
              (pinned == null || notes.isPinned(note.id) == pinned) &&
              (tagged == null ||
                  tags!.tagsOf(note.id).any((each) => each.id == tagged)),
        );
    final matches = trimmed.isEmpty
        ? pool.toList()
        : pool.where((note) => note.matches(trimmed)).toList();
    matches.sort((a, b) {
      final pinned =
          (notes.isPinned(b.id) ? 1 : 0) - (notes.isPinned(a.id) ? 1 : 0);
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
    final results = _engine().evaluateDocument(note.body, titled: true);
    return {
      for (final entry in results.entries) entry.key + 1: entry.value.text,
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
    return [for (final line in taskLines(note.body)) _task(note, line, seen)];
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
    _checkCreate();
    final text = rest.isEmpty ? heading : '$heading\n$rest';
    return notes.create(body: text, authored: false);
  }

  void _checkCreate() {
    if (!_canCreate()) {
      throw const McpRefusal(
        'This account is at its note limit, so Kapy Notes can’t add another.',
      );
    }
  }

  Note append(String id, String text) {
    final addition = _clean(text, maxAppend, 'text');
    if (addition.trim().isEmpty) {
      throw const McpRefusal('There’s no text to add.');
    }
    final note = _writable(id);
    final body = note.body;
    final joined = body.isEmpty || body.endsWith('\n')
        ? '$body$addition'
        : '$body\n$addition';
    return _write(note, joined);
  }

  McpTask addTask(String noteId, String text) {
    final words = _taskWords(text);
    final note = _writable(noteId);
    final line = '${_box(note)}$words';
    final body = note.body;
    final joined = body.isEmpty || body.endsWith('\n')
        ? '$body$line'
        : '$body\n$line';
    final written = _write(note, joined);
    return tasksIn(written).lastWhere((task) => task.text == words);
  }

  McpTask setTaskDone(String taskId, {required bool done}) {
    final task = _taskAt(taskId);
    if (task.done == done) return task;
    final note = task.note;
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

  /// Why an assistant may not change what [note] says, its title or its
  /// drawing, or null when it may.
  String? readOnlyReason(Note note) {
    if (note.isArchived) return 'Archived notes are read-only.';
    if (note.isShared) return 'Notes in shared spaces are read-only here.';
    if (_isLocked(note)) return 'Read-only on Free.';
    return null;
  }

  /// The note with [id] if an assistant may change its content. Read again
  /// at the moment of writing, so a note hidden since it was listed is
  /// refused.
  Note _changeable(String id) {
    final note = read(id);
    final reason = readOnlyReason(note);
    if (reason != null) throw McpRefusal(reason);
    return note;
  }

  /// [_changeable], and a note with text rather than a drawing.
  Note _writable(String id) {
    final note = _changeable(id);
    if (note.isDrawing) {
      throw const McpRefusal('A drawing has no text. Use draw to change it.');
    }
    return note;
  }

  // ---------------------------------------------------------------------------
  // Titles, pins and the archive

  /// Puts [title] in place of the note's first line, or a drawing's title.
  Note rename(String id, String title) {
    final heading = _clean(title, maxTitle, 'title').trim();
    if (heading.isEmpty || heading.contains('\n')) {
      throw const McpRefusal('A title is one line of text.');
    }
    final note = _changeable(id);
    if (note.isDrawing) {
      notes.updateDrawing(id, note.drawing!, title: heading, authored: false);
    } else {
      if (note.firstLine.contains(_anchor)) {
        throw const McpRefusal(
          'This note’s first line holds an attachment, so it can’t be renamed '
          'from here.',
        );
      }
      notes.retitle(id, heading);
    }
    return notes.byId(id)!;
  }

  /// Pins or unpins a note; false when it already was. Pins are the
  /// person's own and reach nobody else, so a shared note can be pinned.
  bool setPinned(String id, {required bool pinned}) {
    final note = read(id);
    if (note.isArchived) {
      throw const McpRefusal('Archived notes can’t be pinned.');
    }
    if (notes.isPinned(id) == pinned) return false;
    notes.togglePinned(id);
    return true;
  }

  /// Archives a note or brings it back; false when it already was. Never on
  /// a shared note, which would leave everyone's list.
  bool setArchived(String id, {required bool archived}) {
    final note = read(id);
    if (note.isShared) {
      throw const McpRefusal(
        'Notes in shared spaces can’t be archived from here.',
      );
    }
    if (note.isArchived == archived) return false;
    archived ? notes.archive(id) : notes.restore(id);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Editing text

  /// Makes every edit in [edits] to the note as it stands now: offsets and
  /// matches all refer to that one text, and no two may overlap. An edit
  /// can't cut an attachment out. Styles and attachments move with the text
  /// around them.
  Note edit(String id, List<McpEdit> edits) {
    if (edits.isEmpty) throw const McpRefusal('There are no edits.');
    if (edits.length > maxEdits) {
      throw const McpRefusal('That’s more than $maxEdits edits at once.');
    }
    final note = _writable(id);
    final body = note.body;
    final regions = <_Region>[];
    for (final edit in edits) {
      switch (edit) {
        case McpReplace(:final find, :final replacement, :final occurrence):
          final needle = _clean(find, maxAppend, 'find');
          final text = _clean(replacement, maxAppend, 'replacement');
          if (needle.isEmpty) throw const McpRefusal('find can’t be empty.');
          final found = <int>[];
          for (var at = body.indexOf(needle); at >= 0;) {
            found.add(at);
            at = body.indexOf(needle, at + needle.length);
          }
          final quoted = '“${_clipped(needle)}”';
          if (found.isEmpty) throw McpRefusal('$quoted isn’t in the note.');
          final List<int> chosen;
          if (occurrence == null) {
            if (found.length > 1) {
              throw McpRefusal(
                '$quoted is in the note ${found.length} times. Say which '
                'occurrence, or all.',
              );
            }
            chosen = found;
          } else if (occurrence == 0) {
            chosen = found;
          } else if (occurrence > found.length) {
            throw McpRefusal(
              '$quoted is in the note only ${found.length} times.',
            );
          } else {
            chosen = [found[occurrence - 1]];
          }
          for (final at in chosen) {
            regions.add((start: at, end: at + needle.length, text: text));
          }
        case McpSplice(:final start, :final end, :final text, :final expected):
          final from = _realOffset(note, start);
          final to = _realOffset(note, end ?? start);
          if (to < from) {
            throw const McpRefusal('end comes before start.');
          }
          final there = body.substring(from, to);
          if (expected != null && there != expected) {
            throw const McpRefusal('That note changed; read it again.');
          }
          if (there.contains(_anchor)) {
            throw const McpRefusal(
              'That would remove an attachment, and assistants can’t.',
            );
          }
          regions.add((
            start: from,
            end: to,
            text: _clean(text, maxAppend, 'text'),
          ));
      }
    }
    regions.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < regions.length; i++) {
      if (regions[i].start < regions[i - 1].end ||
          regions[i].start == regions[i - 1].start) {
        throw const McpRefusal('Two of those edits overlap.');
      }
    }
    return _splice(note, regions);
  }

  /// Writes [regions], sorted and apart, into [note], moving styles and
  /// attachments along. None of them holds an attachment's anchor.
  Note _splice(Note note, List<_Region> regions) {
    var text = note.body;
    var formats = note.formats;
    var attachments = note.attachments;
    for (final region in regions.reversed) {
      final newEnd = region.start + region.text.length;
      final delta = newEnd - region.end;
      int moved(int at) => at <= region.start
          ? at
          : at >= region.end
          ? at + delta
          : newEnd;
      text = text.replaceRange(region.start, region.end, region.text);
      formats = [
        for (final range in formats)
          NoteFormatRange(
            start: moved(range.start),
            end: moved(range.end),
            format: range.format,
          ),
      ];
      attachments = [
        for (final ref in attachments)
          ref.offset >= region.end
              ? ref.copyWith(offset: ref.offset + delta)
              : ref,
      ];
    }
    return _write(
      note,
      text,
      formats: normalizeNoteFormats(formats, text.length),
      attachments: attachments,
    );
  }

  /// Where [view], an offset in [bodyOf]'s text, is in the note's own text.
  int _realOffset(Note note, int view) {
    var shift = 0;
    for (final ref in note.attachments) {
      final at = ref.offset + shift;
      if (view <= at) break;
      final width = _placeholder(ref.mime).length;
      if (view < at + width) {
        throw const McpRefusal('That offset is inside an attachment.');
      }
      shift += width - 1;
    }
    final real = view - shift;
    if (real < 0 || real > note.body.length) {
      throw const McpRefusal('That offset is past the end of the note.');
    }
    return real;
  }

  static const String _anchor = '\uFFFC';

  static String _clipped(String text) =>
      text.length <= 40 ? text : '${text.substring(0, 39)}…';

  // ---------------------------------------------------------------------------
  // Tags

  TagStore get _tags =>
      tags ?? (throw const McpRefusal('Tags aren’t available here.'));

  Tag _tag(String name) => switch (_tags.named(name)) {
    final tag? when _visible(tag) => tag,
    _ => throw McpRefusal('There’s no tag called “${name.trim()}”.'),
  };

  /// Whether an assistant may know [tag] exists: no Hidden note carries it,
  /// or a note it can see does too. A tag only Hidden notes carry is as
  /// hidden as they are, its name included.
  bool _visible(Tag tag) =>
      !_onHidden(tag) ||
      notes.allNotes.any((note) => !note.isHidden && _carries(note, tag));

  bool _onHidden(Tag tag) =>
      notes.hiddenNotes.any((note) => _carries(note, tag));

  bool _carries(Note note, Tag tag) =>
      _tags.tagsOf(note.id).any((each) => each.id == tag.id);

  /// [name]'s tag, if changing it reaches no Hidden note. The refusal says
  /// nothing of why, so it gives no Hidden note away.
  Tag _changeableTag(String name) {
    final tag = _tag(name);
    if (_onHidden(tag)) {
      throw const McpRefusal('Change this tag in Kapy Notes.');
    }
    return tag;
  }

  /// The live tag called [name], ignoring case.
  Tag tagNamed(String name) => _tag(name);

  /// The tags on [note], in its order. Read by every summary.
  List<Tag> tagsOf(Note note) => tags?.tagsOf(note.id) ?? const [];

  /// Every tag, with how many notes an assistant can see carry it.
  List<({Tag tag, int notes})> allTags() {
    final store = _tags;
    final counts = <String, int>{};
    for (final note in list(includeArchived: true)) {
      for (final tag in store.tagsOf(note.id)) {
        counts[tag.id] = (counts[tag.id] ?? 0) + 1;
      }
    }
    return [
      for (final tag in store.tags)
        if (_visible(tag)) (tag: tag, notes: counts[tag.id] ?? 0),
    ];
  }

  /// Adds and takes off tags by name. Tags are the person's own, so a shared
  /// or archived note can carry them too. Returns which tags it actually
  /// added, took off and created, for Recent activity and Undo.
  ({List<Tag> added, List<Tag> removed, List<Tag> created}) retag(
    String id, {
    List<String> add = const [],
    List<String> remove = const [],
    bool createMissing = false,
  }) {
    read(id);
    final store = _tags;
    final current = [for (final tag in store.tagsOf(id)) tag.id];
    final off = {for (final name in remove) _tag(name).id};
    final existing = <Tag>[];
    final missing = <String>[];
    for (final name in add) {
      final tag = store.named(name);
      if (tag != null && (createMissing || _visible(tag))) {
        existing.add(tag);
      } else if (!createMissing) {
        throw McpRefusal(
          'There’s no tag called “${name.trim()}”. Set create_missing to '
          'make it.',
        );
      } else if (!missing.any(
        (m) => m.toLowerCase() == name.trim().toLowerCase(),
      )) {
        _clean(name, tagNameMax * 2, 'tag name');
        if (name.trim().isEmpty || name.trim().runes.length > tagNameMax) {
          throw const McpRefusal(
            'A tag’s name is 1 to $tagNameMax characters.',
          );
        }
        missing.add(name.trim());
      }
    }
    final keep = [
      for (final tagId in current)
        if (!off.contains(tagId)) tagId,
    ];
    final adding = {
      for (final tag in existing)
        if (!keep.contains(tag.id)) tag.id,
    }.toList();
    if (keep.length + adding.length + missing.length > noteTagsMax) {
      throw const McpRefusal('A note carries at most $noteTagsMax tags.');
    }
    final created = [for (final name in missing) store.create(name)!];
    store.setTags(id, [...keep, ...adding, for (final tag in created) tag.id]);
    return (
      added: [...existing.where((tag) => adding.contains(tag.id)), ...created],
      removed: [
        for (final tagId in current)
          if (off.contains(tagId)) store.byId(tagId)!,
      ],
      created: created,
    );
  }

  /// A new tag. Refused if one has that name already.
  Tag createTag(String name, {String? colour}) {
    final store = _tags;
    _clean(name, tagNameMax * 2, 'name');
    final taken = store.named(name);
    if (taken != null) {
      throw McpRefusal(
        _visible(taken)
            ? 'There’s already a tag called “${name.trim()}”.'
            : 'Choose another name for that tag.',
      );
    }
    if (colour != null) _colour(colour);
    final tag =
        store.create(name) ??
        (throw const McpRefusal(
          'A tag’s name is 1 to $tagNameMax characters.',
        ));
    if (colour != null) store.recolour(tag.id, colour);
    return store.byId(tag.id)!;
  }

  Tag renameTag(String name, String to) {
    final tag = _changeableTag(name);
    _clean(to, tagNameMax * 2, 'name');
    if (!_tags.rename(tag.id, to)) {
      throw McpRefusal(
        _tags.named(to) != null
            ? 'There’s already a tag called “${to.trim()}”.'
            : 'A tag’s name is 1 to $tagNameMax characters.',
      );
    }
    return _tags.byId(tag.id)!;
  }

  Tag recolourTag(String name, String colour) {
    final tag = _changeableTag(name);
    _tags.recolour(tag.id, _colour(colour));
    return _tags.byId(tag.id)!;
  }

  /// Deletes a tag and nothing else: every note stays, and Undo puts it
  /// back on them.
  Tag deleteTag(String name) {
    final tag = _changeableTag(name);
    _tags.delete(tag.id);
    return tag;
  }

  static String _colour(String colour) {
    if (colour == noTagColour || tagColours.contains(colour)) return colour;
    throw McpRefusal(
      'A tag’s colour is one of ${tagColours.join(', ')}, or $noTagColour.',
    );
  }

  // ---------------------------------------------------------------------------
  // Tasks

  /// The task [taskId] names, in a note an assistant may change.
  McpTask _taskAt(String taskId) {
    final split = taskId.indexOf('~');
    if (split <= 0) throw const McpRefusal('No task with that id.');
    final note = _writable(taskId.substring(0, split));
    final task = tasksIn(note).where((task) => task.id == taskId).firstOrNull;
    if (task == null) {
      throw const McpRefusal('That task changed; list the tasks again.');
    }
    return task;
  }

  /// Changes a task's words.
  McpTask rewordTask(String taskId, String text) {
    final words = _taskWords(text);
    final task = _taskAt(taskId);
    final note = _splice(task.note, [
      (start: task.line.textStart, end: task.line.end, text: words),
    ]);
    return tasksIn(
      note,
    ).firstWhere((each) => each.line.start == task.line.start);
  }

  /// Takes a task's line out of its note. The note stays.
  Note removeTask(String taskId) {
    final task = _taskAt(taskId);
    return _splice(task.note, [_lineOf(task)]);
  }

  /// Moves a task to the end of [noteId], or before [beforeTaskId] there,
  /// ticked or not as it was, and in the style that note's tasks use.
  McpTask moveTask(
    String taskId, {
    required String noteId,
    String? beforeTaskId,
  }) {
    final task = _taskAt(taskId);
    final target = _writable(noteId);
    if (beforeTaskId == taskId) return task;
    final before = beforeTaskId == null ? null : _taskAt(beforeTaskId);
    if (before != null && before.note.id != noteId) {
      throw const McpRefusal('before_task_id is a task in that note.');
    }
    final line = '${_box(target, done: task.done)}${task.text}';
    final body = target.body;
    final _Region insert = before != null
        ? (start: before.line.start, end: before.line.start, text: '$line\n')
        : (
            start: body.length,
            end: body.length,
            text: body.isEmpty || body.endsWith('\n') ? line : '\n$line',
          );
    final removal = _lineOf(task);
    var at = insert.start + (insert.text.startsWith('\n') ? 1 : 0);
    final Note written;
    if (target.id == task.note.id) {
      if (insert.start >= removal.end) at -= removal.end - removal.start;
      written = _splice(
        target,
        [removal, insert]..sort((a, b) => a.start.compareTo(b.start)),
      );
    } else {
      if (body.length + insert.text.length > maxNoteLength) {
        throw const McpRefusal('That would make the note too long.');
      }
      written = _splice(target, [insert]);
      _splice(task.note, [removal]);
    }
    return tasksIn(written).firstWhere((each) => each.line.start == at);
  }

  /// The whole line [task] is on, with the line break that ends it, or the
  /// one before it at the end of a note.
  _Region _lineOf(McpTask task) {
    final body = task.note.body;
    final line = body.substring(task.line.start, task.line.end);
    if (line.contains(_anchor)) {
      throw const McpRefusal(
        'That task holds an attachment, and assistants can’t remove those.',
      );
    }
    if (task.line.end < body.length) {
      return (start: task.line.start, end: task.line.end + 1, text: '');
    }
    final start = task.line.start > 0 ? task.line.start - 1 : 0;
    return (start: start, end: task.line.end, text: '');
  }

  String _taskWords(String text) {
    final words = _clean(text, maxTaskText, 'text').trim();
    if (words.isEmpty || words.contains('\n')) {
      throw const McpRefusal('A task is one line of text.');
    }
    return words;
  }

  /// A task box in the style [note]'s tasks already use.
  String _box(Note note, {bool done = false}) {
    final existing = taskLines(note.body);
    final markdown =
        existing.isNotEmpty &&
        !_glyphBox.hasMatch(
          note.body.substring(existing.first.start, existing.first.textStart),
        );
    return markdown ? (done ? '- [x] ' : '- [ ] ') : (done ? '☑ ' : '☐ ');
  }

  // ---------------------------------------------------------------------------
  // Drawings

  /// Adds [add] to the drawing [id] and takes [remove] off it, or starts a
  /// new drawing called [title] when [id] is null. Returns the drawing and
  /// the ids its new elements were given.
  ({Note note, List<String> added}) draw({
    String? id,
    String? title,
    List<Object?> add = const [],
    List<String> remove = const [],
  }) {
    if (add.length > McpDrawing.maxPerCall) {
      throw const McpRefusal(
        'That’s more than ${McpDrawing.maxPerCall} elements at once.',
      );
    }
    String? heading;
    Note? existing;
    if (id == null) {
      heading = _clean(title ?? '', maxTitle, 'title').trim();
      if (heading.isEmpty || heading.contains('\n')) {
        throw const McpRefusal('A new drawing needs a one-line title.');
      }
      if (remove.isNotEmpty) {
        throw const McpRefusal('A new drawing has nothing to remove.');
      }
      _checkCreate();
    } else {
      existing = _changeable(id);
      if (!existing.isDrawing) {
        throw const McpRefusal(
          'That note has text, not a drawing. Leave out note_id to start a '
          'drawing.',
        );
      }
    }
    var drawing = existing?.drawing ?? NoteDrawing.empty;
    final unknown = remove.where((each) => drawing.byId(each) == null);
    if (unknown.isNotEmpty) {
      throw McpRefusal('There’s no element ${unknown.first} in that drawing.');
    }
    final z = drawing.nextZ;
    final elements = [
      for (final (i, raw) in add.indexed)
        McpDrawing.parse(raw, id: NotesStore.newId(), z: z + i),
    ];
    drawing = drawing.remove(remove).upsert(elements);
    if (drawing.elements.length > McpDrawing.maxElements) {
      throw const McpRefusal(
        'A drawing holds at most ${McpDrawing.maxElements} elements.',
      );
    }
    final noteId =
        existing?.id ?? notes.create(authored: false, drawing: true).id;
    notes.updateDrawing(noteId, drawing, title: heading, authored: false);
    return (
      note: notes.byId(noteId)!,
      added: [for (final element in elements) element.id],
    );
  }

  // ---------------------------------------------------------------------------
  // Voice notes

  /// What an assistant calls a voice note within its note.
  static String voiceIdOf(NoteAttachmentRef ref) =>
      ref.hash.length > 12 ? ref.hash.substring(0, 12) : ref.hash;

  NoteVoiceRef voice(String noteId, String voiceId) {
    final note = read(noteId);
    for (final ref in note.attachments) {
      if (ref is NoteVoiceRef && voiceIdOf(ref) == voiceId) return ref;
    }
    throw const McpRefusal('No voice note with that id in this note.');
  }

  Note _write(
    Note note,
    String body, {
    List<NoteFormatRange>? formats,
    List<NoteAttachmentRef>? attachments,
  }) {
    if (body.length > maxNoteLength) {
      throw const McpRefusal('That would make the note too long.');
    }
    if (body == note.body) return note;
    notes.updateForAssistant(
      note.id,
      body,
      diffTexts(note.body, body),
      formats: formats,
      attachments: attachments,
    );
    return notes.byId(note.id)!;
  }

  FolderStore _folderStore() {
    final store = folders;
    if (store == null) throw const McpRefusal('Folders aren’t available.');
    return store;
  }

  static String folderRefusal(FolderRefusal refusal) => switch (refusal) {
    FolderRefusal.emptyName => 'Give the folder a name.',
    FolderRefusal.longName => 'Use up to $folderNameMax characters.',
    FolderRefusal.nameTaken => 'A folder here already has that name.',
    FolderRefusal.tooDeep => 'Folders go at most $folderDepthMax levels deep.',
    FolderRefusal.intoItself => 'A folder can’t go inside itself.',
    FolderRefusal.gone => 'That folder was deleted.',
    FolderRefusal.full =>
      'Folders are full. Take some notes out of folders to file more.',
  };

  /// Whether a note may sit in a folder: the person's own, not a drawing,
  /// not archived, and not one shared with them.
  bool showsInFolder(Note note) =>
      !note.isDrawing &&
      !note.isHidden &&
      !note.isArchived &&
      !_sharedWithMe(note);

  /// The live folders, each under its parent, with the notes filed in it.
  List<Map<String, Object?>> listFolders() {
    final store = _folderStore();
    final tree = store.tree;
    final visible = notes.notes.where(showsInFolder).toList();
    final out = <Folder>[];
    void walk(String? parent) {
      for (final folder in tree.childrenOf(parent)) {
        out.add(folder);
        walk(folder.id);
      }
    }

    walk(null);
    return [
      for (final folder in out)
        {
          'id': folder.id,
          'name': folder.name,
          'parent_id': folder.parentId,
          'notes': [
            for (final note in tree.notesIn(visible, folder.id)) note.id,
          ],
        },
    ];
  }

  Folder createFolder(String name, {String? parentId}) {
    final store = _folderStore();
    final refusal = store.checkCreate(name, parentId: parentId);
    if (refusal != null) throw McpRefusal(folderRefusal(refusal));
    return store.create(name, parentId: parentId)!;
  }

  Folder renameFolder(String id, String name) {
    final store = _folderStore();
    final refusal = store.rename(id, name);
    if (refusal != null) throw McpRefusal(folderRefusal(refusal));
    return store.tree.byId(id)!;
  }

  Folder moveFolder(String id, {String? parentId}) {
    final store = _folderStore();
    final refusal = store.move(id, parentId: parentId);
    if (refusal != null) throw McpRefusal(folderRefusal(refusal));
    return store.tree.byId(id)!;
  }

  Folder deleteFolder(String id) {
    final store = _folderStore();
    final folder = store.tree.byId(id);
    if (folder == null) throw McpRefusal(folderRefusal(FolderRefusal.gone));
    store.delete(id);
    return folder;
  }

  Folder restoreFolder(String id) {
    final store = _folderStore();
    store.restore(id);
    final folder = store.tree.byId(id);
    if (folder == null) throw McpRefusal(folderRefusal(FolderRefusal.gone));
    return folder;
  }

  /// Files [id] in [folderId], or takes it out of every folder when that is
  /// null. A drawing, a Hidden note, an archived note and a note shared with
  /// the person are refused. Hidden reads as missing.
  String? fileNote(String id, String? folderId) {
    final store = _folderStore();
    final note = read(id);
    if (note.isDrawing) throw const McpRefusal('Folders hold notes only.');
    if (note.isArchived) {
      throw const McpRefusal('Archived notes can’t be filed.');
    }
    if (_sharedWithMe(note)) {
      throw const McpRefusal('Notes shared with you can’t be filed.');
    }
    final from = store.tree.folderOf(id);
    final refusal = store.file([id], folderId);
    if (refusal != null) throw McpRefusal(folderRefusal(refusal));
    return from;
  }

  /// Refuses [text] that has characters a note can't hold.
  static void checkText(String text, String field) =>
      _clean(text, text.length, field);

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
