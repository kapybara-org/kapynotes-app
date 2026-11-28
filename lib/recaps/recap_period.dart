import 'package:flutter/foundation.dart';

import '../ui/sidebar_timestamp.dart';

/// How long a recap reaches over. Notes, tasks done and voice notes together
/// fewer than [least] are too little for one.
enum RecapKind {
  day(3),
  week(5),
  month(10),
  year(30);

  const RecapKind(this.least);

  final int least;
}

/// The days a recap covers, [first] to [last] and both included, as calendar
/// dates in the person's own time.
///
/// Worked out on the dates alone, never by adding hours, so a day that
/// daylight saving made 23 or 25 hours long is still one day.
@immutable
class RecapPeriod {
  const RecapPeriod._(this.kind, this.first, this.last);

  /// The period of [kind] that holds [date], with weeks starting on
  /// [firstWeekday], a [DateTime.weekday].
  factory RecapPeriod.containing(
    DateTime date,
    RecapKind kind, {
    required int firstWeekday,
  }) {
    final year = date.year;
    final month = date.month;
    final day = date.day;
    final week = day - (date.weekday - firstWeekday) % 7;
    return switch (kind) {
      RecapKind.day => RecapPeriod._(
        kind,
        DateTime(year, month, day),
        DateTime(year, month, day),
      ),
      RecapKind.week => RecapPeriod._(
        kind,
        DateTime(year, month, week),
        DateTime(year, month, week + 6),
      ),
      RecapKind.month => RecapPeriod._(
        kind,
        DateTime(year, month),
        DateTime(year, month + 1, 0),
      ),
      RecapKind.year => RecapPeriod._(
        kind,
        DateTime(year),
        DateTime(year, 12, 31),
      ),
    };
  }

  final RecapKind kind;
  final DateTime first;
  final DateTime last;

  /// The period of the same kind just before this one.
  RecapPeriod get previous => RecapPeriod.containing(
    DateTime(first.year, first.month, first.day - 1),
    kind,
    firstWeekday: first.weekday,
  );

  /// The period of the same kind just after this one.
  RecapPeriod get next => RecapPeriod.containing(
    DateTime(last.year, last.month, last.day + 1),
    kind,
    firstWeekday: first.weekday,
  );

  /// How many days it covers.
  int get days => _number(last) - _number(first) + 1;

  /// Which of its [days] [date] is, from 0, or null when it is outside.
  int? indexOf(DateTime date) {
    final index = _number(date) - _number(first);
    return index >= 0 && index < days ? index : null;
  }

  bool contains(DateTime date) => indexOf(date) != null;

  /// Whether [today] is one of its days, so the period is still going.
  bool isOngoing(DateTime today) => contains(today);

  /// How much of it has passed at [now], a time as the person sees it, from
  /// 0 before it starts to 1 once it has ended: for the pie on a period
  /// still going.
  double elapsed(DateTime now) {
    final into =
        _number(now) - _number(first) + (now.hour * 60 + now.minute) / 1440;
    return (into / days).clamp(0, 1).toDouble();
  }

  /// What the drawer and the rows call it: "Wed 19", "17–23 Nov",
  /// "November" or "2026".
  String get label => switch (kind) {
    RecapKind.day => SidebarTimestamp.weekdayAndDay(first),
    RecapKind.week => SidebarTimestamp.dayRange(first, last),
    RecapKind.month => SidebarTimestamp.monthName(first),
    RecapKind.year => '${first.year}',
  };

  /// As a chat about the period keeps it: its kind and its first and last
  /// days.
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'first': _iso(first),
    'last': _iso(last),
  };

  /// Null for anything that is not exactly a period as [toJson] writes one:
  /// a record from another device is not trusted to hold one.
  static RecapPeriod? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = RecapKind.values.asNameMap()[raw['kind']];
    final first = _day(raw['first']);
    final last = _day(raw['last']);
    if (kind == null || first == null || last == null) return null;
    final period = RecapPeriod.containing(
      first,
      kind,
      firstWeekday: first.weekday,
    );
    return _number(period.first) == _number(first) &&
            _number(period.last) == _number(last)
        ? period
        : null;
  }

  static String _iso(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// A day written as [_iso] does, and only a real one: 30 February is not.
  static DateTime? _day(Object? raw) {
    if (raw is! String) return null;
    final parts = _isoDay.firstMatch(raw);
    if (parts == null) return null;
    final day = DateTime(
      int.parse(parts[1]!),
      int.parse(parts[2]!),
      int.parse(parts[3]!),
    );
    return _iso(day) == raw ? day : null;
  }

  static final RegExp _isoDay = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// [date]'s calendar day as a number, whole days since 1 January 1970.
  static int _number(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  @override
  bool operator ==(Object other) =>
      other is RecapPeriod &&
      other.kind == kind &&
      _number(other.first) == _number(first) &&
      _number(other.last) == _number(last);

  @override
  int get hashCode => Object.hash(kind, _number(first), _number(last));

  @override
  String toString() => 'RecapPeriod(${kind.name}, $label ${first.year})';
}
