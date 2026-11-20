import 'dart:convert';

import '../data/note.dart';
import '../data/task_details.dart';
import '../data/note_attachment.dart';
import '../data/tags.dart';
import 'mcp_drawing.dart';
import 'mcp_library.dart';

/// A change the person can take back from Recent activity, while
/// [possible] says nothing has changed it since.
typedef McpUndo = ({bool Function() possible, void Function() run});

/// The answer to one tool call, the line it leaves in Recent activity, and
/// how to take it back when that is cheap.
typedef McpToolResult = ({
  Map<String, Object?>? output,
  String? error,
  String activity,
  McpUndo? undo,
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
    'edit_note',
    'update_note',
    'tag_note',
    'manage_tag',
    'add_task',
    'set_task_done',
    'edit_task',
    'draw',
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
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
      },
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
      'tags',
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
      'details': {
        'type': 'string',
        'description':
            'The words indented under the task, if it has any. Read only.',
      },
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
          'left out unless include_archived is true; only_archived lists '
          'just them. tag and pinned narrow the list.',
      'inputSchema': _object({
        'query': {
          'type': 'string',
          'maxLength': 200,
          'description': 'Words to search for. Leave out to list everything.',
        },
        'include_archived': {'type': 'boolean', 'default': false},
        'only_archived': {'type': 'boolean', 'default': false},
        'tag': {'type': 'string', 'description': 'A tag’s name.'},
        'pinned': {'type': 'boolean'},
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
      'annotations': _readHints,
    },
    {
      'name': 'read_note',
      'title': 'Read a note',
      'description':
          'Reads one note as markdown, with what the calculator answers on '
          'its lines. Long notes come in pages: pass next_offset back as '
          'offset for the rest. Attachments show as [image], [file], '
          '[voice note] or [video] in the body and are listed under '
          'attachments; read a voice note’s transcript with read_voice_note. '
          'A drawing has no body and comes as SVG, each element with its id. '
          'read_only says why the note can’t be changed, if it can’t.',
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
          'read_only': {
            'type': ['string', 'null'],
          },
          'attachments': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'kind': {
                  'type': 'string',
                  'enum': ['image', 'video', 'voice', 'file', 'other'],
                },
                'mime': {'type': 'string'},
                'bytes': {'type': 'integer'},
                'name': {'type': 'string'},
                'duration_ms': {'type': 'integer'},
                'voice_id': {'type': 'string'},
                'summary_title': {'type': 'string'},
                'has_transcript': {'type': 'boolean'},
              },
              'required': ['kind', 'mime', 'bytes'],
            },
          },
          'drawing': {
            'type': ['object', 'null'],
            'properties': {
              'svg': {
                'type': ['string', 'null'],
              },
              'elements': {'type': 'integer'},
            },
          },
        },
        [
          'note',
          'body',
          'offset',
          'next_offset',
          'results',
          'read_only',
          'attachments',
          'drawing',
        ],
      ),
      'annotations': _readHints,
    },
    {
      'name': 'read_voice_note',
      'title': 'Read a voice note',
      'description':
          'Reads a voice note’s summary, the posts written from it, and its '
          'transcript, one line per stretch of speech with its time and '
          'speaker. Long transcripts come in pages through offset.',
      'inputSchema': _object({
        'note_id': _id,
        'voice_id': {
          'type': 'string',
          'description': 'voice_id from read_note’s attachments.',
        },
        'offset': {'type': 'integer', 'minimum': 0, 'default': 0},
      }, ['note_id', 'voice_id']),
      'outputSchema': _object(
        {
          'duration_ms': {'type': 'integer'},
          'summary': {
            'type': ['object', 'null'],
            'properties': {
              'title': {'type': 'string'},
              'points': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
          'takes': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'kind': {'type': 'string'},
                'text': {'type': 'string'},
              },
            },
          },
          'transcript': {
            'type': ['string', 'null'],
          },
          'offset': {'type': 'integer'},
          'next_offset': {
            'type': ['integer', 'null'],
          },
        },
        ['duration_ms', 'summary', 'takes', 'transcript', 'offset', 'next_offset'],
      ),
      'annotations': _readHints,
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
      'annotations': _readHints,
    },
    {
      'name': 'list_tags',
      'title': 'List tags',
      'description':
          'Lists the person’s tags in their order, with each one’s colour '
          'and how many notes carry it.',
      'inputSchema': _object({}),
      'outputSchema': _object(
        {
          'tags': {
            'type': 'array',
            'items': _tagSchema,
          },
        },
        ['tags'],
      ),
      'annotations': _readHints,
    },
    {
      'name': 'create_note',
      'title': 'Create a note',
      'description':
          'Creates a note. The title becomes its first line and the body '
          'follows as plain text; "☐ " or "- [ ] " starts a task line. '
          'Tags it carries must exist, or set create_missing_tags.',
      'inputSchema': _object({
        'title': {'type': 'string', 'minLength': 1, 'maxLength': 200},
        'body': {'type': 'string', 'maxLength': 100000},
        'tags': _tagNames,
        'create_missing_tags': {'type': 'boolean', 'default': false},
        'pinned': {'type': 'boolean', 'default': false},
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
      'name': 'edit_note',
      'title': 'Edit a note',
      'description':
          'Changes a note’s text. Each edit either replaces find with '
          'replacement (occurrence picks one from 1, or 0 for every one; '
          'needed when find appears more than once), or puts text between '
          'start and end, offsets in read_note’s body (leave out end to '
          'insert at start; give expected to make sure the text there is '
          'still what you read). All edits refer to the note as it is '
          'before this call and may not overlap. Attachments can’t be '
          'removed.',
      'inputSchema': _object({
        'id': _id,
        'edits': {
          'type': 'array',
          'minItems': 1,
          'maxItems': McpLibrary.maxEdits,
          'items': {
            'type': 'object',
            'properties': {
              'find': {'type': 'string', 'minLength': 1, 'maxLength': 20000},
              'replacement': {'type': 'string', 'maxLength': 20000},
              'occurrence': {'type': 'integer', 'minimum': 0},
              'start': {'type': 'integer', 'minimum': 0},
              'end': {'type': 'integer', 'minimum': 0},
              'text': {'type': 'string', 'maxLength': 20000},
              'expected': {'type': 'string', 'maxLength': 20000},
            },
            'additionalProperties': false,
          },
        },
      }, ['id', 'edits']),
      'outputSchema': _object({'note': _summary}, ['note']),
      'annotations': {..._writeHints, 'destructiveHint': true},
    },
    {
      'name': 'update_note',
      'title': 'Rename, pin or archive a note',
      'description':
          'Renames a note (its first line), pins or unpins it, or archives '
          'it or brings it back from the archive. Archived notes are kept, '
          'read-only, and can be brought back; nothing is deleted. The '
          'person can undo each of these.',
      'inputSchema': _object({
        'id': _id,
        'title': {'type': 'string', 'minLength': 1, 'maxLength': 200},
        'pinned': {'type': 'boolean'},
        'archived': {'type': 'boolean'},
      }, ['id']),
      'outputSchema': _object({'note': _summary}, ['note']),
      'annotations': {..._writeHints, 'idempotentHint': true},
    },
    {
      'name': 'tag_note',
      'title': 'Tag a note',
      'description':
          'Puts tags on a note and takes them off, by name. A tag that '
          'doesn’t exist is refused unless create_missing is true. A note '
          'carries at most $noteTagsMax tags.',
      'inputSchema': _object({
        'id': _id,
        'add': _tagNames,
        'remove': _tagNames,
        'create_missing': {'type': 'boolean', 'default': false},
      }, ['id']),
      'outputSchema': _object(
        {
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        ['tags'],
      ),
      'annotations': {..._writeHints, 'idempotentHint': true},
    },
    {
      'name': 'manage_tag',
      'title': 'Create, rename, recolour or delete a tag',
      'description':
          'Creates a tag, renames one, changes its colour, or deletes it. '
          'Deleting a tag keeps every note; it only comes off them. Colours: '
          '${tagColours.join(', ')}, or none.',
      'inputSchema': _object({
        'action': {
          'type': 'string',
          'enum': ['create', 'rename', 'recolour', 'delete'],
        },
        'tag': {'type': 'string', 'description': 'The tag’s name.'},
        'new_name': {'type': 'string', 'maxLength': tagNameMax},
        'colour': {
          'type': 'string',
          'enum': [...tagColours, noTagColour],
        },
      }, ['action', 'tag']),
      'outputSchema': _object({'tag': _tagSchema}, ['tag']),
      'annotations': {..._writeHints, 'destructiveHint': true},
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
    {
      'name': 'edit_task',
      'title': 'Change a task',
      'description':
          'Does one thing to a task: rewords it (text), moves it to the end '
          'of a note or before another task there (move_to_note_id, '
          'before_task_id), or takes its line out of the note (remove). '
          'A moved task keeps its tick.',
      'inputSchema': _object({
        'task_id': {'type': 'string'},
        'text': {'type': 'string', 'minLength': 1, 'maxLength': 500},
        'move_to_note_id': _id,
        'before_task_id': {'type': 'string'},
        'remove': {'type': 'boolean'},
      }, ['task_id']),
      'outputSchema': _object({
        'task': {
          'type': ['object', 'null'],
          'properties': _task['properties'],
        },
      }, ['task']),
      'annotations': {..._writeHints, 'destructiveHint': true},
    },
    {
      'name': 'draw',
      'title': 'Draw',
      'description':
          'Adds elements to a drawing, removes them by id, or starts a new '
          'drawing (leave out note_id and give a title). Elements are the '
          'canvas’s own kinds: pen (a polyline, curves as many points), '
          'line, arrow, rect and ellipse (two corner or end points), and '
          'text (one point, its top-left). Points are [x, y] pairs; y goes '
          'down. Leave out colour for the theme’s ink.',
      'inputSchema': _object({
        'note_id': _id,
        'title': {'type': 'string', 'minLength': 1, 'maxLength': 200},
        'add': {
          'type': 'array',
          'maxItems': McpDrawing.maxPerCall,
          'items': {
            'type': 'object',
            'properties': {
              'kind': {'type': 'string', 'enum': McpDrawing.kinds},
              'points': {
                'type': 'array',
                'items': {
                  'type': 'array',
                  'items': {'type': 'number'},
                  'minItems': 2,
                  'maxItems': 2,
                },
              },
              'color': {'type': 'string', 'pattern': r'^#[0-9a-fA-F]{6}$'},
              'width': {'type': 'number', 'minimum': 0.5, 'maximum': 40},
              'text': {'type': 'string', 'maxLength': McpDrawing.maxText},
              'font_size': {'type': 'number', 'minimum': 8, 'maximum': 200},
            },
            'required': ['kind', 'points'],
            'additionalProperties': false,
          },
        },
        'remove': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      }),
      'outputSchema': _object(
        {
          'note': _summary,
          'added': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'elements': {'type': 'integer'},
        },
        ['note', 'added', 'elements'],
      ),
      'annotations': {..._writeHints, 'destructiveHint': true},
    },
  ];

  static const _readHints = {
    'readOnlyHint': true,
    'idempotentHint': true,
    'openWorldHint': false,
  };

  static const _tagNames = {
    'type': 'array',
    'maxItems': noteTagsMax,
    'items': {'type': 'string', 'minLength': 1, 'maxLength': tagNameMax},
  };

  static const _tagSchema = <String, Object?>{
    'type': 'object',
    'properties': {
      'name': {'type': 'string'},
      'colour': {'type': 'string'},
      'notes': {'type': 'integer'},
    },
    'required': ['name', 'colour'],
  };

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
        undo: null,
      );
    }
    try {
      return switch (name) {
        'list_notes' => _listNotes(args),
        'read_note' => _readNote(args),
        'read_voice_note' => _readVoiceNote(args),
        'list_tasks' => _listTasks(args),
        'list_tags' => _listTags(),
        'create_note' => _createNote(args),
        'append_to_note' => _append(args),
        'edit_note' => _editNote(args),
        'update_note' => _updateNote(args),
        'tag_note' => _tagNote(args),
        'manage_tag' => _manageTag(args),
        'add_task' => _addTask(args),
        'set_task_done' => _setTaskDone(args),
        'edit_task' => _editTask(args),
        'draw' => _draw(args),
        _ => throw McpRefusal('There’s no tool called $name.'),
      };
    } on McpRefusal catch (refusal) {
      return (
        output: null,
        error: refusal.message,
        activity: 'Couldn’t ${_verb(name)}: ${_lower(refusal.message)}',
        undo: null,
      );
    }
  }

  static String _verb(String name) => switch (name) {
    'list_notes' => 'list notes',
    'read_note' => 'read a note',
    'read_voice_note' => 'read a voice note',
    'list_tasks' => 'list tasks',
    'list_tags' => 'list tags',
    'create_note' => 'create a note',
    'append_to_note' => 'add to a note',
    'edit_note' => 'edit a note',
    'update_note' => 'change a note',
    'tag_note' => 'tag a note',
    'manage_tag' => 'change a tag',
    'add_task' => 'add a task',
    'set_task_done' => 'tick off a task',
    'edit_task' => 'change a task',
    'draw' => 'draw',
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
      archivedOnly: _bool(args, 'only_archived') ?? false,
      tag: _string(args, 'tag', max: 200),
      pinned: _bool(args, 'pinned'),
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
      undo: null,
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
        'read_only': library.readOnlyReason(note),
        'attachments': [
          for (final ref in note.attachments) _attachmentOf(ref),
        ],
        'drawing': switch (note.drawing) {
          null => null,
          final drawing => {
            'svg': switch (McpDrawing.svg(drawing)) {
              final svg when svg.length <= McpDrawing.maxSvg => svg,
              _ => null,
            },
            'elements': drawing.elements.length,
          },
        },
      },
      error: null,
      undo: null,
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
      undo: null,
      activity: 'Listed ${_count(tasks.length, '${status == 'all' ? '' : '$status '}task')}',
    );
  }

  McpToolResult _createNote(Map<String, Object?> args) {
    final tagNames = _strings(args, 'tags');
    final createMissing = _bool(args, 'create_missing_tags') ?? false;
    if (tagNames.length > noteTagsMax) {
      throw const McpRefusal('A note carries at most $noteTagsMax tags.');
    }
    if (!createMissing) tagNames.forEach(library.tagNamed);
    final created = library.create(
      title: _required(args, 'title'),
      body: _string(args, 'body') ?? '',
    );
    if (tagNames.isNotEmpty) {
      library.retag(created.id, add: tagNames, createMissing: createMissing);
    }
    if (_bool(args, 'pinned') ?? false) {
      library.setPinned(created.id, pinned: true);
    }
    final note = library.read(created.id);
    return (
      output: {'note': _summaryOf(note)},
      error: null,
      undo: null,
      activity: 'Created “${_clip(note.title, 40)}”',
    );
  }

  McpToolResult _append(Map<String, Object?> args) {
    final note = library.append(_required(args, 'id'), _required(args, 'text'));
    return (
      output: {'note': _summaryOf(note)},
      error: null,
      undo: null,
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
      undo: null,
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
      undo: null,
      activity:
          '${done ? 'Ticked off' : 'Reopened'} a task in “${_clip(task.note.title, 40)}”',
    );
  }

  McpToolResult _readVoiceNote(Map<String, Object?> args) {
    final note = library.read(_required(args, 'note_id'));
    final voice = library.voice(note.id, _required(args, 'voice_id'));
    final transcript = voice.transcript;
    final named = (transcript?.speakerIds.length ?? 0) > 1;
    final text = transcript == null
        ? null
        : [
            for (final segment in transcript.segments)
              '[${_clock(segment.s)}] '
                  '${named && segment.speaker != null ? '${transcript.nameFor(segment.speaker!)}: ' : ''}'
                  '${segment.t.trim()}',
          ].join('\n');
    final offset = _int(args, 'offset', min: 0) ?? 0;
    if (offset > (text?.length ?? 0)) {
      throw const McpRefusal('That offset is past the end of the transcript.');
    }
    final end = text == null
        ? 0
        : (offset + McpLibrary.pageSize).clamp(0, text.length);
    final summary = voice.summary;
    return (
      output: {
        'duration_ms': voice.durationMs,
        'summary': summary == null
            ? null
            : {'title': summary.title, 'points': summary.points},
        'takes': [
          for (final take in voice.takes)
            {'kind': take.kind.name, 'text': take.text},
        ],
        'transcript': text?.substring(offset, end),
        'offset': offset,
        'next_offset': text != null && end < text.length ? end : null,
      },
      error: null,
      undo: null,
      activity: 'Read a voice note in “${_clip(note.title, 40)}”',
    );
  }

  static String _clock(int ms) {
    final seconds = ms ~/ 1000;
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  McpToolResult _listTags() {
    final tags = library.allTags();
    return (
      output: {
        'tags': [
          for (final (:tag, :notes) in tags)
            {'name': tag.name.v, 'colour': tag.colour.v, 'notes': notes},
        ],
      },
      error: null,
      undo: null,
      activity: 'Listed ${_count(tags.length, 'tag')}',
    );
  }

  McpToolResult _editNote(Map<String, Object?> args) {
    final raw = args['edits'];
    if (raw is! List) throw const McpRefusal('edits is a list of edits.');
    final edits = [
      for (final edit in raw)
        switch (edit) {
          final Map<String, Object?> edit when edit['find'] != null =>
            McpReplace(
              find: _required(edit, 'find'),
              replacement: _required(edit, 'replacement'),
              occurrence: _int(edit, 'occurrence', min: 0),
            ),
          final Map<String, Object?> edit when edit['start'] != null =>
            McpSplice(
              start: _int(edit, 'start', min: 0)!,
              end: _int(edit, 'end', min: 0),
              text: _string(edit, 'text') ?? '',
              expected: _string(edit, 'expected'),
            ),
          _ => throw const McpRefusal(
            'Each edit has find and replacement, or start and text.',
          ),
        },
    ];
    final note = library.edit(_required(args, 'id'), edits);
    return (
      output: {'note': _summaryOf(note)},
      error: null,
      undo: null,
      activity: 'Edited “${_clip(note.title, 40)}”',
    );
  }

  McpToolResult _updateNote(Map<String, Object?> args) {
    final id = _required(args, 'id');
    final title = _string(args, 'title', max: McpLibrary.maxTitle);
    final pinned = _bool(args, 'pinned');
    final archived = _bool(args, 'archived');
    if (title == null && pinned == null && archived == null) {
      throw const McpRefusal('Give a title, pinned or archived.');
    }
    final before = library.read(id);
    final oldTitle = before.title;
    final oldFirst = before.isDrawing ? before.body : before.firstLine;
    final done = <String>[];
    final undos = <McpUndo>[];
    bool live() =>
        library.notes.byId(id) != null && !library.notes.byId(id)!.isHidden;
    if (title != null) {
      final after = library.rename(id, title);
      if (after.title != oldTitle) {
        final newFirst = after.isDrawing ? after.body : after.firstLine;
        done.add('Renamed “${_clip(oldTitle, 30)}” to “${_clip(after.title, 30)}”');
        undos.add((
          possible: () {
            final now = library.notes.byId(id);
            return live() &&
                library.readOnlyReason(now!) == null &&
                (now.isDrawing ? now.body : now.firstLine) == newFirst;
          },
          run: () {
            final now = library.notes.byId(id)!;
            if (now.isDrawing) {
              library.notes.updateDrawing(
                id,
                now.drawing!,
                title: oldFirst,
                authored: false,
              );
            } else {
              library.notes.retitle(id, oldFirst);
            }
          },
        ));
      }
    }
    if (pinned != null && library.setPinned(id, pinned: pinned)) {
      done.add(pinned ? 'Pinned' : 'Unpinned');
      undos.add((
        possible: () =>
            live() &&
            !library.notes.byId(id)!.isArchived &&
            library.notes.isPinned(id) == pinned,
        run: () => library.notes.togglePinned(id),
      ));
    }
    if (archived != null && library.setArchived(id, archived: archived)) {
      done.add(archived ? 'Archived' : 'Brought back');
      undos.add((
        possible: () =>
            live() && library.notes.byId(id)!.isArchived == archived,
        run: () =>
            archived ? library.notes.restore(id) : library.notes.archive(id),
      ));
    }
    final note = library.read(id);
    final name = '“${_clip(note.title, 40)}”';
    return (
      output: {'note': _summaryOf(note)},
      error: null,
      undo: undos.isEmpty
          ? null
          : (
              possible: () => undos.every((undo) => undo.possible()),
              run: () {
                for (final undo in undos.reversed) {
                  undo.run();
                }
              },
            ),
      activity: done.isEmpty
          ? 'Left $name as it was'
          : done.first.startsWith('Renamed')
          ? [done.first, ...done.skip(1).map(_lowerFirst)].join(', ')
          : '${[done.first, ...done.skip(1).map(_lowerFirst)].join(', ')} $name',
    );
  }

  McpToolResult _tagNote(Map<String, Object?> args) {
    final id = _required(args, 'id');
    final add = _strings(args, 'add');
    final remove = _strings(args, 'remove');
    if (add.isEmpty && remove.isEmpty) {
      throw const McpRefusal('Give tags to add or remove.');
    }
    final change = library.retag(
      id,
      add: add,
      remove: remove,
      createMissing: _bool(args, 'create_missing') ?? false,
    );
    final note = library.read(id);
    final store = library.tags!;
    final added = [for (final tag in change.added) tag.id];
    final removed = [for (final tag in change.removed) tag.id];
    final parts = [
      if (change.added.isNotEmpty) 'Tagged “${_clip(note.title, 40)}” with ${_names(change.added)}',
      if (change.removed.isNotEmpty)
        '${change.added.isEmpty ? 'Took' : 'took'} ${_names(change.removed)} off'
            '${change.added.isEmpty ? ' “${_clip(note.title, 40)}”' : ''}',
    ];
    return (
      output: {
        'tags': [for (final tag in library.tagsOf(note)) tag.name.v],
      },
      error: null,
      undo: parts.isEmpty
          ? null
          : (
              possible: () {
                final now = library.notes.byId(id);
                if (now == null || now.isHidden) return false;
                final on = {for (final tag in store.tagsOf(id)) tag.id};
                return added.every(on.contains) &&
                    removed.every(
                      (tagId) => !on.contains(tagId) && store.byId(tagId) != null,
                    );
              },
              run: () {
                final on = [
                  for (final tag in store.tagsOf(id))
                    if (!added.contains(tag.id)) tag.id,
                ];
                store.setTags(id, [...on, ...removed]);
                for (final tag in change.created) {
                  store.delete(tag.id);
                }
              },
            ),
      activity: parts.isEmpty
          ? 'Left the tags on “${_clip(note.title, 40)}” as they were'
          : parts.join(', and '),
    );
  }

  McpToolResult _manageTag(Map<String, Object?> args) {
    final action = _required(args, 'action');
    final name = _required(args, 'tag');
    final store = library.tags;
    switch (action) {
      case 'create':
        final tag = library.createTag(name, colour: _string(args, 'colour'));
        return (
          output: {'tag': _tagOf(tag)},
          error: null,
          undo: (
            possible: () => store!.byId(tag.id) != null,
            run: () => store!.delete(tag.id),
          ),
          activity: 'Created tag ${_names([tag])}',
        );
      case 'rename':
        final old = library.tagNamed(name);
        final tag = library.renameTag(name, _required(args, 'new_name'));
        return (
          output: {'tag': _tagOf(tag)},
          error: null,
          undo: (
            possible: () => store!.byId(tag.id)?.name.v == tag.name.v,
            run: () => store!.rename(tag.id, old.name.v),
          ),
          activity: 'Renamed tag ${_names([old])} to ${_names([tag])}',
        );
      case 'recolour':
        final colour = _string(args, 'colour');
        if (colour == null) throw const McpRefusal('Give a colour.');
        final old = library.tagNamed(name).colour.v;
        final tag = library.recolourTag(name, colour);
        return (
          output: {'tag': _tagOf(tag)},
          error: null,
          undo: old == colour
              ? null
              : (
                  possible: () => store!.byId(tag.id)?.colour.v == colour,
                  run: () => store!.recolour(tag.id, old),
                ),
          activity: 'Made tag ${_names([tag])} $colour',
        );
      case 'delete':
        final tag = library.deleteTag(name);
        return (
          output: {'tag': _tagOf(tag)},
          error: null,
          undo: (
            possible: () => store!.byId(tag.id) == null,
            run: () => store!.restore(tag.id),
          ),
          activity: 'Deleted tag ${_names([tag])}; its notes stay',
        );
      default:
        throw const McpRefusal('action is create, rename, recolour or delete.');
    }
  }

  McpToolResult _editTask(Map<String, Object?> args) {
    final taskId = _required(args, 'task_id');
    final text = _string(args, 'text');
    final moveTo = _string(args, 'move_to_note_id');
    final remove = _bool(args, 'remove') ?? false;
    if ([text != null, moveTo != null, remove].where((on) => on).length != 1) {
      throw const McpRefusal(
        'Give exactly one of text, move_to_note_id or remove.',
      );
    }
    if (remove) {
      final note = library.removeTask(taskId);
      return (
        output: {'task': null},
        error: null,
        undo: null,
        activity: 'Removed a task from “${_clip(note.title, 40)}”',
      );
    }
    final task = text != null
        ? library.rewordTask(taskId, text)
        : library.moveTask(
            taskId,
            noteId: moveTo!,
            beforeTaskId: _string(args, 'before_task_id'),
          );
    return (
      output: {'task': _taskOf(task)},
      error: null,
      undo: null,
      activity: text != null
          ? 'Reworded a task in “${_clip(task.note.title, 40)}”'
          : 'Moved a task to “${_clip(task.note.title, 40)}”',
    );
  }

  McpToolResult _draw(Map<String, Object?> args) {
    final add = args['add'] ?? const <Object?>[];
    if (add is! List) throw const McpRefusal('add is a list of elements.');
    final remove = _strings(args, 'remove');
    final noteId = _string(args, 'note_id');
    if (noteId != null && args['title'] != null) {
      throw const McpRefusal(
        'Give note_id to change a drawing, or title to start one, not both.',
      );
    }
    final result = library.draw(
      id: noteId,
      title: _string(args, 'title'),
      add: add,
      remove: remove,
    );
    final name = '“${_clip(result.note.title, 40)}”';
    final parts = [
      if (result.added.isNotEmpty) 'drew ${_count(result.added.length, 'shape')}',
      if (remove.isNotEmpty) 'erased ${_count(remove.length, 'shape')}',
    ];
    return (
      output: {
        'note': _summaryOf(result.note),
        'added': result.added,
        'elements': result.note.drawing!.elements.length,
      },
      error: null,
      undo: null,
      activity: noteId == null
          ? 'Started drawing $name'
                '${parts.isEmpty ? '' : ' and ${parts.join(' and ')}'}'
          : parts.isEmpty
          ? 'Left drawing $name as it was'
          : '${_upperFirst(parts.join(' and '))} on $name',
    );
  }

  static Map<String, Object?> _attachmentOf(NoteAttachmentRef ref) => {
    'kind': switch (ref) {
      NoteImageRef() => 'image',
      NoteVideoRef() => 'video',
      NoteVoiceRef() => 'voice',
      NoteFileRef() => 'file',
      _ => 'other',
    },
    'mime': ref.mime,
    'bytes': ref.bytes,
    if (ref is NoteFileRef) 'name': ref.name,
    if (ref is NoteVideoRef) 'duration_ms': ref.durationMs,
    if (ref is NoteVoiceRef) ...{
      'voice_id': McpLibrary.voiceIdOf(ref),
      'duration_ms': ref.durationMs,
      if (ref.summary != null) 'summary_title': ref.summary!.title,
      'has_transcript': ref.transcript != null,
    },
  };

  static Map<String, Object?> _tagOf(Tag tag) => {
    'name': tag.name.v,
    'colour': tag.colour.v,
  };

  static String _names(List<Tag> tags) =>
      tags.map((tag) => '“${_clip(tag.name.v, 30)}”').join(', ');

  static String _lowerFirst(String text) =>
      text.isEmpty ? text : text[0].toLowerCase() + text.substring(1);

  static String _upperFirst(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

  static List<String> _strings(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value == null) return const [];
    if (value is! List || value.any((each) => each is! String)) {
      throw McpRefusal('$key is a list of names.');
    }
    if (value.length > 100) throw McpRefusal('$key is too long.');
    return value.cast<String>();
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
      'tags': [for (final tag in library.tagsOf(note)) tag.name.v],
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
    'details': taskDetailsText(task.note.body, task.line),
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
