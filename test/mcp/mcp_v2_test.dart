import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/mcp/mcp_library.dart';
import 'package:kapy_notes/mcp/mcp_tools.dart';

import '../crdt/helpers.dart' show bold, image;
import 'mcp_test_helpers.dart';

/// Every tool an assistant gets, called as a client would call it.
void main() {
  late McpFixture f;
  late McpTools tools;

  setUp(() async {
    f = McpFixture();
    await f.tags.load();
    tools = McpTools(f.library);
  });

  McpToolResult call(
    String name,
    Map<String, Object?> args, {
    bool writes = true,
  }) => tools.call(name, args, writes: writes);

  Map<String, Object?> ok(String name, Map<String, Object?> args) {
    final result = call(name, args);
    expect(result.error, isNull, reason: '$name: ${result.error}');
    return result.output!;
  }

  String refused(String name, Map<String, Object?> args) {
    final result = call(name, args);
    expect(result.output, isNull, reason: name);
    return result.error!;
  }

  String body(String id) => f.notes.byId(id)!.body;

  group('tiers', () {
    test('read-only offers no change, and refuses every one', () {
      final offered = {
        for (final tool in tools.definitions(writes: false)) tool['name'],
      };
      expect(offered, {
        'list_notes',
        'read_note',
        'read_voice_note',
        'list_tasks',
        'list_tags',
      });
      final before = [for (final note in f.notes.notes) note.body];
      for (final name in McpTools.writeTools) {
        final result = call(name, {
          'id': f.plain,
          'note_id': f.plain,
          'title': 'x',
        }, writes: false);
        expect(result.error, startsWith('Changes are off'), reason: name);
      }
      expect([for (final note in f.notes.notes) note.body], before);
      expect(f.tags.tags, isEmpty);
    });

    test('each tool says what it does to the notes', () {
      final all = tools.definitions(writes: true);
      expect(all, hasLength(15));
      for (final tool in all) {
        final hints = tool['annotations']! as Map<String, Object?>;
        final writes = McpTools.writeTools.contains(tool['name']);
        expect(hints['readOnlyHint'], !writes, reason: '${tool['name']}');
        expect(hints['openWorldHint'], isFalse);
        expect(
          hints['destructiveHint'] == true,
          const {
            'edit_note',
            'manage_tag',
            'edit_task',
            'draw',
          }.contains(tool['name']),
          reason: '${tool['name']}',
        );
      }
    });
  });

  test('every tool treats a Hidden note as one that doesn’t exist', () {
    final h = f.hidden;
    final calls = <String, Map<String, Object?>>{
      'read_note': {'id': h},
      'read_voice_note': {'note_id': h, 'voice_id': 'x'},
      'append_to_note': {'id': h, 'text': 'x'},
      'edit_note': {
        'id': h,
        'edits': [
          {'find': 'diary', 'replacement': 'x'},
        ],
      },
      'update_note': {'id': h, 'archived': true},
      'tag_note': {
        'id': h,
        'add': ['Leak'],
        'create_missing': true,
      },
      'add_task': {'note_id': h, 'text': 'x'},
      'set_task_done': {'task_id': '$h~x~0', 'done': true},
      'edit_task': {'task_id': '$h~x~0', 'remove': true},
      'draw': {'note_id': h, 'add': <Object?>[]},
    };
    for (final MapEntry(key: name, value: args) in calls.entries) {
      expect(refused(name, args), McpLibrary.notFound, reason: name);
    }
    expect(f.tags.tags, isEmpty);
    expect(body(h), 'Secret diary\nnothing to see');
  });

  test('a tag only Hidden notes carry is as hidden as they are', () {
    final secret = f.tags.create('Secret')!;
    f.tags.addTag(f.hidden, secret.id);
    final shared = f.tags.create('Shared')!;
    f.tags.addTag(f.hidden, shared.id);
    f.tags.addTag(f.plain, shared.id);
    expect(ok('list_tags', {})['tags'], [
      {'name': 'Shared', 'colour': shared.colour.v, 'notes': 1},
    ]);
    const missing = 'There’s no tag called “Secret”.';
    expect(refused('list_notes', {'tag': 'Secret'}), missing);
    expect(
      refused('tag_note', {
        'id': f.plain,
        'add': ['Secret'],
      }),
      '$missing Set create_missing to make it.',
    );
    expect(
      refused('tag_note', {
        'id': f.plain,
        'remove': ['Secret'],
      }),
      missing,
    );
    for (final args in [
      {'action': 'rename', 'tag': 'Secret', 'new_name': 'Out'},
      {'action': 'recolour', 'tag': 'Secret', 'colour': 'rose'},
      {'action': 'delete', 'tag': 'Secret'},
    ]) {
      expect(refused('manage_tag', args), missing, reason: '${args['action']}');
    }
    expect(
      refused('manage_tag', {'action': 'create', 'tag': 'secret'}),
      'Choose another name for that tag.',
    );
    for (final args in [
      {'action': 'rename', 'tag': 'Shared', 'new_name': 'Out'},
      {'action': 'recolour', 'tag': 'Shared', 'colour': 'rose'},
      {'action': 'delete', 'tag': 'Shared'},
    ]) {
      expect(
        refused('manage_tag', args),
        'Change this tag in Kapy Notes.',
        reason: '${args['action']}',
      );
    }
    ok('tag_note', {
      'id': f.plain,
      'remove': ['Shared'],
    });
    expect(f.tags.byId(shared.id)!.name.v, 'Shared');
    expect(f.tags.byId(shared.id)!.colour.v, shared.colour.v);
    expect(f.tags.byId(secret.id)!.name.v, 'Secret');
    expect(f.tags.tagsOf(f.hidden).map((tag) => tag.id), [
      secret.id,
      shared.id,
    ]);
  });

  group('edit_note', () {
    test('replaces a match, and asks which when there are several', () {
      ok('edit_note', {
        'id': f.plain,
        'edits': [
          {'find': '420', 'replacement': '450'},
        ],
      });
      expect(body(f.plain), contains('flights = 450'));

      final echo = f.notes.create(body: 'Echo\na a a', authored: false).id;
      Map<String, Object?> once(int? occurrence, String to) => {
        'id': echo,
        'edits': [
          {'find': 'a', 'replacement': to, 'occurrence': ?occurrence},
        ],
      };
      expect(refused('edit_note', once(null, 'b')), contains('3 times'));
      ok('edit_note', once(2, 'b'));
      expect(body(echo), 'Echo\na b a');
      ok('edit_note', once(0, 'c'));
      expect(body(echo), 'Echo\nc b c');
      expect(
        refused(
          'edit_note',
          once(null, 'x')
            ..['edits'] = [
              {'find': 'zebra', 'replacement': 'x'},
            ],
        ),
        contains('isn’t in the note'),
      );
      expect(f.notes.streak.wroteToday, isFalse);
    });

    test('inserts and replaces by offset, and notices a stale read', () {
      final view = ok('read_note', {'id': f.plain})['body']! as String;
      final at = view.indexOf('hotel');
      ok('edit_note', {
        'id': f.plain,
        'edits': [
          {'start': at, 'end': at + 5, 'text': 'room', 'expected': 'hotel'},
          {'start': 0, 'text': '# '},
        ],
      });
      expect(body(f.plain), startsWith('# Trip budget\n'));
      expect(body(f.plain), contains('\nroom = 300'));
      expect(
        refused('edit_note', {
          'id': f.plain,
          'edits': [
            {'start': 0, 'end': 4, 'text': 'x', 'expected': 'Trip'},
          ],
        }),
        'That note changed; read it again.',
      );
      expect(
        refused('edit_note', {
          'id': f.plain,
          'edits': [
            {'start': 2, 'end': 6, 'text': 'x'},
            {'start': 4, 'end': 8, 'text': 'y'},
          ],
        }),
        'Two of those edits overlap.',
      );
    });

    test('styles and attachments move with the text, and stay', () {
      final id = f.notes.create(authored: false).id;
      f.notes.updateDocument(
        id,
        'Head\n\uFFFC bold',
        [bold(7, 11)],
        [image(5)],
      );
      ok('edit_note', {
        'id': id,
        'edits': [
          {'find': 'Head', 'replacement': 'Heading longer'},
        ],
      });
      var note = f.notes.byId(id)!;
      expect(note.attachments.single.offset, 15);
      expect(note.formats.single.start, 17);

      final view = ok('read_note', {'id': id})['body']! as String;
      expect(view, 'Heading longer\n[image] bold');
      final at = view.indexOf('bold');
      ok('edit_note', {
        'id': id,
        'edits': [
          {'start': at, 'end': at + 4, 'text': 'BOLD', 'expected': 'bold'},
        ],
      });
      note = f.notes.byId(id)!;
      expect(note.body, 'Heading longer\n\uFFFC BOLD');
      expect(
        note.formats.single,
        isA<NoteFormatRange>().having((r) => r.end, 'end', note.body.length),
      );

      final image0 = view.indexOf('[image]');
      expect(
        refused('edit_note', {
          'id': id,
          'edits': [
            {'start': image0 + 2, 'text': 'x'},
          ],
        }),
        'That offset is inside an attachment.',
      );
      expect(
        refused('edit_note', {
          'id': id,
          'edits': [
            {'start': image0, 'end': image0 + 7, 'text': ''},
          ],
        }),
        contains('remove an attachment'),
      );
      expect(f.notes.byId(id)!.attachments, hasLength(1));
    });

    test('a drawing, an archived note and a shared one are refused', () {
      Map<String, Object?> edit(String id) => {
        'id': id,
        'edits': [
          {'start': 0, 'text': 'x'},
        ],
      };
      expect(
        refused('edit_note', edit(f.drawing)),
        'A drawing has no text. Use draw to change it.',
      );
      expect(
        refused('edit_note', edit(f.archived)),
        'Archived notes are read-only.',
      );
      expect(
        refused('edit_note', edit(f.shared)),
        'Notes in shared spaces are read-only here.',
      );
    });
  });

  group('update_note', () {
    test('renames, and Undo puts the old title back', () {
      final result = call('update_note', {'id': f.plain, 'title': 'Trip plan'});
      expect(result.error, isNull);
      expect(f.notes.byId(f.plain)!.title, 'Trip plan');
      expect(result.activity, 'Renamed “Trip budget” to “Trip plan”');
      expect(result.undo!.possible(), isTrue);
      result.undo!.run();
      expect(f.notes.byId(f.plain)!.title, 'Trip budget');
      expect(result.undo!.possible(), isFalse);
      expect(body(f.plain), startsWith('Trip budget\nflights'));
    });

    test('pins and archives, and Undo takes each back', () {
      final pin = call('update_note', {'id': f.plain, 'pinned': true});
      expect(f.notes.isPinned(f.plain), isTrue);
      expect(pin.activity, 'Pinned “Trip budget”');
      pin.undo!.run();
      expect(f.notes.isPinned(f.plain), isFalse);

      final archive = call('update_note', {'id': f.plain, 'archived': true});
      expect(f.notes.byId(f.plain)!.isArchived, isTrue);
      expect(archive.activity, 'Archived “Trip budget”');
      expect(archive.undo!.possible(), isTrue);
      archive.undo!.run();
      expect(f.notes.byId(f.plain)!.isArchived, isFalse);

      final again = call('update_note', {'id': f.plain, 'archived': false});
      expect(again.undo, isNull);
      expect(again.activity, 'Left “Trip budget” as it was');
    });

    test('a shared note can be pinned but not renamed or archived', () {
      ok('update_note', {'id': f.shared, 'pinned': true});
      expect(f.notes.isPinned(f.shared), isTrue);
      expect(
        refused('update_note', {'id': f.shared, 'title': 'Mine'}),
        'Notes in shared spaces are read-only here.',
      );
      expect(
        refused('update_note', {'id': f.shared, 'archived': true}),
        contains('shared spaces can’t be archived'),
      );
      f.locked.add(f.plain);
      expect(
        refused('update_note', {'id': f.plain, 'title': 'x'}),
        'Read-only on Free.',
      );
    });
  });

  group('tags', () {
    test('tag_note adds only tags that exist, unless asked to make them', () {
      expect(
        refused('tag_note', {
          'id': f.plain,
          'add': ['Travel'],
        }),
        contains('Set create_missing'),
      );
      final result = call('tag_note', {
        'id': f.plain,
        'add': ['Travel'],
        'create_missing': true,
      });
      expect(result.output, {
        'tags': ['Travel'],
      });
      expect(result.activity, 'Tagged “Trip budget” with “Travel”');
      expect(ok('list_tags', {})['tags'], [
        {
          'name': 'Travel',
          'colour': f.tags.named('Travel')!.colour.v,
          'notes': 1,
        },
      ]);
      expect(
        ok('read_note', {'id': f.plain})['note'],
        containsPair('tags', ['Travel']),
      );
      result.undo!.run();
      expect(f.tags.tagsOf(f.plain), isEmpty);
      expect(f.tags.named('Travel'), isNull);
    });

    test('a shared note can carry the person’s tags; a note at most 20', () {
      ok('tag_note', {
        'id': f.shared,
        'add': ['Work'],
        'create_missing': true,
      });
      expect(f.tags.tagsOf(f.shared).single.name.v, 'Work');
      expect(
        refused('tag_note', {
          'id': f.plain,
          'add': [for (var i = 0; i < 21; i++) 'T$i'],
          'create_missing': true,
        }),
        'A note carries at most 20 tags.',
      );
      expect(f.tags.tags, hasLength(1));
    });

    test(
      'manage_tag creates, renames, recolours and deletes, each undoable',
      () {
        final created = call('manage_tag', {
          'action': 'create',
          'tag': 'Ideas',
          'colour': 'teal',
        });
        expect(created.output, {
          'tag': {'name': 'Ideas', 'colour': 'teal'},
        });
        expect(
          refused('manage_tag', {'action': 'create', 'tag': 'ideas'}),
          contains('already a tag'),
        );
        ok('tag_note', {
          'id': f.plain,
          'add': ['Ideas'],
        });

        final renamed = call('manage_tag', {
          'action': 'rename',
          'tag': 'Ideas',
          'new_name': 'Plans',
        });
        expect(renamed.activity, 'Renamed tag “Ideas” to “Plans”');
        renamed.undo!.run();
        expect(f.tags.named('Ideas'), isNotNull);

        expect(
          refused('manage_tag', {
            'action': 'recolour',
            'tag': 'Ideas',
            'colour': 'purple',
          }),
          contains('colour is one of'),
        );
        final recoloured = call('manage_tag', {
          'action': 'recolour',
          'tag': 'Ideas',
          'colour': 'rose',
        });
        expect(f.tags.named('Ideas')!.colour.v, 'rose');
        recoloured.undo!.run();
        expect(f.tags.named('Ideas')!.colour.v, 'teal');

        final deleted = call('manage_tag', {
          'action': 'delete',
          'tag': 'Ideas',
        });
        expect(deleted.activity, 'Deleted tag “Ideas”; its notes stay');
        expect(f.notes.byId(f.plain), isNotNull);
        expect(f.tags.tagsOf(f.plain), isEmpty);
        deleted.undo!.run();
        expect(f.tags.tagsOf(f.plain).single.name.v, 'Ideas');
      },
    );

    test('create_note tags and pins, and list_notes filters by both', () {
      final note =
          ok('create_note', {
                'title': 'Packing',
                'tags': ['Travel'],
                'create_missing_tags': true,
                'pinned': true,
              })['note']!
              as Map<String, Object?>;
      expect(note, containsPair('tags', ['Travel']));
      expect(note, containsPair('pinned', true));
      expect(
        refused('create_note', {
          'title': 'Nope',
          'tags': ['Unknown'],
        }),
        contains('no tag called'),
      );
      expect(f.notes.notes.where((n) => n.title == 'Nope'), isEmpty);

      List<Object?> ids(Map<String, Object?> args) => [
        for (final n in ok('list_notes', args)['notes']! as List)
          (n as Map)['id'],
      ];
      expect(ids({'tag': 'Travel'}), [note['id']]);
      expect(ids({'pinned': true}), [note['id']]);
      expect(ids({'only_archived': true}), [f.archived]);
    });
  });

  group('edit_task', () {
    String taskId(String noteId, String text) => [
      for (final t
          in ok('list_tasks', {'note_id': noteId, 'status': 'all'})['tasks']!
              as List)
        if ((t as Map)['text'] == text) t['id'] as String,
    ].single;

    test('rewords a task', () {
      ok('edit_task', {
        'task_id': taskId(f.plain, 'Book taxi'),
        'text': 'Book cab',
      });
      expect(body(f.plain), contains('\n☐ Book cab\n'));
    });

    test('moves a task, ticked, in the other note’s style', () {
      final chores = f.notes
          .create(body: 'Chores\n- [ ] Laundry', authored: false)
          .id;
      final moved =
          ok('edit_task', {
                'task_id': taskId(f.plain, 'Pack bag'),
                'move_to_note_id': chores,
              })['task']!
              as Map;
      expect(moved['done'], isTrue);
      expect(body(chores), 'Chores\n- [ ] Laundry\n- [x] Pack bag');
      expect(body(f.plain), isNot(contains('Pack bag')));

      ok('edit_task', {
        'task_id': taskId(chores, 'Pack bag'),
        'move_to_note_id': chores,
        'before_task_id': taskId(chores, 'Laundry'),
      });
      expect(body(chores), 'Chores\n- [x] Pack bag\n- [ ] Laundry');
    });

    test('moves before the right one of two tasks with the same words', () {
      final chores = f.notes
          .create(
            body: 'Chores\n- [ ] Laundry\n- [ ] Dishes\n- [ ] Laundry',
            authored: false,
          )
          .id;
      final second = [
        for (final t in ok('list_tasks', {'note_id': chores})['tasks']! as List)
          if ((t as Map)['text'] == 'Laundry') t['id'] as String,
      ].last;
      ok('edit_task', {
        'task_id': taskId(f.plain, 'Book taxi'),
        'move_to_note_id': chores,
        'before_task_id': second,
      });
      expect(
        body(chores),
        'Chores\n- [ ] Laundry\n- [ ] Dishes\n- [ ] Book taxi\n- [ ] Laundry',
      );
    });

    test('a move the other note can’t take leaves the task where it was', () {
      final full = f.notes
          .create(
            body: 'Full\n${'x' * (McpLibrary.maxNoteLength - 8)}',
            authored: false,
          )
          .id;
      final before = body(f.plain);
      expect(
        refused('edit_task', {
          'task_id': taskId(f.plain, 'Book taxi'),
          'move_to_note_id': full,
        }),
        'That would make the note too long.',
      );
      expect(body(f.plain), before);
      expect(body(full), isNot(contains('Book taxi')));
    });

    test('removes a task’s line and keeps the note', () {
      ok('edit_task', {
        'task_id': taskId(f.plain, 'Book taxi'),
        'remove': true,
      });
      expect(
        body(f.plain),
        'Trip budget\nflights = 420\nhotel = 300\n☑ Pack bag',
      );
      ok('edit_task', {'task_id': taskId(f.plain, 'Pack bag'), 'remove': true});
      expect(body(f.plain), 'Trip budget\nflights = 420\nhotel = 300');
      expect(
        refused('edit_task', {
          'task_id': '${f.plain}~x~0',
          'text': 'a',
          'remove': true,
        }),
        'Give exactly one of text, move_to_note_id or remove.',
      );
    });
  });

  group('draw', () {
    final shapes = [
      {
        'kind': 'rect',
        'points': [
          [0, 0],
          [100, 50],
        ],
        'color': '#336699',
      },
      {
        'kind': 'text',
        'points': [
          [10, 10],
        ],
        'text': 'Kitchen <1>',
      },
      {
        'kind': 'pen',
        'points': [
          [0, 60],
          [20, 70],
          [40, 60],
        ],
        'width': 3,
      },
    ];

    test('starts a drawing, and reads it back as SVG with element ids', () {
      final out = ok('draw', {'title': 'Floor plan', 'add': shapes});
      final added = (out['added']! as List).cast<String>();
      final id = (out['note']! as Map)['id'] as String;
      expect(added, hasLength(3));
      expect((out['note']! as Map)['kind'], 'drawing');
      expect(f.notes.byId(id)!.title, 'Floor plan');
      expect(f.notes.streak.wroteToday, isFalse);

      final read = ok('read_note', {'id': id});
      final drawing = read['drawing']! as Map;
      expect(drawing['elements'], 3);
      final svg = drawing['svg']! as String;
      expect(svg, startsWith('<svg xmlns="http://www.w3.org/2000/svg"'));
      expect(
        svg,
        contains(
          '<rect id="${added[0]}" x="0" y="0" width="100" height="50" stroke="#336699"',
        ),
      );
      expect(svg, contains('Kitchen &lt;1&gt;'));
      expect(
        svg,
        contains('<polyline id="${added[2]}" points="0,60 20,70 40,60"'),
      );

      ok('draw', {
        'note_id': id,
        'remove': [added[1]],
        'add': [
          {
            'kind': 'arrow',
            'points': [
              [0, 0],
              [50, 50],
            ],
          },
        ],
      });
      expect(f.notes.byId(id)!.drawing!.elements, hasLength(3));
      expect(f.notes.byId(id)!.drawing!.byId(added[1]), isNull);
      expect(
        refused('draw', {
          'note_id': id,
          'remove': ['nope'],
        }),
        contains('no element nope'),
      );
    });

    test('refuses what the canvas can’t hold, and notes with text', () {
      expect(
        refused('draw', {
          'title': 'x',
          'add': [
            {
              'kind': 'star',
              'points': [
                [0, 0],
              ],
            },
          ],
        }),
        contains('kind is one of'),
      );
      expect(
        refused('draw', {
          'title': 'x',
          'add': [
            {
              'kind': 'rect',
              'points': [
                [0, 0],
                [1, 1],
                [2, 2],
              ],
            },
          ],
        }),
        'A rect has two points.',
      );
      expect(
        refused('draw', {
          'title': 'x',
          'add': [
            {
              'kind': 'line',
              'points': [
                [0, 0],
                [1, 1],
              ],
              'color': 'red',
            },
          ],
        }),
        contains('#RRGGBB'),
      );
      expect(
        refused('draw', {
          'title': 'x',
          'add': [
            {
              'kind': 'pen',
              'points': [
                [0, 1e9],
              ],
            },
          ],
        }),
        contains('Coordinates'),
      );
      expect(
        refused('draw', {'note_id': f.plain, 'add': shapes}),
        contains('not a drawing'),
      );
      expect(f.notes.notes.where((n) => n.title == 'x'), isEmpty);
    });
  });

  test('read_voice_note reads the summary, takes and transcript', () {
    final id = f.notes.create(authored: false).id;
    f.notes.updateDocument(id, 'Call\n\uFFFC', const [], [
      NoteVoiceRef(
        offset: 5,
        hash: '0123456789abcdef',
        key: Uint8List(32),
        bytes: 10,
        durationMs: 65000,
        transcript: VoiceTranscript(
          lang: 'en',
          engine: 't',
          at: 1,
          segments: const [
            TranscriptSegment(s: 0, e: 1000, t: 'Hello', speaker: 0),
            TranscriptSegment(s: 61000, e: 62000, t: 'Hi there', speaker: 1),
          ],
          speakers: const {0: 'Ana'},
        ),
        summary: VoiceSummary(
          engine: 's',
          at: 1,
          title: 'Greeting',
          points: const ['They said hello'],
        ),
      ),
    ]);
    final attachment =
        ((ok('read_note', {'id': id})['attachments']! as List).single as Map);
    expect(attachment['kind'], 'voice');
    expect(attachment['voice_id'], '0123456789ab');
    expect(attachment['summary_title'], 'Greeting');

    final voice = ok('read_voice_note', {
      'note_id': id,
      'voice_id': '0123456789ab',
    });
    expect(voice['duration_ms'], 65000);
    expect(voice['summary'], {
      'title': 'Greeting',
      'points': ['They said hello'],
    });
    final transcript = voice['transcript']! as String;
    expect(transcript, startsWith('[0:00] Ana: Hello\n[1:01] '));
    expect(transcript, endsWith('Hi there'));
    expect(
      refused('read_voice_note', {'note_id': id, 'voice_id': 'nope'}),
      contains('No voice note'),
    );
  });
}
