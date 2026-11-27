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

  List<Object> partsOf(RecapRecord record) => [
    for (final part in record.read!)
      [part.first, part.last, part.notes.toBase64()],
  ];

  KapyChat chat(RecapRecord record) => recapChat(
    null,
    record: record,
    answer: 'TITLE: A busy week\nNEXT: Rest',
    model: KapyModel.cloud,
    now: record.madeAt,
  );

  int chatRecordBytes(KapyChat chat) =>
      utf8.encode(jsonEncode(ChatMeta.of(chat).toPayload())).length;

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
    expect(back.notesRead!.mayHold('mon'), isTrue);
    expect(record().toJson(), isNot(contains('read')));
    expect(RecapRecord.fromJson(record().toJson())!.read, isNull);
  });

  test('parts that do not hold together are read as none at all', () {
    final json = record(read: parts).toJson();
    final good = (json['read']! as List).first;
    for (final broken in [
      'parts',
      [good, 'part'],
      [
        good,
        [0, 7, (good as List).last],
      ],
      [
        good,
        [3, 1, good.last],
      ],
      [
        good,
        [0, 3, 'AAAA'],
      ],
      [
        good,
        [0, 3, 'not base64!'],
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

  test('a year of 13 parts fits, its parts never cut', () {
    final year = periodOf(DateTime(2026, 11, 19), RecapKind.year);
    final read = <RecapRead>[
      for (var month = 1; month <= 12; month++)
        (
          first: year.indexOf(DateTime(2026, month))!,
          last: year.indexOf(DateTime(2026, month + 1, 0))!,
          notes: RecapFilter.of([for (var i = 0; i < 200; i++) '$month-$i']),
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
        done: [for (var i = 0; i < 40; i++) 'task-NaN-$i'],
        open: [for (var i = 0; i < 40; i++) 'task-NaN-$i'],
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
    expect(partsOf(back), partsOf(long));
    expect(chatRecordBytes(chat(long)), lessThanOrEqualTo(chatPayloadMax));
  });

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
