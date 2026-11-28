import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/period_scope.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/recaps/recap_period.dart';

import '../recaps/recap_fixtures.dart';

/// Gives [noteId] the tags [names], made as needed.
void tag(RecapWorld world, String noteId, List<String> names) => world.tags
    .setTags(noteId, [for (final name in names) world.tags.create(name)!.id]);

void main() {
  final today = DateTime(2026, 11, 19, 15);
  final day = dayOf(DateTime(2026, 11, 19));
  final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
  final month = periodOf(DateTime(2026, 11, 19), RecapKind.month);
  final year = periodOf(DateTime(2026, 11, 19), RecapKind.year);

  group('the question', () {
    test('starts with a line naming the period, with its year', () {
      expect(kapyPeriodLine(day), 'About Thu 19 Nov 2026:');
      expect(kapyPeriodLine(week), 'About 16–22 Nov 2026:');
      expect(kapyPeriodLine(month), 'About November 2026:');
      expect(kapyPeriodLine(year), 'About 2026:');
      expect(
        kapyPeriodLine(periodOf(DateTime(2026, 12, 30), RecapKind.week)),
        'About 28 Dec 2026 – 3 Jan 2027:',
      );
      expect(
        kapyPeriodQuestion(week, 'What did I get done?'),
        'About 16–22 Nov 2026:\nWhat did I get done?',
      );
    });

    test('stays within the contract with the line in front', () {
      final long = kapyPeriodQuestion(
        week,
        'a' * AnswerRequest.maxQuestionChars,
      );
      expect(long.length, AnswerRequest.maxQuestionChars);
      expect(long, startsWith('About 16–22 Nov 2026:\naaa'));

      // Never through the middle of a character that takes two.
      final room =
          AnswerRequest.maxQuestionChars - kapyPeriodLine(week).length - 1;
      final emoji = kapyPeriodQuestion(week, '${'a' * (room - 1)}😀 more');
      expect(emoji.length, AnswerRequest.maxQuestionChars - 1);
      expect(emoji.codeUnitAt(emoji.length - 1), 'a'.codeUnitAt(0));
    });
  });

  test('names a period as a person would', () {
    expect(kapyPeriodName(day, today), 'today');
    expect(kapyPeriodName(day.previous, today), 'yesterday');
    expect(kapyPeriodName(day.previous.previous, today), 'Tue 17');
    expect(kapyPeriodName(week, today), 'this week');
    expect(kapyPeriodName(week.previous, today), 'last week');
    expect(kapyPeriodName(week.previous.previous, today), '2–8 Nov');
    expect(kapyPeriodName(month, today), 'this month');
    expect(kapyPeriodName(month.previous.previous, today), 'September');
    expect(kapyPeriodName(year.previous, today), 'last year');
    expect(
      kapyPeriodName(
        RecapPeriod.containing(today, RecapKind.week, firstWeekday: 7),
        today,
      ),
      'this week',
      reason: 'a week that starts on Sunday',
    );
  });

  group('what a period holds', () {
    late RecapWorld world;

    setUp(() async {
      world = RecapWorld();
      await world.tags.load();
      await world.folders.load();
    });

    KapyPeriodRead read(RecapPeriod period) =>
        KapyPeriodRead(world.material(period), world.digest(period));

    test('counts what the recap counts, and never a hidden note', () async {
      world.note('call', '2026-11-17T09:00:00Z', body: 'Call with Arjun');
      void launch(String done) => world.note(
        'launch',
        '2026-11-18T09:00:00Z',
        body:
            '${NoteAttachmentRef.placeholder}\nLaunch\n$done Write notes\n☐ Ship',
        attachments: [recapVoice()],
      );
      world.tick('2026-11-17T09:00:00Z', () => launch('☐'));
      world.tick('2026-11-18T09:00:00Z', () => launch('☑'));
      world.note('october', '2026-10-02T09:00:00Z', body: 'October plan');
      world.note(
        'bank',
        '2026-11-18T10:00:00Z',
        body: 'PIN 4321',
        hidden: true,
      );
      tag(world, 'call', ['Acme']);
      tag(world, 'launch', ['Acme']);
      await world.load();

      final it = read(week);
      expect([it.notes, it.voiceNotes], [2, 1]);
      expect(
        it.reads,
        'Answers come only from your 2 notes, 2 tasks and 1 voice note from '
        '16–22 Nov. Hidden notes are never used.',
      );
      expect(it.narrower, isNull);
      expect(it.topic, 'Acme');
      final sent = it.sent(world.store, today: today);
      expect(sent.map((note) => note.id).toSet(), {'call', 'launch', ''});
      expect(
        [for (final note in sent) '${note.title} ${note.text}'].join(),
        isNot(contains('4321')),
      );
      expect(
        sent.where((note) => note.id.isEmpty).single.text,
        allOf(contains('Write notes'), contains('Ship')),
      );
    });

    test('says only what it holds, and nothing for an empty one', () async {
      world.note('one', '2026-11-19T09:00:00Z', body: 'One');
      await world.load();
      expect(
        read(day).reads,
        'Answers come only from your 1 note from Thu 19. Hidden notes are '
        'never used.',
      );
      expect(
        read(day.previous).reads,
        'Answers come only from Wed 18. Hidden notes are never used.',
      );
      expect(read(day).topic, isNull);
    });

    test('one of each is said in the singular', () async {
      world.note(
        'launch',
        '2026-11-19T09:00:00Z',
        body: '${NoteAttachmentRef.placeholder}\nLaunch\n☐ Ship',
        attachments: [recapVoice()],
      );
      await world.load();
      expect(
        read(day).reads,
        'Answers come only from your 1 note, 1 task and 1 voice note from '
        'Thu 19. Hidden notes are never used.',
      );
    });

    test('a long period says a narrower question does better', () async {
      for (var i = 0; i < 31; i++) {
        world.note(
          'n$i',
          '2026-11-${(i % 28 + 1).toString().padLeft(2, '0')}'
              'T09:00:00Z',
          body: 'Note $i',
        );
      }
      await world.load();
      expect(
        read(month).narrower,
        'November has 31 notes. Each answer reads the 12 that fit the '
        'question best, so a narrower question gets a fuller answer.',
      );
    });

    test('a topic reaches the screen as plain words alone', () async {
      world.note('a', '2026-11-19T09:00:00Z', body: 'A');
      tag(world, 'a', ['\u202eAcme\u202c\u200b plan']);
      await world.load();
      final topic = read(day).topic!;
      expect(topic, isNot(contains('\u202e')));
      expect(topic, startsWith('Acme'));
      expect(topic.length, lessThanOrEqualTo(40));
    });

    test('suggests two questions for any period, and one from its topic', () {
      expect(kapyPeriodSuggestions(week, today: today), [
        'What did I get done this week?',
        'What’s still open from this week?',
      ]);
      expect(kapyPeriodSuggestions(day.previous.previous, today: today), [
        'What did I get done on Tue 17?',
        'What’s still open from Tue 17?',
      ]);
      expect(kapyPeriodSuggestions(month.previous.previous, today: today), [
        'What did I get done in September?',
        'What’s still open from September?',
      ]);
    });

    test('the third question is about the main topic', () async {
      world.note('a', '2026-11-19T09:00:00Z', body: 'A');
      tag(world, 'a', ['Acme']);
      await world.load();
      expect(
        kapyPeriodSuggestions(week, today: today, read: read(week)).last,
        'What did I decide about Acme?',
      );
    });
  });

  group('as a chat keeps it', () {
    test('goes and comes back the same', () {
      for (final period in [day, week, month, year]) {
        expect(RecapPeriod.fromJson(period.toJson()), period);
      }
      expect(week.toJson(), {
        'kind': 'week',
        'first': '2026-11-16',
        'last': '2026-11-22',
      });
    });

    test('anything else is no period', () {
      for (final raw in <Object?>[
        null,
        'week',
        {'kind': 'fortnight', 'first': '2026-11-16', 'last': '2026-11-29'},
        {'kind': 'week', 'first': '2026-11-16', 'last': '2026-11-23'},
        {'kind': 'month', 'first': '2026-11-02', 'last': '2026-11-30'},
        {'kind': 'day', 'first': '2026-02-30', 'last': '2026-02-30'},
        {'kind': 'day', 'first': '2026-2-3', 'last': '2026-2-3'},
        {'kind': 'day', 'first': 20261116, 'last': 20261116},
        {'kind': 'day', 'first': '2026-11-16'},
      ]) {
        expect(RecapPeriod.fromJson(raw), isNull, reason: '$raw');
      }
    });
  });
}
