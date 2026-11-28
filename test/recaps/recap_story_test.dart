import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/recaps/recap_filter.dart';
import 'package:kapy_notes/recaps/recap_lines.dart';
import 'package:kapy_notes/recaps/recap_material.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_record.dart';
import 'package:kapy_notes/recaps/recap_story.dart';

import '../ai/ai_fakes.dart';
import 'recap_fixtures.dart';
import 'recap_story_samples.dart';

void main() {
  final thursday = dayOf(DateTime(2026, 11, 19));
  final made = DateTime(2026, 11, 20, 9);
  late RecapWorld world;

  void write({Set<String> hidden = const {}}) {
    world.note(
      'trip',
      '2026-11-19T08:00:00Z',
      body: 'Trip\n☑ Book\n☐ Pay',
      hidden: hidden.contains('trip'),
    );
    world.note(
      'standup',
      '2026-11-19T10:00:00Z',
      body: '${NoteAttachmentRef.placeholder}\nStandup',
      attachments: [recapVoice()],
      hidden: hidden.contains('standup'),
    );
    world.note(
      'plan',
      '2026-11-19T11:00:00Z',
      body: 'Plan\nThe deck, the room, a walk',
      hidden: hidden.contains('plan'),
    );
  }

  setUp(() async {
    world = RecapWorld();
    world.tick('2026-11-18T08:00:00Z', () {
      world.note('trip', '2026-11-19T08:00:00Z', body: 'Trip\n☐ Book\n☐ Pay');
    });
    world.tick('2026-11-19T12:00:00Z', write);
    await world.load();
  });

  KapyChat recap() {
    final material = world.material(thursday);
    return recapChat(
      null,
      record: RecapRecord(
        period: thursday,
        timeZone: 'UTC',
        firstWeekday: DateTime.monday,
        madeAt: made,
        numbers: RecapNumbers.of(world.digest(thursday), material),
        fingerprint: material.fingerprint,
      ),
      answer: [
        'TITLE: A full day',
        'HIGHLIGHT: Trip | Booked, one left to pay',
        'HIGHLIGHT: Plan | The plan for today',
        'QUOTE: Pricing call | 0:10 | We ship the annual plan first.',
        'NEXT: Pay for the trip',
      ].join('\n'),
      model: KapyModel.cloud,
      now: made,
    );
  }

  Future<RecapStory> reopen(
    KapyChat chat, {
    Set<String> hidden = const {},
  }) async {
    write(hidden: hidden);
    await world.load();
    return RecapStory.read(chat, world.material(thursday))!;
  }

  group('opening a recap again', () {
    test('reads its newest answer against what the day holds now', () async {
      final story = await reopen(recap());
      expect(story.name, 'Recap · Thu 19');
      expect(story.title, 'A full day');
      expect(story.lines.highlights.map((it) => it.noteId), ['trip', 'plan']);
      expect(story.lines.quote?.at, const Duration(seconds: 10));
      expect(story.voice?.hash, 'call');
      expect(story.done, ['Book']);
      expect(story.open, ['Pay']);
      expect(story.cards, [
        RecapCard.cover,
        RecapCard.numbers,
        RecapCard.highlights,
        RecapCard.tasks,
        RecapCard.voice,
        RecapCard.closing,
      ]);
    });

    test('drops a highlight of a note hidden since, and its tasks', () async {
      final story = await reopen(recap(), hidden: {'trip'});
      expect(story.lines.highlights.map((it) => it.noteId), ['plan']);
      expect(story.done, isEmpty);
      expect(story.open, isEmpty);
      expect(story.cards, isNot(contains(RecapCard.tasks)));
      expect(story.numbers.counts.tasksDone, 1, reason: 'numbers stay as made');
    });

    test('drops every line of Kapy AI’s naming a note hidden since', () async {
      final story = await reopen(recap(), hidden: {'trip'});
      expect(story.lines.next, isNull, reason: 'NEXT: Pay for the trip');
      expect(story.note.body.toLowerCase(), isNot(contains('trip')));
    });

    test('drops every line naming a title the app says is gone', () async {
      world.tick('2026-11-20T09:00:00Z', () {});
      final chat = recapChat(
        null,
        record: recapOf(recap())!,
        answer: [
          'TITLE: After the secret plan',
          'HIGHLIGHT: Plan | The plan for today',
          'TOPIC: Work | The secret plan, and leaving in June',
          'NEXT: Tell Bob about the Secret plan',
        ].join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
      final story = RecapStory.read(
        chat,
        world.material(thursday),
        gone: {'Secret plan'},
      )!;
      expect(story.title, 'Your day');
      expect(story.lines.topics, isEmpty);
      expect(story.lines.next, isNull);
      expect(story.lines.highlights.map((it) => it.noteId), ['plan']);
      expect(story.note.body.toLowerCase(), isNot(contains('secret')));
    });

    test(
      'drops the quote of a voice note hidden since, and its card',
      () async {
        final story = await reopen(recap(), hidden: {'standup'});
        expect(story.lines.quote, isNull);
        expect(story.voice, isNull);
        expect(story.cards, isNot(contains(RecapCard.voice)));
      },
    );

    test('drops a highlight of a note deleted since', () async {
      final chat = recap();
      world.notes.removeWhere((note) => note.id == 'plan');
      await world.load();
      final story = RecapStory.read(chat, world.material(thursday))!;
      expect(story.lines.highlights.map((it) => it.noteId), ['trip']);
    });

    test(
      'with nothing left to show, leaves out the cards, never empty',
      () async {
        final story = await reopen(
          recap(),
          hidden: {'trip', 'standup', 'plan'},
        );
        expect(story.cards, [
          RecapCard.cover,
          RecapCard.numbers,
          RecapCard.closing,
        ]);
        expect(story.title, 'A full day');
      },
    );

    test('reads a recap chat with no answer yet as one with no words', () {
      final asked = recap();
      final chat = KapyChat(
        id: asked.id,
        title: asked.title,
        createdAt: asked.createdAt,
        updatedAt: asked.updatedAt,
        model: asked.model,
        messages: [asked.messages.first],
        recap: asked.recap,
      );
      final story = RecapStory.read(chat, world.material(thursday))!;
      expect(story.title, 'Your day');
      expect(story.lines.text, isEmpty);
      expect(story.wordsGone, isFalse);
      expect(story.dropped, isFalse);
    });

    test('reads nothing from a chat that is not a recap of the period', () {
      final chat = recap();
      final friday = dayOf(DateTime(2026, 11, 20));
      expect(RecapStory.read(chat, world.material(friday)), isNull);
      final plain = KapyChat(
        id: 'c',
        title: 'Chat',
        createdAt: made,
        updatedAt: made,
        model: KapyModel.cloud,
        messages: const [],
      );
      expect(RecapStory.read(plain, world.material(thursday)), isNull);
    });
  });

  group('a note gone since the recap was made', () {
    final since = DateTime.utc(2026, 11, 25).toIso8601String();
    final before = DateTime.utc(2026, 11, 19, 13).toIso8601String();
    const answer = [
      'TITLE: A full day',
      'HIGHLIGHT: Trip | Booked, one left to pay',
      'QUOTE: Pricing call | 0:10 | We ship the annual plan first.',
      'NEXT: Pay for it before Friday',
    ];

    /// The day's recap, its one part having read every note of the day.
    KapyChat parted() {
      final material = world.material(thursday);
      final record = recapOf(recap())!;
      return recapChat(
        null,
        record: RecapRecord(
          period: record.period,
          timeZone: record.timeZone,
          firstWeekday: record.firstWeekday,
          madeAt: record.madeAt,
          numbers: record.numbers,
          fingerprint: record.fingerprint,
          read: [
            (
              first: 0,
              last: 0,
              notes: RecapFilter.of([
                for (final item in material.items) item.note.id,
              ]),
            ),
          ],
        ),
        answer: answer.join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
    }

    Future<RecapStory> reopenWith(
      KapyChat chat, {
      String? hiddenAt,
      String? archivedAt,
    }) async {
      world.note(
        'trip',
        '2026-11-19T08:00:00Z',
        body: 'Trip\n☑ Book\n☐ Pay',
        hiddenAt: hiddenAt,
        archivedAt: archivedAt,
      );
      await world.load();
      return RecapStory.read(chat, world.material(thursday))!;
    }

    void expectAllLeftOut(RecapStory story) {
      expect(story.lines.next, isNull, reason: 'Pay for it before Friday');
      expect(story.lines.title, isNull);
      expect(story.lines.highlights, isEmpty);
      expect(story.lines.quote, isNull, reason: 'the part read the trip too');
      expect(story.wordsGone, isTrue);
      expect(story.note.body.toLowerCase(), isNot(contains('friday')));
    }

    test('drops a line telling of it without naming it', () async {
      expectAllLeftOut(await reopenWith(parted(), hiddenAt: since));
    });

    test('a remake that comes back with no labelled lines has no words '
        'gone, and a prune that empties a worded answer has', () async {
      final chat = parted();
      final record = recapOf(chat)!;
      final later = DateTime.utc(2026, 11, 26);
      final remade = recapChat(
        chat,
        record: RecapRecord(
          period: record.period,
          timeZone: record.timeZone,
          firstWeekday: record.firstWeekday,
          madeAt: later,
          numbers: record.numbers,
          fingerprint: record.fingerprint,
        ),
        answer: 'A quiet day, nothing much to tell.',
        model: KapyModel.cloud,
        now: later,
      );
      final quiet = await reopenWith(remade);
      expect(quiet.lines.text, isEmpty);
      expect(quiet.wordsGone, isFalse, reason: 'nothing was hidden');

      final pruned = recapPruned(
        await reopenWith(chat, hiddenAt: since),
        now: later,
      )!;
      expect(
        RecapStory.read(pruned, world.material(thursday))!.wordsGone,
        isTrue,
        reason: 'the answer before it, under the same record, had words',
      );
    });

    test('a note hidden before the recap was made drops nothing', () async {
      final story = await reopenWith(parted(), hiddenAt: before);
      expect(story.lines.next, 'Pay for it before Friday');
      expect(story.lines.title, 'A full day');
      expect(story.lines.quote, isNotNull);
      expect(story.wordsGone, isFalse);
    });

    test('a note archived since drops nothing more', () async {
      final story = await reopenWith(parted(), archivedAt: since);
      expect(story.lines.next, 'Pay for it before Friday');
      expect(story.lines.title, 'A full day');
      expect(story.lines.quote, isNotNull);
      expect(story.wordsGone, isFalse);
    });

    test(
      'a held delete, a deleted note and an archive alone drop nothing',
      () async {
        final chat = parted();
        void expectKept(RecapStory story, String how) {
          expect(story.lines.next, 'Pay for it before Friday', reason: how);
          expect(story.lines.title, 'A full day', reason: how);
          expect(story.lines.quote, isNotNull, reason: how);
          expect(story.wordsGone, isFalse, reason: how);
        }

        world.store.holdDelete(['trip']);
        expectKept(RecapStory.read(chat, world.material(thursday))!, 'held');

        final local = MemoryStore()
          ..data['notes.v1'] = [for (final note in world.notes) note.toJson()];
        world.store = NotesStore(local, now: () => DateTime.utc(2026, 11, 25));
        await world.store.load();
        world.store.delete('trip');
        expect(world.store.tombstones.single.deletedAt.isAfter(made), isTrue);
        expectKept(RecapStory.read(chat, world.material(thursday))!, 'deleted');

        expectKept(await reopenWith(chat, archivedAt: since), 'archived');
      },
    );

    test('a note hidden and then deleted stays dropped once its tombstone is '
        'gone, by keeping the drop', () async {
      final chat = parted();
      final local = MemoryStore()
        ..data['notes.v1'] = [for (final note in world.notes) note.toJson()];
      world.store = NotesStore(local, now: () => DateTime.utc(2026, 11, 25));
      await world.store.load();
      world.store.hide('trip');
      final pruned = recapPruned(
        RecapStory.read(chat, world.material(thursday))!,
        now: DateTime.utc(2026, 11, 25),
      )!;
      expect(pruned.recap, chat.recap, reason: 'the record stays as made');
      world.store.delete('trip');
      await Future<void>.delayed(Duration.zero);
      final saved = local.data['notes.v2']! as Map;
      for (final stone in saved['tombstones'] as List) {
        (stone as Map)['syncedAt'] = stone['deletedAt'];
      }
      world.store = NotesStore(local, now: () => DateTime.utc(2027, 1, 5));
      await world.store.load();
      expect(world.store.tombstones, isEmpty, reason: 'synced, 41 days on');
      expect(
        world.store.allNotes.map((note) => note.id),
        isNot(contains('trip')),
      );
      final story = RecapStory.read(pruned, world.material(thursday))!;
      expectAllLeftOut(story);
      expect(story.cards, [
        RecapCard.cover,
        RecapCard.numbers,
        RecapCard.closing,
      ]);
      expect(recapPruned(story, now: DateTime.utc(2027, 1, 5)), isNull);

      final remade = recapChat(
        pruned,
        record: recapOf(pruned)!,
        answer: 'TITLE: A quieter day',
        model: KapyModel.cloud,
        now: DateTime.utc(2027, 1, 5),
      );
      final fresh = RecapStory.read(remade, world.material(thursday))!;
      expect(fresh.wordsGone, isFalse, reason: 'a remake with words');
      expect(fresh.title, 'A quieter day');
      expect(
        RecapStory.read(chat, world.material(thursday))!.lines.next,
        'Pay for it before Friday',
        reason: 'unkept, its words come back once the note is gone',
      );
    });

    test('with nothing left out, there is nothing to keep', () async {
      final story = await reopenWith(parted());
      expect(story.dropped, isFalse);
      expect(recapPruned(story, now: made), isNull);
    });

    test('a record with no parts treats every part as affected', () async {
      final chat = recapChat(
        null,
        record: recapOf(recap())!,
        answer: answer.join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
      expect((await reopenWith(chat)).lines.next, 'Pay for it before Friday');
      expectAllLeftOut(await reopenWith(chat, hiddenAt: since));
    });

    test('in a week, only the part that read it loses its words', () async {
      final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
      world = RecapWorld();
      world.note('deck', '2026-11-16T10:00:00Z', body: 'Deck\nDrafted');
      world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday\nOff early');
      await world.load();
      final material = world.material(week);
      RecapFilter read(DateTime first, DateTime last) => RecapFilter.of([
        for (final item in material.within(first, last)) item.note.id,
      ]);
      final chat = recapChat(
        null,
        record: RecapRecord(
          period: week,
          timeZone: 'UTC',
          firstWeekday: DateTime.monday,
          madeAt: made,
          numbers: RecapNumbers.of(world.digest(week), material),
          fingerprint: material.fingerprint,
          read: [
            (
              first: 0,
              last: 3,
              notes: read(week.first, DateTime(2026, 11, 19)),
            ),
            (first: 4, last: 6, notes: read(DateTime(2026, 11, 20), week.last)),
          ],
        ),
        answer: [
          'TITLE: Drafts and a day off',
          'HIGHLIGHT: Deck | Drafted on Monday',
          'TOPIC: Work | Quiet by the end',
          'NEXT: Take it easy again',
        ].join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
      world.note(
        'fri',
        '2026-11-20T10:00:00Z',
        body: 'Friday\nOff early',
        hiddenAt: since,
      );
      await world.load();
      final story = RecapStory.read(chat, world.material(week))!;
      expect(story.lines.title, isNull);
      expect(story.lines.topics, isEmpty);
      expect(story.lines.next, isNull);
      expect(story.lines.highlights.map((it) => it.noteId), ['deck']);
      expect(story.wordsGone, isFalse);

      final pruned = recapPruned(story, now: made)!;
      expect(pruned.messages, hasLength(chat.messages.length + 1));
      expect(recapAnswer(pruned), 'HIGHLIGHT: Deck | Drafted on Monday');
      final again = RecapStory.read(pruned, world.material(week))!;
      expect(again.cards, story.cards);
      expect(again.lines.text, story.lines.text);
      expect(again.dropped, isFalse);
    });

    group('in a week, a hide takes out only the parts that read it', () {
      final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
      late RecapMaterial material;
      late KapyChat chat;

      KapyChat recapReading(List<RecapRead> read, {RecapFilter? allRead}) =>
          recapChat(
            null,
            record: RecapRecord(
              period: week,
              timeZone: 'UTC',
              firstWeekday: DateTime.monday,
              madeAt: made,
              numbers: RecapNumbers.of(world.digest(week), material),
              fingerprint: material.fingerprint,
              read: read,
              allRead: allRead,
            ),
            answer: [
              'TITLE: Drafts and a walk',
              'HIGHLIGHT: Deck | Drafted on Monday',
              'HIGHLIGHT: Saturday | A long walk',
              'NEXT: Take it easy again',
            ].join('\n'),
            model: KapyModel.cloud,
            now: made,
          );

      setUp(() async {
        world = RecapWorld();
        world.note('deck', '2026-11-16T10:00:00Z', body: 'Deck\nDrafted');
        world.note('old', '2026-11-16T11:00:00Z', body: 'Old\nSomething');
        world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday\nOff early');
        world.note('sat', '2026-11-21T10:00:00Z', body: 'Saturday\nA walk');
        await world.load();
        material = world.material(week);
        chat = recapReading([
          (first: 0, last: 3, notes: RecapFilter.of(['deck', 'old'])),
          (first: 4, last: 6, notes: RecapFilter.of(['fri', 'sat'])),
        ]);
      });

      Future<RecapStory> hide(
        String id, {
        Set<String> handled = const {},
      }) async {
        final note = world.notes.firstWhere((note) => note.id == id);
        world.note(
          id,
          note.updatedAt.toIso8601String(),
          body: note.body,
          hiddenAt: since,
        );
        await world.load();
        return RecapStory.read(
          chat,
          RecapMaterial.gather(
            week,
            store: world.store,
            tasks: world.board,
            tags: world.tags,
            displayTime: world.displayTime,
          ),
          handled: handled,
        )!;
      }

      List<String> highlights(RecapStory story) =>
          story.lines.highlights.map((it) => it.noteId).toList();

      test('a hide already dealt with: nothing', () async {
        final story = await hide('fri', handled: {'fri'});
        expect(story.lines.title, 'Drafts and a walk');
        expect(highlights(story), ['deck', 'sat']);
        expect(story.dropped, isFalse);
      });

      test('the part that read it, whatever day it shows on now', () async {
        final story = await hide('fri');
        expect(story.lines.title, isNull);
        expect(story.lines.next, isNull);
        expect(highlights(story), ['deck']);
      });

      test('nothing, where the whole recap\'s filter says no part read it, '
          'whatever the parts say', () async {
        chat = recapReading([
          (first: 0, last: 3, notes: RecapFilter.of(['deck', 'old', 'fri'])),
          (first: 4, last: 6, notes: RecapFilter.of(['fri', 'sat'])),
        ], allRead: RecapFilter.of(['deck', 'old', 'sat']));
        final story = await hide('fri');
        expect(story.lines.title, 'Drafts and a walk');
        expect(highlights(story), ['deck', 'sat']);
      });

      test(
        'a set that does not read back takes out more, never less',
        () async {
          chat = recapReading([
            (first: 0, last: 3, notes: RecapFilter.of(['deck', 'old'])),
            (first: 4, last: 6, notes: RecapFilter.of(['fri', 'sat'])),
          ]);
          KapyChat broken({bool part = false, bool whole = false}) {
            String cut(String bits) => bits.substring(0, bits.length - 4);
            final recap = chat.recap!;
            final parts = [
              for (final read in recap['read']! as List) [...read as List],
            ];
            final all = [...recap['readAll']! as List];
            if (part) parts.last.last = cut(parts.last.last as String);
            if (whole) all.last = cut(all.last as String);
            return KapyChat(
              id: chat.id,
              title: chat.title,
              createdAt: chat.createdAt,
              updatedAt: chat.updatedAt,
              model: chat.model,
              messages: chat.messages,
              recap: {...recap, 'read': parts, 'readAll': all},
            );
          }

          expect(highlights(await hide('sat')), ['deck']);
          chat = broken(part: true);
          expect(
            highlights(await hide('sat')),
            isEmpty,
            reason: 'a part that does not read back may have read anything',
          );
        },
      );

      test('sets that do not read back take everything out, even for a note '
          'no part read', () async {
        final now = DateTime.utc(2026, 11, 26);
        world.note('new', '2026-11-26T10:00:00Z', body: 'New\nAfter it');
        await world.load();
        chat = recapReading([
          (first: 0, last: 3, notes: RecapFilter.of(['deck', 'old'])),
          (first: 4, last: 6, notes: RecapFilter.of(['fri', 'sat'])),
        ]);
        expect((await hide('new')).lines.title, 'Drafts and a walk');
        final recap = chat.recap!;
        String cut(Object? set) {
          final bits = (set! as List).last as String;
          return bits.substring(0, bits.length - 4);
        }

        chat = KapyChat(
          id: chat.id,
          title: chat.title,
          createdAt: chat.createdAt,
          updatedAt: now,
          model: chat.model,
          messages: chat.messages,
          recap: {
            ...recap,
            'read': [
              for (final read in recap['read']! as List)
                [...(read as List).take(4), cut(read)],
            ],
            'readAll': [
              ...(recap['readAll']! as List).take(2),
              cut(recap['readAll']),
            ],
          },
        );
        final story = await hide('new');
        expect(story.lines.title, isNull);
        expect(highlights(story), isEmpty);
      });

      test('a note the first part read: that part only', () async {
        final story = await hide('old');
        expect(story.lines.title, isNull);
        expect(highlights(story), ['sat']);
      });

      // Friday's note was made on the 20th, so the second part read it. A
      // day a note shows on can move after the recap was made, and then
      // the day it had before its hide is not the day that part read it on.
      Future<RecapStory> movedThenHidden({
        DateTime? Function(Note note)? ownDay,
      }) async {
        world.note(
          'fri',
          '2026-12-01T10:00:00Z',
          created: '2026-11-20T09:00:00Z',
          body: 'Friday\nOff early, and the plan for Monday',
          hiddenAt: '2026-12-01T10:00:00Z',
        );
        await world.load();
        return RecapStory.read(
          chat,
          RecapMaterial.gather(
            week,
            store: world.store,
            tasks: world.board,
            tags: world.tags,
            displayTime: world.displayTime,
            ownDay: ownDay,
          ),
        )!;
      }

      test('a note written in again after the recap, then hidden, still '
          'takes out the part that read it', () async {
        final story = await movedThenHidden();
        expect(story.lines.title, isNull);
        expect(story.lines.next, isNull);
        expect(highlights(story), ['deck']);
      });

      test('a note given another day after the recap, then hidden, still '
          'takes out the part that read it', () async {
        final story = await movedThenHidden(
          ownDay: (note) => note.id == 'fri' ? DateTime(2026, 11, 30) : null,
        );
        expect(story.lines.title, isNull);
        expect(story.lines.next, isNull);
        expect(highlights(story), ['deck']);
      });

      test('a note written on an earlier day\'s page takes out the part '
          'that covers that day', () async {
        // Made on the 20th on the page of the 17th, which a past day's page
        // or Move to another day allows, so the first part read it.
        chat = recapReading([
          (first: 0, last: 3, notes: RecapFilter.of(['deck', 'old', 'fri'])),
          (first: 4, last: 6, notes: RecapFilter.of(['sat'])),
        ]);
        world.note(
          'fri',
          '2026-12-01T10:00:00Z',
          created: '2026-11-20T09:00:00Z',
          body: 'Friday\nOff early',
          hiddenAt: '2026-12-01T10:00:00Z',
        );
        await world.load();
        final story = RecapStory.read(
          chat,
          RecapMaterial.gather(
            week,
            store: world.store,
            tasks: world.board,
            tags: world.tags,
            displayTime: world.displayTime,
            ownDay: (note) => note.id == 'fri' ? DateTime(2026, 11, 17) : null,
          ),
        )!;
        expect(story.lines.title, isNull);
        expect(highlights(story), isNot(contains('deck')));
      });
    });

    test('in a year, only the months of the part that read it', () async {
      final year = periodOf(DateTime(2026, 11, 19), RecapKind.year);
      world = RecapWorld();
      world.note('lisbon', '2026-03-10T10:00:00Z', body: 'Lisbon\nFlights');
      world.note('garden', '2026-06-05T10:00:00Z', body: 'Garden\nSeeds');
      world.note('pool', '2026-06-20T10:00:00Z', body: 'Pool\nOpen');
      await world.load();
      final material = world.material(year);
      RecapRead month(int m) => (
        first: year.indexOf(DateTime(2026, m))!,
        last: year.indexOf(DateTime(2026, m + 1, 0))!,
        notes: RecapFilter.of([
          for (final item in material.within(
            DateTime(2026, m),
            DateTime(2026, m + 1, 0),
          ))
            item.note.id,
        ]),
      );
      final chat = recapChat(
        null,
        record: RecapRecord(
          period: year,
          timeZone: 'UTC',
          firstWeekday: DateTime.monday,
          madeAt: made,
          numbers: RecapNumbers.of(world.digest(year), material),
          fingerprint: material.fingerprint,
          read: [month(3), month(6)],
        ),
        answer: [
          'TITLE: Trips and a garden',
          'MOMENT: March | Lisbon, booked at last',
          'MOMENT: June | Seeds in, and the pool open',
          'LINE: Small steps',
        ].join('\n'),
        model: KapyModel.cloud,
        now: made,
      );
      world.note(
        'garden',
        '2026-06-05T10:00:00Z',
        body: 'Garden\nSeeds',
        hiddenAt: since,
      );
      await world.load();
      final story = RecapStory.read(chat, world.material(year))!;
      expect(story.lines.moments.map((it) => it.month), [3]);
      expect(story.lines.line, isNull);
      expect(story.lines.title, isNull);
      expect(story.wordsGone, isFalse);
    });
  });

  group('as a note', () {
    test(
      'holds the words and names the notes, never one hidden since',
      () async {
        final story = await reopen(recap(), hidden: {'plan'});
        final note = story.note;
        expect(note.names, ['trip', 'standup']);
        expect(note.body, contains('- Trip: Booked, one left to pay'));
        expect(note.body, isNot(contains('Plan')));
        expect(note.body.split('\n').take(3), [
          'Recap · Thu 19',
          'A full day',
          '3 notes · 1 task done · 1 minute recorded',
        ]);
        expect(note.body, contains('“We ship the annual plan first.”'));
      },
    );

    test('starts no line of Kapy AI’s with what a note would format', () {
      final story = sampleDay(
        lines: const RecapLines(
          title: '# - [ ] **Big** [link](https://example.com)',
          next: '> 1. Done',
          topics: [(name: '## Work', line: '| a | b |')],
        ),
      );
      final lines = story.note.body.split('\n');
      expect(lines[1], '**Big** [link](https://example.com)');
      expect(story.note.body, contains('- Work: a | b |'));
      expect(lines.last, '- Done');
      for (final line in lines) {
        expect(line, isNot(matches(RegExp(r'^(#|>|\||\d+[.)]|\[)'))));
      }
    });
  });

  test('topics: the counted ones first, each with Kapy AI’s line', () {
    final story = sampleMonth();
    expect(story.topics, [
      (name: 'Work', notes: 38, line: null, colour: 'mustard'),
      (
        name: 'Acme',
        notes: 21,
        line: 'The pricing deck went from draft to signed.',
        colour: 'rust',
      ),
      (name: 'Lisbon', notes: 12, line: null, colour: 'slate'),
    ]);
    final year = sampleYear();
    expect(year.topics.last.line, 'A week in June, planned since March.');
  });

  test('a topic only Kapy AI named comes after, with no count', () {
    final story = RecapStory(
      record: sampleWeek().record,
      lines: const RecapLines(topics: [(name: 'Garden', line: 'Seeds in')]),
    );
    expect(story.topics.last, (
      name: 'Garden',
      notes: null,
      line: 'Seeds in',
      colour: null,
    ));
  });

  test('a tag topic takes its colour as the tag has it now', () async {
    world.tags.setTags('plan', [world.tags.create('Work')!.id]);
    world.folders.file(['trip'], world.folders.create('Travel')!.id);
    final work = world.tags.tags.single;
    world.tags.recolour(work.id, 'teal');
    final chat = recapChat(
      null,
      record: RecapRecord(
        period: thursday,
        timeZone: 'UTC',
        firstWeekday: DateTime.monday,
        madeAt: made,
        numbers: RecapNumbers.of(
          world.digest(thursday),
          world.material(thursday),
        ),
        fingerprint: world.material(thursday).fingerprint,
      ),
      answer: 'TOPIC: Garden | Seeds in',
      model: KapyModel.cloud,
      now: made,
    );
    expect(
      RecapStory.read(chat, world.material(thursday))!.topics,
      contains((name: 'Work', notes: 1, line: null, colour: 'teal')),
    );
    world.tags.recolour(work.id, 'plum');
    final story = RecapStory.read(chat, world.material(thursday))!;
    expect(
      story.topics.map((topic) => (topic.name, topic.colour)),
      unorderedEquals([('Work', 'plum'), ('Travel', null)]),
    );
  });

  test('a tag topic with a long name takes its colour by the name the '
      'record keeps', () async {
    final long = world.tags.create('話' * 20)!;
    world.tags.setTags('plan', [long.id]);
    world.tags.recolour(long.id, 'rose');
    final chat = recapChat(
      null,
      record: RecapRecord(
        period: thursday,
        timeZone: 'UTC',
        firstWeekday: DateTime.monday,
        madeAt: made,
        numbers: RecapNumbers.of(
          world.digest(thursday),
          world.material(thursday),
        ),
        fingerprint: world.material(thursday).fingerprint,
      ),
      answer: 'TITLE: A day',
      model: KapyModel.cloud,
      now: made,
    );
    expect(
      RecapStory.read(
        chat,
        world.material(thursday),
      )!.topics.map((topic) => (topic.name, topic.colour)),
      contains(('話' * 13, 'rose')),
    );
  });

  test('the busiest day and the longest run come from the numbers', () {
    final month = sampleMonth();
    expect(month.day(month.busiest!), DateTime(2026, 11, 18));
    expect(month.run, (DateTime(2026, 11, 15), DateTime(2026, 11, 26)));
    expect(sampleWeek().day(sampleWeek().busiest!), DateTime(2026, 11, 18));
    expect(sampleYear().run, isNull);
  });

  test('the day set beside the day before', () {
    expect(sampleDay().comparison, '2 more notes than Wed 18.');
  });

  test('durations and figures', () {
    expect(recapDuration(1), '1 minute');
    expect(recapDuration(12), '12 minutes');
    expect(recapDuration(60), '1 hour');
    expect(recapDuration(200), '3 h 20');
    expect(recapFigures(1086), '1,086');
    expect(recapFigures(1234567), '1,234,567');
  });

  test('shown text has no control or direction characters', () {
    expect(recapShown('a\u202eb\u0000c \n\t d\u2066'), 'a b c d');
  });

  test('the closing card names what comes next', () {
    expect(sampleDay().closingLabel, 'What’s next');
    expect(sampleWeek().closingLabel, 'Next week');
    expect(sampleMonth().closingLabel, 'December');
    expect(sampleYear().closingLabel, 'Into 2027');
    expect(
      RecapStory(record: sampleYear().record, lines: const RecapLines()).cards,
      [
        RecapCard.cover,
        RecapCard.numbers,
        RecapCard.months,
        RecapCard.topics,
        RecapCard.closing,
      ],
    );
    expect(sampleWeek().period.kind, RecapKind.week);
  });
}
