import 'package:flutter/foundation.dart';

import '../data/folders.dart';
import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/tags.dart';
import '../data/task_board.dart';
import '../ui/notes_grouping.dart';
import 'recap_period.dart';

/// A tag or folder name, and how many of a period's notes carry it.
typedef RecapTopic = ({String name, int notes});

/// What a period holds, counted: what its folded card says, and what the
/// too-little rule weighs.
@immutable
class RecapCounts {
  const RecapCounts({
    this.notes = 0,
    this.tasksDone = 0,
    this.voiceNotes = 0,
    this.voiceMinutes = 0,
  });

  /// [period]'s counts, read as [RecapDigest.compute] reads them.
  factory RecapCounts.of(
    RecapPeriod period, {
    required List<Note> notes,
    required TaskBoard tasks,
    required DateTime Function(DateTime) displayTime,
    DateTime? Function(Note note)? ownDay,
  }) => _count(
    period,
    _held(period, notes, displayTime, ownDay),
    _visible(notes),
    tasks,
    displayTime,
  );

  final int notes;
  final int tasksDone;
  final int voiceNotes;

  /// The recordings' length together, in whole minutes rounded up.
  final int voiceMinutes;

  /// The longest [line] that still names voice notes.
  static const int lineMax = 40;

  /// Whether there is too little in the period for a recap of [kind].
  bool tooLittleFor(RecapKind kind) =>
      notes + tasksDone + voiceNotes < kind.least;

  /// A folded card's counts: "14 notes · 9 tasks done · 2 voice notes",
  /// leaving out what is none, and the voice notes when the line would
  /// pass [lineMax].
  String get line {
    String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
    final parts = [
      if (notes > 0) count(notes, 'note', 'notes'),
      if (tasksDone > 0) count(tasksDone, 'task done', 'tasks done'),
    ];
    final full = [
      ...parts,
      if (voiceNotes > 0) count(voiceNotes, 'voice note', 'voice notes'),
    ].join(' · ');
    return full.length <= lineMax ? full : parts.join(' · ');
  }

  @override
  bool operator ==(Object other) =>
      other is RecapCounts &&
      other.notes == notes &&
      other.tasksDone == tasksDone &&
      other.voiceNotes == voiceNotes &&
      other.voiceMinutes == voiceMinutes;

  @override
  int get hashCode => Object.hash(notes, tasksDone, voiceNotes, voiceMinutes);

  @override
  String toString() =>
      'RecapCounts($notes notes, $tasksDone done, '
      '$voiceNotes voice, $voiceMinutes min)';
}

/// The numbers in a recap, worked out on the device from the notes, the
/// tasks, the recordings, the tags and the folders, so every one is exact.
///
/// Only visible notes count: hidden and archived notes, and their tasks,
/// recordings, tags and folders, never do.
@immutable
class RecapDigest {
  const RecapDigest._({
    required this.period,
    required this.counts,
    required this.tasksOpen,
    required this.perDay,
    required this.topics,
    required this.previous,
  });

  /// [period]'s numbers. A note is in the period that holds its day in the
  /// notes list: the day it was given ([ownDay]), or the day it was last
  /// edited as [displayTime] shows it. A task is done in the period that
  /// holds the day it was finished.
  factory RecapDigest.compute(
    RecapPeriod period, {
    required List<Note> notes,
    required TaskBoard tasks,
    required TagStore tags,
    required FolderTree folders,
    required DateTime Function(DateTime) displayTime,
    DateTime? Function(Note note)? ownDay,
  }) {
    final visible = _visible(notes);
    final held = _held(period, notes, displayTime, ownDay);
    final heldIds = {for (final note in held.keys) note.id};
    final perDay = List.filled(period.days, 0);
    final topics = <String, RecapTopic>{};
    for (final MapEntry(key: note, value: day) in held.entries) {
      perDay[day]++;
      final names = {
        for (final tag in tags.tagsOf(note.id)) tag.name.v,
        ?folders.pathOfNote(note.id).lastOrNull?.name,
      };
      final seen = <String>{};
      for (final name in names) {
        final key = name.toLowerCase();
        if (!seen.add(key)) continue;
        final topic = topics[key];
        topics[key] = (
          name: topic?.name ?? name,
          notes: (topic?.notes ?? 0) + 1,
        );
      }
    }
    final ranked = topics.values.toList()
      ..sort((a, b) {
        final byNotes = b.notes.compareTo(a.notes);
        return byNotes != 0
            ? byNotes
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return RecapDigest._(
      period: period,
      counts: _count(period, held, visible, tasks, displayTime),
      tasksOpen: tasks.open
          .where((item) => heldIds.contains(item.note.id))
          .length,
      perDay: List.unmodifiable(perDay),
      topics: List.unmodifiable(ranked.take(topicsMax)),
      previous: RecapCounts.of(
        period.previous,
        notes: notes,
        tasks: tasks,
        displayTime: displayTime,
        ownDay: ownDay,
      ),
    );
  }

  /// The most [topics] a recap names.
  static const int topicsMax = 3;

  final RecapPeriod period;
  final RecapCounts counts;

  /// Tasks in the period's notes that are still open.
  final int tasksOpen;

  /// Notes on each of the period's days, from its first: the week's chart
  /// and the month's calendar.
  final List<int> perDay;

  /// The tags and folders most of the period's notes carry, most first, at
  /// most [topicsMax].
  final List<RecapTopic> topics;

  /// The period before's counts, for the line comparing the two.
  final RecapCounts previous;

  /// The day with the most notes, the earliest of any tie, or null when
  /// there are none.
  DateTime? get busiestDay {
    var best = -1;
    for (var i = 0; i < perDay.length; i++) {
      if (perDay[i] > 0 && (best < 0 || perDay[i] > perDay[best])) best = i;
    }
    return best < 0 ? null : _dayAt(best);
  }

  /// The most days in a row with a note, within the period.
  int get longestRun {
    var longest = 0;
    var run = 0;
    for (final count in perDay) {
      run = count > 0 ? run + 1 : 0;
      if (run > longest) longest = run;
    }
    return longest;
  }

  /// Notes in each month, January first: the year's month by month.
  List<int> get perMonth {
    final months = List.filled(12, 0);
    for (var i = 0; i < perDay.length; i++) {
      months[_dayAt(i).month - 1] += perDay[i];
    }
    return months;
  }

  DateTime _dayAt(int index) =>
      DateTime(period.first.year, period.first.month, period.first.day + index);
}

/// The visible notes in [period], as [RecapDigest.compute] counts them,
/// each with its day: what a recap made with Kapy AI reads.
Map<Note, DateTime> recapNotes(
  RecapPeriod period, {
  required List<Note> notes,
  required DateTime Function(DateTime) displayTime,
  DateTime? Function(Note note)? ownDay,
}) => {
  for (final MapEntry(key: note, value: index) in _held(
    period,
    notes,
    displayTime,
    ownDay,
  ).entries)
    note: DateTime(
      period.first.year,
      period.first.month,
      period.first.day + index,
    ),
};

/// The ids of [notes] a recap may read: not hidden, not archived.
Set<String> _visible(List<Note> notes) => {
  for (final note in notes)
    if (!note.isHidden && !note.isArchived) note.id,
};

/// The visible notes in [period], each with the index of its day in it.
Map<Note, int> _held(
  RecapPeriod period,
  List<Note> notes,
  DateTime Function(DateTime) displayTime,
  DateTime? Function(Note note)? ownDay,
) => {
  for (final note in notes)
    if (!note.isHidden && !note.isArchived)
      note: ?period.indexOf(
        noteDay(note, displayTime, ownDay: ownDay?.call(note)),
      ),
};

RecapCounts _count(
  RecapPeriod period,
  Map<Note, int> held,
  Set<String> visible,
  TaskBoard tasks,
  DateTime Function(DateTime) displayTime,
) {
  final recordings = [
    for (final note in held.keys) ...note.attachments.whereType<NoteVoiceRef>(),
  ];
  final voiceMs = recordings.fold(0, (sum, voice) => sum + voice.durationMs);
  return RecapCounts(
    notes: held.length,
    tasksDone: tasks.done
        .where(
          (item) =>
              visible.contains(item.note.id) &&
              period.contains(dayShown(item.doneAt!, displayTime)),
        )
        .length,
    voiceNotes: recordings.length,
    voiceMinutes: (voiceMs + 59999) ~/ 60000,
  );
}
