import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/ui/tasks/task_marks.dart';

Note _note(String title) => Note(
  id: 'note-1',
  body: '$title\n☐ Automate Backlink Outreach',
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 20),
);

Space _space({String? name, SpaceKind kind = SpaceKind.team}) => Space(
  id: 'space-1',
  kind: kind,
  name: name,
  ownerId: 'me',
  role: SpaceRole.owner,
  keyGeneration: 1,
  rotationPending: false,
  spaceKey: null,
  members: const [],
  invites: const [],
  liveNotes: 1,
  createdAt: DateTime.utc(2026, 9, 1),
);

void main() {
  const title = 'SnowSEO Issues';

  test('omits a missing space name instead of printing null', () {
    final note = _note(title);
    expect(taskNoteLabel(note, null), title);
    expect(taskNoteLabel(note, _space(name: null)), title);
    expect(taskNoteLabel(note, _space(name: '   ')), title);
    expect(
      taskNoteLabel(note, _space(name: null, kind: SpaceKind.personal)),
      title,
    );
    expect(taskNoteLabel(note, _space(name: null)), isNot(contains('null')));
  });

  test('keeps a space name that is actually set', () {
    expect(
      taskNoteLabel(_note(title), _space(name: 'With coders')),
      '$title · With coders',
    );
  });
}
