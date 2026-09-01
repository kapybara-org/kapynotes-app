import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/daily_separator.dart';

void main() {
  final previousEdit = DateTime(2026, 9, 1, 21, 42);

  test('formats a short comment separator with centered date and time', () {
    expect(DailySeparator.line(previousEdit), '// ─ 1 Sep · 21:42 ─');
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
