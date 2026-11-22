import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/ui/notes_grouping.dart';

Note _note(String id, String body, DateTime updatedAt) => Note(
  id: id,
  body: body,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: updatedAt,
);

void main() {
  DateTime shown(DateTime at) => at;
  // A Thursday.
  final today = DateTime(2026, 11, 19);

  List<(String, String?, String)> outline(List<NoteGroup> groups) => [
    for (final group in groups)
      (group.label, group.detail, group.notes.map((note) => note.id).join(' ')),
  ];

  test('a note sits under the day it was last edited', () {
    final note = Note(
      id: 'plan',
      body: 'Plan',
      createdAt: DateTime(2026, 11, 2, 9),
      updatedAt: DateTime(2026, 11, 19, 23, 50),
    );
    expect(noteDay(note, shown), DateTime(2026, 11, 19));
  });

  test('by date: a heading for each day, newest first, with no date after '
      'Today or Yesterday', () {
    final notes = [
      _note('call', 'Call with Arjun', DateTime(2026, 11, 19, 11, 40)),
      _note('pages', 'Morning pages', DateTime(2026, 11, 19, 9, 12)),
      _note('ideas', 'Pricing ideas', DateTime(2026, 11, 17, 8)),
      _note('standup', 'Standup notes', DateTime(2026, 11, 18, 17)),
    ];
    expect(
      outline(
        groupNotes(
          notes,
          NotesGrouping.byDate,
          today: today,
          displayTime: shown,
          firstTag: (_) => null,
        ),
      ),
      [
        ('Today', null, 'call pages'),
        ('Yesterday', null, 'standup'),
        ('Tue 17', null, 'ideas'),
      ],
    );
  });

  test(
    'a note given a day sits under it, and one waiting for a later day folds into Upcoming',
    () {
      final notes = [
        _note('call', 'Call with Arjun', DateTime(2026, 11, 19, 11, 40)),
        _note('plan', 'Plan Friday', DateTime(2026, 11, 19, 9, 12)),
        _note('tax', 'Last year', DateTime(2026, 11, 19, 9, 20)),
        _note('trip', 'Packing', DateTime(2026, 11, 19, 9, 30)),
      ];
      final own = {
        'plan': DateTime(2026, 11, 21),
        'tax': DateTime(2026, 11, 17),
        'trip': DateTime(2026, 11, 23),
      };
      final groups = groupNotes(
        notes,
        NotesGrouping.byDate,
        today: today,
        displayTime: shown,
        firstTag: (_) => null,
        ownDay: (note) => own[note.id],
      );
      expect(outline(groups), [
        ('Upcoming', '2', 'plan trip'),
        ('Today', null, 'call'),
        ('Tue 17', null, 'tax'),
      ]);
      expect(
        [for (final group in groups) group.day],
        [null, DateTime(2026, 11, 19), DateTime(2026, 11, 17)],
      );
      expect(
        noteDay(notes[1], shown, ownDay: DateTime(2026, 11, 21)),
        DateTime(2026, 11, 21),
      );
    },
  );

  test('a note on today\'s own day stays in Today, not in Upcoming', () {
    final note = _note('call', 'Call', DateTime(2026, 11, 12, 8));
    expect(
      outline(
        groupNotes(
          [note],
          NotesGrouping.byDate,
          today: today,
          displayTime: shown,
          firstTag: (_) => null,
          ownDay: (_) => DateTime(2026, 11, 19),
        ),
      ),
      [('Today', null, 'call')],
    );
  });

  test(
    'a group by tag or by letter names no day, though its notes share one',
    () {
      final notes = [_note('call', 'Call', DateTime(2026, 11, 19, 11, 40))];
      for (final grouping in [NotesGrouping.byTag, NotesGrouping.aToZ]) {
        final groups = groupNotes(
          notes,
          grouping,
          today: today,
          displayTime: shown,
          firstTag: (_) => null,
        );
        expect(groups.single.day, isNull, reason: grouping.name);
      }
    },
  );

  test('by tag: each first tag by name, then the untagged', () {
    final at = DateTime(2026, 11, 19);
    final notes = [
      _note('call', 'Call', at),
      _note('gym', 'Gym', at),
      _note('book', 'Book', at),
      _note('launch', 'Launch', at),
    ];
    const tags = {'call': 'Work', 'book': 'ideas', 'launch': 'Work'};
    expect(
      outline(
        groupNotes(
          notes,
          NotesGrouping.byTag,
          today: today,
          displayTime: shown,
          firstTag: (note) => tags[note.id],
        ),
      ),
      [
        ('ideas', null, 'book'),
        ('Work', null, 'call launch'),
        ('No tag', null, 'gym'),
      ],
    );
  });

  test('A to Z: by title, a heading for each first letter, others last', () {
    final at = DateTime(2026, 11, 19);
    final notes = [
      _note('banana', 'banana bread', at),
      _note('apple', 'Apple pie', at),
      _note('plan', '2026 plan', at),
      _note('avocado', 'avocado toast', at),
      _note('eclair', 'Éclair', at),
    ];
    expect(
      outline(
        groupNotes(
          notes,
          NotesGrouping.aToZ,
          today: today,
          displayTime: shown,
          firstTag: (_) => null,
        ),
      ),
      [
        ('A', null, 'apple avocado'),
        ('B', null, 'banana'),
        ('É', null, 'eclair'),
        ('#', null, 'plan'),
      ],
    );
  });

  test('When reaches back by the day, the week and the month', () {
    bool covers(NotesWhen when, DateTime day, {int start = DateTime.monday}) =>
        when.span(today: today, firstWeekday: start)?.covers(day) ?? true;

    expect(covers(NotesWhen.anyTime, DateTime(2019, 3, 1)), isTrue);
    expect(covers(NotesWhen.today, today), isTrue);
    expect(covers(NotesWhen.today, DateTime(2026, 11, 18)), isFalse);

    // This week began on Monday the 16th, and next week isn't in it.
    expect(covers(NotesWhen.thisWeek, DateTime(2026, 11, 16)), isTrue);
    expect(covers(NotesWhen.thisWeek, DateTime(2026, 11, 22)), isTrue);
    expect(covers(NotesWhen.thisWeek, DateTime(2026, 11, 15)), isFalse);
    expect(covers(NotesWhen.thisWeek, DateTime(2026, 11, 23)), isFalse);
    expect(covers(NotesWhen.lastWeek, DateTime(2026, 11, 15)), isTrue);
    expect(covers(NotesWhen.lastWeek, DateTime(2026, 11, 9)), isTrue);
    expect(covers(NotesWhen.lastWeek, DateTime(2026, 11, 8)), isFalse);
    expect(covers(NotesWhen.lastWeek, DateTime(2026, 11, 16)), isFalse);

    // Where weeks start on Sunday, Sunday the 15th is this week.
    expect(
      covers(
        NotesWhen.thisWeek,
        DateTime(2026, 11, 15),
        start: DateTime.sunday,
      ),
      isTrue,
    );
    expect(
      covers(
        NotesWhen.thisWeek,
        DateTime(2026, 11, 14),
        start: DateTime.sunday,
      ),
      isFalse,
    );

    expect(covers(NotesWhen.thisMonth, DateTime(2026, 11, 1)), isTrue);
    expect(covers(NotesWhen.thisMonth, DateTime(2026, 10, 31)), isFalse);
  });

  test("When's menu names the days each span covers", () {
    String? detail(NotesWhen when, {int start = DateTime.monday}) =>
        when.detail(today: today, firstWeekday: start);

    expect(detail(NotesWhen.anyTime), isNull);
    expect(detail(NotesWhen.today), 'Thu 19');
    expect(detail(NotesWhen.thisWeek), '16–22 Nov');
    expect(detail(NotesWhen.thisWeek, start: DateTime.sunday), '15–21 Nov');
    expect(detail(NotesWhen.lastWeek), '9–15 Nov');
    expect(detail(NotesWhen.thisMonth), 'November');
    // A week across two months names both.
    expect(
      NotesWhen.thisWeek.detail(
        today: DateTime(2026, 12, 2),
        firstWeekday: DateTime.monday,
      ),
      '30 Nov – 6 Dec',
    );
  });
}
