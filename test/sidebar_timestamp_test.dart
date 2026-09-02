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
}
