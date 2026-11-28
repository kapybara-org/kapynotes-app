import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/data/tombstone.dart';
import 'package:kapy_notes/recaps/recap_maker.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_record.dart';

import 'recap_fixtures.dart';
import 'recap_maker_fixtures.dart';

void main() {
  late MakerWorld w;

  setUp(() => w = MakerWorld());
  tearDown(() => w.maker.dispose());

  String answer(RecapPeriod period) => recapAnswer(w.maker.chatOf(period)!)!;

  group('making', () {
    test('a day costs what it quoted, 1, and is kept as a recap', () async {
      final ai = ScriptedEngine([dayAnswer]);
      await w.start(engine: ai);
      final quote = w.maker.quote(w.day);
      expect(quote.credits, 1);
      expect(quote.digest.counts.notes, 3);

      expect(await w.maker.make(quote), isTrue);

      expect(ai.paid, quote.credits);
      expect(w.maker.hasRecap(w.day), isTrue);
      expect(w.maker.runOf(w.day), isNull);
      expect(w.maker.recordOf(w.day)!.numbers.counts.notes, 3);
    });

    test('a week costs what it quoted, 2', () async {
      final ai = ScriptedEngine(['A digest.', 'TITLE: Your week']);
      await w.start(engine: ai);
      final quote = w.maker.quote(w.week);
      expect(quote.credits, 2);
      await w.maker.make(quote);
      expect(ai.paid, 2);
      expect(w.maker.hasRecap(w.week), isTrue);
    });

    test('spends nothing when it would now cost more than it quoted', () async {
      final ai = ScriptedEngine();
      await w.start(
        engine: ai,
        more: (world) {
          world.notes.clear();
          for (final day in [2, 3, 4, 5, 6, 9, 10, 11, 12, 13]) {
            final date = DateTime.utc(2026, 11, day, 9);
            world.note('m$day', date.toIso8601String());
          }
          world.note('late', '2026-11-25T09:00:00Z', hidden: true);
        },
      );
      final month = periodOf(DateTime(2026, 11, 16), RecapKind.month);
      final quoted = w.maker.quote(month);
      expect(quoted.credits, 3);
      var heard = 0;
      w.maker.addListener(() => heard++);
      w.world.store.unhide('late');
      expect(w.maker.quote(month).credits, 4);

      expect(await w.maker.make(quoted), isFalse);

      expect(ai.asked, isEmpty);
      expect(w.maker.runOf(month), isNull);
      expect(heard, greaterThan(0));
    });

    test('spends nothing when the model changed since the quote', () async {
      final ai = ScriptedEngine([dayAnswer]);
      await w.start(engine: ai);
      w.ai.defaultModel = const KapyModel(
        kind: KapyModelKind.codex,
        id: 'gpt',
        label: 'GPT',
      );
      final own = w.maker.quote(w.day);
      expect(own.credits, 0);
      w.ai.defaultModel = KapyModel.cloud;
      expect(await w.maker.make(own), isFalse);
      expect(ai.asked, isEmpty);
    });

    test('shows its progress while it keeps going without a drawer', () async {
      final ai = GatedEngine();
      await w.start(engine: ai);
      final made = w.make(w.week);
      await pumpEventQueue();
      expect(w.maker.progressOf(w.week), (made: 0, parts: 2));
      expect(w.maker.making!.period, w.week);
      expect(w.maker.progressOf(w.day), isNull);

      ai.reply('A digest.');
      await pumpEventQueue();
      expect(w.maker.progressOf(w.week), (made: 1, parts: 2));

      ai.reply('TITLE: Your week');
      expect(await made, isTrue);
      expect(w.maker.progressOf(w.week), isNull);
      expect(w.maker.making, isNull);
      expect(w.maker.hasRecap(w.week), isTrue);
    });

    test('makes one recap at a time', () async {
      final ai = GatedEngine();
      await w.start(engine: ai);
      final made = w.make(w.week);
      await pumpEventQueue();
      expect(await w.make(w.day), isFalse);
      ai.reply('A digest.');
      await pumpEventQueue();
      ai.reply('TITLE: Your week');
      await made;
    });

    test('counts the numbers once the calls are back', () async {
      final ai = GatedEngine();
      await w.start(engine: ai);
      final made = w.make(w.day);
      await pumpEventQueue();
      w.world.store.hide('c');
      ai.reply(dayAnswer);
      await made;
      expect(w.maker.recordOf(w.day)!.numbers.counts.notes, 2);
    });
  });

  group('stopping and failing', () {
    test(
      'Stop keeps the parts made, so again costs only what is left',
      () async {
        final ai = GatedEngine();
        await w.start(engine: ai);
        final made = w.make(w.week);
        await pumpEventQueue();
        w.maker.stop(w.week);
        expect(w.maker.runOf(w.week)!.stopping, isTrue);
        ai.reply('A digest.');
        await made;

        expect(ai.waiting, isEmpty);
        expect(ai.paid, 1);
        expect(w.maker.runOf(w.week), isNull);
        expect(w.maker.hasRecap(w.week), isFalse);
        expect(w.maker.quote(w.week).credits, 1);

        final again = ScriptedEngine(['TITLE: Your week']);
        w.ai.engine = again;
        await w.make(w.week);
        expect(again.paid, 1);
        expect(w.maker.hasRecap(w.week), isTrue);
      },
    );

    test(
      'an error keeps the parts made, and Try again makes the rest',
      () async {
        final ai = GatedEngine();
        await w.start(engine: ai);
        final made = w.make(w.week);
        await pumpEventQueue();
        ai.reply('A digest.');
        await pumpEventQueue();
        ai.fail(const AnswerFailed('Kapy AI is busy.'));
        await made;

        final run = w.maker.runOf(w.week)!;
        expect(run.end, RecapEnd.failed);
        expect((run.failedPart, run.parts), (2, 2));
        expect(w.maker.quote(w.week).credits, 1);

        final again = ScriptedEngine(['TITLE: Your week']);
        w.ai.engine = again;
        await w.make(w.week);
        expect(ai.paid + again.paid, 2);
        expect(w.maker.runOf(w.week), isNull);
        expect(w.maker.hasRecap(w.week), isTrue);
      },
    );

    test('offline before anything came back used nothing', () async {
      final ai = GatedEngine();
      await w.start(engine: ai);
      final made = w.make(w.day);
      await pumpEventQueue();
      ai.fail(const AnswerOffline());
      await made;
      expect(w.maker.runOf(w.day)!.end, RecapEnd.offline);
      expect(ai.paid, 0);
    });

    test('offline after a part came back is an error that resumes', () async {
      final ai = GatedEngine();
      await w.start(engine: ai);
      final made = w.make(w.week);
      await pumpEventQueue();
      ai.reply('A digest.');
      await pumpEventQueue();
      ai.fail(const AnswerOffline());
      await made;
      expect(w.maker.runOf(w.week)!.end, RecapEnd.failed);
    });

    test('anything else that goes wrong is an error, not a crash', () async {
      final ai = GatedEngine();
      await w.start(engine: ai);
      final made = w.make(w.day);
      await pumpEventQueue();
      ai.fail(StateError('boom'));
      await made;
      expect(w.maker.runOf(w.day)!.end, RecapEnd.failed);
      expect(w.maker.making, isNull);
    });
  });

  group('credits', () {
    test('too few left asks nothing', () async {
      final ai = ScriptedEngine();
      await w.start(engine: ai, left: 1);
      expect(await w.make(w.week), isFalse);
      expect(ai.asked, isEmpty);
      final run = w.maker.runOf(w.week)!;
      expect(run.end, RecapEnd.noCredits);
      expect(run.usage!.remaining, 1);
    });

    test('running out partway keeps the parts and says so', () async {
      final ai = GatedEngine();
      await w.start(engine: ai);
      final made = w.make(w.week);
      await pumpEventQueue();
      ai.reply('A digest.');
      await pumpEventQueue();
      ai.fail(
        AnswerLimitReached(
          CloudUsage(remaining: 0, limit: 50, resetsAt: DateTime.utc(2026, 12)),
        ),
      );
      await made;
      final run = w.maker.runOf(w.week)!;
      expect(run.end, RecapEnd.noCredits);
      expect(run.usage!.limit, 50);
      expect(w.maker.quote(w.week).credits, 1);
    });

    test('Kapy AI Cloud locked asks to sign in or to upgrade', () async {
      final ai = ScriptedEngine();
      await w.start(engine: ai);
      w.ai.held = const KapyCloudLocked(signIn: true, upgrade: true);
      await w.make(w.day);
      expect(w.maker.runOf(w.day)!.end, RecapEnd.signIn);
      w.ai.held = const KapyCloudLocked(signIn: false, upgrade: true);
      await w.make(w.day);
      expect(w.maker.runOf(w.day)!.end, RecapEnd.upgrade);
      expect(ai.asked, isEmpty);
    });

    test('a session that ended partway asks to sign in', () async {
      final ai = ScriptedEngine([const AnswerSignInNeeded()]);
      await w.start(engine: ai);
      await w.make(w.day);
      expect(w.maker.runOf(w.day)!.end, RecapEnd.signIn);
    });

    test('an account of their own costs nothing and needs no usage', () async {
      final ai = ScriptedEngine([dayAnswer]);
      await w.start(engine: ai, left: null, pro: false);
      w.ai.set(
        accounts: [
          const KapyAccountState(
            kind: KapyAccountKind.claudeCode,
            status: KapyAccountStatus.connected,
            models: [
              KapyModel(kind: KapyModelKind.claudeCode, id: 's', label: 'S'),
            ],
          ),
        ],
      );
      expect(w.maker.model.kind, KapyModelKind.claudeCode);
      expect(w.maker.quote(w.day).credits, 0);
      expect(await w.make(w.day), isTrue);
      expect(w.maker.hasRecap(w.day), isTrue);
    });
  });

  group('takes words out', () {
    setUp(() async {
      await w.start(engine: ScriptedEngine([dayAnswer]));
      await w.make(w.day);
      expect(answer(w.day), contains('Alpha plan'));
    });

    void expectPruned(String id) {
      expect(answer(w.day), isNot(contains('Alpha plan')));
      expect(w.maker.handled, contains(id));
      expect(w.local.data[RecapMaker.handledKey], contains(id));
    }

    test('when a note is hidden here', () {
      w.world.store.hide('a');
      expectPruned('a');
    });

    test('when a hide arrives by sync', () {
      final at = DateTime.utc(2026, 11, 17, 13);
      final note = w.world.store.allNotes.firstWhere((note) => note.id == 'a');
      w.world.store.applyRemote(
        notes: [note.copyWith(hiddenAt: at, updatedAt: at)],
      );
      expectPruned('a');
    });

    test('when a note is deleted here', () {
      w.world.store.delete('a');
      expectPruned('a');
    });

    test('when notes are deleted together', () {
      w.world.store.deleteAll(['a']);
      expectPruned('a');
    });

    test('a delete held for Undo takes nothing out until it is final', () {
      w.world.store.holdDelete(['a']);
      expect(answer(w.day), contains('Alpha plan'));
      expect(w.maker.handled, isEmpty);
      w.world.store.undoDelete(['a']);
      expect(answer(w.day), contains('Alpha plan'));
      w.world.store.holdDelete(['a']);
      w.world.store.deleteAll(['a']);
      expectPruned('a');
    });

    test('when a delete arrives by sync', () {
      w.world.store.applyRemote(
        tombstones: [
          Tombstone(id: 'a', deletedAt: DateTime.utc(2026, 11, 17, 13)),
        ],
      );
      expectPruned('a');
    });

    test('a note the recap never read is left alone', () {
      w.world.store.hide('d');
      expect(answer(w.day), contains('Alpha plan'));
      expect(w.maker.handled, isEmpty);
    });

    test('reopening passes what was handled, and keeps it', () {
      w.world.store.hide('a');
      final pruned = w.maker.chatOf(w.day)!;
      w.maker.dispose();
      w.maker = w.build();
      expect(w.maker.handled, {'a'});
      expect(w.maker.chatOf(w.day), same(pruned));
      expect(w.maker.story(w.day)!.dropped, isFalse);
    });

    test('reopening takes out a hide no path saw', () {
      w.maker.dispose();
      w.world.store.hide('b');
      final story = w.maker.story(w.day)!;
      expect(story.dropped, isTrue);
      expect(story.lines.text, isNot(contains('Beta call')));
      w.maker = w.build();
      expect(answer(w.day), isNot(contains('Beta call')));
      expect(w.maker.handled, {'b'});
    });

    test('unhiding forgets the hide, so a later one is looked at again', () {
      w.world.store.hide('a');
      w.world.store.unhide('a');
      expect(w.maker.handled, isEmpty);
      expect(w.local.data[RecapMaker.handledKey], isEmpty);
    });
  });
}
