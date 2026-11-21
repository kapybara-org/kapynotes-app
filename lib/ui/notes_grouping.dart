import 'package:material_ui/material_ui.dart';

import '../data/layout_prefs.dart';
import '../data/note.dart';
import 'sidebar_timestamp.dart';

/// What When narrows the list to: a span from its menu, or one day picked
/// in the week at the top of the page. Picking one replaces the other.
sealed class WhenFilter {
  /// What the chip beside the filter says: "This week", "Tue 17".
  String get label;

  /// How a sentence says it: "No notes this week", "No notes on Tue 17".
  String get phrase;

  /// The days it covers on [today], in weeks that start on [firstWeekday],
  /// a [DateTime.weekday]; null for any time.
  DaySpan? span({required DateTime today, required int firstWeekday});
}

/// How far back the notes list reaches: the notes filter's When menu.
enum NotesWhen implements WhenFilter {
  anyTime('Any time', 'at any time'),
  today('Today', 'today'),
  thisWeek('This week', 'this week'),
  lastWeek('Last week', 'last week'),
  thisMonth('This month', 'this month');

  const NotesWhen(this.label, this.phrase);

  @override
  final String label;

  @override
  final String phrase;

  @override
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

/// One day picked at the top of the page, other than today, which is
/// When's own [NotesWhen.today].
final class WhenDay implements WhenFilter {
  factory WhenDay(DateTime day, {required DateTime today}) {
    final (heading, date) = SidebarTimestamp.dayHeading(day, today: today);
    return WhenDay._(day, date ?? heading);
  }

  const WhenDay._(this.day, this.label);

  final DateTime day;

  /// As the list heads the day on the day it was picked, with the date in
  /// place of "Yesterday": "Wed 18", "Tue 17", then "Mon 9 Nov" before the
  /// week. None of it says how long ago, so it stays true past midnight.
  @override
  final String label;

  @override
  String get phrase => 'on $label';

  @override
  DaySpan span({required DateTime today, required int firstWeekday}) =>
      DaySpan(day, day);

  @override
  bool operator ==(Object other) => other is WhenDay && other.day == day;

  @override
  int get hashCode => day.hashCode;
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

/// The day a note sits under in the list: the day it was given, or the day it
/// was last edited when it has none of its own. Grouping by day, When and the
/// days that show notes all ask this.
DateTime noteDay(
  Note note,
  DateTime Function(DateTime) displayTime, {
  DateTime? ownDay,
}) => ownDay ?? dayShown(note.updatedAt, displayTime);

/// A heading in the notes list, and the notes under it. [upcoming] marks the
/// one grouping by day gives the notes waiting for a later day, which the
/// list beside the rail folds; no other group is it, whatever its label.
typedef NoteGroup = ({
  String label,
  String? detail,
  List<Note> notes,
  bool upcoming,
});

/// [notes] under the headings [grouping] gives them, each group keeping the
/// order the notes came in: a heading for each day, newest first; one for
/// each first tag, by name, and then the untagged; or one for each first
/// letter of the titles, sorted A to Z, with anything that is not a letter
/// last.
/// [ownDay] is the day a note was given, where it has one: those waiting for a
/// day after [today] go into one Upcoming group at the top, and the rest sit
/// under the day they were given rather than the day they were last edited.
List<NoteGroup> groupNotes(
  List<Note> notes,
  NotesGrouping grouping, {
  required DateTime today,
  required DateTime Function(DateTime) displayTime,
  required String? Function(Note note) firstTag,
  DateTime? Function(Note note)? ownDay,
}) {
  final groups = <Object?, NoteGroup>{};
  void add(Object? key, String label, Note note) => groups
      .putIfAbsent(
        key,
        () => (label: label, detail: null, notes: <Note>[], upcoming: false),
      )
      .notes
      .add(note);

  switch (grouping) {
    case NotesGrouping.byDate:
      final from = DateTime(today.year, today.month, today.day);
      final waiting = <Note>[];
      for (final note in notes) {
        final own = ownDay?.call(note);
        if (own != null && own.isAfter(from)) {
          waiting.add(note);
          continue;
        }
        final day = noteDay(note, displayTime, ownDay: own);
        // The page's week already says which day Today and Yesterday are.
        final (label, _) = SidebarTimestamp.dayHeading(day, today: today);
        add(day, label, note);
      }
      final days = groups.keys.cast<DateTime>().toList()
        ..sort((a, b) => b.compareTo(a));
      return [
        if (waiting.isNotEmpty)
          (
            label: 'Upcoming',
            detail: '${waiting.length}',
            notes: waiting,
            upcoming: true,
          ),
        for (final day in days) groups[day]!,
      ];
    case NotesGrouping.byTag:
      for (final note in notes) {
        final tag = firstTag(note);
        add(tag?.toLowerCase(), tag ?? 'No tag', note);
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
        add(key, key ?? '#', note);
      }
      return [
        for (final entry in groups.entries)
          if (entry.key != null) entry.value,
        ?groups[null],
      ];
  }
}

final _letter = RegExp(r'^\p{L}', unicode: true);
