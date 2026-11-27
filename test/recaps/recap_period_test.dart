import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/time_zones.dart';
import 'package:kapy_notes/recaps/recap_period.dart';

void main() {
  RecapPeriod week(DateTime day, int firstWeekday) =>
      RecapPeriod.containing(day, RecapKind.week, firstWeekday: firstWeekday);
  RecapPeriod of(DateTime day, RecapKind kind) =>
      RecapPeriod.containing(day, kind, firstWeekday: DateTime.monday);

  group('a week', () {
    test('starts on Monday or on Sunday, as the app does', () {
      final monday = week(DateTime(2026, 11, 19), DateTime.monday);
      expect(
        (monday.first, monday.last),
        (DateTime(2026, 11, 16), DateTime(2026, 11, 22)),
      );
      expect(monday.label, '16–22 Nov');

      final sunday = week(DateTime(2026, 11, 19), DateTime.sunday);
      expect(
        (sunday.first, sunday.last),
        (DateTime(2026, 11, 15), DateTime(2026, 11, 21)),
      );
      expect(sunday.label, '15–21 Nov');
    });

    test('holds its own first and last day', () {
      expect(week(DateTime(2026, 11, 16), DateTime.monday).first.day, 16);
      expect(week(DateTime(2026, 11, 22), DateTime.monday).first.day, 16);
      expect(week(DateTime(2026, 11, 15), DateTime.sunday).first.day, 15);
      expect(week(DateTime(2026, 11, 21), DateTime.sunday).last.day, 21);
    });

    test('across two months says both', () {
      final period = week(DateTime(2026, 11, 1), DateTime.monday);
      expect(
        (period.first, period.last),
        (DateTime(2026, 10, 26), DateTime(2026, 11, 1)),
      );
      expect(period.label, '26 Oct – 1 Nov');
      expect(period.days, 7);
    });

    test('across the new year', () {
      final monday = week(DateTime(2026, 12, 31), DateTime.monday);
      expect(
        (monday.first, monday.last),
        (DateTime(2026, 12, 28), DateTime(2027, 1, 3)),
      );
      expect(monday.label, '28 Dec – 3 Jan');
      expect(monday.contains(DateTime(2027, 1, 3)), isTrue);
      expect(monday.contains(DateTime(2027, 1, 4)), isFalse);

      final sunday = week(DateTime(2027, 1, 1), DateTime.sunday);
      expect(
        (sunday.first, sunday.last),
        (DateTime(2026, 12, 27), DateTime(2027, 1, 2)),
      );
    });

    test('steps back and on by whole weeks, keeping its first weekday', () {
      final period = week(DateTime(2026, 11, 19), DateTime.sunday);
      expect(period.previous, week(DateTime(2026, 11, 8), DateTime.sunday));
      expect(period.next, week(DateTime(2026, 11, 22), DateTime.sunday));
      expect(period.next.next.previous.previous, period);
      expect(
        week(DateTime(2026, 12, 31), DateTime.monday).next,
        week(DateTime(2027, 1, 4), DateTime.monday),
      );
    });
  });

  test('a day, a month and a year, with their labels', () {
    final day = of(DateTime(2026, 11, 19, 15, 30), RecapKind.day);
    expect(
      (day.first, day.last),
      (DateTime(2026, 11, 19), DateTime(2026, 11, 19)),
    );
    expect(day.label, 'Thu 19');

    final month = of(DateTime(2026, 11, 19), RecapKind.month);
    expect(
      (month.first, month.last),
      (DateTime(2026, 11), DateTime(2026, 11, 30)),
    );
    expect(month.label, 'November');
    expect(month.previous.label, 'October');
    expect(
      of(DateTime(2027, 1, 5), RecapKind.month).previous.first,
      DateTime(2026, 12),
    );

    final year = of(DateTime(2026, 11, 19), RecapKind.year);
    expect((year.first, year.last), (DateTime(2026), DateTime(2026, 12, 31)));
    expect(year.label, '2026');
    expect(year.days, 365);
    expect(year.next.label, '2027');
  });

  test('a leap day is a day of its own, in a 29-day February', () {
    final leap = of(DateTime(2028, 2, 29), RecapKind.day);
    expect(leap.label, 'Tue 29');
    expect(leap.previous.first, DateTime(2028, 2, 28));
    expect(leap.next.first, DateTime(2028, 3, 1));

    final february = of(DateTime(2028, 2, 29), RecapKind.month);
    expect(february.last, DateTime(2028, 2, 29));
    expect(february.days, 29);
    expect(february.next.first, DateTime(2028, 3));
    expect(of(DateTime(2026, 2, 10), RecapKind.month).days, 28);
    expect(of(DateTime(2028, 6, 1), RecapKind.year).days, 366);

    final week = RecapPeriod.containing(
      DateTime(2028, 2, 29),
      RecapKind.week,
      firstWeekday: DateTime.monday,
    );
    expect(
      (week.first, week.last),
      (DateTime(2028, 2, 28), DateTime(2028, 3, 5)),
    );
    expect(week.label, '28 Feb – 5 Mar');
  });

  group('still going', () {
    final period = of(DateTime(2026, 11, 19), RecapKind.week);

    test('while today is one of its days', () {
      expect(period.isOngoing(DateTime(2026, 11, 16)), isTrue);
      expect(period.isOngoing(DateTime(2026, 11, 22, 23, 59)), isTrue);
      expect(period.isOngoing(DateTime(2026, 11, 23)), isFalse);
      expect(period.isOngoing(DateTime(2026, 11, 15, 23, 59)), isFalse);
    });

    test('has passed a share of its days, from none to all', () {
      expect(period.elapsed(DateTime(2026, 11, 15, 12)), 0);
      expect(period.elapsed(DateTime(2026, 11, 16)), 0);
      expect(period.elapsed(DateTime(2026, 11, 19, 12)), 0.5);
      expect(period.elapsed(DateTime(2026, 11, 23)), 1);
      expect(
        of(
          DateTime(2026, 11, 19),
          RecapKind.day,
        ).elapsed(DateTime(2026, 11, 19, 18)),
        0.75,
      );
    });
  });

  group('time zones', () {
    DateTime shown(String zone, String instant) =>
        AppTimeZones.convert(DateTime.parse(instant), zone);

    test('New York keeps its days whole across both switches', () {
      final spring = RecapPeriod.containing(
        DateTime(2026, 3, 8),
        RecapKind.week,
        firstWeekday: DateTime.sunday,
      );
      expect(spring.days, 7);
      expect(spring.indexOf(DateTime(2026, 3, 9)), 1);
      expect(spring.label, '8–14 Mar');
      expect(spring.previous.label, '1–7 Mar');
      expect(
        spring.contains(shown('America/New_York', '2026-03-08T04:30:00Z')),
        isFalse,
      );
      expect(
        spring.contains(shown('America/New_York', '2026-03-09T03:30:00Z')),
        isTrue,
      );

      final fall = of(DateTime(2026, 11, 1), RecapKind.day);
      expect(fall.next.label, 'Mon 2');
      final lateOnFallDay = shown('America/New_York', '2026-11-02T04:30:00Z');
      expect(fall.contains(lateOnFallDay), isTrue);
      expect(fall.elapsed(lateOnFallDay), closeTo(23.5 / 24, 1e-9));
      expect(
        fall.isOngoing(shown('America/New_York', '2026-11-02T05:30:00Z')),
        isFalse,
      );
    });

    test('London keeps its days whole across both switches', () {
      final spring = of(DateTime(2026, 3, 29), RecapKind.day);
      expect(
        spring.contains(shown('Europe/London', '2026-03-29T22:30:00Z')),
        isTrue,
      );
      expect(
        spring.contains(shown('Europe/London', '2026-03-29T23:30:00Z')),
        isFalse,
      );
      final autumn = of(DateTime(2026, 10, 25), RecapKind.week);
      expect(autumn.label, '19–25 Oct');
      expect(
        autumn.contains(shown('Europe/London', '2026-10-25T23:30:00Z')),
        isTrue,
      );
      expect(autumn.next.first, DateTime(2026, 10, 26));
    });

    test('India, with no switch, takes the day by its own clock', () {
      final day = of(DateTime(2026, 11, 19), RecapKind.day);
      expect(
        day.contains(shown('Asia/Kolkata', '2026-11-18T18:45:00Z')),
        isTrue,
      );
      expect(
        day.contains(shown('Asia/Kolkata', '2026-11-18T18:15:00Z')),
        isFalse,
      );
    });
  });
}
