import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/ai/device_model.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_ai_controller.dart';
import 'package:kapy_notes/ai/local_tools.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/speech/apple_summarizer.dart';
import 'package:kapy_notes/speech/gemma_summarizer.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';
import 'package:kapy_notes/sync/key_store.dart';

import 'ai_fakes.dart';
import 'fake_cli.dart';

/// A Hidden note matching the question, in every shape Hidden can take, and
/// an ordinary note next to them so the question still has something to read.
/// Locked or unlocked makes no difference to a note's own record: Hidden is
/// its hiddenAt, and nothing on the way to a model asks about the lock.
const _secret = 'HIDDEN-SECRET-7731';

List<Map<String, Object?>> _notes() => [
  noteJson('open', 'Lisbon trip\nflights on Friday'),
  noteJson('hidden', 'Lisbon $_secret\nthe door code', hidden: true),
  noteJson(
    'hidden-archived',
    'Lisbon archived $_secret',
    hidden: true,
    archived: true,
  ),
  noteJson('hidden-title', '$_secret Lisbon\nbody', hidden: true),
];

const _question = 'What did I plan for Lisbon?';
const _openRouterKey = 'sk-or-v1-feedface';

void main() {
  late MemoryStore store;
  late List<http.Request> web;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    store = MemoryStore()
      ..data['kapyAi.v1'] = {
        'cloudConsent': true,
        'accountConsent': ['codex', 'claudeCode', 'openRouter'],
      };
    web = [];
  });

  Future<KapyAiController> build({
    required bool pro,
    NotesStore? notes,
    DeviceModel? device,
    LocalTool? codex,
    LocalTool? claudeCode,
  }) async {
    final ai = KapyAiController(
      store: store,
      notes: notes ?? await notesWith(_notes(), store: store),
      device: device ?? FakeDeviceModel(),
      billing: await billingOn(pro: pro),
      token: () => 'session-token',
      client: MockClient((request) async {
        web.add(request);
        if (request.url.host == 'api.test') {
          return http.Response(
            jsonEncode({
              'answer': 'cloud answer',
              'usage': {
                'used': 1,
                'limit': 500,
                'remaining': 499,
                'resetsAt': testNow
                    .add(const Duration(days: 14))
                    .toUtc()
                    .toIso8601String(),
              },
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/key')) return http.Response('{}', 200);
        if (request.url.path.endsWith('/models')) {
          return http.Response('{"data":[{"id":"openai/gpt-5.5"}]}', 200);
        }
        return http.Response(
          '{"choices":[{"message":{"content":"routed"}}]}',
          200,
        );
      }),
      secrets: InMemorySecureStore(),
      codex: codex ?? FakeLocalTool(KapyAccountKind.codex),
      claudeCode: claudeCode ?? FakeLocalTool(KapyAccountKind.claudeCode),
      apiBaseUrl: Uri.parse('https://api.test/'),
      now: () => testNow,
    );
    addTearDown(ai.dispose);
    return ai;
  }

  void expectOnlyTheOpenNote(String sent) {
    expect(sent, isNot(contains(_secret)));
    expect(sent, isNot(contains('door code')));
    expect(sent, contains('flights on Friday'));
  }

  test('Kapy AI Cloud: the request body', () async {
    final ai = await build(pro: true);
    await ai.ask(_question);
    expect(ai.current!.messages.last.text, 'cloud answer');
    final call = web.singleWhere((r) => r.url.path == '/ai/answer');
    expectOnlyTheOpenNote(call.body);
    expect(((jsonDecode(call.body) as Map)['notes'] as List).length, 1);
    expect(ai.current!.messages.last.read.map((n) => n.noteId), ['open']);
    expect(ai.current!.messages.last.matching, 1);
  });

  test('an answer that read a note hidden since is not sent again', () async {
    final notes = await notesWith([
      ..._notes(),
      noteJson('flight', 'Lisbon flight at 9:40'),
    ], store: store);
    final ai = await build(pro: true, notes: notes);
    await ai.ask(_question);
    notes.hide('open');
    await ai.ask('And when do I fly?');

    final second =
        jsonDecode(web.where((r) => r.url.path == '/ai/answer').last.body)
            as Map;
    expect(second['history'], [
      {'role': 'user', 'text': _question},
    ]);
  });

  test('nothing after an answer that read a note hidden since is sent '
      'again, since a later answer may repeat it', () async {
    final notes = await notesWith([
      ..._notes(),
      noteJson('dentist', 'Dentist appointment Tuesday 4pm'),
    ], store: store);
    final ai = await build(pro: true, notes: notes);
    await ai.ask(_question);
    await ai.ask('When is the dentist?');
    expect(ai.current!.messages.last.read.map((n) => n.noteId), ['dentist']);
    notes.hide('open');
    await ai.ask('When is the dentist again?');

    final third =
        jsonDecode(web.where((r) => r.url.path == '/ai/answer').last.body)
            as Map;
    expect(third['history'], [
      {'role': 'user', 'text': _question},
    ]);
  });

  test('a link may come from the question or a note still open', () async {
    final notes = await notesWith(_notes(), store: store);
    final ai = await build(pro: true, notes: notes);
    await ai.ask(_question);
    final chat = ai.current!;
    final answer = chat.messages.last;

    expect(ai.linkSources(chat, answer), contains(_question));
    expect(ai.linkSources(chat, answer), contains('flights on Friday'));
    expect(ai.linkSources(chat, answer), isNot(contains(_secret)));

    notes.hide('open');
    expect(ai.linkSources(chat, answer), isNot(contains('flights on Friday')));
  });

  test(
    'Kapy AI Cloud: a hidden "This note" chip sends nothing of it',
    () async {
      final ai = await build(pro: true);
      await ai.ask('Summarise this note', noteId: 'hidden');
      final call = web.singleWhere((r) => r.url.path == '/ai/answer');
      expect(call.body, isNot(contains(_secret)));
      expect((jsonDecode(call.body) as Map)['notes'], isEmpty);
    },
  );

  test('OpenRouter: the request body', () async {
    final ai = await build(pro: false);
    expect(await ai.saveOpenRouterKey(_openRouterKey), isTrue);
    ai.pickModel(
      const KapyModel(
        kind: KapyModelKind.openRouter,
        id: 'openai/gpt-5.5',
        label: 'GPT-5.5',
      ),
    );
    await ai.ask(_question);
    expect(ai.current!.messages.last.text, 'routed');
    final call = web.singleWhere(
      (r) => r.url.path == '/api/v1/chat/completions',
    );
    expectOnlyTheOpenNote(call.body);
  });

  test('Codex: the bytes on stdin', () async {
    final cli = await FakeCli.create();
    addTearDown(cli.dispose);
    final ai = await build(pro: false, codex: codexCli(executable: cli.path));
    ai.pickModel(
      const KapyModel(kind: KapyModelKind.codex, id: 'm', label: 'M'),
    );
    await ai.ask(_question);
    expect(ai.current!.messages.last.text, 'the answer');
    final run = cli.answers().single;
    expectOnlyTheOpenNote(run.stdin + run.argv.join(' '));
  });

  test('Claude Code: the bytes on stdin', () async {
    final cli = await FakeCli.create(reply: '{"result":"the answer"}');
    addTearDown(cli.dispose);
    final ai = await build(
      pro: false,
      claudeCode: ClaudeCodeCli(executable: cli.path),
    );
    ai.pickModel(
      const KapyModel(kind: KapyModelKind.claudeCode, id: 'sonnet', label: 'S'),
    );
    await ai.ask(_question);
    expect(ai.current!.messages.last.text, 'the answer');
    final run = cli.answers().single;
    expectOnlyTheOpenNote(run.stdin + run.argv.join(' '));
  });

  test(
    'Apple Intelligence: the instructions and prompt on the channel',
    () async {
      final seen = <Map<Object?, Object?>>[];
      const channel = MethodChannel(AppleSummarizer.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'availability':
            return 'ready';
          case 'physicalMemory':
            return 8 * 1000 * 1000 * 1000;
          case 'answer':
            seen.add(call.arguments as Map);
            return 'apple answer';
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final temp = Directory.systemTemp.createTempSync('kapy-ai-models');
      addTearDown(() => temp.deleteSync(recursive: true));
      final models = LocalModelStore(
        catalogue: localSummaryModels,
        directory: temp,
        client: MockClient((_) async => fail('nothing here downloads')),
      );
      addTearDown(models.dispose);
      final device = PlatformDeviceModel(
        apple: AppleSummarizer(),
        gemma: GemmaSummarizer(models: models),
        models: models,
      );
      addTearDown(device.dispose);

      final ai = await build(pro: false, device: device);
      // The app asks the device what it can do before a chat takes a model, so
      // the chat is not pinned to a default taken while that was unknown.
      await device.refresh();
      await ai.ask(_question);
      expect(ai.current!.messages.last.text, 'apple answer');
      final call = seen.single;
      expectOnlyTheOpenNote('${call['instructions']}\n${call['prompt']}');
      expect(call['prompt'], contains('<note title="Lisbon trip"'));
    },
  );
}
