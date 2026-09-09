import '../data/time_zones.dart';
import 'unit.dart';
import 'value.dart';

/// The small amount of grammar that is intrinsically wall-clock shaped.
/// Numeric date arithmetic (`today + 2 weeks`, `fromunix(0)`) stays in the
/// normal parser; this recognises clock literals and named-zone readouts that
/// cannot be represented as ordinary arithmetic tokens.
class TemporalExpressions {
  static final RegExp _timeInZonePattern = RegExp(
    r'^(time|now)\s+(?:in|at)\s+(.+)$',
    caseSensitive: false,
  );
  static final RegExp _zoneTimePattern = RegExp(
    r'^(.+?)\s+(time|now)$',
    caseSensitive: false,
  );
  static final RegExp _clockPattern = RegExp(
    r'^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?(?:\s+(.+))?$',
    caseSensitive: false,
  );
  static final RegExp _targetZonePattern = RegExp(
    r'^(?:in|to)\s+(.+)$',
    caseSensitive: false,
  );
  static final RegExp _zoneConversionPattern = RegExp(
    r'^(.+?)\s+(?:in|to)\s+(.+)$',
    caseSensitive: false,
  );
  static final RegExp _differencePattern = RegExp(r'^(.+?)\s+-\s+(.+)$');

  static final Unit _hours = Unit.single(
    UnitDef(
      symbol: 'h',
      dimension: Dimension.base(Dimension.time),
      factor: 3600,
      aliases: const ['h', 'hour'],
      category: 'time',
    ),
  );

  final DateTime Function() now;
  final String? defaultTimeZoneId;

  const TemporalExpressions({
    required this.now,
    required this.defaultTimeZoneId,
  });

  CalcValue? evaluate(String raw) {
    final source = raw.trim();
    if (source.isEmpty) return null;
    final reference = now();
    return _timeDifference(source, reference) ??
        _currentTime(source, reference) ??
        _clockTime(source, reference);
  }

  CalcValue? _timeDifference(String source, DateTime reference) {
    final match = _differencePattern.firstMatch(source);
    if (match == null) return null;
    final left = _currentTime(match.group(1)!, reference);
    final right = _currentTime(match.group(2)!, reference);
    if (left == null || right == null) return null;

    // Current times describe wall clocks. Compare their displayed calendar
    // fields rather than their shared instant to expose the zone difference.
    final leftWall = AppTimeZones.convert(left.instant, left.timeZoneId);
    final rightWall = AppTimeZones.convert(right.instant, right.timeZoneId);
    final leftNominal = DateTime.utc(
      leftWall.year,
      leftWall.month,
      leftWall.day,
      leftWall.hour,
      leftWall.minute,
      leftWall.second,
      leftWall.millisecond,
      leftWall.microsecond,
    );
    final rightNominal = DateTime.utc(
      rightWall.year,
      rightWall.month,
      rightWall.day,
      rightWall.hour,
      rightWall.minute,
      rightWall.second,
      rightWall.millisecond,
      rightWall.microsecond,
    );
    final hours = leftNominal.difference(rightNominal).inMicroseconds / 3.6e9;
    return QuantityValue(hours, _hours);
  }

  DateTimeValue? _currentTime(String source, DateTime reference) {
    final inZone = _timeInZonePattern.firstMatch(source);
    if (inZone != null) {
      final zone = CalcTimeZones.resolve(inZone.group(2)!);
      if (zone == null) return null;
      return DateTimeValue(
        reference.toUtc(),
        timeZoneId: zone,
        display: inZone.group(1)!.toLowerCase() == 'time'
            ? TemporalDisplay.time
            : TemporalDisplay.dateTime,
      );
    }

    final prefixed = _zoneTimePattern.firstMatch(source);
    if (prefixed == null) return null;
    final zone = CalcTimeZones.resolve(prefixed.group(1)!);
    if (zone == null) return null;
    return DateTimeValue(
      reference.toUtc(),
      timeZoneId: zone,
      display: prefixed.group(2)!.toLowerCase() == 'time'
          ? TemporalDisplay.time
          : TemporalDisplay.dateTime,
    );
  }

  DateTimeValue? _clockTime(String source, DateTime reference) {
    final match = _clockPattern.firstMatch(source);
    if (match == null) return null;

    var hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final second = int.tryParse(match.group(3) ?? '') ?? 0;
    final meridiem = match.group(4)?.toLowerCase();
    if (minute > 59 || second > 59) return null;
    if (meridiem != null) {
      if (hour < 1 || hour > 12) return null;
      hour %= 12;
      if (meridiem == 'pm') hour += 12;
    } else if (hour > 23) {
      return null;
    }

    final zones = _splitZones(match.group(5));
    if (zones == null) return null;
    final explicitSource = zones.source == null
        ? null
        : CalcTimeZones.resolve(zones.source!);
    final target = zones.target == null
        ? null
        : CalcTimeZones.resolve(zones.target!);
    if (zones.source != null && explicitSource == null) return null;
    if (zones.target != null && target == null) return null;

    // `2:30 pm in New York` states a New York time. When both sides are
    // present (`2:30 pm HKT in Berlin`), HKT is the source and Berlin the
    // presentation zone.
    final sourceZone = explicitSource ?? target ?? defaultTimeZoneId;
    final displayZone = target ?? explicitSource ?? defaultTimeZoneId;
    final today = AppTimeZones.convert(reference, sourceZone);
    final instant = AppTimeZones.fromWallClock(
      year: today.year,
      month: today.month,
      day: today.day,
      hour: hour,
      minute: minute,
      second: second,
      locationId: sourceZone,
    );
    return DateTimeValue(
      instant,
      timeZoneId: displayZone,
      display: TemporalDisplay.time,
    );
  }

  static ({String? source, String? target})? _splitZones(String? raw) {
    final rest = raw?.trim();
    if (rest == null || rest.isEmpty) return (source: null, target: null);

    final targetOnly = _targetZonePattern.firstMatch(rest);
    if (targetOnly != null) {
      return (source: null, target: targetOnly.group(1)!.trim());
    }

    final conversion = _zoneConversionPattern.firstMatch(rest);
    if (conversion != null) {
      return (
        source: conversion.group(1)!.trim(),
        target: conversion.group(2)!.trim(),
      );
    }
    return (source: rest, target: null);
  }
}

/// Friendly names layered over the bundled IANA database. Abbreviations map
/// to regions rather than fixed offsets so summer/winter results remain
/// correct; the formatter displays the actual abbreviation for the date.
class CalcTimeZones {
  const CalcTimeZones._();

  static const Map<String, String> _aliases = {
    'utc': 'UTC',
    'gmt': 'UTC',
    'pst': 'America/Los_Angeles',
    'pdt': 'America/Los_Angeles',
    'pt': 'America/Los_Angeles',
    'mst': 'America/Denver',
    'mdt': 'America/Denver',
    'mt': 'America/Denver',
    'cst': 'America/Chicago',
    'cdt': 'America/Chicago',
    'ct': 'America/Chicago',
    'est': 'America/New_York',
    'edt': 'America/New_York',
    'et': 'America/New_York',
    'ist': 'Asia/Kolkata',
    'hkt': 'Asia/Hong_Kong',
    'jst': 'Asia/Tokyo',
    'kst': 'Asia/Seoul',
    'cet': 'Europe/Berlin',
    'cest': 'Europe/Berlin',
    'bst': 'Europe/London',
    'aest': 'Australia/Sydney',
    'aedt': 'Australia/Sydney',
    'nzst': 'Pacific/Auckland',
    'nzdt': 'Pacific/Auckland',
  };

  static Map<String, String>? _locations;

  static String? resolve(String raw) {
    final query = _key(raw);
    if (query.isEmpty) return null;
    final alias = _aliases[query];
    if (alias != null) return alias;

    final locations = _locations ??= _buildLocations();
    return locations[query];
  }

  static Map<String, String> _buildLocations() {
    final byName = <String, String>{};
    final ambiguous = <String>{};
    for (final id in AppTimeZones.locationIds) {
      final full = _key(id.replaceAll('_', ' ').replaceAll('/', ' '));
      byName[full] = id;

      final city = _key(id.split('/').last.replaceAll('_', ' '));
      final previous = byName[city];
      if (previous == null) {
        byName[city] = id;
      } else if (previous != id) {
        ambiguous.add(city);
      }
    }
    for (final key in ambiguous) {
      byName.remove(key);
    }
    return byName;
  }

  static String _key(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}
