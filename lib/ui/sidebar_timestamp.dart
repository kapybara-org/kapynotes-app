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
}
