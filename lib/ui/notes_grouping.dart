import 'package:material_ui/material_ui.dart';

import '../data/layout_prefs.dart';
import '../data/note.dart';
import 'sidebar_timestamp.dart';

/// How far back the notes list reaches: the notes filter's When menu.
enum NotesWhen {
  anyTime('Any time', 'at any time'),
  today('Today', 'today'),
  thisWeek('This week', 'this week'),
  lastWeek('Last week', 'last week'),
  thisMonth('This month', 'this month');

  const NotesWhen(this.label, this.phrase);

  final String label;

  /// How a sentence says it: "No notes this week".
  final String phrase;

  /// The days this span covers on [today], in weeks that start on
  /// [firstWeekday], a [DateTime.weekday]; null for any time.
  DaySpan? span({required DateTime today, required int firstWeekday}) {
    DateTime after(DateTime day, int days) =>
        DateTime(day.year, day.month, day.day + days);
    final week = after(today, -((today.weekday - firstWeekday) % 7));
    return switch (this) {
      NotesWhen.anyTime => null,
      NotesWhen.today => DaySpan(today, today),
      NotesWhen.thisWeek => DaySpan(week, after(week, 6)),
      NotesWhen.lastWeek => DaySpan(after(week, -7), after(week, -1)),
      NotesWhen.thisMonth => DaySpan(
        DateTime(today.year, today.month),
        DateTime(today.year, today.month + 1, 0),
      ),
    };
  }

  /// What this span covers on [today], beside it in When's menu: "Wed 19",
  /// "10–16 Nov" or "November", and nothing for any time.
  String? detail({required DateTime today, required int firstWeekday}) {
    final span = this.span(today: today, firstWeekday: firstWeekday);
    if (span == null) return null;
    return switch (this) {
      NotesWhen.today => SidebarTimestamp.weekdayAndDay(today),
      NotesWhen.thisMonth => SidebarTimestamp.monthName(today),
      _ => SidebarTimestamp.dayRange(span.first, span.last),
    };
  }
}

/// The days a When span reaches over, from [first] to [last].
class DaySpan {
  const DaySpan(this.first, this.last);

  final DateTime first;
  final DateTime last;

  bool covers(DateTime day) => !day.isBefore(first) && !day.isAfter(last);
}

/// The [DateTime.weekday] weeks start on where the app is used.
int firstWeekday(BuildContext context) {
  final index = MaterialLocalizations.of(context).firstDayOfWeekIndex;
  return index == 0 ? DateTime.sunday : index;
}

/// The calendar day [instant] falls on, as the list shows times.
DateTime dayShown(DateTime instant, DateTime Function(DateTime) displayTime) {
  final shown = displayTime(instant);
  return DateTime(shown.year, shown.month, shown.day);
}

/// The day a note sits under in the list: the day it was last edited, which
/// is also the day its card names. Grouping by day, When and the days that
/// show notes all ask this.
DateTime noteDay(Note note, DateTime Function(DateTime) displayTime) =>
    dayShown(note.updatedAt, displayTime);

/// A heading in the notes list, and the notes under it.
typedef NoteGroup = ({String label, String? detail, List<Note> notes});

/// [notes] under the headings [grouping] gives them, each group keeping the
/// order the notes came in: a heading for each day, newest first; one for
/// each first tag, by name, and then the untagged; or one for each first
/// letter of the titles, sorted A to Z, with anything that is not a letter
/// last.
List<NoteGroup> groupNotes(
  List<Note> notes,
  NotesGrouping grouping, {
  required DateTime today,
  required DateTime Function(DateTime) displayTime,
  required String? Function(Note note) firstTag,
}) {
  final groups = <Object?, NoteGroup>{};
  void add(Object? key, String label, String? detail, Note note) => groups
      .putIfAbsent(key, () => (label: label, detail: detail, notes: <Note>[]))
      .notes
      .add(note);

  switch (grouping) {
    case NotesGrouping.byDate:
      for (final note in notes) {
        final day = noteDay(note, displayTime);
        final (label, detail) = SidebarTimestamp.dayHeading(day, today: today);
        add(day, label, detail, note);
      }
      final days = groups.keys.cast<DateTime>().toList()
        ..sort((a, b) => b.compareTo(a));
      return [for (final day in days) groups[day]!];
    case NotesGrouping.byTag:
      for (final note in notes) {
        final tag = firstTag(note);
        add(tag?.toLowerCase(), tag ?? 'No tag', null, note);
      }
      final names = groups.keys.whereType<String>().toList()..sort();
      return [for (final name in names) groups[name]!, ?groups[null]];
    case NotesGrouping.aToZ:
      final sorted = [
        ...notes,
      ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      for (final note in sorted) {
        final first = note.title.trimLeft().runes.firstOrNull;
        final letter = first == null
            ? null
            : String.fromCharCode(first).toUpperCase();
        final key = letter != null && _letter.hasMatch(letter) ? letter : null;
        add(key, key ?? '#', null, note);
      }
      return [
        for (final entry in groups.entries)
          if (entry.key != null) entry.value,
        ?groups[null],
      ];
  }
}

final _letter = RegExp(r'^\p{L}', unicode: true);
