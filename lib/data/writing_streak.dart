import 'note.dart';

/// Days in a row on which something was written.
///
/// Counted from a record of the days themselves — [NotesStore] keeps it —
/// rather than read off the notes, because a note only remembers the last
/// time it changed. Somebody who keeps one running note and adds to it every
/// morning would otherwise have a streak of one, forever.
///
/// A run that reached yesterday is still alive today. It ends when a whole day
/// goes by with nothing written, which is how every streak people already know
/// behaves: waking up to a zero because you have not written *yet* would be a
/// lie about the one thing the number is for.
class WritingStreak {
  const WritingStreak({required this.days, required this.wroteToday});

  /// The run in [written], a set of [dayOf] numbers, as of [today].
  factory WritingStreak.from(Set<int> written, {required int today}) {
    final wroteToday = written.contains(today);
    var day = wroteToday ? today : today - 1;
    var days = 0;
    while (written.contains(day)) {
      days++;
      day--;
    }
    return WritingStreak(days: days, wroteToday: wroteToday);
  }

  /// How many days long the run is. Zero once a day has been missed.
  final int days;

  /// Whether today is one of them. False on a live run means the run is
  /// waiting on today: write something and it grows, leave it and it ends at
  /// midnight.
  final bool wroteToday;

  /// A calendar day as a number: whole days since 1 January 1970.
  ///
  /// Taken from the date rather than by dividing the instant, so a day that
  /// daylight saving made 23 or 25 hours long is still exactly one apart from
  /// its neighbours. On the device's calendar rather than in the zone note
  /// timestamps are shown in: a day of writing is the day where you are.
  static int dayOf(DateTime at) {
    final local = at.toLocal();
    return DateTime.utc(
          local.year,
          local.month,
          local.day,
        ).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
  }

  /// The days a note's own timestamps show somebody writing in it: the day it
  /// was started and the day it last changed.
  ///
  /// Nothing for a note that is blank, or exactly as it was created — which is
  /// how the welcome note arrives — and not the day a note was archived, which
  /// is tidying rather than writing. For what was written before the record
  /// existed and on the person's other devices; what is typed here is recorded
  /// as it happens.
  static Iterable<int> daysIn(Note note) sync* {
    if (note.isEmpty || note.updatedAt.isAtSameMomentAs(note.createdAt)) {
      return;
    }
    yield dayOf(note.createdAt);
    final archivedLast =
        note.archivedAt?.isAtSameMomentAs(note.updatedAt) ?? false;
    if (!archivedLast) yield dayOf(note.updatedAt);
  }

  @override
  bool operator ==(Object other) =>
      other is WritingStreak &&
      other.days == days &&
      other.wroteToday == wroteToday;

  @override
  int get hashCode => Object.hash(days, wroteToday);

  @override
  String toString() =>
      'WritingStreak($days day${days == 1 ? '' : 's'}'
      '${wroteToday ? ', today' : ''})';
}
