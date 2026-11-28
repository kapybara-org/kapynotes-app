import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/recaps/recap_digest.dart';
import 'package:kapy_notes/recaps/recap_lines.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_record.dart';
import 'package:kapy_notes/recaps/recap_story.dart';

/// Recaps as the boards draw them (Paper p-2-0), one of each kind, for the
/// viewer's tests, goldens and the phone's integration test.

RecapRecord _record(
  RecapKind kind,
  DateTime day, {
  required RecapCounts counts,
  required int open,
  required List<int> chart,
  int run = 0,
  List<RecapTopic> topics = const [],
  RecapCounts previous = const RecapCounts(),
}) => RecapRecord(
  period: RecapPeriod.containing(day, kind, firstWeekday: DateTime.monday),
  timeZone: 'Asia/Kolkata',
  firstWeekday: DateTime.monday,
  madeAt: DateTime(2026, 11, 27, 9),
  numbers: RecapNumbers(
    counts: counts,
    tasksOpen: open,
    chart: chart,
    longestRun: run,
    topics: topics,
    previous: previous,
  ),
  fingerprint: '0123456789abcdef',
);

/// A recording of [seconds], loud and quiet in turn.
NoteVoiceRef sampleVoice({int seconds = 260}) => NoteVoiceRef(
  offset: 0,
  hash: 'morning',
  key: Uint8List(32),
  bytes: 1,
  durationMs: seconds * 1000,
  peaks: Uint8List.fromList([
    for (var i = 0; i < 100; i++)
      (60 + 150 * (0.5 + 0.5 * math.sin(i * 0.9)) * (i < 40 ? 1 : 0.55))
          .round(),
  ]),
);

const _highlights = [
  RecapHighlight(
    noteId: 'arjun',
    title: 'Call with Arjun',
    line: 'Pricing page is due Friday, with the annual plan shown first.',
  ),
  RecapHighlight(
    noteId: 'quote',
    title: 'Quote for the deck',
    line: '40 seats at 12 comes to 480 a month.',
  ),
  RecapHighlight(
    noteId: 'morning',
    title: 'Morning pages',
    line: 'The plan for today: the deck, the room, a walk.',
  ),
];

/// Wed 19 November: six cards.
RecapStory sampleDay({RecapLines? lines}) => RecapStory(
  record: _record(
    RecapKind.day,
    DateTime(2026, 11, 19),
    counts: const RecapCounts(
      notes: 6,
      tasksDone: 4,
      voiceNotes: 1,
      voiceMinutes: 12,
    ),
    open: 2,
    chart: const [6],
    previous: const RecapCounts(notes: 4, tasksDone: 2),
  ),
  lines:
      lines ??
      const RecapLines(
        title: 'A full day, and the deck is nearly there',
        highlights: _highlights,
        quote: RecapQuote(
          noteId: 'morning',
          hash: 'morning',
          title: 'Morning pages',
          at: Duration(minutes: 1, seconds: 42),
          line:
              'If the deck is done by Thursday, Friday is just the room and '
              'a walk.',
        ),
        next: 'Tomorrow: send the deck, then the room.',
      ),
  done: const [
    'Send Arjun the pricing notes',
    'Book the meeting room',
    'Draft slide 4',
    'Call the bank',
  ],
  open: const ['Send the deck', 'Pick up the spare keys'],
  voice: sampleVoice(),
);

/// 17–23 November: four cards.
RecapStory sampleWeek() => RecapStory(
  record: _record(
    RecapKind.week,
    DateTime(2026, 11, 19),
    counts: const RecapCounts(
      notes: 30,
      tasksDone: 19,
      voiceNotes: 3,
      voiceMinutes: 48,
    ),
    open: 3,
    chart: const [3, 5, 9, 4, 6, 2, 1],
    run: 7,
    topics: const [
      (name: 'Acme pricing', notes: 9),
      (name: 'Lisbon trip', notes: 6),
      (name: 'Reading', notes: 4),
    ],
  ),
  lines: const RecapLines(
    title: 'The week the deck came together',
    highlights: [
      RecapHighlight(
        noteId: 'arjun',
        title: 'Call with Arjun',
        line: 'Annual plan first, and the invoice split over two months.',
      ),
      RecapHighlight(
        noteId: 'budget',
        title: 'Lisbon budget',
        line: 'Flights are booked; 412 EUR left for the week.',
      ),
    ],
    next: 'Ship the deck, then plan Lisbon.',
  ),
  open: const ['Send the deck', 'Book the Lisbon flat', 'Finish The Overstory'],
  colours: const {
    'acme pricing': 'mustard',
    'lisbon trip': 'slate',
    'reading': 'sage',
  },
);

/// November 2026: four cards.
RecapStory sampleMonth() => RecapStory(
  record: _record(
    RecapKind.month,
    DateTime(2026, 11, 19),
    counts: const RecapCounts(
      notes: 96,
      tasksDone: 71,
      voiceNotes: 9,
      voiceMinutes: 200,
    ),
    open: 2,
    chart: const [
      1, 2, 3, 0, 2, 3, 1, 2, 6, 3, 3, 2, 1, 0, 3, 2, 6, 7, 3, 1, 1, 2, //
      3, 2, 3, 6, 1, 1, 2, 2,
    ],
    run: 12,
    topics: const [
      (name: 'Work', notes: 38),
      (name: 'Acme', notes: 21),
      (name: 'Lisbon', notes: 12),
    ],
  ),
  lines: const RecapLines(
    title: 'A month of small, steady days',
    topics: [
      (name: 'Acme', line: 'The pricing deck went from draft to signed.'),
    ],
    next: 'Finish Acme, then a slower month.',
  ),
  open: const ['Send the deck', 'Plan the Lisbon week'],
  colours: const {'work': 'mustard', 'acme': 'rust', 'lisbon': 'slate'},
);

/// 2026: seven cards.
RecapStory sampleYear() => RecapStory(
  record: _record(
    RecapKind.year,
    DateTime(2026, 6, 1),
    counts: const RecapCounts(
      notes: 412,
      tasksDone: 1086,
      voiceNotes: 40,
      voiceMinutes: 1860,
    ),
    open: 2,
    chart: const [28, 31, 58, 36, 30, 44, 26, 22, 35, 33, 49, 24],
    run: 23,
    topics: const [
      (name: 'Work', notes: 164),
      (name: 'Acme', notes: 88),
      (name: 'Lisbon', notes: 41),
    ],
  ),
  lines: const RecapLines(
    title: 'Lisbon, Acme and a lot of mornings',
    topics: [(name: 'Lisbon', line: 'A week in June, planned since March.')],
    moments: [
      (month: 3, line: 'Signed the Acme deal'),
      (month: 6, line: 'First week in Lisbon'),
      (month: 9, line: 'Finished The Overstory'),
      (month: 11, line: 'The deck, finally'),
    ],
    line: 'Write it down first. Decide on Monday.',
    next: 'Keep the mornings. Ship more.',
  ),
  open: const ['Plan the 2027 Lisbon trip', 'Read 12 books'],
  colours: const {
    'work': 'mustard',
    'acme': 'rust',
    'lisbon': 'slate',
    'reading': 'sage',
    'health': 'plum',
  },
);
