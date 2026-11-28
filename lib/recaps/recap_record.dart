import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart' show StringCharacters;

import '../ai/kapy_ai.dart';
import '../ai/kapy_chat_records.dart';
import '../data/notes_store.dart';
import 'recap_digest.dart';
import 'recap_filter.dart';
import 'recap_lines.dart';
import 'recap_material.dart';
import 'recap_period.dart';

/// The most a recap's record may take of its chat's record, in UTF-8 bytes
/// of JSON: what the server takes of one ([chatPayloadMax]) less the rest of
/// a recap chat's record at its longest. That is its id, kind and stamps
/// (166 bytes), a title of at most 64 ([recapTitle] gives 31 at most) and a
/// model of at most 256 (the longest this build names takes 80), with 128
/// to spare for a field a later build adds.
const int recapRecordMax = chatPayloadMax - 166 - 64 - 256 - 128;

/// The most often a note a recap never read may take words out of it. Past
/// it, a record keeps the filter of every note it read alone, which drops
/// every part where it matches but matches less often.
const double recapDropsMost = 0.004;

/// The most UTF-8 bytes of a topic's name a recap's record keeps.
const int recapTopicBytesMax = 40;

/// [name] as a recap's record keeps a topic's: at most [recapTopicBytesMax]
/// bytes of it, cut between graphemes.
String recapTopicName(String name) {
  final kept = StringBuffer();
  var bytes = 0;
  for (final grapheme in name.characters) {
    bytes += utf8.encode(grapheme).length;
    if (bytes > recapTopicBytesMax) break;
    kept.write(grapheme);
  }
  return kept.toString();
}

/// The most tasks each of a recap's lists keeps.
const int recapTasksMax = 6;

/// The numbers a recap shows, worked out on the device when it was made
/// ([RecapDigest]), so it opens as it was made.
class RecapNumbers {
  const RecapNumbers({
    required this.counts,
    required this.tasksOpen,
    required this.chart,
    required this.longestRun,
    required this.topics,
    required this.previous,
    this.done = const [],
    this.open = const [],
  });

  factory RecapNumbers.of(RecapDigest digest, RecapMaterial material) {
    List<String> tasks(RecapSource source) => [
      for (final item in material.items)
        if (item.source == source) item.taskId!,
    ].take(recapTasksMax).toList();
    return RecapNumbers(
      counts: digest.counts,
      tasksOpen: digest.tasksOpen,
      chart: digest.period.kind == RecapKind.year
          ? digest.perMonth
          : digest.perDay,
      longestRun: digest.longestRun,
      topics: digest.topics,
      previous: digest.previous,
      done: tasks(RecapSource.taskDone),
      open: tasks(RecapSource.taskOpen),
    );
  }

  final RecapCounts counts;
  final int tasksOpen;

  /// Notes a day, from the period's first, or a month in a year: the week's
  /// chart, the month's calendar, the year's month by month.
  final List<int> chart;
  final int longestRun;
  final List<RecapTopic> topics;
  final RecapCounts previous;

  /// The ids of the tasks done and still open that the day's card lists.
  final List<String> done;
  final List<String> open;
}

/// One part of a recap, as its call read: the days it covered, as days from
/// its period's first, and the notes that call could read, the notes of its
/// tasks and voice notes among them.
typedef RecapRead = ({int first, int last, RecapFilter notes});

/// What a recap's chat carries beside its messages, in its chat record's
/// `recap` field: what it covers and how it was worked out, its numbers, a
/// fingerprint of what it read, and for a month that was over, the digest
/// a year recap reads instead of asking again.
class RecapRecord {
  const RecapRecord({
    required this.period,
    required this.timeZone,
    required this.firstWeekday,
    required this.madeAt,
    required this.numbers,
    required this.fingerprint,
    this.digest,
    this.read,
    RecapFilter? allRead,
  }) : _allRead = allRead;

  final RecapPeriod period;
  final String timeZone;
  final int firstWeekday;
  final DateTime madeAt;
  final RecapNumbers numbers;

  /// [RecapMaterial.fingerprint] as it was.
  final String fingerprint;
  final String? digest;

  /// Each part that went into the recap. Null where a record has none, and
  /// then any part may have read any note.
  final List<RecapRead>? read;

  /// Every note any of [read]'s parts could read, in one filter sized by
  /// how many: a hidden note it does not hold was read by no part. Null
  /// where a record has none, and then each part says for itself.
  RecapFilter? get allRead => switch (read) {
    final parts? =>
      _allRead ?? RecapFilter.union([for (final part in parts) part.notes]),
    null => _allRead,
  };
  final RecapFilter? _allRead;

  /// How many of the period's notes changed since it was made: "2 notes
  /// changed since then". [now] is what the period holds now.
  int changesSince(RecapMaterial now) {
    if (now.fingerprint == fingerprint) return 0;
    final edited = now.edited.values.where((at) => at.isAfter(madeAt)).length;
    final gone = max(0, numbers.counts.notes - (now.edited.length - edited));
    return max(1, edited + gone);
  }

  /// Within [recapRecordMax]: the digest is cut first, then the task lists,
  /// never [read] or [allRead]. Their filters are sized first, each to how
  /// many notes it holds, in the room the rest leaves without the task
  /// lists and the digest: which notes a recap read keeps its words honest,
  /// and outweighs the lists. Where that room is too little, [allRead] is
  /// served first, since it alone says whether a hidden note takes anything
  /// out, and the parts share what it leaves in proportion. Where a note
  /// read by none would then take words out more often than
  /// [recapDropsMost], and [allRead] alone, in all the room, would do so
  /// less often, the record keeps [allRead] alone and no [read].
  /// `at` goes first, so where two devices each made one, the later is the
  /// greater JSON and every device keeps it (mergeExtra).
  Map<String, Object?> toJson() {
    final counts = numbers.counts;
    final previous = numbers.previous;
    Object? shell;
    Object? whole;
    Map<String, Object?> json({String? digest, int tasks = recapTasksMax}) => {
      'at': madeAt.millisecondsSinceEpoch,
      'kind': period.kind.name,
      'first': _iso(period.first),
      'last': _iso(period.last),
      'zone': _cut(timeZone, 64),
      'weekStart': firstWeekday,
      'notes': counts.notes,
      'done': counts.tasksDone,
      'open': numbers.tasksOpen,
      'voice': counts.voiceNotes,
      'minutes': counts.voiceMinutes,
      'chart': numbers.chart,
      'run': numbers.longestRun,
      'topics': [
        for (final topic in numbers.topics)
          [recapTopicName(topic.name), topic.notes],
      ],
      'before': [
        previous.notes,
        previous.tasksDone,
        previous.voiceNotes,
        previous.voiceMinutes,
      ],
      'doneTasks': numbers.done.take(tasks).toList(),
      'openTasks': numbers.open.take(tasks).toList(),
      'material': fingerprint,
      'read': ?shell,
      'readAll': ?whole,
      'digest': ?digest,
    };
    int size(Map<String, Object?> value) =>
        utf8.encode(jsonEncode(value)).length;
    if (read case final parts?) {
      final all = allRead;
      shell = [
        for (final part in parts)
          [part.first, part.last, part.notes.count, RecapFilter.roomyM, ''],
      ];
      whole = all == null ? null : [all.count, RecapFilter.roomyM, ''];
      final room = max(0, (recapRecordMax - size(json(tasks: 0))) * 3 ~/ 4);
      final wanted = parts.fold(0, (sum, part) => sum + part.notes.bytes);
      final left = max(0, room - (all?.bytes ?? 0));
      final sized = [
        for (final part in parts)
          part.notes.sized(
            wanted <= left
                ? part.notes.bytes
                : part.notes.bytes * left ~/ wanted,
          ),
      ];
      shell = [
        for (final (index, part) in parts.indexed)
          [
            part.first,
            part.last,
            sized[index].count,
            sized[index].m,
            sized[index].toBase64(),
          ],
      ];
      if (all != null) {
        final notes = all.sized(
          min(all.bytes, room - sized.fold(0, (sum, it) => sum + it.bytes)),
        );
        whole = [notes.count, notes.m, notes.toBase64()];
        final drops =
            notes.falseRate *
            (1 - sized.fold(1.0, (none, it) => none * (1 - it.falseRate)));
        if (drops > recapDropsMost) {
          final (withParts, withWhole) = (shell, whole);
          shell = null;
          whole = [all.count, RecapFilter.roomyM, ''];
          final alone = all.sized(
            min(
              all.bytes,
              max(0, (recapRecordMax - size(json(tasks: 0))) * 3 ~/ 4),
            ),
          );
          if (alone.falseRate < drops) {
            whole = [alone.count, alone.m, alone.toBase64()];
          } else {
            (shell, whole) = (withParts, withWhole);
          }
        }
      }
    }
    var tasks = recapTasksMax;
    while (tasks > 0 && size(json(tasks: tasks)) > recapRecordMax) {
      tasks--;
    }
    final room = recapRecordMax - size(json(tasks: tasks, digest: ''));
    final digest = this.digest;
    if (digest == null || room <= 0) return json(tasks: tasks);
    var kept = digest;
    while (kept.isNotEmpty &&
        size(json(tasks: tasks, digest: kept)) > recapRecordMax) {
      kept = kept.substring(0, max(0, kept.length - (kept.length ~/ 8 + 1)));
    }
    return json(tasks: tasks, digest: kept.isEmpty ? null : kept);
  }

  /// Null for anything that is not a whole record this build can read.
  static RecapRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = RecapKind.values.asNameMap()[raw['kind']];
    final first = DateTime.tryParse('${raw['first']}');
    final last = DateTime.tryParse('${raw['last']}');
    final weekStart = raw['weekStart'];
    final at = raw['at'];
    final zone = raw['zone'];
    final fingerprint = raw['material'];
    if (kind == null ||
        first == null ||
        last == null ||
        weekStart is! int ||
        weekStart < DateTime.monday ||
        weekStart > DateTime.sunday ||
        at is! int ||
        zone is! String ||
        fingerprint is! String) {
      return null;
    }
    final period = RecapPeriod.containing(first, kind, firstWeekday: weekStart);
    if (period.first != DateTime(first.year, first.month, first.day) ||
        period.last != DateTime(last.year, last.month, last.day)) {
      return null;
    }
    int count(String key) => switch (raw[key]) {
      final int n when n >= 0 => n,
      _ => 0,
    };
    List<int> ints(Object? list) => [
      for (final n in list is List ? list : const [])
        n is int && n >= 0 ? n : 0,
    ];
    List<String> ids(Object? list) => [
      for (final id in list is List ? list : const [])
        if (id is String) id,
    ].take(recapTasksMax).toList();
    final before = ints(raw['before']);
    int was(int i) => i < before.length ? before[i] : 0;
    final digest = raw['digest'];
    return RecapRecord(
      period: period,
      timeZone: zone,
      firstWeekday: weekStart,
      madeAt: DateTime.fromMillisecondsSinceEpoch(at),
      numbers: RecapNumbers(
        counts: RecapCounts(
          notes: count('notes'),
          tasksDone: count('done'),
          voiceNotes: count('voice'),
          voiceMinutes: count('minutes'),
        ),
        tasksOpen: count('open'),
        chart: ints(raw['chart']),
        longestRun: count('run'),
        topics: [
          for (final topic
              in raw['topics'] is List ? raw['topics'] as List : const [])
            if (topic case [final String name, final int notes])
              (name: name, notes: notes),
        ].take(RecapDigest.topicsMax).toList(),
        previous: RecapCounts(
          notes: was(0),
          tasksDone: was(1),
          voiceNotes: was(2),
          voiceMinutes: was(3),
        ),
        done: ids(raw['doneTasks']),
        open: ids(raw['openTasks']),
      ),
      fingerprint: fingerprint,
      digest: digest is String && digest.isNotEmpty ? digest : null,
      read: _reads(raw['read'], period.days),
      allRead: switch (raw['readAll']) {
        [final count, final m, final bits] => RecapFilter.fromJson(
          count,
          m,
          bits,
          whole: true,
        ),
        _ => null,
      },
    );
  }

  /// The parts [raw] holds, or null when any of them does not hold together,
  /// which leaves every part to have read anything.
  static List<RecapRead>? _reads(Object? raw, int days) {
    if (raw is! List) return null;
    final parts = <RecapRead>[];
    for (final part in raw) {
      if (part case [
        final int first,
        final int last,
        final count,
        final m,
        final bits,
      ] when first >= 0 && first <= last && last < days) {
        final notes = RecapFilter.fromJson(count, m, bits);
        if (notes == null) return null;
        parts.add((first: first, last: last, notes: notes));
      } else {
        return null;
      }
    }
    return parts;
  }
}

/// The question a recap chat starts with, readable in any build: "Make a
/// recap of Wed 19".
String recapRequest(RecapPeriod period) => 'Make a recap of ${period.label}';

RecapRecord? recapOf(KapyChat chat) => RecapRecord.fromJson(chat.recap);

/// The recap of [period] among [chats], the one made last where two
/// devices each made one.
KapyChat? recapChatOf(Iterable<KapyChat> chats, RecapPeriod period) {
  KapyChat? best;
  RecapRecord? bestRecord;
  for (final chat in chats) {
    final record = recapOf(chat);
    if (record == null || record.period != period) continue;
    if (bestRecord == null || record.madeAt.isAfter(bestRecord.madeAt)) {
      best = chat;
      bestRecord = record;
    }
  }
  return best;
}

/// The lines of a recap's newest answer: "Make it again" adds one, and the
/// newest wins.
String? recapAnswer(KapyChat chat) => chat.messages.reversed
    .where((message) => message.role == KapyRole.assistant)
    .firstOrNull
    ?.text;

/// [chat] with [record] and a new answer holding [answer], or a new recap
/// chat when there is none yet: its question, then the answer.
KapyChat recapChat(
  KapyChat? chat, {
  required RecapRecord record,
  required String answer,
  required KapyModel model,
  required DateTime now,
}) {
  final answered = KapyMessage(
    id: NotesStore.newId(),
    role: KapyRole.assistant,
    text: answer,
    at: now,
    model: model,
  );
  if (chat != null) {
    return KapyChat(
      id: chat.id,
      title: chat.title,
      createdAt: chat.createdAt,
      updatedAt: now,
      model: chat.model,
      messages: [...chat.messages, answered],
      titleAt: chat.titleAt,
      modelAt: chat.modelAt,
      recap: record.toJson(),
    );
  }
  return KapyChat(
    id: NotesStore.newId(),
    title: recapTitle(record.period),
    createdAt: now,
    updatedAt: now,
    model: model,
    messages: [
      KapyMessage(
        id: NotesStore.newId(),
        role: KapyRole.user,
        text: recapRequest(record.period),
        at: now,
      ),
      answered,
    ],
    recap: record.toJson(),
  );
}

String _iso(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

String _cut(String text, int max) =>
    text.length <= max ? text : text.substring(0, max);
