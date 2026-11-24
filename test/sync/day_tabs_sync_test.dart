import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/sync_api.dart';

import 'fake_server.dart';
import 'record_device.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Map<String, ({WireTaskRecord record, int seq})> stored() =>
      server.tasks['user-1'] ?? {};

  String tabsRecordOf(String day) => sharedVault().dayTabsRecordId(day);

  final tue = DateTime(2026, 11, 18);

  Future<(Device, Device)> pair() async {
    final laptop = Device(server, name: 'laptop');
    final phone = Device(server, name: 'phone');
    await laptop.boot();
    await phone.boot();
    return (laptop, phone);
  }

  Future<void> passes(List<Device> devices) async {
    for (final d in devices) {
      await d.pass();
    }
  }

  /// Three notes on Tue 18 on [d], earliest first.
  List<String> three(Device d) => [
    for (final title in ['Standup notes', 'Lunch with Maya', 'Q4 budget'])
      d.notes.create(body: title).id,
  ];

  test('an order and its pins reach another device, under an id that names '
      'no day', () async {
    final (a, b) = await pair();
    final notes = three(a);
    await passes([a, b]);

    expect(a.dayTabs.pin(tue, notes, notes[2]), isTrue);
    expect(a.dayTabs.move(tue, notes, notes[0], 2), isTrue);
    await passes([a, b]);
    final record = tabsRecordOf('2026-11-18');
    expect(record, isNot(contains('2026')));
    expect(stored().keys, contains(record));
    expect(stored()[record]!.record.deletedAt, isNull);
    final shown = b.dayTabs.arrange(tue, notes);
    expect(shown.order, [notes[2], notes[1], notes[0]]);
    expect(shown.pinned, 1);
    expect(a.dayTabs.owed, isEmpty);
    expect(b.dayTabs.owed, isEmpty);
    a.dispose();
    b.dispose();
  });

  test('a day put back in its own order goes back on every device', () async {
    final (a, b) = await pair();
    final notes = three(a);
    a.dayTabs.move(tue, notes, notes[2], 0);
    await passes([a, b]);
    expect(b.dayTabs.arrange(tue, notes).order.first, notes[2]);

    b.dayTabs.move(tue, notes, notes[2], 2);
    await passes([b, a]);
    expect(stored()[tabsRecordOf('2026-11-18')]!.record.deletedAt, isNotNull);
    expect(a.dayTabs.arrange(tue, notes).order, notes);
    expect(a.dayTabs.owed, isEmpty);
    expect(b.dayTabs.owed, isEmpty);
    a.dispose();
    b.dispose();
  });

  test(
    'a pin on one device and a drag on another leave the later whole',
    () async {
      final (a, b) = await pair();
      final notes = three(a);
      await passes([a, b]);

      a.dayTabs.pin(tue, notes, notes[1]);
      b.clock = a.clock.add(const Duration(seconds: 1));
      b.dayTabs.move(tue, notes, notes[2], 0);
      await passes([a, b, a]);
      for (final d in [a, b]) {
        final shown = d.dayTabs.arrange(tue, notes);
        expect(shown.order, [notes[2], notes[0], notes[1]], reason: d.name);
        expect(shown.pinned, 0, reason: d.name);
      }
      a.dispose();
      b.dispose();
    },
  );

  test(
    "a day's order moved onto another day's id is not taken for it",
    () async {
      final (laptop, phone) = await pair();
      final notes = three(laptop);
      laptop.dayTabs.move(tue, notes, notes[2], 0);
      await laptop.pass();

      final real = stored()[tabsRecordOf('2026-11-18')]!.record;
      server.pushTasks('user-1', 'mallory', [
        WireTaskRecord(
          id: tabsRecordOf('2026-11-17'),
          updatedAt: real.updatedAt,
          payload: real.payload,
        ),
      ]);
      await phone.pass();
      expect(phone.dayTabs.days, ['2026-11-18']);
      laptop.dispose();
      phone.dispose();
    },
  );

  test(
    'a build from before day tabs keeps the record and never writes one',
    () async {
      final newer = Device(server, name: 'laptop');
      final older = Device(server, name: 'phone', withDayTabs: false);
      await newer.boot();
      await older.boot();
      final notes = three(newer);
      newer.dayTabs.pin(tue, notes, notes[2]);
      await passes([newer, older]);
      final record = tabsRecordOf('2026-11-18');
      final before = (
        stored()[record]!.seq,
        stored()[record]!.record.updatedAt,
      );
      expect(
        (older.store.data['tags.v1'] as Map)['unknown'] as List,
        contains(predicate((entry) => (entry as Map)['id'] == record)),
        reason: 'kept by id and time alone',
      );

      older.notes.updateBody(notes[0], 'Standup notes, moved');
      newer.notes.updateBody(notes[1], 'Lunch with Maya on the 30th');
      server.taskPushes.clear();
      await passes([older, newer, older]);

      expect((
        stored()[record]!.seq,
        stored()[record]!.record.updatedAt,
      ), before);
      expect(
        server.taskPushes.expand((ids) => ids),
        isNot(contains(record)),
        reason: 'a build from before day tabs never writes one',
      );
      expect(newer.dayTabs.arrange(tue, notes).order.first, notes[2]);
      expect(older.dayTabs.days, isEmpty);
      newer.dispose();
      older.dispose();
    },
  );
}
