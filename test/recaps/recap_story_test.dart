import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/recaps/recap_filter.dart';
import 'package:kapy_notes/recaps/recap_lines.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_record.dart';
import 'package:kapy_notes/recaps/recap_story.dart';

import '../ai/ai_fakes.dart';
import 'recap_fixtures.dart';
import 'recap_story_samples.dart';

void main() {
  final thursday = dayOf(DateTime(2026, 11, 19));
  final made = DateTime(2026, 11, 20, 9);
  late RecapWorld world;

  void write({Set<String> hidden = const {}}) {
    world.note(
      'trip',
      '2026-11-19T08:00:00Z',
      body: 'Trip\n☑ Book\n☐ Pay',
      hidden: hidden.contains('trip'),
    );
    world.note(
      'standup',
      '2026-11-19T10:00:00Z',
      body: '${NoteAttachmentRef.placeholder}\nStandup',
      attachments: [recapVoice()],
      hidden: hidden.contains('standup'),
    );
    world.note(
      'plan',
      '2026-11-19T11:00:00Z',
      body: 'Plan\nThe deck, the room, a walk',
      hidden: hidden.contains('plan'),
    );
  }

  setUp(() async {
    world = RecapWorld();
    world.tick('2026-11-18T08:00:00Z', () {
      world.note('trip', '2026-11-19T08:00:00Z', body: 'Trip\n☐ Book\n☐ Pay');
    });
    world.tick('2026-11-19T12:00:00Z', write);
    await world.load();
  });

  KapyChat recap() {
    final material = world.material(thursday);
    return recapChat(
      null,
      record: RecapRecord(
        period: thursday,
        timeZone: 'UTC',
        firstWeekday: DateTime.monday,
        madeAt: made,
        numbers: RecapNumbers.of(world.digest(thursday), material),
        fingerprint: material.fingerprint,
      ),
      answer: [
        'TITLE: A full day',
        'HIGHLIGHT: Trip | Booked, one left to pay',
        'HIGHLIGHT: Plan | The plan for today',
        'QUOTE: Pricing call | 0:10 | We ship the annual plan first.',
        'NEXT: Pay for the trip',
      ].join('\n'),
      model: KapyModel.cloud,
      now: made,
    );
  }

  Future<RecapStory> reopen(
    KapyChat chat, {
    Set<String> hidden = const {},
  }) async {
    write(hidden: hidden);
    await world.load();
    return RecapStory.read(chat, world.material(thursday))!;
  }

  group('opening a recap again', () {
    test('reads its newest answer against what the day holds now', () async {
      final story = await reopen(recap());
      expect(story.name, 'Recap · Thu 19');
      expect(story.title, 'A full day');
      expect(story.lines.highlights.map((it) => it.noteId), ['trip', 'plan']);
      expect(story.lines.quote?.at, const Duration(seconds: 10));
      expect(story.voice?.hash, 'call');
      expect(story.done, ['Book']);
      expect(story.open, ['Pay']);
      expect(story.cards, [
        RecapCard.cover,
        RecapCard.numbers,
        RecapCard.highlights,
        RecapCard.tasks,
        RecapCard.voice,
        RecapCard.closing,
      ]);
    });

    test('drops a highlight of a note hidden since, and its tasks', () async {
      final story = await reopen(recap(), hidden: {'trip'});
      expect(story.lines.highlights.map((it) => it.noteId), ['plan']);
      expect(story.done, isEmpty);
      expect(story.open, isEmpty);
      expect(story.cards, isNot(contains(RecapCard.tasks)));
      expect(story.numbers.counts.tasksDone, 1, reason: 'numbers stay as made');
    });

    test('drops every line of Kapy AI’s naming a note hidden since', () async {
      final story = await reopen(recap(), hidden: {'trip'});
      expect(story.lines.next, isNull, reason: 'NEXT: Pay for the trip');
      expect(story.note.body.toLowerCase(), isNot(contains('trip')));
    });

    test('drops every line naming a title the app says is gone', () async {
      world.tick('2026-11-20T09:00:00Z', () {});
      final chat = recapChat(
        null,
        record: recapOf(recap())!,
        answer: [
          'TITLE: After the secret plan',
          'HIGHLIGHT: Plan | The plan for today',
          'TOPIC: Work | The secret plan, and leaving in June',
          'NEXT: Tell Bob about the Secret plan',
        ].join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
      final story = RecapStory.read(
        chat,
        world.material(thursday),
        gone: {'Secret plan'},
      )!;
      expect(story.title, 'Your day');
      expect(story.lines.topics, isEmpty);
      expect(story.lines.next, isNull);
      expect(story.lines.highlights.map((it) => it.noteId), ['plan']);
      expect(story.note.body.toLowerCase(), isNot(contains('secret')));
    });

    test(
      'drops the quote of a voice note hidden since, and its card',
      () async {
        final story = await reopen(recap(), hidden: {'standup'});
        expect(story.lines.quote, isNull);
        expect(story.voice, isNull);
        expect(story.cards, isNot(contains(RecapCard.voice)));
      },
    );

    test('drops a highlight of a note deleted since', () async {
      final chat = recap();
      world.notes.removeWhere((note) => note.id == 'plan');
      await world.load();
      final story = RecapStory.read(chat, world.material(thursday))!;
      expect(story.lines.highlights.map((it) => it.noteId), ['trip']);
    });

    test(
      'with nothing left to show, leaves out the cards, never empty',
      () async {
        final story = await reopen(
          recap(),
          hidden: {'trip', 'standup', 'plan'},
        );
        expect(story.cards, [
          RecapCard.cover,
          RecapCard.numbers,
          RecapCard.closing,
        ]);
        expect(story.title, 'A full day');
      },
    );

    test('reads nothing from a chat that is not a recap of the period', () {
      final chat = recap();
      final friday = dayOf(DateTime(2026, 11, 20));
      expect(RecapStory.read(chat, world.material(friday)), isNull);
      final plain = KapyChat(
        id: 'c',
        title: 'Chat',
        createdAt: made,
        updatedAt: made,
        model: KapyModel.cloud,
        messages: const [],
      );
      expect(RecapStory.read(plain, world.material(thursday)), isNull);
    });
  });

  group('a note gone since the recap was made', () {
    final since = DateTime.utc(2026, 11, 25).toIso8601String();
    final before = DateTime.utc(2026, 11, 19, 13).toIso8601String();
    const answer = [
      'TITLE: A full day',
      'HIGHLIGHT: Trip | Booked, one left to pay',
      'QUOTE: Pricing call | 0:10 | We ship the annual plan first.',
      'NEXT: Pay for it before Friday',
    ];

    /// The day's recap, its one part having read every note of the day.
    KapyChat parted() {
      final material = world.material(thursday);
      final record = recapOf(recap())!;
      return recapChat(
        null,
        record: RecapRecord(
          period: record.period,
          timeZone: record.timeZone,
          firstWeekday: record.firstWeekday,
          madeAt: record.madeAt,
          numbers: record.numbers,
          fingerprint: record.fingerprint,
          read: [
            (
              first: 0,
              last: 0,
              notes: RecapFilter.of([
                for (final item in material.items) item.note.id,
              ]),
            ),
          ],
        ),
        answer: answer.join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
    }

    Future<RecapStory> reopenWith(
      KapyChat chat, {
      String? hiddenAt,
      String? archivedAt,
    }) async {
      world.note(
        'trip',
        '2026-11-19T08:00:00Z',
        body: 'Trip\n☑ Book\n☐ Pay',
        hiddenAt: hiddenAt,
        archivedAt: archivedAt,
      );
      await world.load();
      return RecapStory.read(chat, world.material(thursday))!;
    }

    void expectAllLeftOut(RecapStory story) {
      expect(story.lines.next, isNull, reason: 'Pay for it before Friday');
      expect(story.lines.title, isNull);
      expect(story.lines.highlights, isEmpty);
      expect(story.lines.quote, isNull, reason: 'the part read the trip too');
      expect(story.wordsGone, isTrue);
      expect(story.note.body.toLowerCase(), isNot(contains('friday')));
    }

    test('drops a line telling of it without naming it', () async {
      expectAllLeftOut(await reopenWith(parted(), hiddenAt: since));
    });

    test('a note hidden before the recap was made drops nothing', () async {
      final story = await reopenWith(parted(), hiddenAt: before);
      expect(story.lines.next, 'Pay for it before Friday');
      expect(story.lines.title, 'A full day');
      expect(story.lines.quote, isNotNull);
      expect(story.wordsGone, isFalse);
    });

    test('a note archived since drops nothing more', () async {
      final story = await reopenWith(parted(), archivedAt: since);
      expect(story.lines.next, 'Pay for it before Friday');
      expect(story.lines.title, 'A full day');
      expect(story.lines.quote, isNotNull);
      expect(story.wordsGone, isFalse);
    });

    test('a deleted note and one held for deleting act like a hide', () async {
      final chat = parted();
      final local = MemoryStore()
        ..data['notes.v1'] = [for (final note in world.notes) note.toJson()];
      world.store = NotesStore(local, now: () => DateTime.utc(2026, 11, 25));
      await world.store.load();
      world.store.delete('trip');
      expectAllLeftOut(RecapStory.read(chat, world.material(thursday))!);

      await world.load();
      world.store.holdDelete(['trip']);
      expectAllLeftOut(RecapStory.read(chat, world.material(thursday))!);
    });

    test('a record with no parts treats every part as affected', () async {
      final chat = recapChat(
        null,
        record: recapOf(recap())!,
        answer: answer.join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
      expect((await reopenWith(chat)).lines.next, 'Pay for it before Friday');
      expectAllLeftOut(await reopenWith(chat, hiddenAt: since));
    });

    test('in a week, only the part that read it loses its words', () async {
      final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
      world = RecapWorld();
      world.note('deck', '2026-11-16T10:00:00Z', body: 'Deck\nDrafted');
      world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday\nOff early');
      await world.load();
      final material = world.material(week);
      RecapFilter read(DateTime first, DateTime last) => RecapFilter.of([
        for (final item in material.within(first, last)) item.note.id,
      ]);
      final chat = recapChat(
        null,
        record: RecapRecord(
          period: week,
          timeZone: 'UTC',
          firstWeekday: DateTime.monday,
          madeAt: made,
          numbers: RecapNumbers.of(world.digest(week), material),
          fingerprint: material.fingerprint,
          read: [
            (
              first: 0,
              last: 3,
              notes: read(week.first, DateTime(2026, 11, 19)),
            ),
            (first: 4, last: 6, notes: read(DateTime(2026, 11, 20), week.last)),
          ],
        ),
        answer: [
          'TITLE: Drafts and a day off',
          'HIGHLIGHT: Deck | Drafted on Monday',
          'TOPIC: Work | Quiet by the end',
          'NEXT: Take it easy again',
        ].join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
      world.note(
        'fri',
        '2026-11-20T10:00:00Z',
        body: 'Friday\nOff early',
        hiddenAt: since,
      );
      await world.load();
      final story = RecapStory.read(chat, world.material(week))!;
      expect(story.lines.title, isNull);
      expect(story.lines.topics, isEmpty);
      expect(story.lines.next, isNull);
      expect(story.lines.highlights.map((it) => it.noteId), ['deck']);
      expect(story.wordsGone, isFalse);
    });

    test('in a year, only the months of the part that read it', () async {
      final year = periodOf(DateTime(2026, 11, 19), RecapKind.year);
      world = RecapWorld();
      world.note('lisbon', '2026-03-10T10:00:00Z', body: 'Lisbon\nFlights');
      world.note('garden', '2026-06-05T10:00:00Z', body: 'Garden\nSeeds');
      world.note('pool', '2026-06-20T10:00:00Z', body: 'Pool\nOpen');
      await world.load();
      final material = world.material(year);
      RecapRead month(int m) => (
        first: year.indexOf(DateTime(2026, m))!,
        last: year.indexOf(DateTime(2026, m + 1, 0))!,
        notes: RecapFilter.of([
          for (final item in material.within(
            DateTime(2026, m),
            DateTime(2026, m + 1, 0),
          ))
            item.note.id,
        ]),
      );
      final chat = recapChat(
        null,
        record: RecapRecord(
          period: year,
          timeZone: 'UTC',
          firstWeekday: DateTime.monday,
          madeAt: made,
          numbers: RecapNumbers.of(world.digest(year), material),
          fingerprint: material.fingerprint,
          read: [month(3), month(6)],
        ),
        answer: [
          'TITLE: Trips and a garden',
          'MOMENT: March | Lisbon, booked at last',
          'MOMENT: June | Seeds in, and the pool open',
          'LINE: Small steps',
        ].join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
      world.note(
        'garden',
        '2026-06-05T10:00:00Z',
        body: 'Garden\nSeeds',
        hiddenAt: since,
      );
      await world.load();
      final story = RecapStory.read(chat, world.material(year))!;
      expect(story.lines.moments.map((it) => it.month), [3]);
      expect(story.lines.line, isNull);
      expect(story.lines.title, isNull);
      expect(story.wordsGone, isFalse);
    });
  });

  group('as a note', () {
    test(
      'holds the words and names the notes, never one hidden since',
      () async {
        final story = await reopen(recap(), hidden: {'plan'});
        final note = story.note;
        expect(note.names, ['trip', 'standup']);
        expect(note.body, contains('- Trip: Booked, one left to pay'));
        expect(note.body, isNot(contains('Plan')));
        expect(note.body.split('\n').take(3), [
          'Recap · Thu 19',
          'A full day',
          '3 notes · 1 task done · 1 minute recorded',
        ]);
        expect(note.body, contains('“We ship the annual plan first.”'));
      },
    );

    test('starts no line of Kapy AI’s with what a note would format', () {
      final story = sampleDay(
        lines: const RecapLines(
          title: '# - [ ] **Big** [link](https://example.com)',
          next: '> 1. Done',
          topics: [(name: '## Work', line: '| a | b |')],
        ),
      );
      final lines = story.note.body.split('\n');
      expect(lines[1], '**Big** [link](https://example.com)');
      expect(story.note.body, contains('- Work: a | b |'));
      expect(lines.last, '- Done');
      for (final line in lines) {
        expect(line, isNot(matches(RegExp(r'^(#|>|\||\d+[.)]|\[)'))));
      }
    });
  });

  test('topics: the counted ones first, each with Kapy AI’s line', () {
    final story = sampleMonth();
    expect(story.topics, [
      (name: 'Work', notes: 38, line: null),
      (
        name: 'Acme',
        notes: 21,
        line: 'The pricing deck went from draft to signed.',
      ),
      (name: 'Lisbon', notes: 12, line: null),
    ]);
    final year = sampleYear();
    expect(year.topics.last.line, 'A week in June, planned since March.');
  });

  test('a topic only Kapy AI named comes after, with no count', () {
    final story = RecapStory(
      record: sampleWeek().record,
      lines: const RecapLines(topics: [(name: 'Garden', line: 'Seeds in')]),
    );
    expect(story.topics.last, (name: 'Garden', notes: null, line: 'Seeds in'));
  });

  test('the busiest day and the longest run come from the numbers', () {
    final month = sampleMonth();
    expect(month.day(month.busiest!), DateTime(2026, 11, 18));
    expect(month.run, (DateTime(2026, 11, 15), DateTime(2026, 11, 26)));
    expect(sampleWeek().day(sampleWeek().busiest!), DateTime(2026, 11, 18));
    expect(sampleYear().run, isNull);
  });

  test('the day set beside the day before', () {
    expect(sampleDay().comparison, '2 more notes than Wed 18.');
  });

  test('durations and figures', () {
    expect(recapDuration(1), '1 minute');
    expect(recapDuration(12), '12 minutes');
    expect(recapDuration(60), '1 hour');
    expect(recapDuration(200), '3 h 20');
    expect(recapFigures(1086), '1,086');
    expect(recapFigures(1234567), '1,234,567');
  });

  test('shown text has no control or direction characters', () {
    expect(recapShown('a\u202eb\u0000c \n\t d\u2066'), 'a b c d');
  });

  test('the closing card names what comes next', () {
    expect(sampleDay().closingLabel, 'What’s next');
    expect(sampleWeek().closingLabel, 'Next week');
    expect(sampleMonth().closingLabel, 'December');
    expect(sampleYear().closingLabel, 'Into 2027');
    expect(
      RecapStory(record: sampleYear().record, lines: const RecapLines()).cards,
      [
        RecapCard.cover,
        RecapCard.numbers,
        RecapCard.months,
        RecapCard.topics,
        RecapCard.closing,
      ],
    );
    expect(sampleWeek().period.kind, RecapKind.week);
  });
}
