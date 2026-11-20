import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/sync_api.dart';

import 'fake_server.dart';
import 'record_device.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Map<String, ({WireTaskRecord record, int seq})> stored() =>
      server.tasks['user-1'] ?? {};

  String dayRecordOf(String noteId) => sharedVault().noteDayRecordId(noteId);

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

  void expectSettled(Device a, Device b) {
    expect(a.days.owed, isEmpty, reason: a.name);
    expect(b.days.owed, isEmpty, reason: b.name);
  }

  test(
    'a day reaches another device, under an id that names no note',
    () async {
      final (a, b) = await pair();
      final note = a.notes.create(body: 'Plan Friday');
      await passes([a, b]);

      expect(a.days.setDay(note.id, DateTime(2026, 11, 21)), isTrue);
      await passes([a, b]);
      final record = dayRecordOf(note.id);
      expect(stored().keys, contains(record));
      expect(record, isNot(note.id));
      expect(stored()[record]!.record.deletedAt, isNull);
      expect(b.days.dayOf(note.id), DateTime(2026, 11, 21));
      expectSettled(a, b);
      a.dispose();
      b.dispose();
    },
  );

  test(
    'clearing reaches the other device, and the note goes back to its last edit',
    () async {
      final (a, b) = await pair();
      final note = a.notes.create(body: 'Plan Friday');
      a.days.setDay(note.id, DateTime(2026, 11, 21));
      await passes([a, b]);
      expect(b.days.dayOf(note.id), DateTime(2026, 11, 21));

      expect(a.days.clearDay(note.id), isTrue);
      await passes([a, b]);
      expect(b.days.dayOf(note.id), isNull);
      expectSettled(a, b);
      a.dispose();
      b.dispose();
    },
  );

  test('a note deleted for good takes its day off the server', () async {
    final (a, b) = await pair();
    final note = a.notes.create(body: 'Old plan');
    a.days.setDay(note.id, DateTime(2026, 11, 21));
    await passes([a, b]);
    expect(b.days.noteIds, [note.id]);

    a.notes.delete(note.id);
    await passes([a, b]);
    expect(stored()[dayRecordOf(note.id)]!.record.deletedAt, isNotNull);
    expect(a.days.noteIds, isEmpty);
    expect(b.days.noteIds, isEmpty);
    expectSettled(a, b);
    a.dispose();
    b.dispose();
  });

  test(
    'a day given after a fast clock cleared the note stays, on every device',
    () async {
      final (a, b) = await pair();
      final note = b.notes.create(body: 'Plan');
      a.days.setDay(note.id, DateTime(2026, 11, 21));
      await passes([a, b]);

      a.clock = a.clock.add(const Duration(minutes: 4));
      a.days.clearDay(note.id);
      await passes([a, b]);
      expect(b.days.dayOf(note.id), isNull);

      b.days.setDay(note.id, DateTime(2026, 11, 23));
      await passes([b, a, b]);
      expect(a.days.dayOf(note.id), DateTime(2026, 11, 23));
      expect(b.days.dayOf(note.id), DateTime(2026, 11, 23));
      expectSettled(a, b);
      a.dispose();
      b.dispose();
    },
  );

  test('a build from before days keeps the day and never writes one', () async {
    final newer = Device(server, name: 'laptop');
    final older = Device(server, name: 'phone', withDays: false);
    await newer.boot();
    await older.boot();
    final note = newer.notes.create(body: 'Plan Friday');
    newer.days.setDay(note.id, DateTime(2026, 11, 21));
    await passes([newer, older]);
    final record = dayRecordOf(note.id);
    final before = (stored()[record]!.seq, stored()[record]!.record.updatedAt);
    expect(
      (older.store.data['tags.v1'] as Map)['unknown'] as List,
      contains(predicate((entry) => (entry as Map)['id'] == record)),
      reason: 'kept by id and time alone',
    );

    older.notes.updateBody(note.id, 'Plan Friday and Saturday');
    older.notes.create(body: 'Another');
    newer.notes.updateBody(note.id, 'Plan Saturday');
    server.taskPushes.clear();
    await passes([older, newer, older]);

    expect((stored()[record]!.seq, stored()[record]!.record.updatedAt), before);
    expect(
      server.taskPushes.expand((ids) => ids),
      isNot(contains(record)),
      reason: 'a build from before days never writes one',
    );
    expect(newer.days.dayOf(note.id), DateTime(2026, 11, 21));
    expect(older.days.noteIds, isEmpty);
    newer.dispose();
    older.dispose();
  });
}
