import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/recaps/recap_lines.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_record.dart';
import 'package:kapy_notes/recaps/recap_story.dart';

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
      expect(story.name, 'Thu 19 recap');
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
          'Thu 19 recap',
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
