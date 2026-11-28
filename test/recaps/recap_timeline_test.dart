import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/time_zones.dart';
import 'package:kapy_notes/recaps/recap_digest.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_record.dart';
import 'package:kapy_notes/recaps/recap_timeline.dart';

import 'recap_fixtures.dart';

String _iso(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// The rows as lines: a day with its notes, a card folded (+) or open (-),
/// and a section heading, each indented by its depth.
List<String> _lay(List<RecapRow> rows) => [
  for (final row in rows)
    switch (row) {
      RecapDayRow() =>
        '${'  ' * row.depth}day ${_iso(row.period.first)} '
            '${row.notes.map((note) => note.id).join(',')}',
      RecapGroupRow() =>
        '${'  ' * row.depth}${row.open ? '-' : '+'} '
            '${row.period.kind.name} ${_iso(row.period.first)}',
      RecapSectionRow(:final period) =>
        period == null
            ? 'earlier years'
            : 'earlier ${period.kind.name} ${_iso(period.first)}',
    },
];

RecapPeriod _of(int year, int month, int day, RecapKind kind) =>
    RecapPeriod.containing(
      DateTime(year, month, day),
      kind,
      firstWeekday: DateTime.monday,
    );

void main() {
  late RecapWorld world;
  late Map<String, DateTime> ownDays;
  var zone = 'Asia/Kolkata';

  setUp(() {
    world = RecapWorld();
    ownDays = {};
    zone = 'Asia/Kolkata';
  });

  DateTime displayTime(DateTime instant) => AppTimeZones.convert(instant, zone);

  TaskBoard board([List<Note>? notes]) => TaskBoard.read(
    entries: world.index.entries,
    notes: notes ?? world.notes,
    docOf: (id) => world.docs[id],
  );

  RecapTimeline timeline(
    String now, {
    List<Note>? notes,
    int firstWeekday = DateTime.monday,
    List<KapyChat> chats = const [],
    RecapProgress? Function(RecapPeriod period)? making,
  }) => RecapTimeline(
    notes: notes ?? world.notes,
    tasks: board(notes),
    displayTime: displayTime,
    firstWeekday: firstWeekday,
    now: DateTime.parse(now),
    ownDay: (note) => ownDays[note.id],
    chats: chats,
    making: making,
  );

  void openAll(RecapTimeline timeline, RecapFolds folds) {
    while (true) {
      final shut = [
        for (final row in timeline.rows(folds))
          if (row is RecapGroupRow && !row.open) row.period,
      ];
      if (shut.isEmpty) return;
      folds.open(shut);
    }
  }

  RecapCounts counted(RecapPeriod period, [List<Note>? notes]) =>
      RecapCounts.of(
        period,
        notes: notes ?? world.notes,
        tasks: board(notes),
        displayTime: displayTime,
        ownDay: (note) => ownDays[note.id],
      );

  const now = '2026-11-19T06:00:00Z';

  group('the layout', () {
    setUp(() {
      world
        ..note('today', '2026-11-19T05:00:00Z')
        ..note('tue', '2026-11-17T06:00:00Z')
        ..note('late', '2026-11-15T18:45:00Z')
        ..note('nov12', '2026-11-12T06:00:00Z')
        ..note('nov3', '2026-11-03T06:00:00Z')
        ..note('oct28', '2026-10-28T06:00:00Z')
        ..note('oct10', '2026-10-10T06:00:00Z')
        ..note('sep1', '2026-09-01T06:00:00Z')
        ..note('dec30', '2025-12-30T06:00:00Z')
        ..note('jun1', '2025-06-01T06:00:00Z')
        ..note('mar3', '2024-03-03T06:00:00Z')
        ..note('secret', '2026-11-18T06:00:00Z', hidden: true)
        ..note(
          'gone',
          '2026-11-18T07:00:00Z',
          archivedAt: '2026-11-18T08:00:00Z',
        )
        ..note('old secret', '2023-05-05T06:00:00Z', hidden: true);
    });

    test('goes day by day this week, then folds earlier weeks, months and '
        'years', () {
      expect(_lay(timeline(now).rows(RecapFolds())), [
        'day 2026-11-19 today',
        'day 2026-11-17 tue',
        'day 2026-11-16 late',
        'earlier month 2026-11-01',
        '+ week 2026-11-09',
        '+ week 2026-11-02',
        '+ week 2026-10-26',
        'earlier year 2026-01-01',
        '+ month 2026-10-01',
        '+ month 2026-09-01',
        '+ month 2026-01-01',
        'earlier years',
        '+ year 2025-01-01',
        '+ year 2024-01-01',
      ]);
    });

    test('each card carries its whole period\'s counts and its line', () {
      final rows = timeline(now).rows(RecapFolds());
      final october = rows.whereType<RecapGroupRow>().firstWhere(
        (row) => row.period == _of(2026, 10, 1, RecapKind.month),
      );
      expect(october.counts, const RecapCounts(notes: 2));
      expect(october.counts.line, '2 notes');
      final year = rows.whereType<RecapSectionRow>().firstWhere(
        (row) => row.period?.kind == RecapKind.year,
      );
      expect(year.period, _of(2026, 1, 1, RecapKind.year));
      expect(year.counts, const RecapCounts(notes: 8));
      expect(rows.whereType<RecapSectionRow>().last.counts, isNull);
      expect(rows.whereType<RecapSectionRow>().last.state, isNull);
    });

    test('opens a card in place, a level at a time, and folds it again', () {
      final folds = RecapFolds();
      final made = timeline(now);
      folds
        ..toggle(_of(2026, 11, 9, RecapKind.week))
        ..toggle(_of(2025, 1, 1, RecapKind.year))
        ..toggle(_of(2025, 6, 1, RecapKind.month))
        ..toggle(_of(2025, 6, 1, RecapKind.week));
      expect(_lay(made.rows(folds)), [
        'day 2026-11-19 today',
        'day 2026-11-17 tue',
        'day 2026-11-16 late',
        'earlier month 2026-11-01',
        '- week 2026-11-09',
        '  day 2026-11-12 nov12',
        '+ week 2026-11-02',
        '+ week 2026-10-26',
        'earlier year 2026-01-01',
        '+ month 2026-10-01',
        '+ month 2026-09-01',
        '+ month 2026-01-01',
        'earlier years',
        '- year 2025-01-01',
        '  + month 2025-12-01',
        '  - month 2025-06-01',
        '    - week 2025-05-26',
        '      day 2025-06-01 jun1',
        '+ year 2024-01-01',
      ]);
      folds.toggle(_of(2025, 1, 1, RecapKind.year));
      final folded = _lay(made.rows(folds));
      expect(folded, contains('+ year 2025-01-01'));
      expect(folded, isNot(contains('  - month 2025-06-01')));
      folds.toggle(_of(2025, 1, 1, RecapKind.year));
      expect(_lay(made.rows(folds)), contains('      day 2025-06-01 jun1'));
    });

    test('names the cards that fold a note away, outermost first', () {
      final made = timeline(now);
      expect(made.holding('jun1'), [
        _of(2025, 1, 1, RecapKind.year),
        _of(2025, 6, 1, RecapKind.month),
        _of(2025, 5, 26, RecapKind.week),
      ]);
      expect(made.holding('dec30'), [
        _of(2026, 1, 1, RecapKind.month),
        _of(2025, 12, 29, RecapKind.week),
      ]);
      expect(made.holding('oct28'), [_of(2026, 10, 26, RecapKind.week)]);
      expect(made.holding('nov12'), [_of(2026, 11, 9, RecapKind.week)]);
      expect(made.holding('today'), isEmpty);
      expect(made.holding('late'), isEmpty);
      expect(made.holding('secret'), isEmpty);
      expect(made.holding('gone'), isEmpty);
      expect(made.holding('nobody'), isEmpty);
    });

    test('reveals a folded note by opening every card around it', () {
      final made = timeline(now);
      final folds = RecapFolds();
      var heard = 0;
      folds.addListener(() => heard++);
      folds.open(made.holding('dec30'));
      expect(heard, 1);
      expect(
        _lay(made.rows(folds)),
        containsAllInOrder([
          '- month 2026-01-01',
          '  - week 2025-12-29',
          '    day 2025-12-30 dec30',
        ]),
      );
      folds.open(made.holding('dec30'));
      folds.open(made.holding('today'));
      expect(heard, 1);
      folds.toggle(_of(2026, 1, 1, RecapKind.month));
      expect(heard, 2);
      expect(folds.isOpen(_of(2026, 1, 1, RecapKind.month)), isFalse);
    });

    test('every row counts what RecapCounts.of counts', () {
      world
        ..note('voice', '2026-11-11T06:00:00Z', attachments: [recapVoice()])
        ..note(
          'long voice',
          '2026-11-11T07:00:00Z',
          attachments: [recapVoice(hash: 'b', segments: 7)],
        )
        ..note('trip', '2026-10-05T06:00:00Z', body: 'Trip\n☐ Book\n☐ Pay');
      world.tick('2026-11-10T06:00:00Z', () {
        world.note('trip', '2026-10-05T06:00:00Z', body: 'Trip\n☑ Book\n☐ Pay');
      });
      ownDays['jun1'] = DateTime(2025, 7, 9);
      final made = timeline(now);
      final folds = RecapFolds();
      openAll(made, folds);
      final rows = made.rows(folds);
      expect(rows.length, greaterThan(20));
      for (final row in rows) {
        final (period, counts) = switch (row) {
          RecapDayRow() => (row.period, row.counts),
          RecapGroupRow() => (row.period, row.counts),
          RecapSectionRow() => (row.period, row.counts),
        };
        if (period == null) continue;
        expect(counts, counted(period), reason: '$period');
        expect(made.countsOf(period), counts);
      }
      expect(
        made.countsOf(_of(2026, 11, 9, RecapKind.week)),
        const RecapCounts(
          notes: 3,
          tasksDone: 1,
          voiceNotes: 2,
          voiceMinutes: 3,
        ),
      );
      expect(_lay(rows), contains('      day 2025-07-09 jun1'));
    });
  });

  group('time zones', () {
    test('puts a note on the day it was in the person\'s own time', () {
      world
        ..note('late', '2026-11-15T18:45:00Z')
        ..note('today', '2026-11-19T05:00:00Z');
      expect(_lay(timeline(now).rows(RecapFolds())), [
        'day 2026-11-19 today',
        'day 2026-11-16 late',
      ]);
      zone = 'UTC';
      expect(_lay(timeline(now).rows(RecapFolds())), [
        'day 2026-11-19 today',
        'earlier month 2026-11-01',
        '+ week 2026-11-09',
      ]);
      zone = 'America/Los_Angeles';
      expect(_lay(timeline('2026-11-19T06:00:00Z').rows(RecapFolds())), [
        'day 2026-11-18 today',
        'earlier month 2026-11-01',
        '+ week 2026-11-09',
      ]);
    });

    test('keeps a day whole when the clocks go back', () {
      zone = 'America/New_York';
      world
        ..note('a', '2026-11-01T04:30:00Z')
        ..note('b', '2026-11-01T05:30:00Z')
        ..note('c', '2026-11-01T06:30:00Z')
        ..note('d', '2026-11-02T04:30:00Z')
        ..note('e', '2026-11-02T05:30:00Z');
      final made = timeline('2026-11-05T17:00:00Z');
      final folds = RecapFolds()..open([_of(2026, 10, 26, RecapKind.week)]);
      expect(_lay(made.rows(folds)), [
        'day 2026-11-02 e',
        'earlier month 2026-11-01',
        '- week 2026-10-26',
        '  day 2026-11-01 a,b,c,d',
      ]);
      expect(made.countsOf(_of(2026, 11, 1, RecapKind.day)).notes, 4);
    });

    test('measures how much of today has passed by the clock on the wall', () {
      zone = 'America/New_York';
      final made = timeline('2026-03-08T16:00:00Z');
      final today = _of(2026, 3, 8, RecapKind.day);
      expect(made.today, DateTime(2026, 3, 8));
      expect(made.stateOf(today).stage, RecapStage.going);
      expect(made.stateOf(today).passed, closeTo(0.5, 1e-9));
    });

    test('starts weeks on the day the person\'s weeks start', () {
      world
        ..note('sun', '2026-11-15T06:00:00Z')
        ..note('today', '2026-11-19T05:00:00Z');
      expect(
        _lay(timeline(now, firstWeekday: DateTime.sunday).rows(RecapFolds())),
        ['day 2026-11-19 today', 'day 2026-11-15 sun'],
      );
      expect(_lay(timeline(now).rows(RecapFolds())), [
        'day 2026-11-19 today',
        'earlier month 2026-11-01',
        '+ week 2026-11-09',
      ]);
    });
  });

  group('period edges', () {
    test('puts a week that spans two months under the month it ends in', () {
      world
        ..note('sep29', '2026-09-29T06:00:00Z')
        ..note('oct2', '2026-10-02T06:00:00Z');
      final made = timeline(now);
      final folds = RecapFolds()
        ..open([
          _of(2026, 10, 1, RecapKind.month),
          _of(2026, 9, 1, RecapKind.month),
          _of(2026, 9, 28, RecapKind.week),
        ]);
      expect(_lay(made.rows(folds)), [
        'earlier year 2026-01-01',
        '- month 2026-10-01',
        '  - week 2026-09-28',
        '    day 2026-10-02 oct2',
        '    day 2026-09-29 sep29',
        '- month 2026-09-01',
      ]);
      expect(made.countsOf(_of(2026, 9, 1, RecapKind.month)).notes, 1);
      expect(made.countsOf(_of(2026, 9, 28, RecapKind.week)).notes, 2);
      expect(made.holding('sep29'), [
        _of(2026, 10, 1, RecapKind.month),
        _of(2026, 9, 28, RecapKind.week),
      ]);
    });

    test('crosses the new year day by day, and folds the old year whole', () {
      world
        ..note('nyd', '2026-01-01T06:00:00Z')
        ..note('eve', '2025-12-31T06:00:00Z')
        ..note('mon', '2025-12-29T06:00:00Z')
        ..note('dec20', '2025-12-20T06:00:00Z')
        ..note('y24', '2024-12-31T06:00:00Z');
      final made = timeline('2026-01-02T06:00:00Z');
      final folds = RecapFolds()
        ..open([
          _of(2025, 1, 1, RecapKind.year),
          _of(2025, 12, 1, RecapKind.month),
          _of(2025, 1, 1, RecapKind.month),
        ]);
      expect(_lay(made.rows(folds)), [
        'day 2026-01-01 nyd',
        'day 2025-12-31 eve',
        'day 2025-12-29 mon',
        'earlier years',
        '- year 2025-01-01',
        '  - month 2025-12-01',
        '    + week 2025-12-15',
        '  - month 2025-01-01',
        '    + week 2024-12-30',
        '+ year 2024-01-01',
      ]);
      expect(made.countsOf(_of(2025, 1, 1, RecapKind.year)).notes, 3);
      expect(made.holding('y24'), [
        _of(2025, 1, 1, RecapKind.year),
        _of(2025, 1, 1, RecapKind.month),
        _of(2024, 12, 30, RecapKind.week),
      ]);
      expect(made.holding('eve'), isEmpty);
    });

    test('heads January\'s earlier weeks with the year alone', () {
      world
        ..note('wed', '2027-01-06T06:00:00Z')
        ..note('sat', '2027-01-02T06:00:00Z')
        ..note('dec29', '2026-12-29T06:00:00Z');
      final made = timeline('2027-01-06T06:00:00Z');
      expect(_lay(made.rows(RecapFolds())), [
        'day 2027-01-06 wed',
        'earlier year 2027-01-01',
        '+ week 2026-12-28',
        'earlier years',
        '+ year 2026-01-01',
      ]);
      expect(made.holding('dec29'), [_of(2026, 12, 28, RecapKind.week)]);
    });

    test('gives the periods still going no row at the top', () {
      world
        ..note('nyd', '2029-01-01T06:00:00Z')
        ..note('old', '2028-12-20T06:00:00Z');
      expect(_lay(timeline('2029-01-01T06:00:00Z').rows(RecapFolds())), [
        'day 2029-01-01 nyd',
        'earlier years',
        '+ year 2028-01-01',
      ]);
    });

    test('gives an empty period no row, and a heading with nothing under '
        'it none', () {
      expect(timeline(now).rows(RecapFolds()), isEmpty);
      world.note('trip', '2026-11-17T06:00:00Z', body: 'Trip\n☐ Book');
      world.tick('2026-11-11T06:00:00Z', () {
        world.note('trip', '2026-11-17T06:00:00Z', body: 'Trip\n☑ Book');
      });
      world.note('may', '2026-05-12T06:00:00Z');
      final made = timeline(now);
      expect(_lay(made.rows(RecapFolds())), [
        'day 2026-11-17 trip',
        'earlier year 2026-01-01',
        '+ month 2026-05-01',
      ]);
      expect(
        made.countsOf(_of(2026, 11, 9, RecapKind.week)),
        const RecapCounts(tasksDone: 1),
      );
    });
  });

  group('notes that never count', () {
    test(
      'leaves out hidden, archived and deleted notes and what they hold',
      () {
        world
          ..note('kept', '2026-11-03T06:00:00Z')
          ..note('trash', '2026-11-03T07:00:00Z', attachments: [recapVoice()])
          ..note('secret', '2026-11-04T06:00:00Z', body: 'Bank\n☐ PIN')
          ..note('shelved', '2026-10-04T06:00:00Z', body: 'Old\n☐ Box');
        world.tick('2026-11-05T06:00:00Z', () {
          world
            ..note(
              'secret',
              '2026-11-04T06:00:00Z',
              body: 'Bank\n☑ PIN',
              attachments: [recapVoice(hash: 'secret')],
              hidden: true,
            )
            ..note(
              'shelved',
              '2026-10-04T06:00:00Z',
              body: 'Old\n☑ Box',
              archivedAt: '2026-11-05T06:00:00Z',
            );
        });
        return world.load().then((store) {
          store.holdDelete(['trash']);
          final active = store.notes;
          expect(active.map((note) => note.id), ['kept']);
          final made = timeline(now, notes: active);
          final folds = RecapFolds();
          openAll(made, folds);
          expect(_lay(made.rows(folds)), [
            'earlier month 2026-11-01',
            '- week 2026-11-02',
            '  day 2026-11-03 kept',
          ]);
          expect(
            made.countsOf(_of(2026, 1, 1, RecapKind.year)),
            const RecapCounts(notes: 1),
          );
          expect(made.holding('secret'), isEmpty);
          expect(made.holding('trash'), isEmpty);

          final given = timeline(now);
          expect(
            given.countsOf(_of(2026, 11, 2, RecapKind.week)),
            counted(_of(2026, 11, 2, RecapKind.week)),
          );
          expect(given.countsOf(_of(2026, 1, 1, RecapKind.year)).notes, 2);
          expect(given.countsOf(_of(2026, 1, 1, RecapKind.year)).tasksDone, 0);
        });
      },
    );
  });

  group('recap state', () {
    KapyChat recap(RecapPeriod period, DateTime at) => recapChat(
      null,
      record: RecapRecord(
        period: period,
        timeZone: 'Asia/Kolkata',
        firstWeekday: DateTime.monday,
        madeAt: at,
        numbers: const RecapNumbers(
          counts: RecapCounts(notes: 6),
          tasksOpen: 0,
          chart: [1, 1, 1, 1, 1, 1, 0],
          longestRun: 6,
          topics: [],
          previous: RecapCounts(),
        ),
        fingerprint: '0123456789abcdef',
      ),
      answer: 'TITLE: A week',
      model: KapyModel.cloud,
      now: at,
    );

    setUp(() {
      world.note('today', '2026-11-19T05:00:00Z');
      for (var day = 2; day <= 7; day++) {
        world.note('nov$day', '2026-11-0${day}T06:00:00Z');
      }
      world
        ..note('nov12', '2026-11-12T06:00:00Z')
        ..note('oct1', '2026-10-01T06:00:00Z');
      for (var day = 1; day <= 12; day++) {
        world.note(
          'sep$day',
          '2026-09-${day.toString().padLeft(2, '0')}T06:00:00Z',
        );
      }
    });

    test('tells ready, made, too little and still going apart', () {
      final older = recap(
        _of(2026, 11, 2, RecapKind.week),
        DateTime.utc(2026, 11, 9),
      );
      final newer = recap(
        _of(2026, 11, 2, RecapKind.week),
        DateTime.utc(2026, 11, 10),
      );
      final plain = KapyChat(
        id: 'plain',
        title: 'Plans',
        createdAt: DateTime.utc(2026, 11, 9),
        updatedAt: DateTime.utc(2026, 11, 9),
        model: KapyModel.cloud,
      );
      final made = timeline(now, chats: [plain, newer, older]);
      final rows = {
        for (final row in made.rows(RecapFolds()))
          if (row
              case RecapDayRow(:final period, :final state) ||
                  RecapGroupRow(:final period, :final state))
            period: state,
      };
      final today = rows[_of(2026, 11, 19, RecapKind.day)]!;
      expect(today.stage, RecapStage.going);
      expect(today.passed, closeTo(11.5 / 24, 1e-9));
      final week = rows[_of(2026, 11, 2, RecapKind.week)]!;
      expect(week.stage, RecapStage.made);
      expect(week.chat, same(newer));
      expect(
        rows[_of(2026, 11, 9, RecapKind.week)]!.stage,
        RecapStage.tooLittle,
      );
      expect(
        rows[_of(2026, 10, 1, RecapKind.month)]!.stage,
        RecapStage.tooLittle,
      );
      expect(rows[_of(2026, 9, 1, RecapKind.month)]!.stage, RecapStage.ready);

      final month = made
          .rows(RecapFolds())
          .whereType<RecapSectionRow>()
          .first
          .state!;
      expect(month.stage, RecapStage.going);
      expect(month.passed, closeTo((18 + 11.5 / 24) / 30, 1e-9));
    });

    test('shows the parts of a recap being made over every other state', () {
      final progress = <RecapPeriod, RecapProgress>{
        _of(2026, 11, 9, RecapKind.week): (made: 1, parts: 2),
        _of(2026, 11, 2, RecapKind.week): (made: 0, parts: 2),
        _of(2026, 11, 19, RecapKind.day): (made: 0, parts: 1),
      };
      final line = timeline(
        now,
        chats: [
          recap(_of(2026, 11, 2, RecapKind.week), DateTime.utc(2026, 11, 9)),
        ],
        making: (period) => progress[period],
      );
      for (final MapEntry(key: period, value: (:made, :parts))
          in progress.entries) {
        final state = line.stateOf(period);
        expect(state.stage, RecapStage.making);
        expect(state.made, made);
        expect(state.parts, parts);
      }
      progress.remove(_of(2026, 11, 2, RecapKind.week));
      expect(
        line.stateOf(_of(2026, 11, 2, RecapKind.week)).stage,
        RecapStage.made,
      );
    });

    test('marks only the period a recap was made of', () {
      final made = timeline(
        now,
        firstWeekday: DateTime.sunday,
        chats: [
          recap(_of(2026, 11, 2, RecapKind.week), DateTime.utc(2026, 11, 9)),
        ],
      );
      expect(
        made
            .stateOf(
              RecapPeriod.containing(
                DateTime(2026, 11, 2),
                RecapKind.week,
                firstWeekday: DateTime.sunday,
              ),
            )
            .stage,
        RecapStage.ready,
      );
    });
  });

  test('lays out 5,000 notes quickly', () {
    final notes = [
      for (var i = 0; i < 5000; i++)
        Note(
          id: 'n$i',
          body: 'Note $i',
          attachments: [if (i % 10 == 0) recapVoice(hash: 'v$i')],
          createdAt: DateTime.utc(
            2026,
            11,
            19,
          ).subtract(Duration(hours: 7 * i + 1)),
          updatedAt: DateTime.utc(
            2026,
            11,
            19,
          ).subtract(Duration(hours: 7 * i)),
        ),
    ];
    final watch = Stopwatch()..start();
    final made = RecapTimeline(
      notes: notes,
      tasks: TaskBoard.read(
        entries: const [],
        notes: notes,
        docOf: (_) => null,
      ),
      displayTime: displayTime,
      firstWeekday: DateTime.monday,
      now: DateTime.parse(now),
    );
    final folds = RecapFolds();
    final folded = made.rows(folds);
    openAll(made, folds);
    final rows = made.rows(folds);
    watch.stop();
    expect(folded.length, lessThan(40));
    expect(
      rows.whereType<RecapDayRow>().fold(
        0,
        (sum, row) => sum + row.notes.length,
      ),
      5000,
    );
    expect(watch.elapsedMilliseconds, lessThan(2000));
  });
}
