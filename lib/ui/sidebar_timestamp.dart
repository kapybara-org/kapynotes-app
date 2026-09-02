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
