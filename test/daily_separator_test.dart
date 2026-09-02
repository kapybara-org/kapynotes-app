import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/daily_separator.dart';
import 'package:kapy_notes/data/time_zones.dart';

void main() {
  final previousEdit = DateTime(2026, 9, 1, 21, 42);

  test('formats a short comment separator with centered date and time', () {
    expect(DailySeparator.line(previousEdit), '// ─ 1 Sep · 21:42 ─');
  });

  test('formats an instant in the selected time zone', () {
    expect(
      DailySeparator.line(
        DateTime.utc(2026, 9, 1, 18, 12),
        displayTime: (instant) => AppTimeZones.convert(instant, 'Asia/Kolkata'),
      ),
      '// ─ 1 Sep · 23:42 ─',
    );
  });

  test('compares calendar days in the selected time zone', () {
    final beforeMidnight = DateTime.utc(2026, 9, 2, 3, 30);
    final afterMidnight = DateTime.utc(2026, 9, 2, 4, 30);

    expect(
      DailySeparator.isSameDay(
        beforeMidnight,
        afterMidnight,
        displayTime: (instant) =>
            AppTimeZones.convert(instant, 'America/New_York'),
      ),
      isFalse,
    );
    expect(
      DailySeparator.isSameDay(
        beforeMidnight,
        afterMidnight,
        displayTime: (instant) => AppTimeZones.convert(instant, 'Asia/Kolkata'),
      ),
      isTrue,
    );
  });

  test('prepares one empty line without adding a separator', () {
    expect(
      DailySeparator.prepareForAppend('Ideas\nShip the first version'),
      'Ideas\nShip the first version\n\n',
    );
    expect(DailySeparator.prepareForAppend('Ideas\n\n'), 'Ideas\n\n');
  });

  test('removes a trailing separator that never received content', () {
    expect(
      DailySeparator.prepareForAppend(
        'Ideas\n\n// ── 1 Sep 2026 · 9:42 PM ──\n',
      ),
      'Ideas\n\n',
    );
  });

  test('keeps a separator when content follows it', () {
    expect(
      DailySeparator.prepareForAppend(
        'Ideas\n\n// ─ 1 Sep · 21:42 ─\nNew content',
      ),
      'Ideas\n\n// ─ 1 Sep · 21:42 ─\nNew content\n\n',
    );
  });
}
