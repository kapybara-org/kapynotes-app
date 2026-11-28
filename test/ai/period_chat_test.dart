import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_ai_controller.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/ai/period_scope.dart';
import 'package:kapy_notes/ai/retrieval.dart';
import 'package:kapy_notes/recaps/recap_engine.dart';
import 'package:kapy_notes/recaps/recap_period.dart';

import '../recaps/recap_fixtures.dart';
import 'ai_fakes.dart';
import 'fake_cli.dart';

/// Kapy AI asked about a period: what it reads, what it sends and what the
/// chat keeps.
void main() {
  final week = periodOf(DateTime(2026, 11, 17), RecapKind.week);
  final tuesday = dayOf(DateTime(2026, 11, 17));
  final usage = {
    'used': 3,
    'limit': 500,
    'remaining': 497,
    'resetsAt': DateTime.utc(2026, 12).toIso8601String(),
  };

  late RecapWorld world;
  late MemoryStore store;
  late KapyChatBook book;
  late List<http.Request> sent;
  late int reads;

  setUp(() async {
    world = RecapWorld();
    await world.tags.load();
    await world.folders.load();
    world.note(
      'call',
      '2026-11-17T09:00:00Z',
      body: 'Call with Arjun\npricing',
    );
    void launch(String done) => world.note(
      'launch',
      '2026-11-17T10:00:00Z',
      body: 'Launch\n$done Write notes\n☐ Ship the deck',
    );
    world.tick('2026-11-16T10:00:00Z', () => launch('☐'));
    world.tick('2026-11-17T10:00:00Z', () => launch('☑'));
    world.note('october', '2026-10-02T09:00:00Z', body: 'October pricing');
    world.note(
      'bank',
      '2026-11-17T11:00:00Z',
      body: 'Bank pricing PIN 4321',
      hidden: true,
    );
    await world.load();
    store = MemoryStore()..data['kapyAi.v1'] = {'cloudConsent': true};
    book = KapyChatBook(store);
    sent = [];
    reads = 0;
  });

  Future<KapyAiController> build({bool reader = true}) async {
    final ai = KapyAiController(
      store: store,
      chats: book,
      notes: world.store,
      device: FakeDeviceModel(),
      billing: await billingOn(pro: true),
      token: () => 'session-token',
      client: MockClient((request) async {
        sent.add(request);
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('/ai/usage')
                ? usage
                : {'answer': 'Ship the deck is still open.', 'usage': usage},
          ),
          200,
        );
      }),
      codex: FakeLocalTool(KapyAccountKind.codex),
      claudeCode: FakeLocalTool(KapyAccountKind.claudeCode),
      apiBaseUrl: Uri.parse('https://api.test/'),
      now: () => testNow,
      toolHelper: FakeToolHelper(answers: false),
    );
    ai.pickModel(KapyModel.cloud);
    if (reader) {
      ai.periods = (period) {
        reads++;
        return KapyPeriodRead(world.material(period), world.digest(period));
      };
    }
    addTearDown(ai.dispose);
    return ai;
  }

  List<Map<String, Object?>> asked() => [
    for (final request in sent)
      if (request.url.path.endsWith('/ai/answer'))
        (jsonDecode(request.body) as Map).cast<String, Object?>(),
  ];

  String notesOf(Map<String, Object?> body) => [
    for (final note in body['notes']! as List)
      '${note['title']} ${note['text']}',
  ].join('\n');

  test('reads only the period, names it first, and keeps it', () async {
    final ai = await build();
    await ai.ask('Anything?', period: week);

    final body = asked().single;
    expect(body['question'], 'About 16–22 Nov 2026:\nAnything?');
    final notes = notesOf(body);
    expect(notes, contains('Call with Arjun'));
    expect(notes, contains('Ship the deck'), reason: 'the tasks go too');
    expect(notes, isNot(contains('October')));
    expect(notes, isNot(contains('4321')), reason: 'hidden notes never go');

    final chat = ai.current!;
    expect(chat.scope, week);
    expect(chat.messages.first.text, 'Anything?');
    final answer = chat.messages.last;
    expect(answer.role, KapyRole.assistant);
    expect(answer.read.map((ref) => ref.noteId).toSet(), {'call', 'launch'});
    expect(answer.matching, 2, reason: 'no word of it is in the period');
    expect(book.chats.single.scope, week, reason: 'the book keeps it');
  });

  test(
    'a follow-up stays, and without the period a new chat reads all',
    () async {
      final ai = await build();
      await ai.ask('What is still open?', period: week);
      final id = ai.current!.id;
      await ai.ask('And the pricing?', period: week);
      expect(ai.current!.id, id);
      expect(ai.current!.messages, hasLength(4));
      expect(notesOf(asked().last), isNot(contains('October')));

      await ai.ask('What about pricing?');
      expect(ai.current!.id, isNot(id), reason: 'the chip was taken off');
      expect(ai.current!.scope, isNull);
      final body = asked().last;
      expect(body['question'], 'What about pricing?');
      expect(notesOf(body), contains('October'));
      expect(notesOf(body), isNot(contains('4321')));
    },
  );

  test('a question past the contract is cut so the line fits', () async {
    final ai = await build();
    await ai.ask('w' * 3000, period: week);
    final question = asked().single['question']! as String;
    expect(question.length, AnswerRequest.maxQuestionChars);
    expect(question, startsWith('About 16–22 Nov 2026:\nwww'));
  });

  test('once the recap is made it is read first, but never a hidden note '
      'it named', () async {
    final engine = RecapEngine(
      notes: world.store,
      chats: book,
      now: () => testNow.subtract(const Duration(hours: 1)),
    );
    final made = await engine.make(
      engine.plan(world.material(tuesday)),
      digest: () => world.digest(tuesday),
      model: KapyModel.cloud,
      engine: ScriptedEngine([
        'TITLE: A calm Tuesday\nHIGHLIGHT: Launch | Ship it on Friday',
      ]),
      budget: RetrievalBudget.cloud,
      timeZone: 'UTC',
      firstWeekday: DateTime.monday,
    );
    expect(made, isA<RecapMade>());

    final ai = await build();
    expect(ai.chats, isEmpty, reason: 'a recap is not in the chat list');
    await ai.ask('Anything?', period: tuesday);
    final first = (asked().single['notes']! as List).first as Map;
    expect(first['title'], 'Recap · Tue 17');
    expect(first['text'], contains('Ship it on Friday'));
    expect(
      ai.current!.messages.last.read.map((ref) => ref.noteId),
      isNot(contains('')),
      reason: 'the recap and the tasks are not notes to open',
    );

    world.store.hide('launch');
    ai.newChat();
    await ai.ask('Anything?', period: tuesday);
    expect(notesOf(asked().last), isNot(contains('Ship it on Friday')));
    expect(notesOf(asked().last), isNot(contains('Write notes')));
  });

  test(
    'where the period cannot be read, it says so and sends nothing',
    () async {
      final ai = await build(reader: false);
      await ai.ask('What is still open?', period: week);
      final failed = ai.pending! as KapyFailed;
      expect(
        failed.message,
        'Kapy AI can’t read 16–22 Nov here. Remove it to ask about all your '
        'notes.',
      );
      expect(failed.retry, isFalse);
      expect(asked(), isEmpty);
    },
  );

  test('reads a period once until a note changes', () async {
    final ai = await build();
    expect(ai.readPeriod(week)!.notes, 2);
    ai.readPeriod(week);
    expect(reads, 1);
    world.store.hide('call');
    expect(ai.readPeriod(week)!.notes, 1);
    expect(reads, 2);
  });
}
