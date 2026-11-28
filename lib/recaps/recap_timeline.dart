import 'package:flutter/foundation.dart';

import '../ai/kapy_ai.dart';
import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/task_board.dart';
import '../ui/notes_grouping.dart';
import 'recap_digest.dart';
import 'recap_period.dart';
import 'recap_record.dart';

/// How far along a recap being made is: [made] of its [parts] are back.
typedef RecapProgress = ({int made, int parts});

/// What a period's recap icon shows.
enum RecapStage {
  /// There is enough in it, and no recap of it yet.
  ready,

  /// A recap of it was made, and opens free.
  made,

  /// Too little in it for a recap ([RecapCounts.tooLittleFor]).
  tooLittle,

  /// It is still going, and the pie shows how much of it has passed.
  going,

  /// A recap of it is being made, and the pie fills as each part comes back.
  making,
}

/// A period's recap icon: its [stage], and what that stage draws.
@immutable
class RecapState {
  const RecapState._(
    this.stage, {
    this.chat,
    this.passed = 0,
    this.made = 0,
    this.parts = 0,
  });

  final RecapStage stage;

  /// The recap made of it, the one made last where two devices each made
  /// one. Set when [stage] is [RecapStage.made].
  final KapyChat? chat;

  /// How much of a period still going has passed, from 0 to 1.
  final double passed;

  /// The parts back and all the parts, while it is [RecapStage.making].
  final int made;
  final int parts;

  @override
  String toString() => 'RecapState(${stage.name})';
}

/// A row on the timeline's rail, top to bottom.
sealed class RecapRow {
  const RecapRow(this.depth);

  /// How many opened cards it sits in: 0 on the rail itself.
  final int depth;
}

/// A day's heading and its notes, in the order they were given.
class RecapDayRow extends RecapRow {
  const RecapDayRow(
    this.period,
    this.counts,
    this.state,
    this.notes, {
    required int depth,
  }) : super(depth);

  final RecapPeriod period;
  final RecapCounts counts;
  final RecapState state;
  final List<Note> notes;
}

/// An earlier week, month or year folded into one card, or its header when
/// [open], with its days, weeks or months under it one [depth] deeper.
class RecapGroupRow extends RecapRow {
  const RecapGroupRow(
    this.period,
    this.counts,
    this.state, {
    required this.open,
    required int depth,
  }) : super(depth);

  final RecapPeriod period;

  /// The whole period's counts, which its card shows and its recap reads.
  final RecapCounts counts;
  final RecapState state;
  final bool open;
}

/// The heading over folded cards. "Earlier in November" is the month's own
/// row and "Earlier in 2026" the year's, both still going; "Earlier years"
/// has no [period].
class RecapSectionRow extends RecapRow {
  const RecapSectionRow(this.period, this.counts, this.state) : super(0);

  final RecapPeriod? period;
  final RecapCounts? counts;
  final RecapState? state;
}

/// Which cards are open, on this device for as long as the app runs. It is
/// never synced or written down.
class RecapFolds extends ChangeNotifier {
  final Set<RecapPeriod> _open = {};

  bool isOpen(RecapPeriod period) => _open.contains(period);

  /// Opens a folded card, or folds an open one.
  void toggle(RecapPeriod period) {
    if (!_open.remove(period)) _open.add(period);
    notifyListeners();
  }

  /// Opens every card in [periods], such as [RecapTimeline.holding] gives
  /// for a note that search or a link opens.
  void open(Iterable<RecapPeriod> periods) {
    var opened = false;
    for (final period in periods) {
      opened = _open.add(period) || opened;
    }
    if (opened) notifyListeners();
  }
}

/// The notes list as the timeline's rail lays it out. Today and the rest of
/// this week go day by day. Then come this month's earlier weeks, this
/// year's earlier months and the earlier years, each folded into a card
/// that carries its counts and its recap's state.
///
/// A week goes under the month it ends in, as its heading does, and a
/// period with no notes has no row. This week has no row of its own, and
/// this month and year head their earlier periods from below it. In
/// January, where the month and the year start on the same day, only the
/// year heads them.
///
/// It counts the [notes] it is given that are not hidden or archived, as
/// [RecapCounts.of] does, so pass NotesStore's active notes: never notes
/// waiting to be deleted.
class RecapTimeline {
  RecapTimeline({
    required List<Note> notes,
    required TaskBoard tasks,
    required DateTime Function(DateTime) displayTime,
    required this.firstWeekday,
    required DateTime now,
    DateTime? Function(Note note)? ownDay,
    Iterable<KapyChat> chats = const [],
    RecapProgress? Function(RecapPeriod period)? making,
  }) : _now = displayTime(now),
       _making = making {
    today = DateTime(_now.year, _now.month, _now.day);
    week = _period(today, RecapKind.week);
    month = _period(today, RecapKind.month);
    year = _period(today, RecapKind.year);
    final visible = <String>{};
    for (final note in notes) {
      if (note.isHidden || note.isArchived) continue;
      visible.add(note.id);
      final day = noteDay(note, displayTime, ownDay: ownDay?.call(note));
      var tally = _days[_number(day)];
      if (tally == null) {
        _days[_number(day)] = tally = _Day();
        _years
          ..add(day.year)
          ..add(_period(day, RecapKind.week).last.year);
      }
      tally.notes.add(note);
      for (final voice in note.attachments.whereType<NoteVoiceRef>()) {
        tally.voiceNotes++;
        tally.voiceMs += voice.durationMs;
      }
      _dayOf[note.id] = day;
    }
    for (final item in tasks.done) {
      final at = item.doneAt;
      if (at == null || !visible.contains(item.note.id)) continue;
      (_days[_number(dayShown(at, displayTime))] ??= _Day()).tasksDone++;
    }
    for (final chat in chats) {
      final record = recapOf(chat);
      if (record == null) continue;
      final best = _recaps[record.period];
      if (best == null || record.madeAt.isAfter(best.madeAt)) {
        _recaps[record.period] = (chat: chat, madeAt: record.madeAt);
      }
    }
  }

  /// The [DateTime.weekday] weeks start on.
  final int firstWeekday;

  /// Today, and the week, month and year still going.
  late final DateTime today;
  late final RecapPeriod week;
  late final RecapPeriod month;
  late final RecapPeriod year;

  final DateTime _now;
  final RecapProgress? Function(RecapPeriod period)? _making;
  final Map<int, _Day> _days = {};
  final Map<String, DateTime> _dayOf = {};
  final Set<int> _years = {};
  final Map<RecapPeriod, ({KapyChat chat, DateTime madeAt})> _recaps = {};
  final Map<RecapPeriod, RecapCounts> _counts = {};

  /// The rows the rail draws, with the cards [folds] has open opened.
  List<RecapRow> rows(RecapFolds folds) {
    final rows = <RecapRow>[];
    _addDays(rows, week, 0);
    void section(RecapPeriod? period, List<RecapPeriod> cards) {
      if (cards.isEmpty) return;
      rows.add(
        RecapSectionRow(
          period,
          period == null ? null : countsOf(period),
          period == null ? null : stateOf(period),
        ),
      );
      for (final card in cards) {
        _addCard(rows, folds, card, 0);
      }
    }

    final weeks = _weeksIn(month);
    if (month.first == year.first) {
      section(year, weeks);
    } else {
      section(month, weeks);
      section(year, _monthsIn(year.first.year));
    }
    section(null, [
      for (final number in _years.toList()..sort((a, b) => b - a))
        if (number < year.first.year) ?_shownYear(number),
    ]);
    return rows;
  }

  /// The cards, outermost first, that fold the note [noteId] away, so that
  /// opening them all shows it. None when it sits in this week, or isn't on
  /// the timeline.
  List<RecapPeriod> holding(String noteId) {
    final day = _dayOf[noteId];
    if (day == null || !day.isBefore(week.first)) return const [];
    final itsWeek = _period(day, RecapKind.week);
    final itsMonth = _period(itsWeek.last, RecapKind.month);
    if (itsMonth == month) return [itsWeek];
    if (itsMonth.first.year == year.first.year) return [itsMonth, itsWeek];
    return [_period(itsWeek.last, RecapKind.year), itsMonth, itsWeek];
  }

  /// [period]'s counts, the same as [RecapCounts.of] gives.
  RecapCounts countsOf(RecapPeriod period) => _counts[period] ??= () {
    var notes = 0;
    var tasksDone = 0;
    var voiceNotes = 0;
    var voiceMs = 0;
    for (var n = _number(period.first); n <= _number(period.last); n++) {
      final day = _days[n];
      if (day == null) continue;
      notes += day.notes.length;
      tasksDone += day.tasksDone;
      voiceNotes += day.voiceNotes;
      voiceMs += day.voiceMs;
    }
    return RecapCounts(
      notes: notes,
      tasksDone: tasksDone,
      voiceNotes: voiceNotes,
      voiceMinutes: (voiceMs + 59999) ~/ 60000,
    );
  }();

  /// What [period]'s recap icon shows: one being made first, then one
  /// made, then a period still going, then too little.
  RecapState stateOf(RecapPeriod period) {
    if (_making?.call(period) case final progress?) {
      return RecapState._(
        RecapStage.making,
        made: progress.made,
        parts: progress.parts,
      );
    }
    if (_recaps[period] case final recap?) {
      return RecapState._(RecapStage.made, chat: recap.chat);
    }
    if (period.isOngoing(today)) {
      return RecapState._(RecapStage.going, passed: period.elapsed(_now));
    }
    return countsOf(period).tooLittleFor(period.kind)
        ? const RecapState._(RecapStage.tooLittle)
        : const RecapState._(RecapStage.ready);
  }

  void _addCard(
    List<RecapRow> rows,
    RecapFolds folds,
    RecapPeriod period,
    int depth,
  ) {
    final open = folds.isOpen(period);
    rows.add(
      RecapGroupRow(
        period,
        countsOf(period),
        stateOf(period),
        open: open,
        depth: depth,
      ),
    );
    if (!open) return;
    switch (period.kind) {
      case RecapKind.day:
        break;
      case RecapKind.week:
        _addDays(rows, period, depth + 1);
      case RecapKind.month:
        for (final week in _weeksIn(period)) {
          _addCard(rows, folds, week, depth + 1);
        }
      case RecapKind.year:
        for (final month in _monthsIn(period.first.year)) {
          _addCard(rows, folds, month, depth + 1);
        }
    }
  }

  /// [span]'s days up to today that have notes, newest first.
  void _addDays(List<RecapRow> rows, RecapPeriod span, int depth) {
    final last = span.last.isAfter(today) ? today : span.last;
    for (
      var day = last;
      !day.isBefore(span.first);
      day = DateTime(day.year, day.month, day.day - 1)
    ) {
      final notes = _days[_number(day)]?.notes;
      if (notes == null || notes.isEmpty) continue;
      final period = _period(day, RecapKind.day);
      rows.add(
        RecapDayRow(
          period,
          countsOf(period),
          stateOf(period),
          List.unmodifiable(notes),
          depth: depth,
        ),
      );
    }
  }

  /// The weeks before this one that end in [span] and have notes, newest
  /// first.
  List<RecapPeriod> _weeksIn(RecapPeriod span) {
    var week = _period(span.last, RecapKind.week);
    if (week.last.isAfter(span.last)) week = week.previous;
    return [
      for (; !week.last.isBefore(span.first); week = week.previous)
        if (week.first.isBefore(this.week.first) && countsOf(week).notes > 0)
          week,
    ];
  }

  /// [number]'s months before this one that have notes, or weeks with
  /// notes under them, newest first.
  List<RecapPeriod> _monthsIn(int number) => [
    for (var index = 12; index >= 1; index--)
      if (_period(DateTime(number, index), RecapKind.month) case final month
          when month.first.isBefore(this.month.first) &&
              (countsOf(month).notes > 0 || _weeksIn(month).isNotEmpty))
        month,
  ];

  RecapPeriod? _shownYear(int number) {
    final period = _period(DateTime(number), RecapKind.year);
    return countsOf(period).notes > 0 || _monthsIn(number).isNotEmpty
        ? period
        : null;
  }

  RecapPeriod _period(DateTime day, RecapKind kind) =>
      RecapPeriod.containing(day, kind, firstWeekday: firstWeekday);

  /// [date]'s calendar day as a number, whole days since 1 January 1970.
  static int _number(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
}

/// What one day holds, counted once so that every period sums its days.
class _Day {
  final List<Note> notes = [];
  int tasksDone = 0;
  int voiceNotes = 0;
  int voiceMs = 0;
}
