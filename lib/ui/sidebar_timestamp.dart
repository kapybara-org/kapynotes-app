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
  /// around it.
  static String glance(
    DateTime timestamp, {
    required DateTime now,
    required DateTime Function(DateTime) displayTime,
    bool today = false,
  }) {
    final shown = displayTime(timestamp);
    final current = displayTime(now);
    final days = DateTime.utc(
      current.year,
      current.month,
      current.day,
    ).difference(DateTime.utc(shown.year, shown.month, shown.day)).inDays;
    if (days <= 0) {
      final hour = shown.hour.toString().padLeft(2, '0');
      final minute = shown.minute.toString().padLeft(2, '0');
      return today ? 'Today · $hour:$minute' : '$hour:$minute';
    }
    if (days == 1) return 'Yesterday';
    if (days < 7) return _weekdays[shown.weekday - 1];
    final day = '${shown.day} ${_months[shown.month - 1]}';
    return shown.year == current.year ? day : '$day ${shown.year}';
  }
}
