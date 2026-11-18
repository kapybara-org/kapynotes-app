import 'dart:convert';

import '../data/note.dart';
import 'mcp_library.dart';

/// The answer to one tool call, and the line it leaves in Recent activity.
typedef McpToolResult = ({
  Map<String, Object?>? output,
  String? error,
  String activity,
});

/// The tools an assistant is offered, with their schemas, and how each is
/// carried out against the [McpLibrary].
///
/// Read tools are always offered. Write tools are offered only while the
/// person allows changes, and refused if a client calls one it listed
/// before changes were turned off.
class McpTools {
  McpTools(this.library);

  final McpLibrary library;

  static const writeTools = {
    'create_note',
    'append_to_note',
    'add_task',
    'set_task_done',
  };

  static const _summary = <String, Object?>{
    'type': 'object',
    'properties': {
      'id': {'type': 'string'},
      'title': {'type': 'string'},
      'kind': {
        'type': 'string',
        'enum': ['note', 'drawing'],
      },
      'created_at': {'type': 'string', 'format': 'date-time'},
      'updated_at': {'type': 'string', 'format': 'date-time'},
      'pinned': {'type': 'boolean'},
      'archived': {'type': 'boolean'},
      'shared': {'type': 'boolean'},
      'open_tasks': {'type': 'integer'},
      'done_tasks': {'type': 'integer'},
      'snippet': {'type': 'string'},
    },
    'required': [
      'id',
      'title',
      'kind',
      'created_at',
      'updated_at',
      'pinned',
      'archived',
      'shared',
      'open_tasks',
      'done_tasks',
    ],
  };

  static const _task = <String, Object?>{
    'type': 'object',
    'properties': {
      'id': {'type': 'string'},
      'note_id': {'type': 'string'},
      'note_title': {'type': 'string'},
      'text': {'type': 'string'},
      'done': {'type': 'boolean'},
    },
    'required': ['id', 'note_id', 'note_title', 'text', 'done'],
  };

  static Map<String, Object?> _object(
    Map<String, Object?> properties, [
    List<String> required = const [],
  ]) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };

  static const _id = {'type': 'string', 'description': 'A note id.'};

  static final List<Map<String, Object?>> _definitions = [
    {
      'name': 'list_notes',
      'title': 'List notes',
      'description':
          'Lists notes in Kapy Notes, pinned first and then the most recently '
          'changed, or finds the ones matching a search. Archived notes are '
          'left out unless include_archived is true.',
      'inputSchema': _object({
        'query': {
          'type': 'string',
          'maxLength': 200,
          'description': 'Words to search for. Leave out to list everything.',
        },
        'include_archived': {'type': 'boolean', 'default': false},
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 100,
          'default': 30,
        },
        'cursor': {
          'type': 'string',
          'description': 'next_cursor from the previous page.',
        },
      }),
      'outputSchema': _object(
        {
          'notes': {'type': 'array', 'items': _summary},
          'next_cursor': {
            'type': ['string', 'null'],
          },
        },
        ['notes', 'next_cursor'],
      ),
      'annotations': {'readOnlyHint': true, 'openWorldHint': false},
    },
    {
      'name': 'read_note',
      'title': 'Read a note',
      'description':
          'Reads one note as markdown, with what the calculator answers on '
          'its lines. Long notes come in pages: pass next_offset back as '
          'offset for the rest. Attachments show as [image], [file], '
          '[voice note] or [video]; a drawing has a title and no body.',
      'inputSchema': _object({
        'id': _id,
        'offset': {'type': 'integer', 'minimum': 0, 'default': 0},
      }, ['id']),
      'outputSchema': _object(
        {
          'note': _summary,
          'body': {'type': 'string'},
          'offset': {'type': 'integer'},
          'next_offset': {
            'type': ['integer', 'null'],
          },
          'results': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'line': {'type': 'integer'},
                'value': {'type': 'string'},
              },
              'required': ['line', 'value'],
            },
          },
        },
        ['note', 'body', 'offset', 'next_offset', 'results'],
      ),
      'annotations': {'readOnlyHint': true, 'openWorldHint': false},
    },
    {
      'name': 'list_tasks',
      'title': 'List tasks',
      'description':
          'Lists checklist items across notes, or in one note. Open ones by '
          'default.',
      'inputSchema': _object({
        'status': {
          'type': 'string',
          'enum': ['open', 'done', 'all'],
          'default': 'open',
        },
        'note_id': _id,
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 200,
          'default': 50,
        },
      }),
      'outputSchema': _object(
        {
          'tasks': {'type': 'array', 'items': _task},
        },
        ['tasks'],
      ),
      'annotations': {'readOnlyHint': true, 'openWorldHint': false},
    },
    {
      'name': 'create_note',
      'title': 'Create a note',
      'description':
          'Creates a note. The title becomes its first line and the body '
          'follows as markdown; "☐ " or "- [ ] " starts a task line.',
      'inputSchema': _object({
        'title': {'type': 'string', 'minLength': 1, 'maxLength': 200},
        'body': {'type': 'string', 'maxLength': 100000},
      }, ['title']),
      'outputSchema': _object({'note': _summary}, ['note']),
      'annotations': _writeHints,
    },
    {
      'name': 'append_to_note',
      'title': 'Add to a note',
      'description': 'Adds text at the end of a note, on a new line.',
      'inputSchema': _object({
        'id': _id,
        'text': {'type': 'string', 'minLength': 1, 'maxLength': 20000},
      }, ['id', 'text']),
      'outputSchema': _object({'note': _summary}, ['note']),
      'annotations': _writeHints,
    },
    {
      'name': 'add_task',
      'title': 'Add a task',
      'description': 'Adds a checklist item at the end of a note.',
      'inputSchema': _object({
        'note_id': _id,
        'text': {'type': 'string', 'minLength': 1, 'maxLength': 500},
      }, ['note_id', 'text']),
      'outputSchema': _object({'task': _task}, ['task']),
      'annotations': _writeHints,
    },
    {
      'name': 'set_task_done',
      'title': 'Tick off a task',
      'description':
          'Ticks a task off, or back on. Use an id from list_tasks; if the '
          'line has changed since, list the tasks again.',
      'inputSchema': _object({
        'task_id': {'type': 'string'},
        'done': {'type': 'boolean'},
      }, ['task_id', 'done']),
      'outputSchema': _object({'task': _task}, ['task']),
      'annotations': {
        ..._writeHints,
        'idempotentHint': true,
      },
    },
  ];

  static const _writeHints = {
    'readOnlyHint': false,
    'destructiveHint': false,
    'openWorldHint': false,
  };

  List<Map<String, Object?>> definitions({required bool writes}) => [
    for (final tool in _definitions)
      if (writes || !writeTools.contains(tool['name'])) tool,
  ];

  /// Runs [name]. A refusal comes back as an error the assistant can show;
  /// anything else thrown is a bug, and propagates.
  McpToolResult call(
    String name,
    Map<String, Object?> args, {
    required bool writes,
  }) {
    if (writeTools.contains(name) && !writes) {
      return (
        output: null,
        error: 'Changes are off. Turn on Allow changes in Kapy Notes, '
            'Settings, MCP.',
        activity: 'Couldn’t ${_verb(name)}: changes are off',
      );
    }
    try {
      return switch (name) {
        'list_notes' => _listNotes(args),
        'read_note' => _readNote(args),
        'list_tasks' => _listTasks(args),
        'create_note' => _createNote(args),
        'append_to_note' => _append(args),
        'add_task' => _addTask(args),
        'set_task_done' => _setTaskDone(args),
        _ => throw McpRefusal('There’s no tool called $name.'),
      };
    } on McpRefusal catch (refusal) {
      return (
        output: null,
        error: refusal.message,
        activity: 'Couldn’t ${_verb(name)}: ${_lower(refusal.message)}',
      );
    }
  }

  static String _verb(String name) => switch (name) {
    'list_notes' => 'list notes',
    'read_note' => 'read a note',
    'list_tasks' => 'list tasks',
    'create_note' => 'create a note',
    'append_to_note' => 'add to a note',
    'add_task' => 'add a task',
    'set_task_done' => 'tick off a task',
    _ => 'use $name',
  };

  static String _lower(String message) {
    final sentence = message.endsWith('.')
        ? message.substring(0, message.length - 1)
        : message;
    return sentence.isEmpty
        ? sentence
        : sentence[0].toLowerCase() + sentence.substring(1);
  }

  McpToolResult _listNotes(Map<String, Object?> args) {
    final query = _string(args, 'query', max: 200) ?? '';
    final limit = _int(args, 'limit', min: 1, max: 100) ?? 30;
    final start = _cursor(args['cursor']);
    final all = library.list(
      query: query,
      includeArchived: _bool(args, 'include_archived') ?? false,
    );
    final page = all.skip(start).take(limit).toList();
    final end = start + page.length;
    return (
      output: {
        'notes': [
          for (final note in page)
            {
              ..._summaryOf(note),
              if (query.trim().isNotEmpty) 'snippet': _snippet(note, query),
            },
        ],
        'next_cursor': end < all.length
            ? base64Url.encode(utf8.encode('$end'))
            : null,
      },
      error: null,
      activity: query.trim().isEmpty
          ? 'Listed ${_count(page.length, 'note')}'
          : 'Searched for “${_clip(query.trim(), 40)}”',
    );
  }

  McpToolResult _readNote(Map<String, Object?> args) {
    final note = library.read(_required(args, 'id'));
    final body = library.bodyOf(note);
    final offset = _int(args, 'offset', min: 0) ?? 0;
    if (offset > body.length) {
      throw const McpRefusal('That offset is past the end of the note.');
    }
    var end = body.length;
    if (end - offset > McpLibrary.pageSize) {
      end = offset + McpLibrary.pageSize;
      final lineEnd = body.lastIndexOf('\n', end - 1);
      if (lineEnd > offset + McpLibrary.pageSize ~/ 2) end = lineEnd + 1;
    }
    final firstLine = '\n'.allMatches(body.substring(0, offset)).length + 1;
    final lastLine = firstLine + '\n'.allMatches(body.substring(offset, end)).length;
    return (
      output: {
        'note': _summaryOf(note),
        'body': body.substring(offset, end),
        'offset': offset,
        'next_offset': end < body.length ? end : null,
        'results': [
          for (final MapEntry(key: line, :value)
              in library.resultsOf(note).entries)
            if (line >= firstLine && line <= lastLine)
              {'line': line, 'value': value},
        ],
      },
      error: null,
      activity: 'Read “${_clip(note.title, 40)}”',
    );
  }

  McpToolResult _listTasks(Map<String, Object?> args) {
    final status = _string(args, 'status') ?? 'open';
    if (!const {'open', 'done', 'all'}.contains(status)) {
      throw const McpRefusal('status is open, done or all.');
    }
    final limit = _int(args, 'limit', min: 1, max: 200) ?? 50;
    final tasks = library
        .tasks(noteId: _string(args, 'note_id'))
        .where(
          (task) => status == 'all' || task.done == (status == 'done'),
        )
        .take(limit)
        .toList();
    return (
      output: {
        'tasks': [for (final task in tasks) _taskOf(task)],
      },
      error: null,
      activity: 'Listed ${_count(tasks.length, '${status == 'all' ? '' : '$status '}task')}',
    );
  }

  McpToolResult _createNote(Map<String, Object?> args) {
    final note = library.create(
      title: _required(args, 'title'),
      body: _string(args, 'body') ?? '',
    );
    return (
      output: {'note': _summaryOf(note)},
      error: null,
      activity: 'Created “${_clip(note.title, 40)}”',
    );
  }

  McpToolResult _append(Map<String, Object?> args) {
    final note = library.append(_required(args, 'id'), _required(args, 'text'));
    return (
      output: {'note': _summaryOf(note)},
      error: null,
      activity: 'Added to “${_clip(note.title, 40)}”',
    );
  }

  McpToolResult _addTask(Map<String, Object?> args) {
    final task = library.addTask(
      _required(args, 'note_id'),
      _required(args, 'text'),
    );
    return (
      output: {'task': _taskOf(task)},
      error: null,
      activity: 'Added a task to “${_clip(task.note.title, 40)}”',
    );
  }

  McpToolResult _setTaskDone(Map<String, Object?> args) {
    final done = _bool(args, 'done');
    if (done == null) throw const McpRefusal('done is true or false.');
    final task = library.setTaskDone(_required(args, 'task_id'), done: done);
    return (
      output: {'task': _taskOf(task)},
      error: null,
      activity:
          '${done ? 'Ticked off' : 'Reopened'} a task in “${_clip(task.note.title, 40)}”',
    );
  }

  Map<String, Object?> _summaryOf(Note note) {
    final tasks = [for (final task in library.tasksIn(note)) task.done];
    return {
      'id': note.id,
      'title': note.title,
      'kind': note.isDrawing ? 'drawing' : 'note',
      'created_at': note.createdAt.toUtc().toIso8601String(),
      'updated_at': note.updatedAt.toUtc().toIso8601String(),
      'pinned': library.notes.isPinned(note.id),
      'archived': note.isArchived,
      'shared': note.isShared,
      'open_tasks': tasks.where((done) => !done).length,
      'done_tasks': tasks.where((done) => done).length,
    };
  }

  static Map<String, Object?> _taskOf(McpTask task) => {
    'id': task.id,
    'note_id': task.note.id,
    'note_title': task.note.title,
    'text': task.text,
    'done': task.done,
  };

  String _snippet(Note note, String query) {
    final body = library.bodyOf(note);
    final first = query.trim().split(RegExp(r'\s+')).first.toLowerCase();
    final line = body
        .split('\n')
        .firstWhere(
          (line) => line.toLowerCase().contains(first),
          orElse: () => note.title,
        );
    return _clip(line.trim(), 160);
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max - 1)}…';

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  static int _cursor(Object? raw) {
    if (raw == null) return 0;
    if (raw is String) {
      try {
        final value = int.tryParse(utf8.decode(base64Url.decode(raw)));
        if (value != null && value >= 0) return value;
      } on FormatException {
        // Falls through to the refusal.
      }
    }
    throw const McpRefusal('That cursor isn’t one list_notes gave out.');
  }

  static String _required(Map<String, Object?> args, String key) {
    final value = _string(args, key);
    if (value == null) throw McpRefusal('$key is required.');
    return value;
  }

  static String? _string(Map<String, Object?> args, String key, {int? max}) {
    final value = args[key];
    if (value == null) return null;
    if (value is! String) throw McpRefusal('$key must be text.');
    if (max != null && value.length > max) {
      throw McpRefusal('$key is longer than $max characters.');
    }
    return value;
  }

  static bool? _bool(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value == null || value is bool) return value as bool?;
    throw McpRefusal('$key must be true or false.');
  }

  static int? _int(Map<String, Object?> args, String key, {int min = 0, int? max}) {
    final value = args[key];
    if (value == null) return null;
    final number = value is int ? value : value is double && value == value.roundToDouble() ? value.toInt() : null;
    if (number == null || number < min || (max != null && number > max)) {
      throw McpRefusal('$key must be a whole number from $min${max == null ? '' : ' to $max'}.');
    }
    return number;
  }
}
