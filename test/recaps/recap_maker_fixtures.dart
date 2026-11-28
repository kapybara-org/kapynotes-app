import 'dart:async';

import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/recaps/recap_maker.dart';
import 'package:kapy_notes/recaps/recap_period.dart';

import '../ai/ai_fakes.dart';
import '../fake_kapy_ai.dart';
import 'recap_fixtures.dart';

/// Kapy AI for recaps: the engine a recap's calls go through, what holds
/// Kapy AI Cloud back, and whether the account is on the trial.
class RecapAi extends FakeKapyAi {
  RecapAi({super.pro = true, super.usage});

  AnswerEngine? engine;
  KapyPending? held;
  bool trial = false;

  @override
  AnswerEngine? recapEngine(KapyModel model) => engine;

  @override
  KapyPending? recapHold(KapyModel model) => held;

  @override
  bool get onTrial => trial;
}

/// Kapy AI that answers only when a test says: each call waits in
/// [waiting] until it is completed or failed. [paid] counts the answers
/// that came back, which is what Kapy AI Cloud counts.
class GatedEngine implements AnswerEngine {
  final List<Completer<String>> waiting = [];
  int paid = 0;

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    final gate = Completer<String>();
    waiting.add(gate);
    final text = await gate.future;
    paid++;
    return text;
  }

  /// Answers the oldest call still waiting.
  void reply(String text) => waiting.removeAt(0).complete(text);

  /// Fails the oldest call still waiting.
  void fail(Object failure) => waiting.removeAt(0).completeError(failure);
}

/// Notes, a chat book, Kapy AI and the maker over them. The clock is the
/// morning of Tue 17 Nov 2026, before the notes store's own clock, so a
/// hide or a delete comes after any recap made here.
class MakerWorld {
  final world = RecapWorld();
  final local = MemoryStore();
  late KapyChatBook book;
  late RecapAi ai;
  late RecapMaker maker;
  DateTime clock = DateTime.utc(2026, 11, 17, 5);

  /// Mon 16 Nov 2026.
  final RecapPeriod day = dayOf(DateTime(2026, 11, 16));

  /// 16–22 Nov 2026.
  final RecapPeriod week = periodOf(DateTime(2026, 11, 16), RecapKind.week);

  /// Three notes on Mon 16 and two on Fri 20, then everything loaded.
  Future<void> start({
    bool pro = true,
    int? left = 412,
    AnswerEngine? engine,
    void Function(RecapWorld world)? more,
  }) async {
    world
      ..note('a', '2026-11-16T09:00:00Z', body: 'Alpha plan\nShip it')
      ..note('b', '2026-11-16T10:00:00Z', body: 'Beta call\nWith Arjun')
      ..note('c', '2026-11-16T11:00:00Z', body: 'Gamma list\nMilk')
      ..note('d', '2026-11-20T09:00:00Z', body: 'Delta review\nFriday')
      ..note('e', '2026-11-20T10:00:00Z', body: 'Echo notes\nLate');
    more?.call(world);
    await world.load();
    book = KapyChatBook(MemoryStore());
    await book.load();
    ai = RecapAi(
      pro: pro,
      usage: left == null
          ? null
          : CloudUsage(
              remaining: left,
              limit: 500,
              resetsAt: DateTime.utc(2026, 12),
            ),
    )..engine = engine;
    if (pro) ai.set(model: KapyModel.cloud);
    maker = build();
  }

  RecapMaker build() => RecapMaker(
    notes: world.store,
    chats: book,
    ai: ai,
    tags: world.tags,
    local: local,
    tasks: () => world.board,
    folders: () => world.folders.tree,
    displayTime: world.displayTime,
    timeZone: () => 'UTC',
    firstWeekday: () => DateTime.sunday,
    now: () => clock,
    pause: (_) async {},
  );

  /// Makes [period]'s recap at the price quoted now, waiting for it.
  Future<bool> make(RecapPeriod period) => maker.make(maker.quote(period));
}

/// A day recap's answer naming two of Mon 16's notes.
const String dayAnswer =
    'TITLE: A busy Monday\n'
    'HIGHLIGHT: Alpha plan | Planned the launch\n'
    'HIGHLIGHT: Beta call | Called Arjun\n'
    'NEXT: Rest a little';
