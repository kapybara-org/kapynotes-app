import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/day_tabs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/stamped.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'day-tabs-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

String noteIdFor(int i) =>
    '0195f0d0-3333-4444-8555-${i.toRadixString(16).padLeft(12, '0')}';

final a = noteIdFor(1);
final b = noteIdFor(2);
final c = noteIdFor(3);
final d = noteIdFor(4);

final tue = DateTime(2026, 11, 18);

/// An arrangement of tabs: [order], the first [pinned] of them pinned.
Matcher tabsOf(List<String> order, {required int pinned}) =>
    isA<({List<String> order, int pinned})>()
        .having((tabs) => tabs.order, 'order', order)
        .having((tabs) => tabs.pinned, 'pinned', pinned);

void acknowledgeAll(DayTabsStore tabs) {
  tabs.hold();
  for (final record in tabs.owed) {
    tabs.acknowledge(record);
  }
  tabs.release();
}

void main() {
  late _MemoryStore store;
  late DateTime clock;
  late DayTabsStore tabs;

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  setUp(() {
    store = _MemoryStore();
    clock = DateTime.utc(2026, 11, 19, 9);
    tabs = DayTabsStore(store, now: tick);
  });

  test('a day with no record keeps its notes as they came, none pinned', () {
    expect(tabs.arrange(tue, [a, b, c]), tabsOf([a, b, c], pinned: 0));
    expect(tabs.owed, isEmpty);
  });

  test('a drag keeps the day in that order, as one record for the day', () {
    expect(tabs.move(tue, [a, b, c], c, 0), isTrue);
    expect(tabs.arrange(tue, [a, b, c]), tabsOf([c, a, b], pinned: 0));
    final owed = tabs.owed.single;
    expect(owed.key, '2026-11-18');
    expect(owed.payload, {
      'kind': 'dayTabs',
      'day': '2026-11-18',
      'tabs': {
        'v': {
          'order': [c, a, b],
          'pinned': 0,
        },
        'at': owed.updatedAt,
      },
    });
  });

  test('dragged back to the order the notes came in, the record goes', () {
    tabs.move(tue, [a, b, c], c, 0);
    acknowledgeAll(tabs);
    expect(tabs.move(tue, [a, b, c], c, 2), isTrue);
    expect(tabs.arrange(tue, [a, b, c]), tabsOf([a, b, c], pinned: 0));
    expect(tabs.owed.single.payload, isNull);
  });

  test('a drag that ends where it began writes nothing', () {
    expect(tabs.move(tue, [a, b, c], b, 1), isTrue);
    expect(tabs.owed, isEmpty);
  });

  test('a pinned tab moves to the front, the latest pin first, and unpinned '
      'it goes just after the pins left', () {
    expect(tabs.pin(tue, [a, b, c, d], c), isTrue);
    expect(tabs.arrange(tue, [a, b, c, d]), tabsOf([c, a, b, d], pinned: 1));
    expect(tabs.pin(tue, [a, b, c, d], d), isTrue);
    expect(tabs.arrange(tue, [a, b, c, d]), tabsOf([d, c, a, b], pinned: 2));

    expect(tabs.unpin(tue, [a, b, c, d], d), isTrue);
    expect(tabs.arrange(tue, [a, b, c, d]), tabsOf([c, d, a, b], pinned: 1));
  });

  test('pinned tabs stay in front: a drag keeps each tab among its own', () {
    tabs.pin(tue, [a, b, c, d], c);
    tabs.pin(tue, [a, b, c, d], d);
    expect(tabs.move(tue, [a, b, c, d], b, 0), isTrue);
    expect(tabs.arrange(tue, [a, b, c, d]), tabsOf([d, c, b, a], pinned: 2));
    expect(tabs.move(tue, [a, b, c, d], d, 3), isTrue);
    expect(tabs.arrange(tue, [a, b, c, d]), tabsOf([c, d, b, a], pinned: 2));
  });

  test('a note no longer on the day is skipped and takes its pin with it, '
      'and notes the order does not name follow, earliest first', () {
    tabs.pin(tue, [a, b, c], c);
    tabs.move(tue, [a, b, c], b, 1);
    expect(tabs.arrange(tue, [a, b, c]), tabsOf([c, b, a], pinned: 1));

    expect(tabs.arrange(tue, [a, b, d]), tabsOf([b, a, d], pinned: 0));
    expect(tabs.arrange(tue, [d, a, b, c]), tabsOf([c, b, a, d], pinned: 1));
  });

  test('an order names at most 64 notes, losing its last unpinned ones, and '
      'a 65th pin is refused', () {
    expect(dayTabsOrderMax, 64);
    final notes = [for (var i = 0; i < 70; i++) noteIdFor(100 + i)];
    expect(tabs.move(tue, notes, notes[69], 0), isTrue);
    final named = (tabs.owed.single.payload!['tabs'] as Map)['v'] as Map;
    expect(named['order'], [notes[69], ...notes.take(63)]);
    expect(
      tabs.arrange(tue, notes),
      tabsOf([notes[69], ...notes.take(69)], pinned: 0),
    );

    for (final note in notes.take(64)) {
      expect(tabs.pin(tue, notes, note), isTrue);
    }
    final full = tabs.arrange(tue, notes);
    expect(full.pinned, 64);
    expect(tabs.pin(tue, notes, notes[69]), isFalse);
    expect(tabs.arrange(tue, notes), tabsOf(full.order, pinned: 64));
  });

  test('2,000 days in orders of their own are the whole budget: past it no '
      'new day is ordered, though one already ordered still is', () {
    expect(dayTabsRecordsMax, 2000);
    tabs.hold();
    for (var i = 0; i < dayTabsRecordsMax; i++) {
      final key = DateTime(2020, 1, 1 + i);
      final day =
          '${key.year}-${key.month.toString().padLeft(2, '0')}-'
          '${key.day.toString().padLeft(2, '0')}';
      tabs.applyRemote(
        DayTabs(day: day, tabs: Stamped(TabOrder([b, a], 0), 4)),
        4,
      );
    }
    tabs.release();
    expect(tabs.room, 0);
    expect(tabs.move(tue, [a, b], b, 0), isFalse);
    expect(tabs.pin(tue, [a, b], b), isFalse);
    expect(tabs.arrange(tue, [a, b]), tabsOf([a, b], pinned: 0));

    final first = DateTime(2020, 1, 1);
    expect(tabs.pin(first, [a, b], a), isTrue);
    expect(tabs.arrange(first, [a, b]), tabsOf([a, b], pinned: 1));
    expect(tabs.unpin(first, [a, b], a), isTrue);
    acknowledgeAll(tabs);
    expect(tabs.room, 1);
    expect(tabs.move(tue, [a, b], b, 0), isTrue);
    expect(tabs.room, 0);
  });

  group('a record from another device', () {
    Map<String, Object?> payload({
      String day = '2026-11-18',
      Object? order,
      Object? pinned = 1,
    }) => {
      'kind': 'dayTabs',
      'day': day,
      'tabs': {
        'v': {
          'order': order ?? [c, a],
          'pinned': pinned,
        },
        'at': 7,
      },
    };

    test('is read, its order and pins as one', () {
      final tabs = DayTabs.fromPayload(payload())!;
      expect(tabs.day, '2026-11-18');
      expect(tabs.tabs.v.order, [c, a]);
      expect(tabs.tabs.v.pinned, 1);
      expect(tabs.tabs.at, 7);
    });

    test('is not taken when its order names a note twice, pins more than it '
        'names, names more than 64, or its day is not a date', () {
      expect(DayTabs.fromPayload(payload(order: [a, a])), isNull);
      expect(DayTabs.fromPayload(payload(pinned: 3)), isNull);
      expect(DayTabs.fromPayload(payload(pinned: -1)), isNull);
      expect(DayTabs.fromPayload(payload(order: [a, 2])), isNull);
      expect(
        DayTabs.fromPayload(
          payload(order: [for (var i = 0; i < 65; i++) noteIdFor(i)]),
        ),
        isNull,
      );
      expect(DayTabs.fromPayload(payload(day: 'Tue 18')), isNull);
      expect(DayTabs.fromPayload(payload(day: '2026-11-18T00:00')), isNull);
    });

    test('keeps fields a later build wrote, and writes them back', () {
      final raw = payload()
        ..['colour'] = 'sage'
        ..['tabs'] = {
          'v': {
            'order': [c, a],
            'pinned': 1,
            'folded': [a],
          },
          'at': 7,
        };
      tabs.applyRemote(DayTabs.fromPayload(raw)!, 7);
      expect(tabs.move(tue, [a, b, c], b, 1), isTrue);
      final written = tabs.owed.single.payload!;
      expect(written['colour'], 'sage');
      expect((written['tabs'] as Map)['v'], {
        'folded': [a],
        'order': [c, b, a],
        'pinned': 1,
      });
    });

    test('meets this device\'s order and the later wins, pins and all', () {
      tabs.pin(tue, [a, b, c], b);
      final mine = tabs.owed.single.updatedAt;
      final later = DayTabs.fromPayload(payload())!;
      tabs.applyRemote(
        DayTabs(day: later.day, tabs: Stamped(later.tabs.v, mine + 5)),
        mine + 5,
      );
      expect(tabs.arrange(tue, [a, b, c]), tabsOf([c, a, b], pinned: 1));

      final earlier = DayTabs(
        day: later.day,
        tabs: Stamped(const TabOrder([], 0), mine - 5),
      );
      tabs.applyRemote(earlier, mine + 6);
      expect(tabs.arrange(tue, [a, b, c]), tabsOf([c, a, b], pinned: 1));
    });

    test('deleted, it puts the day back in its own order; one ordered after '
        'on a slow clock is stamped past the delete', () {
      tabs.move(tue, [a, b, c], c, 0);
      acknowledgeAll(tabs);
      final ahead = clock.add(const Duration(minutes: 4));
      tabs.applyRemoteDelete('2026-11-18', ahead.millisecondsSinceEpoch);
      expect(tabs.arrange(tue, [a, b, c]), tabsOf([a, b, c], pinned: 0));
      expect(tabs.days, ['2026-11-18']);

      expect(tabs.move(tue, [a, b, c], b, 0), isTrue);
      final owed = tabs.owed.single;
      expect(owed.updatedAt, greaterThan(ahead.millisecondsSinceEpoch));
      expect(
        ((owed.payload!['tabs'] as Map)['at'] as int),
        greaterThan(ahead.millisecondsSinceEpoch),
      );
    });
  });

  test('survives a reload, owed records included', () async {
    tabs.pin(tue, [a, b, c], c);
    final again = DayTabsStore(store, now: tick);
    expect(await again.load(), isTrue);
    expect(again.arrange(tue, [a, b, c]), tabsOf([c, a, b], pinned: 1));
    expect(again.owed.single.key, '2026-11-18');
    expect(jsonEncode(store.data['dayTabs.v1']), contains('2026-11-18'));
  });

  test(
    'a first load from a build before day tabs says it held nothing',
    () async {
      expect(await tabs.load(), isFalse);
      expect(store.data['dayTabs.v1'], {'days': <Object?>[]});
      expect(await DayTabsStore(store, now: tick).load(), isTrue);
    },
  );

  test('signing out keeps the orders, owed to the next account, and drops '
      'what was deleted', () {
    tabs.move(tue, [a, b], b, 0);
    tabs.move(DateTime(2026, 11, 17), [a, b], b, 0);
    acknowledgeAll(tabs);
    tabs.move(DateTime(2026, 11, 17), [a, b], b, 1);
    acknowledgeAll(tabs);
    tabs.forgetAccount();
    expect(tabs.days, ['2026-11-18']);
    expect(tabs.owed.single.key, '2026-11-18');
  });
}
