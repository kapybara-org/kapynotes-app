import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/writing_streak.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'writing-streak-test.json');

  /// How many times the record of days has been written.
  int recordWrites = 0;

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) {
    if (key == 'writingDays.v1') recordWrites++;
    data[key] = value;
  }
}

/// A morning in September 2026, on the device's own calendar.
DateTime day(int date, [int hour = 9]) => DateTime(2026, 9, date, hour);

Map<String, Object?> noteJson(
  String id, {
  String body = 'Words',
  required DateTime created,
  required DateTime updated,
  DateTime? archived,
  String? spaceId,
}) => {
  'id': id,
  'body': body,
  'createdAt': created.millisecondsSinceEpoch,
  'updatedAt': updated.millisecondsSinceEpoch,
  if (archived != null) 'archivedAt': archived.millisecondsSinceEpoch,
  'spaceId': ?spaceId,
};

void main() {
  group('a streak', () {
    WritingStreak from(Set<int> days) => WritingStreak.from(days, today: 100);

    test('is nothing when nothing was written', () {
      expect(from({}), const WritingStreak(days: 0, wroteToday: false));
    });

    test('counts every day of a run that reaches today', () {
      expect(
        from({98, 99, 100}),
        const WritingStreak(days: 3, wroteToday: true),
      );
    });

    test('that reached yesterday is still alive, and waiting on today', () {
      expect(from({98, 99}), const WritingStreak(days: 2, wroteToday: false));
    });

    test('ends once a whole day goes by with nothing written', () {
      expect(from({97, 98}), const WritingStreak(days: 0, wroteToday: false));
    });

    test('is only the latest run, however long an earlier one was', () {
      expect(
        from({90, 91, 92, 93, 94, 99, 100}),
        const WritingStreak(days: 2, wroteToday: true),
      );
    });
  });

  group('a day', () {
    test('runs from midnight to midnight', () {
      final today = WritingStreak.dayOf(DateTime(2026, 9, 11));
      expect(WritingStreak.dayOf(DateTime(2026, 9, 11, 23, 59, 59)), today);
      expect(WritingStreak.dayOf(DateTime(2026, 9, 12)), today + 1);
    });

    test('is one apart from the next, however long the clocks made it', () {
      // Both of Europe's changes and both of America's fall in these
      // stretches, so wherever the suite runs, one of them crosses one.
      for (final (month, date) in [(3, 7), (3, 28), (10, 24), (10, 31)]) {
        final start = DateTime(2026, month, date, 12);
        for (var offset = 1; offset <= 3; offset++) {
          expect(
            WritingStreak.dayOf(DateTime(2026, month, date + offset, 12)),
            WritingStreak.dayOf(start) + offset,
          );
        }
      }
    });
  });

  group('what a note says about when it was written', () {
    Note note({
      String body = 'Words',
      required DateTime created,
      required DateTime updated,
      DateTime? archived,
    }) => Note(
      id: 'n',
      body: body,
      createdAt: created,
      updatedAt: updated,
      archivedAt: archived,
    );

    test('is the day it was started and the day it last changed', () {
      expect(WritingStreak.daysIn(note(created: day(3), updated: day(5))), [
        WritingStreak.dayOf(day(3)),
        WritingStreak.dayOf(day(5)),
      ]);
    });

    test('is nothing for a blank note', () {
      expect(
        WritingStreak.daysIn(
          note(body: '  \n', created: day(3), updated: day(5)),
        ),
        isEmpty,
      );
    });

    test('is nothing for a note exactly as it was created', () {
      expect(
        WritingStreak.daysIn(note(created: day(3), updated: day(3))),
        isEmpty,
      );
    });

    test('leaves out the day it was archived', () {
      expect(
        WritingStreak.daysIn(
          note(created: day(3), updated: day(7), archived: day(7)),
        ),
        [WritingStreak.dayOf(day(3))],
      );
    });
  });

  group('the notes store', () {
    late _MemoryStore store;
    late DateTime now;
    late NotesStore notes;

    setUp(() async {
      store = _MemoryStore();
      now = day(9);
      notes = NotesStore(store, now: () => now);
      await notes.load();
    });

    test('counts a day as soon as something is typed in it', () {
      final note = notes.create();
      expect(notes.streak.days, 0);

      notes.updateBody(note.id, 'Monday');
      expect(notes.streak, const WritingStreak(days: 1, wroteToday: true));

      now = day(10);
      expect(notes.streak, const WritingStreak(days: 1, wroteToday: false));

      notes.updateBody(note.id, 'Monday\nTuesday');
      expect(notes.streak, const WritingStreak(days: 2, wroteToday: true));

      now = day(12);
      expect(notes.streak.days, 0);
    });

    test('writes the record once a day, not once a keystroke', () {
      final note = notes.create();
      for (var length = 1; length <= 40; length++) {
        notes.updateBody(note.id, 'x' * length);
      }
      expect(store.recordWrites, 1);
    });

    test('counts a note that arrives with words in it', () {
      notes.create(body: 'Captured on the way in');
      expect(notes.streak, const WritingStreak(days: 1, wroteToday: true));
    });

    test('does not count the welcome note, which the app wrote', () {
      Onboarding(store).seedWelcomeNote(notes);
      expect(notes.notes, hasLength(1));
      expect(notes.streak.days, 0);
    });

    test('does not count tidying: pinning, archiving, restoring', () {
      final note = notes.create();
      notes.updateBody(note.id, 'Written on the ninth');

      now = day(10);
      notes.togglePinned(note.id);
      notes.archive(note.id);
      notes.restore(note.id);

      expect(notes.streak, const WritingStreak(days: 1, wroteToday: false));
    });

    test('keeps the record across a restart', () async {
      final note = notes.create();
      notes.updateBody(note.id, 'One');
      now = day(10);
      notes.updateBody(note.id, 'One\nTwo');

      final reopened = NotesStore(store, now: () => now);
      await reopened.load();

      expect(reopened.streak, const WritingStreak(days: 2, wroteToday: true));
    });

    test("counts the person's own notes from their other devices", () {
      notes.applyRemote(
        notes: [
          Note.fromJson(
            noteJson('phone', created: day(8), updated: day(9, 7)),
          )!,
        ],
      );
      expect(notes.streak, const WritingStreak(days: 2, wroteToday: true));
    });

    test("does not count a shared space's notes, which others write in", () {
      notes.applyDoc(
        Note.fromJson(
          noteJson('team', created: day(8), updated: day(9), spaceId: 's1'),
        )!,
      );
      expect(notes.streak.days, 0);
    });

    test('forgets the streak with the notes, for somebody else', () {
      notes.create(body: 'Mine');
      expect(notes.streak.days, 1);

      notes.forgetEverything();

      expect(notes.streak.days, 0);
    });
  });

  test('a store from before the record starts it from the notes', () async {
    final store = _MemoryStore();
    store.data['notes.v2'] = {
      'notes': [
        noteJson('journal', created: day(7), updated: day(8)),
        // Somebody else's work, in a space they share.
        noteJson('team', created: day(9), updated: day(9, 11), spaceId: 's1'),
        // Just as the app made it.
        noteJson('welcome', created: day(9, 8), updated: day(9, 8)),
      ],
      'tombstones': <Object?>[],
    };
    final notes = NotesStore(store, now: () => day(9, 18));

    await notes.load();

    expect(notes.streak, const WritingStreak(days: 2, wroteToday: false));
    expect(store.data['writingDays.v1'], [
      WritingStreak.dayOf(day(7)),
      WritingStreak.dayOf(day(8)),
    ]);
  });
}
