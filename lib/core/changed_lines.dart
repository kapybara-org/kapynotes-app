import 'dart:math' as math;

/// Where [after] differs from [before], widened to whole lines: the text from
/// `start` to `oldEnd` in [before] became the text from `start` to
/// `newEnd` in [after], and everything around them is the same in both.
/// Each stretch begins at the start of a line and ends at a line break or at
/// the end of its text.
({int start, int oldEnd, int newEnd}) changedLines(
  String before,
  String after,
) {
  final shorter = math.min(before.length, after.length);
  var prefix = 0;
  while (prefix < shorter &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shorter - prefix &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  final start = prefix == 0 ? 0 : after.lastIndexOf('\n', prefix - 1) + 1;
  final tail = after.indexOf('\n', after.length - suffix);
  final newEnd = tail < 0 ? after.length : tail;
  return (
    start: start,
    oldEnd: newEnd - after.length + before.length,
    newEnd: newEnd,
  );
}
