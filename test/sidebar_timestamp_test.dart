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
      '2 Sep 2026 · 00:15',
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

    expect(glance(DateTime.utc(2026, 11, 16, 9, 5)), '09:05');
    expect(
      glance(DateTime.utc(2026, 11, 16, 9, 5), today: true),
      'Today · 09:05',
    );
    expect(glance(DateTime.utc(2026, 11, 15, 23)), 'Yesterday');
    expect(glance(DateTime.utc(2026, 11, 14, 8)), 'Sat');
    expect(glance(DateTime.utc(2026, 11, 2, 8)), '2 Nov');
    expect(glance(DateTime.utc(2025, 12, 30, 8)), '30 Dec 2025');
  });
}
