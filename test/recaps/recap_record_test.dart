import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/ai/kapy_chat_records.dart';
import 'package:kapy_notes/recaps/recap_digest.dart';
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
  );

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

  test('a recap chat is a question and its answer, readable anywhere', () {
    final made = chat(record());
    expect(made.title, '16–22 Nov recap');
    expect(made.messages.map((m) => (m.role, m.text)), [
      (KapyRole.user, 'Make a recap of 16–22 Nov'),
      (KapyRole.assistant, 'TITLE: A busy week\nNEXT: Rest'),
    ]);
    expect(recapOf(made)!.period, week);
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
