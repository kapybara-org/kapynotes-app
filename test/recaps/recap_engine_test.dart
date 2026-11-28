import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/ai/retrieval.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/recaps/recap_engine.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_plan.dart';
import 'package:kapy_notes/recaps/recap_record.dart';
import 'package:kapy_notes/recaps/recap_story.dart';

import '../ai/ai_fakes.dart';
import 'recap_fixtures.dart';

void main() {
  late RecapWorld world;
  late KapyChatBook book;
  late DateTime now;
  late List<Duration> waits;
  late RecapEngine engine;

  setUp(() async {
    world = RecapWorld();
    book = KapyChatBook(MemoryStore());
    await book.load();
    now = DateTime(2027, 1, 5, 9);
    waits = [];
    engine = RecapEngine(
      notes: world.store = await notesWith(const []),
      chats: book,
      now: () => now,
      pause: (wait) async => waits.add(wait),
    );
  });

  /// A note on each of [days] of every month of [year].
  Future<void> notesOn(int year, List<int> days) async {
    for (var month = 1; month <= 12; month++) {
      for (final day in days) {
        final date = DateTime.utc(year, month, day, 10);
        if (date.month != month) continue;
        world.note(
          'n-$year-$month-$day',
          date.toIso8601String(),
          body: 'Note $month/$day\nWhat happened on $day',
        );
      }
    }
    await world.load();
    engine = RecapEngine(
      notes: world.store,
      chats: book,
      now: () => now,
      pause: (wait) async => waits.add(wait),
    );
  }

  RecapPlan plan(RecapPeriod period) => engine.plan(world.material(period));

  Future<RecapOutcome> make(
    RecapPeriod period,
    ScriptedEngine ai, {
    KapyModel model = KapyModel.cloud,
    RetrievalBudget budget = RetrievalBudget.cloud,
    bool Function()? stopped,
    List<(int, int)>? parts,
  }) => engine.make(
    plan(period),
    digest: () => world.digest(period),
    model: model,
    engine: ai,
    budget: budget,
    timeZone: 'UTC',
    firstWeekday: DateTime.monday,
    stopped: stopped,
    onPart: parts == null ? null : (made, of) => parts.add((made, of)),
  );

  void expectWithinContract(ScriptedEngine ai) {
    for (final request in ai.asked) {
      expect(request.question.length, lessThanOrEqualTo(2000));
      expect(request.notes.length, lessThanOrEqualTo(12));
      var total = 0;
      for (final note in request.notes) {
        expect(note.text.length, lessThanOrEqualTo(12000));
        expect(note.title.length, lessThanOrEqualTo(200));
        total += note.text.length;
      }
      expect(total, lessThanOrEqualTo(48000));
    }
  }

  group('the cost table', () {
    setUp(() => notesOn(2026, [1, 3, 8, 15, 17, 19, 22, 29]));

    test("is the plan's calls, which is what the server counts", () async {
      final table = {
        'day': plan(dayOf(DateTime(2026, 11, 19))).calls,
        'week': plan(periodOf(DateTime(2026, 11, 19), RecapKind.week)).calls,
        'month': plan(periodOf(DateTime(2026, 11, 1), RecapKind.month)).calls,
        'February': plan(periodOf(DateTime(2026, 2, 1), RecapKind.month)).calls,
        'year': plan(periodOf(DateTime(2026, 1, 1), RecapKind.year)).calls,
      };
      expect(table, {
        'day': 1,
        'week': 2,
        'month': 6,
        'February': 5,
        'year': 13,
      });
      final ai = ScriptedEngine();
      await make(periodOf(DateTime(2026, 11, 1), RecapKind.month), ai);
      expect(ai.paid, 6);
    });

    test("a leap year's February is 5 too, its 29th with the 22nd", () async {
      await notesOn(2028, [1, 8, 15, 22, 29]);
      final february = plan(periodOf(DateTime(2028, 2, 1), RecapKind.month));
      expect(february.calls, 5);
      expect(february.slices.last.last, DateTime(2028, 2, 29));
    });

    test('costs no credits through the own account or the device', () {
      final week = plan(periodOf(DateTime(2026, 11, 19), RecapKind.week));
      expect(week.credits(KapyModel.cloud), 2);
      expect(week.credits(FakeDeviceModel.apple), 0);
      expect(
        week.credits(
          const KapyModel(kind: KapyModelKind.codex, id: 'm', label: 'Model'),
        ),
        0,
      );
    });

    test('a slice with nothing in it is no call', () async {
      world = RecapWorld();
      world.note('only', '2026-10-02T10:00:00Z', body: 'Only\nnote');
      await notesOn(2025, const []);
      expect(plan(periodOf(DateTime(2026, 10, 1), RecapKind.month)).calls, 2);
    });
  });

  test('a day is one call, kept as a recap chat', () async {
    world.note('trip', '2026-11-19T08:00:00Z', body: 'Trip to Lisbon\nFlights');
    world.note(
      'standup',
      '2026-11-19T10:00:00Z',
      body: '${NoteAttachmentRef.placeholder}\nStandup',
      attachments: [recapVoice()],
    );
    world.note(
      'secret',
      '2026-11-19T11:00:00Z',
      body: 'Bank PIN 4321',
      hidden: true,
    );
    await notesOn(2025, const []);
    final ai = ScriptedEngine([
      'TITLE: Plans and pricing\n'
          'HIGHLIGHT: Trip to Lisbon | Flights booked\n'
          'HIGHLIGHT: Bank PIN 4321 | Your PIN\n'
          'QUOTE: Pricing call | 0:10 | We ship the annual plan first.\n'
          'NEXT: Pack',
    ]);
    final day = dayOf(DateTime(2026, 11, 19));
    final outcome = await make(day, ai) as RecapMade;
    expect(ai.asked.single.notes.map((n) => n.title), [
      'Trip to Lisbon',
      'Standup',
      'Pricing call',
    ]);
    expect(
      ai.asked.single.notes.map((n) => n.text).join(),
      isNot(contains('PIN')),
    );
    expect(outcome.lines.highlights.single.noteId, 'trip');
    expect(outcome.lines.quote!.at, const Duration(seconds: 10));
    final chat = book.chats.single;
    expect(chat.title, 'Recap · Thu 19');
    expect(chat.messages.first.text, 'Make a recap of Thu 19');
    expect(recapAnswer(chat), outcome.lines.text);
    final record = recapOf(chat)!;
    expect(record.period, day);
    expect(record.numbers.counts.notes, 2);
    expect(record.numbers.counts.voiceNotes, 1);
    expect(record.digest, isNull);
    expect(record.changesSince(world.material(day)), 0);
  });

  test(
    'a week reads its digest with its last days, and names their notes',
    () async {
      world.note('mon', '2026-11-16T10:00:00Z', body: 'Monday plans\nShip it');
      world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday review\nShipped');
      await notesOn(2025, const []);
      final ai = ScriptedEngine([
        'Monday plans said to ship it.',
        'TITLE: Shipped\n'
            'HIGHLIGHT: Monday plans | The plan\n'
            'HIGHLIGHT: Friday review | The review',
      ]);
      final outcome =
          await make(periodOf(DateTime(2026, 11, 19), RecapKind.week), ai)
              as RecapMade;
      expect(ai.asked.first.notes.single.title, 'Monday plans');
      expect(ai.asked.last.notes.map((n) => (n.title, n.text)), [
        ('16–19 Nov', 'Monday plans said to ship it.'),
        ('Friday review', 'Friday review\nShipped'),
      ]);
      expect(outcome.lines.highlights.map((it) => it.noteId), ['mon', 'fri']);
      expectWithinContract(ai);
    },
  );

  test('never gathers a note waiting to be deleted', () async {
    world.note('trip', '2026-11-19T08:00:00Z', body: 'Trip to Lisbon\nFlights');
    world.note('secret', '2026-11-19T11:00:00Z', body: 'Secret plan\nQuit');
    await notesOn(2025, const []);
    world.store.holdDelete(['secret']);
    final items = world.material(dayOf(DateTime(2026, 11, 19))).items;
    expect(items.map((item) => item.note.id), ['trip']);
  });

  group('a note hidden while the recap is made', () {
    final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
    setUp(() async {
      world.note('mon', '2026-11-16T10:00:00Z', body: 'Monday plans\nShip it');
      world.note('secret', '2026-11-17T10:00:00Z', body: 'Secret plan\nQuit');
      world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday review\nShipped');
      await notesOn(2025, const []);
    });

    const recap =
        'TITLE: Shipped\n'
        'HIGHLIGHT: Secret plan | Quit in June\n'
        'HIGHLIGHT: Monday plans | The plan\n'
        'HIGHLIGHT: Friday review | The review\n'
        'NEXT: Talk about the Secret plan';

    void expectLeftOut(ScriptedEngine ai, RecapMade made) {
      expect(
        ai.asked.last.notes.map((n) => '${n.title}\n${n.text}').join('\n'),
        isNot(contains(RegExp('secret|june', caseSensitive: false))),
      );
      expect(made.lines.highlights.map((it) => it.noteId), ['fri']);
      expect(made.lines.next, isNull);
      expect(ai.paid, 2);
      expect(ai.asked.last.notes.map((n) => n.title), ['Friday review']);
      expect(made.lines.text, isNot(contains('Secret')));
      expect(recapAnswer(book.chats.single), isNot(contains('Secret')));
    }

    test('leaves the part out where its digest names it', () async {
      final ai = ScriptedEngine();
      ai.reply = (request) {
        if (ai.asked.length == 1) {
          world.store.hide('secret');
          return 'Monday plans said to ship it. Secret plan: quit in '
              'June.\nShip on Friday.';
        }
        return recap;
      };
      expectLeftOut(ai, await make(week, ai) as RecapMade);
    });

    test('leaves the part out where its digest never names it', () async {
      final ai = ScriptedEngine();
      ai.reply = (request) {
        if (ai.asked.length == 1) {
          world.store.hide('secret');
          return 'Monday plans said to ship it. Someone may quit in June.';
        }
        return recap;
      };
      expectLeftOut(ai, await make(week, ai) as RecapMade);
    });

    test('asks nothing more when no part is left', () async {
      world = RecapWorld();
      world.note('only', '2026-10-02T10:00:00Z', body: 'Only\nnote');
      await notesOn(2025, const []);
      final october = periodOf(DateTime(2026, 10, 1), RecapKind.month);
      expect(plan(october).calls, 2);
      final ai = ScriptedEngine();
      ai.reply = (request) {
        world.store.hide('only');
        return 'Only note.';
      };
      final made = await make(october, ai) as RecapMade;
      expect(ai.paid, 1);
      expect(made.lines.text, isEmpty);
      expect(recapAnswer(book.chats.single), 'Recap · October');
    });

    test(
      'drops its highlight when it is hidden during the last call',
      () async {
        final ai = ScriptedEngine();
        ai.reply = (request) {
          if (ai.asked.length == 1) return 'Monday plans said to ship it.';
          world.store.hide('mon');
          return recap;
        };
        world.store.hide('secret');
        final made = await make(week, ai) as RecapMade;
        expect(made.lines.highlights.map((it) => it.noteId), ['fri']);
        expect(made.lines.text, isNot(contains('Monday plans')));
      },
    );
  });

  group('which notes each part read', () {
    final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);

    test('a part a slice, and one for what the last call read', () async {
      world.note('mon', '2026-11-16T10:00:00Z', body: 'Monday plans\nShip it');
      world.note('thu', '2026-11-19T10:00:00Z', body: 'Thursday\nDemo');
      world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday review\nShipped');
      await notesOn(2025, const []);
      await make(week, ScriptedEngine()..reply = (_) => 'TITLE: Shipped');
      final read = recapOf(book.chats.single)!.read!;
      expect(read.map((part) => (part.first, part.last)), [(0, 3), (4, 6)]);
      expect(read[0].notes.mayHold('mon'), isTrue);
      expect(read[0].notes.mayHold('thu'), isTrue);
      expect(read[0].notes.mayHold('fri'), isFalse);
      expect(read[1].notes.mayHold('fri'), isTrue);
      expect(read[1].notes.mayHold('mon'), isFalse);
    });

    test('a part left out meanwhile gets none', () async {
      world.note('mon', '2026-11-16T10:00:00Z', body: 'Monday plans\nShip it');
      world.note('secret', '2026-11-17T10:00:00Z', body: 'Secret plan\nQuit');
      world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday review\nShipped');
      await notesOn(2025, const []);
      final ai = ScriptedEngine();
      ai.reply = (request) {
        if (ai.asked.length == 1) world.store.hide('secret');
        return 'TITLE: Shipped';
      };
      await make(week, ai);
      final read = recapOf(book.chats.single)!.read!;
      expect(read.map((part) => (part.first, part.last)), [(4, 6)]);
    });

    test(
      "a year's month from its own recap takes that month's notes",
      () async {
        await notesOn(2026, [1, 15]);
        for (var month = 1; month <= 12; month++) {
          now = DateTime(2026, month + 1, 2);
          await make(
            periodOf(DateTime(2026, month), RecapKind.month),
            ScriptedEngine()
              ..reply = (request) =>
                  request.question.startsWith('These are digests')
                  ? 'TITLE: Month $month'
                  : 'Digest.',
          );
        }
        final march = recapOf(
          engine.recaps.firstWhere(
            (chat) => recapOf(chat)!.period.first.month == 3,
          ),
        )!;
        expect(march.read!.map((part) => (part.first, part.last)), [
          (0, 6),
          (14, 20),
        ]);
        final year = periodOf(DateTime(2026, 1, 1), RecapKind.year);
        expect(plan(year).calls, 1);
        now = DateTime(2027, 1, 5);
        await make(year, ScriptedEngine()..reply = (_) => 'TITLE: 2026');
        final made = recapOf(recapChatOf(engine.recaps, year)!)!.read!;
        expect(made, hasLength(12));
        expect(made[2].first, year.indexOf(DateTime(2026, 3, 1)));
        expect(made[2].last, year.indexOf(DateTime(2026, 3, 31)));
        expect(made[2].notes.mayHold('n-2026-3-1'), isTrue);
        expect(made[2].notes.mayHold('n-2026-3-15'), isTrue);
        expect(made[3].notes.mayHold('n-2026-3-15'), isFalse);
      },
    );
  });

  group('a note hidden while the recap is made, more ways', () {
    final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
    setUp(() async {
      world.note('mon', '2026-11-16T10:00:00Z', body: 'Monday plans\nShip it');
      world.note('secret', '2026-11-17T10:00:00Z', body: 'Secret plan\nQuit');
      world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday review\nShipped');
      world.note(
        'old',
        '2026-11-10T10:00:00Z',
        body: 'Clinic\n☐ Book the biopsy',
      );
      world.tick('2026-11-17T09:00:00Z', () {
        world.note(
          'old',
          '2026-11-10T10:00:00Z',
          body: 'Clinic\n☑ Book the biopsy',
        );
      });
      await notesOn(2025, const []);
    });

    String last(ScriptedEngine ai) =>
        ai.asked.last.notes.map((n) => '${n.title}\n${n.text}').join('\n');

    test("leaves out a later day's note held for deleting meanwhile", () async {
      final ai = ScriptedEngine();
      ai.reply = (request) {
        if (ai.asked.length == 1) {
          world.store.holdDelete(['fri']);
          return 'Monday plans said to ship it.';
        }
        return 'TITLE: Shipped';
      };
      await make(week, ai);
      expect(ai.paid, 2);
      expect(last(ai), isNot(contains('Friday')));
    });

    test('drops the sentence after the one naming it, too', () async {
      final ai = ScriptedEngine();
      ai.reply = (request) {
        if (ai.asked.length == 1) {
          world.store.hide('secret');
          return 'Monday plans said to ship it. Secret plan: quit in June. '
              'It means telling Bob first.';
        }
        return 'TITLE: Shipped';
      };
      await make(week, ai);
      expect(ai.paid, 2);
      expect(
        last(ai),
        isNot(contains(RegExp('june|bob', caseSensitive: false))),
      );
    });

    for (final (how, gone) in <(String, void Function(String id))>[
      ('hidden', (id) => world.store.hide(id)),
      ('held for deleting', (id) => world.store.holdDelete([id])),
    ]) {
      test('leaves out the tasks of a note $how meanwhile', () async {
        final ai = ScriptedEngine();
        ai.reply = (request) {
          if (ai.asked.length == 1) {
            gone('old');
            return 'Monday plans said to ship it. Booked the biopsy.';
          }
          return 'TITLE: Shipped';
        };
        await make(week, ai);
        expect(ai.paid, 2);
        for (final request in ai.asked.skip(1)) {
          expect(
            request.notes.map((n) => '${n.title}\n${n.text}').join('\n'),
            isNot(contains('biopsy')),
          );
        }
      });
    }
  });

  group('a part that fails', () {
    setUp(() => notesOn(2026, [1, 8, 15, 22, 29]));
    final november = periodOf(DateTime(2026, 11, 1), RecapKind.month);

    test(
      'keeps the parts before it, and Try again makes only the rest',
      () async {
        final ai = ScriptedEngine([
          'First week.',
          'Second week.',
          const AnswerFailed("Couldn't answer just now. Try again."),
        ]);
        final parts = <(int, int)>[];
        final stopped = await make(november, ai, parts: parts) as RecapStopped;
        expect((stopped.part, stopped.parts), (3, 6));
        expect(stopped.failure, isA<AnswerFailed>());
        expect(parts, [(1, 6), (2, 6)]);
        expect(ai.paid, 2);
        expect(book.chats, isEmpty);

        expect(plan(november).calls, 4);
        final again = ScriptedEngine();
        final made = await make(november, again, parts: parts);
        expect(made, isA<RecapMade>());
        expect(again.asked, hasLength(4));
        expect(ai.paid + again.paid, 6);
        expect(again.asked.last.notes.map((n) => n.text).take(2), [
          'First week.',
          'Second week.',
        ]);
        expect(parts.last, (6, 6));
      },
    );

    test('a part whose days changed since is made again', () async {
      final first = ScriptedEngine(['First.', const AnswerOffline()]);
      await make(november, first);
      world.note('n-2026-11-1', '2026-11-01T11:00:00Z', body: 'Changed\ntoday');
      await world.load();
      expect(plan(november).calls, 6);
    });

    test('offline, the limit and a sign-in each stop it where it is', () async {
      for (final failure in <AnswerFailure>[
        const AnswerOffline(),
        AnswerLimitReached(
          CloudUsage(remaining: 0, limit: 500, resetsAt: DateTime(2026, 12)),
        ),
        const AnswerSignInNeeded(),
        const AnswerProNeeded(),
      ]) {
        final ai = ScriptedEngine([failure]);
        final stopped =
            await make(periodOf(DateTime(2026, 10, 1), RecapKind.month), ai)
                as RecapStopped;
        expect(stopped.failure, same(failure));
        expect(stopped.part, 1);
        expect(ai.paid, 0);
      }
    });

    test('the recap call failing keeps every digest', () async {
      final ai = ScriptedEngine([
        for (var i = 0; i < 5; i++) 'Digest $i.',
        const AnswerFailed('Kapy AI couldn\'t answer. Try again.'),
      ]);
      final stopped = await make(november, ai) as RecapStopped;
      expect((stopped.part, stopped.parts), (6, 6));
      expect(plan(november).calls, 1);
    });

    test('stopping keeps what was made', () async {
      var asked = 0;
      final ai = ScriptedEngine()..reply = (_) => 'Digest ${++asked}.';
      final stopped =
          await make(november, ai, stopped: () => asked == 2) as RecapStopped;
      expect(stopped.failure, isNull);
      expect(stopped.part, 3);
      expect(plan(november).calls, 4);
    });
  });

  group('asked too fast', () {
    setUp(() => notesOn(2026, [19]));
    final day = dayOf(DateTime(2026, 11, 19));

    test('waits for Retry-After and asks again, at no cost', () async {
      final ai = ScriptedEngine([
        const AnswerTooFast('busy', Duration(seconds: 7)),
        const AnswerTooFast('busy', Duration(minutes: 10)),
        'TITLE: Done',
      ]);
      expect(await make(day, ai), isA<RecapMade>());
      expect(waits, [const Duration(seconds: 7), const Duration(minutes: 1)]);
      expect(ai.asked, hasLength(3));
      expect(ai.paid, 1);
    });

    test('stops after asking three times', () async {
      final ai = ScriptedEngine([
        for (var i = 0; i < 3; i++)
          const AnswerTooFast('busy', Duration(seconds: 6)),
      ]);
      final stopped = await make(day, ai) as RecapStopped;
      expect(stopped.failure, isA<AnswerTooFast>());
      expect(waits, hasLength(2));
    });
  });

  group('a year', () {
    setUp(() => notesOn(2026, [1, 8, 15, 22, 29]));
    final year = periodOf(DateTime(2026, 1, 1), RecapKind.year);

    test(
      'never sends a month digest again once a note in it is hidden',
      () async {
        world.note(
          'secret',
          '2026-03-10T10:00:00Z',
          body: 'Secret plan\nQuit in June',
        );
        await notesOn(2026, const []);
        now = DateTime(2026, 4, 2);
        await make(
          periodOf(DateTime(2026, 3), RecapKind.month),
          ScriptedEngine()
            ..reply = (request) =>
                request.question.startsWith('These are digests')
                ? 'TITLE: March\nHIGHLIGHT: Secret plan | Quit in June'
                : 'Secret plan: quit in June.',
        );
        expect(recapOf(engine.recaps.single)!.digest, contains('Secret plan'));

        world.note(
          'secret',
          '2026-03-10T10:00:00Z',
          body: 'Secret plan\nQuit in June',
          hidden: true,
        );
        await notesOn(2026, const []);
        now = DateTime(2027, 1, 5);
        final ai = ScriptedEngine()..reply = (_) => 'TITLE: 2026';
        await make(year, ai);
        for (final request in ai.asked) {
          for (final note in request.notes) {
            expect('${note.title}\n${note.text}', isNot(contains('Secret')));
          }
        }
      },
    );

    test('reads each month recap made once it was over: 1 call', () async {
      for (var month = 1; month <= 12; month++) {
        now = DateTime(2026, month + 1, 2);
        final ai = ScriptedEngine()
          ..reply = (request) =>
              request.question.startsWith('These are digests')
              ? 'TITLE: Month $month\nTOPIC: Work | Busy in $month'
              : 'Digest.';
        await make(periodOf(DateTime(2026, month), RecapKind.month), ai);
      }
      expect(engine.recaps, hasLength(12));
      expect(plan(year).calls, 1);
      final ai = ScriptedEngine([
        'TITLE: 2026\nMOMENT: March | Month 3\nLINE: Small steps',
      ]);
      final made = await make(year, ai) as RecapMade;
      expect(ai.paid, 1);
      final notes = ai.asked.single.notes;
      expect(notes.map((n) => n.title).first, 'January');
      expect(notes, hasLength(12));
      expect(notes[2].text, 'Month 3\nWork: Busy in 3');
      expect(made.lines.moments.single.month, 3);
      expect(engine.recaps, hasLength(13));
    });

    test(
      'a month recap made while the month was going on gives none',
      () async {
        now = DateTime(2026, 11, 20);
        final november = periodOf(DateTime(2026, 11, 1), RecapKind.month);
        await make(november, ScriptedEngine()..reply = (_) => 'TITLE: So far');
        expect(recapOf(engine.recaps.single)!.digest, isNull);
        expect(plan(year).calls, 13);
      },
    );
  });

  test('every call stays within the contract on a busy day', () async {
    for (var i = 0; i < 30; i++) {
      world.note(
        'busy-$i',
        '2026-11-19T${(i % 12 + 8).toString().padLeft(2, '0')}:00:00Z',
        body: 'Busy $i\n${List.filled(900, 'word $i').join('\n')}',
      );
    }
    await notesOn(2025, const []);
    final ai = ScriptedEngine(['TITLE: Busy']);
    await make(dayOf(DateTime(2026, 11, 19)), ai);
    expectWithinContract(ai);
    expect(ai.asked.single.notes, hasLength(12));
  });

  test(
    "the own account and the device run the same plan, the device's smaller",
    () async {
      await notesOn(2026, [19]);
      world.note('long', '2026-11-19T12:00:00Z', body: 'Long\n${'x' * 20000}');
      await notesOn(2025, const []);
      final codex = FakeLocalTool(KapyAccountKind.codex);
      final outcome = await make(
        dayOf(DateTime(2026, 11, 19)),
        ScriptedEngine(),
        model: codex.model,
      );
      expect(outcome, isA<RecapMade>());
      expect(recapOf(book.chats.single), isNotNull);
      final device = FakeDeviceModel();
      final budget = RetrievalBudget.device(device.noteChars);
      final ai = ScriptedEngine();
      await make(
        dayOf(DateTime(2026, 11, 19)),
        ai,
        model: FakeDeviceModel.apple,
        budget: budget,
      );
      expect(
        ai.asked.single.notes.fold(0, (sum, n) => sum + n.text.length),
        lessThanOrEqualTo(device.noteChars),
      );
      expect(book.chats.single.messages, hasLength(3));
    },
  );

  for (final (how, gone) in <(String, void Function(String id))>[
    ('hidden', (id) => world.store.hide(id)),
    ('archived', (id) => world.store.archive(id)),
    ('deleted', (id) => world.store.delete(id)),
  ]) {
    test('never sends a note $how after the plan was made', () async {
      world.note('secret', '2026-11-19T11:00:00Z', body: 'Secret plan\nQuit');
      await notesOn(2026, [19]);
      final day = dayOf(DateTime(2026, 11, 19));
      final planned = plan(day);
      gone('secret');
      final ai = ScriptedEngine(['TITLE: Day']);
      await engine.make(
        planned,
        digest: () => world.digest(day),
        model: KapyModel.cloud,
        engine: ai,
        budget: RetrievalBudget.cloud,
        timeZone: 'UTC',
        firstWeekday: DateTime.monday,
      );
      expect(
        ai.asked.single.notes.map((n) => '${n.title}\n${n.text}').join('\n'),
        isNot(contains('Secret')),
      );
    });
  }

  test(
    'a note hidden during the last call drops its words on reopening',
    () async {
      world.note('mon', '2026-11-16T10:00:00Z', body: 'Monday plans\nShip it');
      world.note('fri', '2026-11-20T10:00:00Z', body: 'Friday review\nQuit');
      await notesOn(2025, const []);
      final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
      now = testNow.subtract(const Duration(hours: 1));
      final ai = ScriptedEngine();
      ai.reply = (request) {
        if (ai.asked.length == 1) return 'Monday plans said to ship it.';
        world.store.hide('fri');
        now = testNow.add(const Duration(hours: 1));
        return 'TITLE: Leaving soon\nNEXT: Hand in the notice';
      };
      await make(week, ai);
      expect(world.store.byId('fri')!.hiddenAt, testNow);
      final story = RecapStory.read(book.chats.single, world.material(week))!;
      expect(story.lines.title, isNull);
      expect(story.lines.next, isNull);
    },
  );
}
