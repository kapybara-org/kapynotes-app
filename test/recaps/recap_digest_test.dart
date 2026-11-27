import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/note_doc.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/data/time_zones.dart';
import 'package:kapy_notes/recaps/recap_digest.dart';
import 'package:kapy_notes/recaps/recap_period.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'recap-digest-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

NoteVoiceRef _voice(int seconds) => NoteVoiceRef(
  offset: 0,
  hash: 'voice-$seconds',
  key: Uint8List(32),
  bytes: 1,
  durationMs: seconds * 1000,
);

void main() {
  late DateTime clock;
  late TaskIndex index;
  late TagStore tags;
  late FolderStore folders;
  late Map<String, NoteDoc> docs;
  late List<Note> notes;
  late Map<String, DateTime> ownDays;
  var zone = 'Asia/Kolkata';

  setUp(() async {
    clock = DateTime.utc(2026, 11, 1);
    final store = _MemoryStore();
    index = TaskIndex(store, now: () => clock);
    tags = TagStore(store, now: () => clock);
    folders = FolderStore(store, now: () => clock);
    await tags.load();
    await folders.load();
    docs = {};
    notes = [];
    ownDays = {};
    zone = 'Asia/Kolkata';
  });

  DateTime displayTime(DateTime instant) => AppTimeZones.convert(instant, zone);

  void note(
    String id,
    String edited, {
    String body = 'Note\nWords',
    List<NoteAttachmentRef> attachments = const [],
    bool hidden = false,
    bool archived = false,
  }) {
    final at = DateTime.parse(edited);
    final made = Note(
      id: id,
      body: body,
      attachments: attachments,
      createdAt: at.subtract(const Duration(hours: 1)),
      updatedAt: at,
      hiddenAt: hidden ? at : null,
      archivedAt: archived ? at : null,
    );
    final doc = docs[id] ??= NoteDoc(replica: 'aaaaaaaaaaaa');
    doc.reconcile(
      body: body,
      formats: const [],
      attachments: const [],
      createdAt: made.createdAt,
    );
    index.reconcileNote(id, doc, idFor: (anchor) => '$id:$anchor');
    notes
      ..removeWhere((n) => n.id == id)
      ..add(made);
  }

  void tick(String instant, void Function() change) {
    clock = DateTime.parse(instant);
    change();
  }

  void tag(String noteId, List<String> names) =>
      tags.setTags(noteId, [for (final name in names) tags.create(name)!.id]);

  RecapDigest digest(RecapPeriod period) => RecapDigest.compute(
    period,
    notes: notes,
    tasks: TaskBoard.read(
      entries: index.entries,
      notes: notes,
      docOf: (id) => docs[id],
    ),
    tags: tags,
    folders: folders.tree,
    displayTime: displayTime,
    ownDay: (note) => ownDays[note.id],
  );

  RecapPeriod weekOf(DateTime day, {int firstWeekday = DateTime.monday}) =>
      RecapPeriod.containing(day, RecapKind.week, firstWeekday: firstWeekday);

  group('a week', () {
    setUp(() {
      note('a', '2026-11-16T04:00:00Z', body: 'Trip\n☐ Book\n☐ Pay\n☐ Pack');
      tick('2026-11-17T05:00:00Z', () {
        note('a', '2026-11-16T04:00:00Z', body: 'Trip\n☐ Book\n☑ Pay\n☐ Pack');
      });
      tag('a', ['Travel', 'Work']);
      note('b', '2026-11-17T06:00:00Z', attachments: [_voice(90)]);
      tag('b', ['work']);
      note('c', '2026-11-18T06:00:00Z', attachments: [_voice(30)]);
      folders.file(['c'], folders.create('Work')!.id);
      note('d', '2026-11-17T08:00:00Z');
      tag('d', ['Garden']);

      note('old', '2026-11-10T06:00:00Z', body: 'Errands\n☐ Milk\n☐ Post');
      tick('2026-11-19T06:00:00Z', () {
        note('old', '2026-11-10T06:00:00Z', body: 'Errands\n☑ Milk\n☐ Post');
      });
      note('older', '2026-11-12T06:00:00Z');

      note(
        'secret',
        '2026-11-18T07:00:00Z',
        body: 'Secret\n☐ Hide',
        attachments: [_voice(600)],
      );
      tick('2026-11-18T07:30:00Z', () {
        note(
          'secret',
          '2026-11-18T07:00:00Z',
          body: 'Secret\n☑ Hide',
          attachments: [_voice(600)],
          hidden: true,
        );
      });
      tag('secret', ['Hidden topic']);
      note('gone', '2026-11-18T09:00:00Z', archived: true);
    });

    test('counts the visible notes, tasks and voice notes in it', () {
      final week = digest(weekOf(DateTime(2026, 11, 19)));
      expect(
        week.counts,
        const RecapCounts(
          notes: 4,
          tasksDone: 2,
          voiceNotes: 2,
          voiceMinutes: 2,
        ),
      );
      expect(week.tasksOpen, 2);
      expect(week.perDay, [1, 2, 1, 0, 0, 0, 0]);
      expect(week.busiestDay, DateTime(2026, 11, 17));
      expect(week.longestRun, 3);
      expect(week.counts.line, '4 notes · 2 tasks done · 2 voice notes');
    });

    test('never counts a hidden or archived note, nor what it holds', () {
      final wednesday = RecapPeriod.containing(
        DateTime(2026, 11, 18),
        RecapKind.day,
        firstWeekday: DateTime.monday,
      );
      final hidden = digest(wednesday);
      expect(
        hidden.counts,
        const RecapCounts(notes: 1, voiceNotes: 1, voiceMinutes: 1),
      );
      expect(hidden.tasksOpen, 0);
      expect(hidden.topics, [(name: 'Work', notes: 1)]);

      note(
        'secret',
        '2026-11-18T07:00:00Z',
        body: 'Secret\n☑ Hide\n☐ Keep',
        attachments: [_voice(600)],
      );
      final shown = digest(wednesday);
      expect(
        shown.counts,
        const RecapCounts(
          notes: 2,
          tasksDone: 1,
          voiceNotes: 2,
          voiceMinutes: 11,
        ),
      );
      expect(shown.tasksOpen, 1);
      expect(shown.topics, hasLength(2));
    });

    test(
      'names its topics from tags and folders, most notes first, capped',
      () {
        final week = digest(weekOf(DateTime(2026, 11, 19)));
        expect(week.topics, [
          (name: 'Work', notes: 3),
          (name: 'Garden', notes: 1),
          (name: 'Travel', notes: 1),
        ]);
        expect(RecapDigest.topicsMax, 3);
      },
    );

    test('carries the week before, for one line of comparison', () {
      final week = digest(weekOf(DateTime(2026, 11, 19)));
      expect(week.previous, const RecapCounts(notes: 2));
      expect(digest(weekOf(DateTime(2026, 11, 26))).previous, week.counts);
    });

    test('puts a note on the day it was given, as the list does', () {
      ownDays['older'] = DateTime(2026, 11, 21);
      final week = digest(weekOf(DateTime(2026, 11, 19)));
      expect(week.perDay, [1, 2, 1, 0, 0, 1, 0]);
      expect(week.previous.notes, 1);
    });
  });

  group('takes each day as the list shows it', () {
    RecapDigest day(int year, int month, int day) => digest(
      RecapPeriod.containing(
        DateTime(year, month, day),
        RecapKind.day,
        firstWeekday: DateTime.monday,
      ),
    );

    test('in New York, across both switches', () {
      zone = 'America/New_York';
      note('before-spring', '2026-03-08T04:30:00Z');
      note('after-spring', '2026-03-09T03:30:00Z');
      note('after-fall', '2026-11-02T04:30:00Z');
      expect(day(2026, 3, 7).counts.notes, 1);
      expect(day(2026, 3, 8).counts.notes, 1);
      expect(day(2026, 11, 1).counts.notes, 1);
      expect(day(2026, 11, 2).counts.notes, 0);

      final week = digest(
        weekOf(DateTime(2026, 11, 1), firstWeekday: DateTime.sunday),
      );
      note('saturday', '2026-11-08T04:30:00Z');
      expect(
        digest(
          weekOf(DateTime(2026, 11, 1), firstWeekday: DateTime.sunday),
        ).perDay,
        [1, 0, 0, 0, 0, 0, 1],
      );
      expect(week.period.days, 7);
    });

    test('in London, across both switches', () {
      zone = 'Europe/London';
      note('spring', '2026-03-29T23:30:00Z');
      note('autumn', '2026-10-25T23:30:00Z');
      expect(day(2026, 3, 29).counts.notes, 0);
      expect(day(2026, 3, 30).counts.notes, 1);
      expect(day(2026, 10, 25).counts.notes, 1);
    });

    test('in India, with no switch', () {
      note('late', '2026-11-18T18:45:00Z');
      note('early', '2026-11-18T18:15:00Z');
      expect(day(2026, 11, 19).counts.notes, 1);
      expect(day(2026, 11, 18).counts.notes, 1);
    });

    test('and a task by the day it was done', () {
      zone = 'America/New_York';
      note('list', '2026-10-30T12:00:00Z', body: 'List\n☐ One');
      tick('2026-11-02T04:30:00Z', () {
        note('list', '2026-10-30T12:00:00Z', body: 'List\n☑ One');
      });
      expect(day(2026, 11, 1).counts.tasksDone, 1);
      expect(day(2026, 11, 2).counts.tasksDone, 0);
    });
  });

  test('a year counts month by month', () {
    note('jan', '2026-01-10T06:00:00Z');
    note('feb', '2026-02-28T06:00:00Z');
    note('nov-1', '2026-11-17T06:00:00Z');
    note('nov-2', '2026-11-18T06:00:00Z');
    note('last-year', '2025-12-31T06:00:00Z');
    final year = digest(
      RecapPeriod.containing(
        DateTime(2026, 6, 1),
        RecapKind.year,
        firstWeekday: DateTime.monday,
      ),
    );
    expect(year.perDay, hasLength(365));
    expect(year.perMonth, [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0]);
    expect(year.longestRun, 2);
    expect(year.busiestDay, DateTime(2026, 1, 10));
    expect(year.previous.notes, 1);
  });

  test('an empty period has no busiest day and no run', () {
    final week = digest(weekOf(DateTime(2026, 11, 19)));
    expect(week.counts, const RecapCounts());
    expect(week.busiestDay, isNull);
    expect(week.longestRun, 0);
    expect(week.topics, isEmpty);
    expect(week.counts.line, '');
  });

  test('too little for a recap below 3, 5, 10 and 30', () {
    for (final (kind, least) in [
      (RecapKind.day, 3),
      (RecapKind.week, 5),
      (RecapKind.month, 10),
      (RecapKind.year, 30),
    ]) {
      final short = least - 1;
      expect(
        RecapCounts(notes: short - 1, tasksDone: 1).tooLittleFor(kind),
        isTrue,
        reason: kind.name,
      );
      expect(
        RecapCounts(
          notes: short - 1,
          voiceNotes: 1,
          voiceMinutes: 40,
        ).tooLittleFor(kind),
        isTrue,
        reason: kind.name,
      );
      expect(
        RecapCounts(
          notes: least - 2,
          tasksDone: 1,
          voiceNotes: 1,
        ).tooLittleFor(kind),
        isFalse,
        reason: kind.name,
      );
    }
  });

  group('the counts line', () {
    test('names what there is, in the singular for one', () {
      expect(
        const RecapCounts(notes: 14, tasksDone: 9, voiceNotes: 2).line,
        '14 notes · 9 tasks done · 2 voice notes',
      );
      expect(
        const RecapCounts(notes: 1, tasksDone: 1, voiceNotes: 1).line,
        '1 note · 1 task done · 1 voice note',
      );
    });

    test('leaves out what is none', () {
      expect(
        const RecapCounts(notes: 3, voiceNotes: 2).line,
        '3 notes · 2 voice notes',
      );
      expect(const RecapCounts(tasksDone: 4).line, '4 tasks done');
      expect(
        const RecapCounts(voiceNotes: 2, voiceMinutes: 9).line,
        '2 voice notes',
      );
    });

    test('drops the voice notes first when it runs long', () {
      expect(
        const RecapCounts(notes: 1204, tasksDone: 312, voiceNotes: 48).line,
        '1204 notes · 312 tasks done',
      );
      expect(
        const RecapCounts(notes: 14, tasksDone: 19, voiceNotes: 2).line,
        '14 notes · 19 tasks done · 2 voice notes',
      );
      expect(
        const RecapCounts(notes: 140, tasksDone: 19, voiceNotes: 2).line,
        '140 notes · 19 tasks done',
      );
    });
  });
}
