import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/stamped.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'note-days-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const noteA = '0195f0d0-1111-4222-8333-00000000000a';
const noteB = '0195f0d0-1111-4222-8333-00000000000b';

String noteIdFor(int i) =>
    '0195f0d0-2222-4333-8444-${i.toRadixString(16).padLeft(12, '0')}';

Note noteAt(String id, DateTime at) =>
    Note(id: id, body: 'Plan', createdAt: DateTime(2026, 11, 1), updatedAt: at);

void acknowledgeAll(NoteDayStore days) {
  days.hold();
  for (final record in days.owed) {
    days.acknowledge(record);
  }
  days.release();
}

void main() {
  late _MemoryStore store;
  late DateTime clock;
  late NoteDayStore days;

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  setUp(() {
    store = _MemoryStore();
    clock = DateTime.utc(2026, 11, 19, 9);
    days = NoteDayStore(store, now: tick);
  });

  test(
    'a day is set, read back, and a note sits on it rather than its last edit',
    () {
      final note = noteAt(noteA, DateTime(2026, 11, 19, 8));
      expect(days.dayOf(noteA), isNull);
      expect(days.dayOfNote(note), DateTime(2026, 11, 19));

      expect(days.setDay(noteA, DateTime(2026, 11, 21)), isTrue);
      expect(days.dayOf(noteA), DateTime(2026, 11, 21));
      expect(days.dayOfNote(note), DateTime(2026, 11, 21));
      expect(days.hasDay(noteA), isTrue);
      expect(days.owed.single.key, noteA);
      expect(days.owed.single.payload, {
        'kind': 'noteDay',
        'noteId': noteA,
        'day': {'v': '2026-11-21', 'at': days.owed.single.updatedAt},
      });
    },
  );

  test('setting the same day again writes nothing', () {
    days.setDay(noteA, DateTime(2026, 11, 21));
    acknowledgeAll(days);
    expect(days.setDay(noteA, DateTime(2026, 11, 21)), isTrue);
    expect(days.owed, isEmpty);
  });

  test('a day is a calendar date, so a time it carries is dropped', () {
    days.setDay(noteA, DateTime(2026, 11, 21, 15, 40));
    expect(days.dayOf(noteA), DateTime(2026, 11, 21));
  });

  test(
    'clearing goes back to the last-edit day, and clearing an undated note changes nothing',
    () {
      final note = noteAt(noteA, DateTime(2026, 11, 19, 8));
      days.setDay(noteA, DateTime(2026, 11, 21));
      acknowledgeAll(days);
      expect(days.clearDay(noteA), isTrue);
      expect(days.dayOf(noteA), isNull);
      expect(days.dayOfNote(note), DateTime(2026, 11, 19));
      expect(days.owed.single.payload, isNull, reason: 'a tombstone');
      expect(days.clearDay(noteA), isFalse);
      expect(days.clearDay(noteB), isFalse);
    },
  );

  test(
    'a clear that reached the server ahead of this clock can be outranked by a day set here',
    () {
      final ahead = clock.millisecondsSinceEpoch + 3600 * 1000;
      days.applyRemote(
        NoteDay(noteId: noteA, day: const Stamped('2026-11-21', 5)),
        5,
      );
      days.applyRemoteDelete(noteA, ahead);
      expect(days.dayOf(noteA), isNull);
      expect(days.noteIds, [noteA], reason: 'the clear is still ahead of us');

      expect(days.setDay(noteA, DateTime(2026, 11, 22)), isTrue);
      final owed = days.owed.single;
      expect(owed.updatedAt, ahead + 1);
      expect(owed.payload!['day'], {'v': '2026-11-22', 'at': ahead + 1});
    },
  );

  test(
    'a clear is let go once this clock passes it, when its note goes, and on signing out',
    () {
      final ahead = clock.millisecondsSinceEpoch + 3600 * 1000;
      days.setDay(noteA, DateTime(2026, 11, 21));
      days.setDay(noteB, DateTime(2026, 11, 22));
      acknowledgeAll(days);

      days.clearDay(noteA);
      acknowledgeAll(days);
      expect(days.noteIds, [noteB], reason: 'this clock has passed the clear');

      days.setDay(noteA, DateTime(2026, 11, 30));
      acknowledgeAll(days);
      days.applyRemoteDelete(noteA, ahead);
      days.applyRemoteDelete(noteB, ahead);
      expect(days.noteIds, unorderedEquals([
        noteA,
        noteB,
      ]), reason: 'both clears are ahead of us');

      days.forgetNote(noteA);
      expect(days.noteIds, [noteB]);
      expect(days.owed, isEmpty);

      days.forgetAccount();
      expect(days.noteIds, isEmpty);
    },
  );

  test(
    'notes on a day, and the ones waiting for a later one, soonest first',
    () {
      final notes = [
        noteAt(noteA, DateTime(2026, 11, 19, 8)),
        noteAt(noteB, DateTime(2026, 11, 19, 9)),
        noteAt(noteIdFor(0), DateTime(2026, 11, 19, 10)),
        noteAt(noteIdFor(1), DateTime(2026, 11, 17, 10)),
      ];
      days.setDay(noteA, DateTime(2026, 11, 21));
      days.setDay(noteB, DateTime(2026, 11, 19));
      days.setDay(noteIdFor(1), DateTime(2026, 11, 17));

      final today = DateTime(2026, 11, 19);
      expect(days.notesOn(notes, today), [notes[1], notes[2]]);
      expect(days.notesOn(notes, DateTime(2026, 11, 21)), [notes[0]]);
      expect(days.notesOn(notes, DateTime(2026, 11, 17)), [notes[3]]);
      expect(days.upcoming(notes, today), [notes[0]]);
      expect(days.waits(notes[0], today), isTrue);
      expect(days.waits(notes[1], today), isFalse);
      expect(days.waits(notes[2], today), isFalse);
      expect(days.taskWaits(noteA, today), isTrue);
      expect(days.taskWaits(noteB, today), isFalse);
      expect(days.taskWaits(noteIdFor(2), today), isFalse, reason: 'no day');

      days.setDay(noteIdFor(1), DateTime(2026, 11, 23));
      expect(days.upcoming(notes, today), [notes[0], notes[3]]);
    },
  );

  test('the later day wins, whichever device merges', () {
    days.applyRemote(
      NoteDay(noteId: noteA, day: const Stamped('2026-11-21', 5)),
      5,
    );
    days.applyRemote(
      NoteDay(noteId: noteA, day: const Stamped('2026-11-23', 7)),
      7,
    );
    expect(days.dayOf(noteA), DateTime(2026, 11, 23));
    days.applyRemote(
      NoteDay(noteId: noteA, day: const Stamped('2026-11-21', 5)),
      5,
    );
    expect(days.dayOf(noteA), DateTime(2026, 11, 23), reason: 'a replay');
  });

  test('fields a later build wrote are kept and written back', () {
    final later = NoteDay.fromPayload({
      'kind': 'noteDay',
      'noteId': noteA,
      'day': {'v': '2026-11-21', 'at': 4},
      'remindAt': {'v': 540, 'at': 4},
    })!;
    days.applyRemote(later, 4);
    expect(days.owed, isEmpty);
    days.setDay(noteA, DateTime(2026, 11, 22));
    expect(days.owed.single.payload!['remindAt'], {'v': 540, 'at': 4});
  });

  test(
    'a payload that is not a calendar date, or names another note, is refused',
    () {
      expect(
        NoteDay.fromPayload({
          'kind': 'noteDay',
          'noteId': noteA,
          'day': {'v': '2026-11-21T00:00:00Z', 'at': 4},
        }),
        isNull,
      );
      expect(
        NoteDay.fromPayload({
          'kind': 'noteDay',
          'noteId': noteA,
          'day': {'v': '21 November', 'at': 4},
        }),
        isNull,
      );
      days.applyRemote(
        NoteDay(noteId: noteB, day: const Stamped('2026-11-21', 4)),
        4,
      );
      expect(days.dayOf(noteA), isNull);
      expect(days.dayOf(noteB), DateTime(2026, 11, 21));
    },
  );

  test(
    'a stamp past the largest safe integer is refused, and none is written past it',
    () {
      const max = 9007199254740991;
      expect(
        NoteDay.fromPayload({
          'kind': 'noteDay',
          'noteId': noteA,
          'day': {'v': '2026-11-21', 'at': max + 1},
        }),
        isNull,
      );
      days.applyRemote(
        NoteDay(noteId: noteA, day: const Stamped('2026-11-20', max - 1)),
        max - 1,
      );
      expect(days.setDay(noteA, DateTime(2026, 11, 21)), isTrue);
      expect(days.setDay(noteA, DateTime(2026, 11, 22)), isTrue);
      expect((days.owed.single.payload!['day'] as Map)['at'], max);
    },
  );

  test(
    'a day for every note is the whole budget, and past it nothing is written',
    () {
      expect(noteDayRecordsMax, 20000);
      days.hold();
      for (var i = 0; i < noteDayRecordsMax; i++) {
        days.applyRemote(
          NoteDay(noteId: noteIdFor(i), day: const Stamped('2026-11-21', 4)),
          4,
        );
      }
      days.release();
      expect(days.room, 0);
      expect(days.setDay(noteA, DateTime(2026, 11, 21)), isFalse);
      expect(days.noteIds.contains(noteA), isFalse);
      expect(
        days.setDay(noteIdFor(noteDayRecordsMax), DateTime(2026, 11, 25)),
        isFalse,
      );
      expect(days.clearDay(noteIdFor(3)), isTrue);
      acknowledgeAll(days);
      expect(days.room, 1);
      expect(
        days.setDay(noteIdFor(noteDayRecordsMax), DateTime(2026, 11, 25)),
        isTrue,
      );
      expect(days.room, 0);
    },
  );

  test('survives a reload, owed records included', () async {
    days.setDay(noteA, DateTime(2026, 11, 21));
    final again = NoteDayStore(store, now: tick);
    expect(await again.load(), isTrue);
    expect(again.dayOf(noteA), DateTime(2026, 11, 21));
    expect(again.owed.single.key, noteA);
    expect(jsonEncode(store.data['noteDays.v1']), contains('2026-11-21'));
  });
}
