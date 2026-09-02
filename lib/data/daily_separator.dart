/// The compact, plain-text section marker used to separate editing sessions.
///
/// It deliberately starts with `//`, so the existing comment highlighter
/// makes it quiet and the calculator ignores it. Keeping the marker in the
/// note body also means exports remain understandable outside Kapy Notes.
class DailySeparator {
  const DailySeparator._();

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

  static final RegExp _linePattern = RegExp(r'^// ─+ .+ ─+$');

  static String line(
    DateTime timestamp, {
    DateTime Function(DateTime)? displayTime,
  }) {
    final displayed = (displayTime ?? _localTime)(timestamp);
    final hour = displayed.hour.toString().padLeft(2, '0');
    final minute = displayed.minute.toString().padLeft(2, '0');
    return '// ─ ${displayed.day} ${_months[displayed.month - 1]} · $hour:$minute ─';
  }

  static bool isLine(String value) => _linePattern.hasMatch(value.trim());

  static bool isSameDay(
    DateTime first,
    DateTime second, {
    DateTime Function(DateTime)? displayTime,
  }) {
    final convert = displayTime ?? _localTime;
    final a = convert(first);
    final b = convert(second);
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Prepares the unsaved append position used when an existing note opens.
  /// There is one empty line between the previous text and the caret. A
  /// separator left empty by an older app version is hidden and will be
  /// removed permanently if the user types.
  static String prepareForAppend(String body) {
    final content = _withoutTrailingEmptySection(body);
    if (content.trim().isEmpty || content.endsWith('\n\n')) return content;
    return content.endsWith('\n') ? '$content\n' : '$content\n\n';
  }

  /// Returns an unused generated separator at the end of [body]. Older app
  /// versions wrote these on launch. The editor can keep it hidden until real
  /// content is appended, then reuse the accurate original boundary.
  static String? trailingEmptySectionLine(String body) {
    final lines = body.split('\n');
    final index = _trailingEmptySectionIndex(lines);
    return index == null ? null : lines[index].trim();
  }

  /// Appends a marker and leaves the caret-ready trailing newline in place.
  /// Reopening before anything is typed never stacks empty sections.
  static String append(
    String body,
    DateTime lastUpdatedAt, {
    DateTime Function(DateTime)? displayTime,
  }) => appendLine(body, line(lastUpdatedAt, displayTime: displayTime));

  static String appendLine(String body, String separatorLine) {
    if (body.trim().isEmpty) return body;
    if (!isLine(separatorLine)) return body;

    final lastNonEmpty = body
        .split('\n')
        .reversed
        .map((line) => line.trimRight())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (isLine(lastNonEmpty)) {
      return body.endsWith('\n') ? body : '$body\n';
    }

    final withoutTrailingNewlines = body.replaceFirst(RegExp(r'\n+$'), '');
    return '$withoutTrailingNewlines\n\n${separatorLine.trim()}\n';
  }

  static String _withoutTrailingEmptySection(String body) {
    final lines = body.split('\n');
    final separatorIndex = _trailingEmptySectionIndex(lines);
    if (separatorIndex == null) return body;

    var lastContentLine = separatorIndex - 1;
    while (lastContentLine >= 0 && lines[lastContentLine].trim().isEmpty) {
      lastContentLine--;
    }
    return lines.take(lastContentLine + 1).join('\n');
  }

  static int? _trailingEmptySectionIndex(List<String> lines) {
    var index = lines.length - 1;
    while (index >= 0 && lines[index].trim().isEmpty) {
      index--;
    }
    return index >= 0 && isLine(lines[index]) ? index : null;
  }

  static DateTime _localTime(DateTime value) => value.toLocal();
}
