import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/time_zones.dart';

void main() {
  test('offers canonical IANA regions without legacy aliases', () {
    expect(AppTimeZones.locationIds.first, 'UTC');
    expect(AppTimeZones.locationIds, contains('Asia/Kolkata'));
    expect(AppTimeZones.locationIds, contains('America/New_York'));
    expect(AppTimeZones.locationIds, isNot(contains('Etc/GMT+5')));
    expect(AppTimeZones.locationIds, isNot(contains('US/Eastern')));
  });

  test('converts instants with non-whole-hour offsets', () {
    final displayed = AppTimeZones.convert(
      DateTime.utc(2026, 9, 1, 18, 12),
      'Asia/Kolkata',
    );

    expect(displayed.year, 2026);
    expect(displayed.month, 9);
    expect(displayed.day, 1);
    expect(displayed.hour, 23);
    expect(displayed.minute, 42);
    expect(displayed.timeZoneOffset, const Duration(hours: 5, minutes: 30));
  });

  test('uses daylight-saving rules at the represented instant', () {
    final winter = DateTime.utc(2026, 1, 15, 12);
    final summer = DateTime.utc(2026, 7, 15, 12);

    expect(
      AppTimeZones.convert(winter, 'America/New_York').timeZoneOffset,
      const Duration(hours: -5),
    );
    expect(
      AppTimeZones.convert(summer, 'America/New_York').timeZoneOffset,
      const Duration(hours: -4),
    );
    expect(
      AppTimeZones.offsetLabel('America/New_York', instant: summer),
      'UTC-04:00',
    );
  });

  test('invalid stored locations safely fall back to system time', () {
    expect(AppTimeZones.normalize('Mars/Olympus_Mons'), isNull);
    expect(AppTimeZones.normalize(''), isNull);
  });
}
