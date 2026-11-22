import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/time_zones.dart';
import 'package:kapy_notes/ui/sidebar_timestamp.dart';

void main() {
  test('formats the exact updated date and time in the selected zone', () {
    final instant = DateTime.utc(2026, 9, 1, 18, 45);

    expect(
      SidebarTimestamp.format(
        instant,
        displayTime: (value) => AppTimeZones.convert(value, 'Asia/Kolkata'),
      ),
      '2 Sep 2026 · 0:15',
    );
    expect(
      SidebarTimestamp.format(
        instant,
        displayTime: (value) => AppTimeZones.convert(value, 'America/New_York'),
      ),
      '1 Sep 2026 · 14:45',
    );
  });

  test('glances at a date as briefly as the notes list can say it', () {
    final now = DateTime.utc(2026, 11, 16, 11, 20);
    String glance(DateTime at, {bool today = false}) => SidebarTimestamp.glance(
      at,
      now: now,
      displayTime: (value) => value,
      today: today,
    );

    expect(glance(DateTime.utc(2026, 11, 16, 9, 5)), '9:05');
    expect(
      glance(DateTime.utc(2026, 11, 16, 9, 5), today: true),
      'Today, 9:05',
    );
    expect(glance(DateTime.utc(2026, 11, 15, 23)), 'Yesterday');
    expect(glance(DateTime.utc(2026, 11, 14, 8)), 'Sat');
    expect(glance(DateTime.utc(2026, 11, 2, 8)), '2 Nov');
    expect(glance(DateTime.utc(2025, 12, 30, 8)), '30 Dec 2025');
  });

  test('heads a day of notes with its name and the date beside it', () {
    final today = DateTime(2026, 11, 19);
    (String, String?) heading(DateTime day) =>
        SidebarTimestamp.dayHeading(day, today: today);

    expect(heading(DateTime(2026, 11, 19)), ('Today', 'Thu 19 Nov'));
    expect(heading(DateTime(2026, 11, 18)), ('Yesterday', 'Wed 18'));
    expect(heading(DateTime(2026, 11, 17)), ('Tue 17', null));
    expect(heading(DateTime(2026, 11, 13)), ('Fri 13', null));
    expect(heading(DateTime(2026, 11, 12)), ('Thu 12 Nov', null));
    expect(heading(DateTime(2025, 12, 30)), ('Tue 30 Dec 2025', null));
    // Edited on a device whose clock runs ahead: dated, never "Today".
    expect(heading(DateTime(2026, 11, 20)), ('Fri 20 Nov', null));
  });

  test("heads a phone's day of notes, counting days by the calendar", () {
    ({String? lead, String date}) heading(DateTime day, DateTime now) =>
        SidebarTimestamp.phoneDay(day, now: now);
    final today = DateTime(2026, 11, 19, 12);

    expect(heading(DateTime(2026, 11, 19), today), (
      lead: 'Today',
      date: 'Thu 19',
    ));
    expect(heading(DateTime(2026, 11, 18), today), (
      lead: 'Yesterday',
      date: 'Wed 18',
    ));
    expect(heading(DateTime(2026, 11, 17), today), (
      lead: null,
      date: 'Tue 17 Nov',
    ));
    // A day still to come, from a device whose clock runs ahead.
    expect(heading(DateTime(2026, 11, 20), today), (
      lead: 'Today',
      date: 'Fri 20',
    ));
    // Across the night the clocks change, where a day is 23 or 25 hours.
    expect(heading(DateTime(2026, 3, 28), DateTime(2026, 3, 29, 0, 30)), (
      lead: 'Yesterday',
      date: 'Sat 28',
    ));
    expect(heading(DateTime(2026, 10, 24), DateTime(2026, 10, 25, 23, 30)), (
      lead: 'Yesterday',
      date: 'Sat 24',
    ));
    expect(heading(DateTime(2026, 10, 23), DateTime(2026, 10, 25, 0, 30)), (
      lead: null,
      date: 'Fri 23 Oct',
    ));
  });
}
