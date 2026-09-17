import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_switcher.dart';

void main() {
  test('committing a preview makes the next switch a two-note toggle', () {
    final switcher = NoteSwitcher();

    expect(
      switcher.advance(
        currentId: 'alpha',
        eligibleIds: const ['alpha', 'charlie', 'bravo'],
        delta: 1,
      ),
      'charlie',
    );
    expect(
      switcher.advance(
        currentId: 'charlie',
        eligibleIds: const ['alpha', 'charlie', 'bravo'],
        delta: 1,
      ),
      'bravo',
    );
    expect(switcher.commit(), 'bravo');

    expect(
      switcher.advance(
        currentId: 'bravo',
        // The caller promoted the committed note to the sidebar's top.
        eligibleIds: const ['bravo', 'alpha', 'charlie'],
        delta: 1,
      ),
      'alpha',
    );
    expect(switcher.commit(), 'alpha');

    expect(
      switcher.advance(
        currentId: 'alpha',
        eligibleIds: const ['alpha', 'bravo', 'charlie'],
        delta: 1,
      ),
      'bravo',
    );
  });

  test('reverse switching starts at the other end of the session', () {
    final switcher = NoteSwitcher();

    expect(
      switcher.advance(
        currentId: 'alpha',
        eligibleIds: const ['alpha', 'charlie', 'bravo'],
        delta: -1,
      ),
      'bravo',
    );
  });

  test('forward switching chooses the visible row below the current note', () {
    final switcher = NoteSwitcher();

    expect(
      switcher.advance(
        currentId: 'alpha',
        eligibleIds: const ['charlie', 'alpha', 'bravo'],
        delta: 1,
      ),
      'bravo',
    );
  });

  test('a filtered-out current note starts at the requested edge', () {
    final switcher = NoteSwitcher();

    expect(
      switcher.advance(
        currentId: 'alpha',
        eligibleIds: const ['bravo', 'charlie'],
        delta: 1,
      ),
      'bravo',
    );
  });

  test('an active session safely drops notes that disappear', () {
    final switcher = NoteSwitcher();
    expect(
      switcher.advance(
        currentId: 'alpha',
        eligibleIds: const ['alpha', 'bravo', 'charlie'],
        delta: 1,
      ),
      'bravo',
    );

    switcher.retain(const ['alpha', 'charlie']);
    expect(switcher.isActive, isTrue);
    expect(
      switcher.advance(
        currentId: 'alpha',
        eligibleIds: const ['alpha', 'charlie'],
        delta: 1,
      ),
      'charlie',
    );

    switcher.retain(const ['alpha']);
    expect(switcher.isActive, isFalse);
    expect(switcher.commit(), isNull);
  });
}
