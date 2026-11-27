import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/ai/kapy_chat_records.dart';
import 'package:kapy_notes/recaps/recap_digest.dart';
import 'package:kapy_notes/recaps/recap_filter.dart';
import 'package:kapy_notes/recaps/recap_lines.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_record.dart';

import '../ai/ai_fakes.dart';
import 'recap_fixtures.dart';

void main() {
  final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
  final made = DateTime(2026, 11, 24, 9);

  RecapRecord record({
    RecapPeriod? period,
    DateTime? at,
    String? digest,
    String zone = 'Asia/Kolkata',
    List<String> done = const ['a:1', 'a:2'],
    List<RecapTopic> topics = const [(name: 'Work', notes: 4)],
    List<RecapRead>? read,
  }) => RecapRecord(
    period: period ?? week,
    timeZone: zone,
    firstWeekday: DateTime.monday,
    madeAt: at ?? made,
    numbers: RecapNumbers(
      counts: const RecapCounts(
        notes: 14,
        tasksDone: 9,
        voiceNotes: 2,
        voiceMinutes: 12,
      ),
      tasksOpen: 3,
      chart: const [1, 4, 0, 2, 3, 0, 4],
      longestRun: 2,
      topics: topics,
      previous: const RecapCounts(notes: 10, tasksDone: 5),
      done: done,
      open: const ['b:1'],
    ),
    fingerprint: '0123456789abcdef',
    digest: digest,
    read: read,
  );

  final parts = <RecapRead>[
    (first: 0, last: 3, notes: RecapFilter.of(['mon', 'tue'])),
    (first: 4, last: 6, notes: RecapFilter.of(['fri'])),
  ];

  Object? partsOf(RecapRecord record) =>
      jsonDecode(jsonEncode(record.toJson()))['read'];

  KapyChat chat(RecapRecord record) => recapChat(
    null,
    record: record,
    answer: 'TITLE: A busy week\nNEXT: Rest',
    model: KapyModel.cloud,
    now: record.madeAt,
  );

  int chatRecordBytes(KapyChat chat) =>
      utf8.encode(jsonEncode(ChatMeta.of(chat).toPayload())).length;

  RecapRecord back(RecapRecord record) =>
      RecapRecord.fromJson(jsonDecode(jsonEncode(record.toJson())))!;

  /// How often a note the recap never read would take its words out.
  double drops(RecapRecord record) {
    var wrong = 0;
    for (var i = 0; i < 20000; i++) {
      final id = 'never-read-$i';
      if (record.allRead!.mayHold(id) &&
          record.read!.any((part) => part.notes.mayHold(id))) {
        wrong++;
      }
    }
    return wrong / 20000;
  }

  /// A recap of [period] as long as one gets, of [notes] notes shared out
  /// over its parts as a recap plans them.
  RecapRecord fullest(RecapPeriod period, int notes) {
    final days = period.kind == RecapKind.week
        ? [(0, 3), (4, 6)]
        : [(0, 6), (7, 13), (14, 20), (21, 27), (28, period.days - 1)];
    return RecapRecord(
      period: period,
      timeZone: 'Z' * 500,
      firstWeekday: DateTime.monday,
      madeAt: made,
      numbers: RecapNumbers(
        counts: RecapCounts(
          notes: notes,
          tasksDone: 412,
          voiceNotes: 96,
          voiceMinutes: 1890,
        ),
        tasksOpen: 37,
        chart: List.filled(period.days, 120),
        longestRun: period.days,
        topics: [for (var i = 0; i < 3; i++) (name: '話' * 200, notes: i)],
        previous: const RecapCounts(notes: 900, tasksDone: 300),
        done: [for (var i = 0; i < 40; i++) 'task-${'x' * 30}-$i'],
        open: [for (var i = 0; i < 40; i++) 'task-${'y' * 30}-$i'],
      ),
      fingerprint: '0123456789abcdef',
      digest: 'A busy month. ' * 200,
      read: [
        for (final (index, (first, last)) in days.indexed)
          (
            first: first,
            last: last,
            notes: RecapFilter.of([
              for (var i = index; i < notes; i += days.length) 'note-$i',
            ]),
          ),
      ],
    );
  }

  test('reads back as it was written', () {
    final back = RecapRecord.fromJson(
      jsonDecode(jsonEncode(record(digest: 'Notes: plans').toJson())),
    )!;
    expect(back.period, week);
    expect(back.timeZone, 'Asia/Kolkata');
    expect(back.firstWeekday, DateTime.monday);
    expect(back.madeAt, made);
    expect(
      back.numbers.counts,
      const RecapCounts(
        notes: 14,
        tasksDone: 9,
        voiceNotes: 2,
        voiceMinutes: 12,
      ),
    );
    expect(back.numbers.tasksOpen, 3);
    expect(back.numbers.chart, [1, 4, 0, 2, 3, 0, 4]);
    expect(back.numbers.longestRun, 2);
    expect(back.numbers.topics, [(name: 'Work', notes: 4)]);
    expect(back.numbers.previous, const RecapCounts(notes: 10, tasksDone: 5));
    expect(back.numbers.done, ['a:1', 'a:2']);
    expect(back.numbers.open, ['b:1']);
    expect(back.fingerprint, '0123456789abcdef');
    expect(back.digest, 'Notes: plans');
  });

  test('keeps which notes each part read', () {
    final back = RecapRecord.fromJson(
      jsonDecode(jsonEncode(record(read: parts).toJson())),
    )!;
    expect(partsOf(back), partsOf(record(read: parts)));
    expect(back.read![0].notes.mayHold('tue'), isTrue);
    expect(back.read![1].notes.mayHold('fri'), isTrue);
    expect(back.read![1].notes.mayHold('mon'), isFalse);
    expect(['mon', 'tue', 'fri'].every(back.allRead!.mayHold), isTrue);
    expect(back.allRead!.mayHold('sat'), isFalse);
    expect(record().toJson(), isNot(contains('read')));
    expect(record().toJson(), isNot(contains('readAll')));
    expect(RecapRecord.fromJson(record().toJson())!.read, isNull);
    expect(RecapRecord.fromJson(record().toJson())!.allRead, isNull);
  });

  test('a whole recap\'s filter that does not hold together leaves each '
      'part to say', () {
    final json = record(read: parts).toJson();
    for (final broken in [
      'bits',
      [16],
      [0, (json['readAll']! as List).last],
      [17, (json['readAll']! as List).last],
      [16, ''],
      [16, 'not base64!'],
    ]) {
      final back = RecapRecord.fromJson({...json, 'readAll': broken})!;
      expect(back.allRead, isNull, reason: '$broken');
      expect(partsOf(back), json['read'], reason: '$broken');
    }
  });

  test('parts that do not hold together are read as none at all', () {
    final json = record(read: parts).toJson();
    final good = (json['read']! as List).first;
    for (final broken in [
      'parts',
      [good, 'part'],
      [
        good,
        [0, 7, (good as List)[2], good.last],
      ],
      [
        good,
        [3, 1, good[2], good.last],
      ],
      [
        good,
        [0, 3, good.last],
      ],
      [
        good,
        [0, 3, 0, good.last],
      ],
      [
        good,
        [0, 3, 17, good.last],
      ],
      [
        good,
        [0, 3, good[2], ''],
      ],
      [
        good,
        [0, 3, good[2], 'not base64!'],
      ],
    ]) {
      final back = RecapRecord.fromJson({...json, 'read': broken});
      expect(back, isNotNull, reason: '$broken');
      expect(back!.read, isNull, reason: '$broken');
    }
  });

  test('a record that does not hold together is not read', () {
    final json = record().toJson();
    for (final broken in [
      {...json, 'kind': 'decade'},
      {...json, 'first': '2026-11-18'},
      {...json, 'weekStart': 9},
      {...json}..remove('at'),
      'recap',
    ]) {
      expect(RecapRecord.fromJson(broken), isNull, reason: '$broken');
    }
  });

  test('stays within its share of a chat record, cutting the digest first', () {
    final long = record(
      digest: 'Lisbon trip, flights booked. ' * 400,
      zone: 'Z' * 500,
      done: [for (var i = 0; i < 40; i++) 'task-${'x' * 30}-$i'],
      topics: [for (var i = 0; i < 3; i++) (name: '話' * 200, notes: i)],
    );
    final json = long.toJson();
    expect(
      utf8.encode(jsonEncode(json)).length,
      lessThanOrEqualTo(recapRecordMax),
    );
    expect(json['digest'], isA<String>());
    expect(
      (json['doneTasks']! as List).length,
      lessThanOrEqualTo(recapTasksMax),
    );
    expect(chatRecordBytes(chat(long)), lessThanOrEqualTo(chatPayloadMax));
    expect(RecapRecord.fromJson(jsonDecode(jsonEncode(json))), isNotNull);
  });

  test('a busy year of 13 parts fits, and its filters still mostly tell', () {
    final year = periodOf(DateTime(2026, 11, 19), RecapKind.year);
    final read = <RecapRead>[
      for (var month = 1; month <= 12; month++)
        (
          first: year.indexOf(DateTime(2026, month))!,
          last: year.indexOf(DateTime(2026, month + 1, 0))!,
          notes: RecapFilter.of([for (var i = 0; i < 90; i++) '$month-$i']),
        ),
      (first: 0, last: 364, notes: RecapFilter.of(['rest'])),
    ];
    final long = RecapRecord(
      period: year,
      timeZone: 'Z' * 500,
      firstWeekday: DateTime.monday,
      madeAt: made,
      numbers: RecapNumbers(
        counts: const RecapCounts(
          notes: 1086,
          tasksDone: 412,
          voiceNotes: 96,
          voiceMinutes: 1890,
        ),
        tasksOpen: 37,
        chart: const [88, 91, 102, 77, 95, 120, 64, 70, 99, 93, 101, 86],
        longestRun: 41,
        topics: [for (var i = 0; i < 3; i++) (name: '話' * 200, notes: i)],
        previous: const RecapCounts(notes: 900, tasksDone: 300),
        done: [for (var i = 0; i < 40; i++) 'task-${'x' * 30}-$i'],
        open: [for (var i = 0; i < 40; i++) 'task-${'y' * 30}-$i'],
      ),
      fingerprint: '0123456789abcdef',
      digest: 'A busy year. ' * 200,
      read: read,
    );
    final json = long.toJson();
    expect(
      utf8.encode(jsonEncode(json)).length,
      lessThanOrEqualTo(recapRecordMax),
    );
    final back = RecapRecord.fromJson(jsonDecode(jsonEncode(json)))!;
    expect(partsOf(back), json['read']);
    expect(chatRecordBytes(chat(long)), lessThanOrEqualTo(chatPayloadMax));
    for (final (index, part) in back.read!.indexed) {
      final ids = index == 12
          ? ['rest']
          : [for (var i = 0; i < 90; i++) '${index + 1}-$i'];
      expect(ids.every(part.notes.mayHold), isTrue, reason: 'part $index');
      expect(ids.every(back.allRead!.mayHold), isTrue, reason: 'part $index');
    }
    expect(drops(back), lessThan(0.15), reason: '1,081 notes');
  });

  test('at its fullest, a week or a month never misses a note it read, and '
      'all but never takes words out for one it did not', () {
    final month = periodOf(DateTime(2026, 10, 19), RecapKind.month);
    for (final (period, notes, most) in [
      (week, 50, 0.002),
      (week, 400, 0.002),
      (month, 150, 0.002),
      (month, 450, 0.006),
      (month, 1000, null),
    ]) {
      final record = fullest(period, notes);
      expect(
        utf8.encode(jsonEncode(record.toJson())).length,
        lessThanOrEqualTo(recapRecordMax),
      );
      final read = back(record);
      for (final (index, part) in read.read!.indexed) {
        for (var i = index; i < notes; i += read.read!.length) {
          final id = 'note-$i';
          expect(part.notes.mayHold(id), isTrue, reason: '$notes: $id');
          expect(read.allRead!.mayHold(id), isTrue, reason: '$notes: $id');
        }
      }
      if (most != null) {
        expect(drops(read), lessThan(most), reason: '$notes notes');
      }
    }
  });

  test(
    'a part is sized to its notes, a few bits each, where there is room',
    () {
      for (final count in [1, 30, 200]) {
        final ids = [for (var i = 0; i < count; i++) 'note-$i'];
        final json = record(
          read: [(first: 0, last: 6, notes: RecapFilter.of(ids))],
        ).toJson();
        final part = (json['read']! as List).single as List;
        final bytes = base64Decode(part[3] as String).length;
        expect(bytes, RecapFilter.of(ids).bytes, reason: '$count notes');
        final back = RecapRecord.fromJson(jsonDecode(jsonEncode(json)))!;
        final notes = back.read!.single.notes;
        expect(ids.every(notes.mayHold), isTrue, reason: 'never a miss');
        var wrong = 0;
        for (var i = 0; i < 20000; i++) {
          if (notes.mayHold('other-$i')) wrong++;
        }
        expect(wrong / 20000, lessThan(0.02), reason: '$count notes: $wrong');
      }
    },
  );

  test('a recap chat is a question and its answer, readable anywhere', () {
    final made = chat(record());
    expect(made.title, 'Recap · 16–22 Nov');
    expect(made.messages.map((m) => (m.role, m.text)), [
      (KapyRole.user, 'Make a recap of 16–22 Nov'),
      (KapyRole.assistant, 'TITLE: A busy week\nNEXT: Rest'),
    ]);
    expect(recapOf(made)!.period, week);
  });

  test('keeping a recap without its words loses nothing in a merge', () {
    final made = record(read: parts);
    final first = chat(made);
    final pruned = recapChat(
      first,
      record: made,
      answer: recapTitle(week),
      model: KapyModel.cloud,
      now: made.madeAt.add(const Duration(days: 40)),
    );
    final before = ChatMeta.of(first);
    final after = ChatMeta.of(pruned);
    expect(after.recap, before.recap, reason: 'the record is not changed');
    expect(after.merge(before).recap, before.recap);
    expect(before.merge(after).recap, before.recap);
    expect(pruned.messages.map((m) => m.text), [
      'Make a recap of 16–22 Nov',
      'TITLE: A busy week\nNEXT: Rest',
      'Recap · 16–22 Nov',
    ], reason: 'the answer with words stays, so the story can tell');
  });

  test('making it again adds an answer, and the newest wins', () {
    final first = chat(record());
    final later = made.add(const Duration(days: 2));
    final again = recapChat(
      first,
      record: record(at: later),
      answer: 'TITLE: Second go',
      model: KapyModel.cloud,
      now: later,
    );
    expect(again.id, first.id);
    expect(again.messages, hasLength(3));
    expect(recapAnswer(again), 'TITLE: Second go');
    expect(recapOf(again)!.madeAt, later);

    final stale = ChatMeta.of(first);
    final fresh = ChatMeta.of(again);
    expect(stale.merge(fresh).recap, fresh.recap);
    expect(fresh.merge(stale).recap, fresh.recap);
    expect(
      recapChatOf([first, chat(record(at: later))], week)!.messages.last.text,
      'TITLE: A busy week\nNEXT: Rest',
    );
  });

  test(
    'keeps its record through a rename on a build that does not know it',
    () {
      final recap = chat(record(digest: 'Plans'));
      // A build from before recaps holds the pulled record with the recap
      // among the fields it does not know, and its own chat without it.
      final pulled = ChatMeta.fromPayload(
        jsonDecode(jsonEncode(ChatMeta.of(recap).toPayload())),
      )!;
      final theirs = KapyChat(
        id: recap.id,
        title: 'Our week',
        createdAt: recap.createdAt,
        updatedAt: made.add(const Duration(hours: 1)),
        titleAt: made.add(const Duration(hours: 1)),
        modelAt: recap.modelAt,
        model: recap.model,
      );
      final renamed = ChatMeta.of(theirs).merge(pulled).toPayload();
      expect(renamed['title'], {
        'v': 'Our week',
        'at': theirs.titleAt.millisecondsSinceEpoch,
      });
      expect(renamed['recap'], jsonDecode(jsonEncode(recap.recap)));
      expect(RecapRecord.fromJson(renamed['recap'])!.digest, 'Plans');
    },
  );

  test('keeps which notes each part read through a build that does not '
      'know them', () {
    final recap = chat(record(read: parts));
    final pulled = ChatMeta.fromPayload(
      jsonDecode(jsonEncode(ChatMeta.of(recap).toPayload())),
    )!;
    final theirs = KapyChat(
      id: recap.id,
      title: 'Our week',
      createdAt: recap.createdAt,
      updatedAt: made.add(const Duration(hours: 1)),
      titleAt: made.add(const Duration(hours: 1)),
      modelAt: recap.modelAt,
      model: recap.model,
    );
    final renamed = ChatMeta.of(theirs).merge(pulled).toPayload();
    expect(renamed['recap'], jsonDecode(jsonEncode(recap.recap)));
    expect(
      partsOf(RecapRecord.fromJson(renamed['recap'])!),
      partsOf(record(read: parts)),
    );
  });

  test('the chat book keeps it on the device and from the account', () async {
    final store = MemoryStore();
    final book = KapyChatBook(store);
    await book.load();
    final recap = chat(record());
    book.put(recap);
    final reopened = KapyChatBook(store);
    await reopened.load();
    expect(reopened.chats.single.recap, recap.recap);

    final elsewhere = KapyChatBook(MemoryStore());
    await elsewhere.load();
    elsewhere.applyRemoteChat(
      ChatMeta.fromPayload(
        jsonDecode(jsonEncode(ChatMeta.of(recap).toPayload())),
      )!,
      1,
    );
    expect(recapOf(elsewhere.chats.single)!.period, week);

    final later = made.add(const Duration(days: 1));
    final again = recapChat(
      recap,
      record: record(at: later),
      answer: 'TITLE: Again',
      model: KapyModel.cloud,
      now: later,
    );
    elsewhere.applyRemoteChat(
      ChatMeta.fromPayload(
        jsonDecode(jsonEncode(ChatMeta.of(again).toPayload())),
      )!,
      2,
    );
    expect(recapOf(elsewhere.chats.single)!.madeAt, later);
  });
}
