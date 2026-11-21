/// Compact, fixed-width-friendly timestamps for the note list.
class SidebarTimestamp {
  const SidebarTimestamp._();

  static const _months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// A day with no time on it, for anything dated rather than timed — the
  /// releases in Settings › Updates. Same table of months, so a date reads
  /// the same wherever the app writes one.
  static String formatDay(DateTime day) =>
      '${day.day} ${_months[day.month - 1]} ${day.year}';

  static String format(
    DateTime timestamp, {
    required DateTime Function(DateTime) displayTime,
  }) {
    final displayed = displayTime(timestamp);
    final hour = displayed.hour.toString().padLeft(2, '0');
    final minute = displayed.minute.toString().padLeft(2, '0');
    return '${displayed.day} ${_months[displayed.month - 1]} ${displayed.year} · $hour:$minute';
  }

  static const _weekdays = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  /// When a note was changed, as briefly as the notes list can say it: the
  /// time today, Yesterday, the weekday within the week, then the date, with
  /// the year only when it is not this one. [today] spells out "Today" before
  /// the time, for a card, where the time stands without a column of dates
  /// around it; without [clock], a card short of room, it is "Today" alone.
  static String glance(
    DateTime timestamp, {
    required DateTime now,
    required DateTime Function(DateTime) displayTime,
    bool today = false,
    bool clock = true,
  }) {
    final shown = displayTime(timestamp);
    final current = displayTime(now);
    final days = _daysBetween(shown, current);
    if (days <= 0) {
      if (!today) return _clock(shown);
      return clock ? 'Today, ${_clock(shown)}' : 'Today';
    }
    if (days == 1) return 'Yesterday';
    if (days < 7) return _weekdays[shown.weekday - 1];
    final day = '${shown.day} ${_months[shown.month - 1]}';
    return shown.year == current.year ? day : '$day ${shown.year}';
  }

  /// The row under a note's title: "Edited today, 11:15" or "Edited
  /// yesterday, 09:02", then the weekday or the date as [glance] has them.
  static String edited(
    DateTime timestamp, {
    required DateTime now,
    required DateTime Function(DateTime) displayTime,
  }) {
    final shown = displayTime(timestamp);
    return switch (_daysBetween(shown, displayTime(now))) {
      <= 0 => 'Edited today, ${_clock(shown)}',
      1 => 'Edited yesterday, ${_clock(shown)}',
      _ => 'Edited ${glance(timestamp, now: now, displayTime: displayTime)}',
    };
  }

  static const _monthNames = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static const _weekdayNames = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  /// A day spelt out, as over Tasks' one list: "Tuesday, 17 November".
  static String fullDay(DateTime shown) =>
      '${_weekdayNames[shown.weekday - 1]}, ${shown.day} '
      '${_monthNames[shown.month - 1]}';

  /// The weekday and the date, as beside Today on Tasks: "Wed 19".
  static String dayAndDate(DateTime shown) =>
      '${_weekdays[shown.weekday - 1]} ${shown.day}';

  /// A day in a few letters, as a task says when it was added: "Sat 14 Nov",
  /// with the year only when it is not this one.
  static String shortDay(DateTime shown, {required DateTime now}) {
    final day =
        '${_weekdays[shown.weekday - 1]} ${shown.day} ${_months[shown.month - 1]}';
    return shown.year == now.year ? day : '$day ${shown.year}';
  }

  /// The heading over a day of notes, and the date beside it: "Today" with
  /// "Thu 19 Nov", "Yesterday" with "Wed 18", then the weekday and the day
  /// alone within the week ("Tue 17"), and the date before that, with the
  /// year when it is not this one ("Mon 9 Nov").
  static (String, String?) dayHeading(DateTime day, {required DateTime today}) {
    final short = weekdayAndDay(day);
    return switch (_daysBetween(day, today)) {
      0 => ('Today', shortDay(day, now: today)),
      1 => ('Yesterday', short),
      > 1 && < 7 => (short, null),
      _ => (shortDay(day, now: today), null),
    };
  }

  /// A weekday in three letters: "Wed".
  static String shortWeekday(DateTime day) => _weekdays[day.weekday - 1];

  /// A weekday and its date alone, as within the week: "Wed 19".
  static String weekdayAndDay(DateTime day) =>
      '${_weekdays[day.weekday - 1]} ${day.day}';

  /// A run of days in a few letters: "10–16 Nov", or "30 Nov – 6 Dec" across
  /// two months.
  static String dayRange(DateTime first, DateTime last) =>
      first.month == last.month
      ? '${first.day}–${last.day} ${_months[last.month - 1]}'
      : '${first.day} ${_months[first.month - 1]} – '
            '${last.day} ${_months[last.month - 1]}';

  /// A month's name: "November".
  static String monthName(DateTime day) => _monthNames[day.month - 1];

  /// The heading over a day of finished tasks: "Today", "Yesterday · Monday,
  /// 16 Nov", then "Sunday, 15 Nov", with the year when it is not this one.
  static String doneDay(DateTime shown, {required DateTime now}) {
    final days = _daysBetween(shown, now);
    if (days <= 0) return 'Today';
    final year = shown.year == now.year ? '' : ' ${shown.year}';
    final day =
        '${_weekdayNames[shown.weekday - 1]}, ${shown.day} '
        '${_months[shown.month - 1]}$year';
    return days == 1 ? 'Yesterday · $day' : day;
  }

  /// The time of day on a 24-hour clock: "16:05".
  static String clock(DateTime shown) => _clock(shown);

  static int _daysBetween(DateTime shown, DateTime current) => DateTime.utc(
    current.year,
    current.month,
    current.day,
  ).difference(DateTime.utc(shown.year, shown.month, shown.day)).inDays;

  static String _clock(DateTime shown) =>
      '${shown.hour.toString().padLeft(2, '0')}:'
      '${shown.minute.toString().padLeft(2, '0')}';
}
