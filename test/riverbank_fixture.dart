import 'dart:typed_data';

import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/notes_store.dart';

/// The notes the final Riverbank artboards in Paper are drawn with
/// (file 01M7HGSWEAH0VTGM4PQWD1H3HS, page "Final · Riverbank dark"): 127 notes,
/// 100 of them pinned, with SnowSEO Issues open.
///
/// The clock is Monday 16 November 2026, so "Sat" is the 14th.
final riverbankNow = DateTime(2026, 11, 16, 11, 20);

const riverbankOpenId = 'snowseo';

const _snowSeoBody =
    'SnowSEO Issues\n'
    '☐ Automate Backlink Outreach\n'
    '☑ Update pricing and plans\n'
    '☐ Shopping and maps\n'
    '☐ agency whitelabel\n'
    '☑ update plans and features\n'
    '☑ GMB Integration\n'
    '☐ Human Expert Writing\n'
    '☐ add a report link with weekly performance report email:\n'
    'https://app.openseo.so/s/_g7CLGiBVMgNALKe4Qw\n'
    '\u{FFFC}\n'
    'Tool costs per month\n'
    'ahrefs = 129 usd\n'
    'looker connector = 29 usd\n'
    'outreach seats = 3 × 49 usd\n'
    'total';

Uint8List _key(int seed) => Uint8List.fromList(List.filled(32, seed % 256));

String _hex(int seed) => seed.toRadixString(16).padLeft(64, '0');

NoteImageRef _image(int offset, int seed) => NoteImageRef(
  offset: offset,
  hash: _hex(seed),
  key: _key(seed),
  mime: 'image/png',
  width: 800,
  height: 600,
  bytes: 4096,
);

NoteVoiceRef _voice(int offset, int seed, {int ms = 42000}) => NoteVoiceRef(
  offset: offset,
  hash: _hex(seed),
  key: _key(seed),
  bytes: 4096,
  durationMs: ms,
  peaks: Uint8List.fromList([
    for (var i = 0; i < NoteVoiceRef.peaksLength; i++) 40 + ((i * 37) % 160),
  ]),
);

NoteVideoRef _video(int offset, int seed) => NoteVideoRef(
  offset: offset,
  hash: _hex(seed),
  key: _key(seed),
  mime: 'video/mp4',
  bytes: 4096,
  width: 1280,
  height: 720,
  durationMs: 31000,
);

Note _note(
  String id,
  String body,
  DateTime at, {
  List<NoteAttachmentRef> attachments = const [],
  bool drawing = false,
}) => Note(
  id: id,
  body: body,
  attachments: attachments,
  drawing: drawing ? NoteDrawing.empty : null,
  createdAt: at,
  updatedAt: at,
);

int _at(String body, [int nth = 0]) {
  var index = -1;
  for (var i = 0; i <= nth; i++) {
    index = body.indexOf('\u{FFFC}', index + 1);
  }
  return index;
}

/// Ids of the pinned notes, the four the artboard shows first.
final riverbankPinnedIds = <String>[
  'snowseo',
  'snowanalytic',
  'todos',
  'goals',
  for (var i = 0; i < 96; i++) 'pinned-filler-$i',
];

List<Note> riverbankNotes() {
  DateTime day(int month, int date, [int hour = 9]) =>
      DateTime(2026, month, date, hour);
  const analytic = 'SnowAnalytic Design Ideas\n\u{FFFC}';
  const land = 'land\nplot = 75,60,000 inr\n\u{FFFC}';
  const car = 'car issues\nrepairs = 18,400 inr\n\u{FFFC}\u{FFFC}';
  const youtube = 'YouTube link\nyoutube.com\n\u{FFFC}';
  return [
    _note(
      'snowseo',
      _snowSeoBody,
      DateTime(2026, 11, 16, 11, 15),
      attachments: [_voice(_at(_snowSeoBody), 1)],
    ),
    _note(
      'snowanalytic',
      analytic,
      day(9, 13),
      attachments: [_image(_at(analytic), 2)],
    ),
    _note('todos', 'Todos\nRenew domain, gym', day(10, 8)),
    _note('goals', 'Goals - Oct 2026', day(9, 29), drawing: true),
    for (var i = 0; i < 96; i++)
      _note(
        'pinned-filler-$i',
        'Pinned note ${i + 1}',
        day(8, 1, 0).subtract(Duration(days: i)),
      ),
    _note('new-note', '', day(11, 14, 18)),
    _note('land', land, day(11, 14, 10), attachments: [_image(_at(land), 3)]),
    _note(
      'car',
      car,
      day(11, 2),
      attachments: [_image(_at(car), 4), _voice(_at(car, 1), 5, ms: 12000)],
    ),
    _note(
      'youtube',
      youtube,
      day(10, 31),
      attachments: [_video(_at(youtube), 6)],
    ),
    _note('bank', 'bank\nsavings = 2,94,000 inr', day(10, 23)),
    _note('sdfsa', 'sdfsa', day(10, 20), drawing: true),
    _note('reading', 'Reading list\nDeep Work, Dune', day(10, 14)),
    _note('trip', 'Trip budget\nbudget = 28,000 inr', day(10, 9)),
    _note('gym', 'Gym plan\nPush · Pull · Legs', day(10, 6)),
    _note('groceries', 'Groceries\nOats, milk, coffee', day(10, 4)),
    for (var i = 0; i < 17; i++)
      _note(
        'note-filler-$i',
        'Older note ${i + 1}',
        day(8, 20, 0).subtract(Duration(days: i)),
      ),
  ];
}

/// Loads the artboard's notes into [notes] and pins the hundred.
void seedRiverbankNotes(NotesStore notes) {
  notes.importNotes(riverbankNotes());
  for (final id in riverbankPinnedIds.reversed) {
    notes.togglePinned(id);
  }
}
