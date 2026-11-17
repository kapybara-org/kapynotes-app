import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_ai_controller.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/sync/key_store.dart';

import 'ai_fakes.dart';

const _usage = {
  'used': 3,
  'limit': 500,
  'remaining': 497,
  'resetsAt': '2026-12-01T00:00:00.000Z',
};

void main() {
  late MemoryStore store;
  late FakeDeviceModel device;
  late FakeLocalTool codex;
  late FakeLocalTool claude;
  late InMemorySecureStore secrets;
  late List<http.Request> sent;
  late http.Response Function(http.Request) server;

  setUp(() {
    store = MemoryStore();
    device = FakeDeviceModel();
    codex = FakeLocalTool(KapyAccountKind.codex);
    claude = FakeLocalTool(KapyAccountKind.claudeCode);
    secrets = InMemorySecureStore();
    sent = [];
    server = (request) => request.url.path.endsWith('/ai/usage')
        ? http.Response(jsonEncode(_usage), 200)
        : http.Response(
            jsonEncode({'answer': 'cloud answer', 'usage': _usage}),
            200,
          );
  });

  Future<KapyAiController> build({
    Billing? billing,
    List<Map<String, Object?>>? notes,
    LocalStore? local,
    Map<String, String> environment = const {},
  }) async {
    final controller = KapyAiController(
      store: local ?? store,
      notes: await notesWith(
        notes ?? [noteJson('lisbon', 'Lisbon trip\nflights')],
        store: local ?? store,
      ),
      device: device,
      billing: billing,
      token: () => 'session-token',
      client: MockClient((request) async {
        sent.add(request);
        return server(request);
      }),
      secrets: secrets,
      codex: codex,
      claudeCode: claude,
      apiBaseUrl: Uri.parse('https://api.test/'),
      now: () => testNow,
      environment: environment,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('plans', () {
    test('Pro starts on Kapy AI Cloud and shows its usage', () async {
      final ai = await build(billing: await billingOn(pro: true));
      expect(ai.isPro, isTrue);
      expect(ai.defaultModel, KapyModel.cloud);
      expect(ai.cloudUsage, isNull);
      await settle();
      expect(ai.cloudUsage?.remaining, 497);
    });

    test('Free starts on the device and cannot use Cloud', () async {
      final ai = await build(billing: await billingOn(pro: false));
      expect(ai.isPro, isFalse);
      expect(ai.defaultModel, FakeDeviceModel.apple);
      ai.defaultModel = KapyModel.cloud;
      expect(ai.defaultModel, FakeDeviceModel.apple);
      ai.pickModel(KapyModel.cloud);
      expect(ai.model, FakeDeviceModel.apple);
      expect(ai.cloudUsage, isNull);
      await ai.ask('Lisbon?');
      expect(sent.where((r) => r.url.path.contains('/ai/')), isEmpty);
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('a Free chat whose model is Cloud falls back', () async {
      store.data['kapyAi.chats.v1'] = {
        'chats': [
          {
            'id': 'c',
            'title': 't',
            'createdAt': 0,
            'updatedAt': 0,
            'model': KapyModel.cloud.toJson(),
            'messages': [],
          },
        ],
      };
      final ai = await build(billing: await billingOn(pro: false));
      ai.openChat('c');
      expect(ai.model, FakeDeviceModel.apple);
    });

    test('own accounts and the device answer on Free', () async {
      final ai = await build(billing: await billingOn(pro: false));
      ai.accounts;
      await settle();
      final codexModel = ai.accounts
          .firstWhere((account) => account.kind == KapyAccountKind.codex)
          .models
          .single;
      ai.pickModel(codexModel);
      await ai.ask('Lisbon?');
      expect(ai.pending, isA<KapyAccountConsent>());
      await ai.proceed();
      expect(ai.current!.messages.last.text, 'tool answer');
      expect(codex.asked.single.notes.single.id, 'lisbon');
    });

    test('a stored default that is no longer pickable falls back', () async {
      final ai = await build(billing: await billingOn(pro: true));
      ai.defaultModel = FakeDeviceModel.gemma;
      expect(ai.defaultModel, KapyModel.cloud);
    });
  });

  group('pending states', () {
    test('cloud consent is asked once per device', () async {
      final ai = await build(billing: await billingOn(pro: true));
      await ai.ask('Lisbon?');
      expect(ai.pending, isA<KapyCloudConsent>());
      expect(ai.current!.messages.single.text, 'Lisbon?');
      await ai.proceed();
      expect(ai.pending, isNull);
      expect(ai.current!.messages.last.text, 'cloud answer');
      expect(ai.current!.messages.last.read.single.noteId, 'lisbon');
      expect(ai.current!.messages.last.matching, 1);
      await ai.ask('And flights?');
      expect(ai.pending, isNull);
      expect(ai.current!.messages.last.text, 'cloud answer');
    });

    test('Use this device answers the held question there', () async {
      final ai = await build(billing: await billingOn(pro: true));
      await ai.ask('Lisbon?');
      await ai.answerWith(FakeDeviceModel.apple);
      expect(ai.current!.model, FakeDeviceModel.apple);
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('account consent: Pick another keeps the question', () async {
      final ai = await build();
      await settle();
      ai.pickModel(claude.model);
      await ai.ask('Lisbon?');
      expect(
        (ai.pending! as KapyAccountConsent).account,
        KapyAccountKind.claudeCode,
      );
      ai.dismissPending();
      expect(ai.pending, isNull);
      expect(ai.current!.messages.single.role, KapyRole.user);
      await ai.answerWith(FakeDeviceModel.apple);
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('download ask, progress, cancel and finish', () async {
      device.state = const DeviceModelState(
        status: DeviceModelStatus.notDownloaded,
        model: FakeDeviceModel.gemma,
        totalBytes: 2600,
      );
      final ai = await build();
      await ai.ask('Lisbon?');
      expect((ai.pending! as KapyDownloadAsk).totalBytes, 2600);

      ai.dismissPending();
      expect(ai.pending, isNull);
      expect(device.downloads, 0);

      await ai.ask('Lisbon again?');
      await ai.proceed();
      expect(device.downloads, 1);
      expect(ai.pending, isA<KapyDownloading>());
      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.downloading,
          model: FakeDeviceModel.gemma,
          receivedBytes: 1100,
          totalBytes: 2600,
        ),
      );
      expect((ai.pending! as KapyDownloading).received, 1100);

      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.ready,
          model: FakeDeviceModel.gemma,
        ),
      );
      await settle();
      expect(ai.pending, isNull);
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('Cancel during a download stops it', () async {
      device.state = const DeviceModelState(
        status: DeviceModelStatus.notDownloaded,
        model: FakeDeviceModel.gemma,
        totalBytes: 2600,
      );
      final ai = await build();
      await ai.ask('Lisbon?');
      await ai.proceed();
      ai.dismissPending();
      expect(device.cancels, 1);
      expect(ai.pending, isNull);
    });

    test('a failed download says so and Try again asks again', () async {
      device.state = const DeviceModelState(
        status: DeviceModelStatus.notDownloaded,
        model: FakeDeviceModel.gemma,
        totalBytes: 2600,
      );
      final ai = await build();
      await ai.ask('Lisbon?');
      await ai.proceed();
      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.downloading,
          model: FakeDeviceModel.gemma,
        ),
      );
      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.notDownloaded,
          model: FakeDeviceModel.gemma,
          totalBytes: 2600,
        ),
      );
      expect(ai.pending, isA<KapyFailed>());
      await ai.proceed();
      expect(ai.pending, isA<KapyDownloadAsk>());
    });

    test('limit reached offers the device model', () async {
      server = (_) => http.Response(
        jsonEncode({
          'error': 'limit reached',
          'usage': {..._usage, 'remaining': 0},
        }),
        429,
      );
      final ai = await build(billing: await billingOn(pro: true));
      await ai.ask('Lisbon?');
      await ai.proceed();
      final limit = ai.pending! as KapyLimitReached;
      expect(limit.resetsAt, DateTime.utc(2026, 12).toLocal());
      expect(limit.fallback, FakeDeviceModel.apple);
      expect(ai.cloudUsage!.remaining, 0);
      await ai.proceed();
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('offline keeps the question for Try again', () async {
      var offline = true;
      server = (request) {
        if (offline) throw http.ClientException('no route');
        return http.Response(
          jsonEncode({'answer': 'back', 'usage': _usage}),
          200,
        );
      };
      final ai = await build(billing: await billingOn(pro: true));
      await ai.ask('Lisbon?');
      await ai.proceed();
      expect((ai.pending! as KapyOffline).fallback, FakeDeviceModel.apple);
      offline = false;
      await ai.proceed();
      expect(ai.pending, isNull);
      expect(ai.current!.messages.map((m) => m.text), ['Lisbon?', 'back']);
    });

    test(
      'a signed-out tool is an account error, Check again retries',
      () async {
        final ai = await build();
        ai.accounts;
        await settle();
        ai.pickModel(codex.model);
        await ai.ask('Lisbon?');
        await ai.proceed();
        codex.failure = const AnswerAccountRejected(KapyAccountKind.codex);
        await ai.ask('Again?');
        final error = ai.pending! as KapyAccountError;
        expect(error.account, KapyAccountKind.codex);
        expect(
          ai.accounts.firstWhere((a) => a.kind == KapyAccountKind.codex).status,
          KapyAccountStatus.error,
        );
        codex.failure = null;
        await ai.proceed();
        expect(ai.pending, isNull);
        expect(ai.current!.messages.last.text, 'tool answer');
      },
    );

    test('any other failure is shown and Try again retries', () async {
      device.failure = const AnswerFailed('Nope.');
      final ai = await build();
      await ai.ask('Lisbon?');
      expect((ai.pending! as KapyFailed).message, 'Nope.');
      device.failure = null;
      await ai.proceed();
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('an unexpected error logs its type and nothing it carried', () async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);
      device.failure = const FormatException(
        'note text: the safe code is 4417',
      );
      final ai = await build();
      await ai.ask('Lisbon?');
      expect(ai.pending, isA<KapyFailed>());
      expect(logs.join('\n'), contains('FormatException'));
      expect(logs.join('\n'), isNot(contains('4417')));
      expect(logs.join('\n'), isNot(contains('safe code')));
      expect(logs.join('\n'), isNot(contains('#0')));
    });
  });

  group('accounts', () {
    test('tools are listed with their switches', () async {
      final ai = await build();
      ai.accounts;
      await settle();
      expect(ai.accounts.map((a) => a.kind), [
        KapyAccountKind.codex,
        KapyAccountKind.claudeCode,
        KapyAccountKind.openRouter,
      ]);
      ai.allowClaudeCode(false);
      final off = ai.accounts.firstWhere(
        (a) => a.kind == KapyAccountKind.claudeCode,
      );
      expect(off.enabled, isFalse);
      expect(off.models, isEmpty);
      claude.status = KapyAccountStatus.error;
      await ai.checkClaudeCode();
      expect(
        ai.accounts
            .firstWhere((a) => a.kind == KapyAccountKind.claudeCode)
            .status,
        KapyAccountStatus.error,
      );
    });
  });

  group('sandboxed app', () {
    const sandbox = {'APP_SANDBOX_CONTAINER_ID': 'com.kapybara.kapynotes'};

    test('Codex and Claude Code are not offered', () async {
      final ai = await build(environment: sandbox);
      await settle();
      expect(ai.accounts.map((a) => a.kind), [KapyAccountKind.openRouter]);
    });

    test('a stored chat or default on either falls back', () async {
      store.data['kapyAi.v1'] = {'defaultModel': codex.model.toJson()};
      store.data['kapyAi.chats.v1'] = {
        'chats': [
          {
            'id': 'c',
            'title': 't',
            'createdAt': 0,
            'updatedAt': 0,
            'model': claude.model.toJson(),
            'messages': [],
          },
        ],
      };
      final ai = await build(environment: sandbox);
      expect(ai.defaultModel, FakeDeviceModel.apple);
      ai.openChat('c');
      expect(ai.model, FakeDeviceModel.apple);
      ai.pickModel(codex.model);
      await ai.ask('Lisbon?');
      expect(codex.asked, isEmpty);
      expect(claude.asked, isEmpty);
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('an unsandboxed app keeps them', () async {
      final ai = await build(environment: const {'HOME': '/Users/someone'});
      await settle();
      expect(ai.accounts.map((a) => a.kind), contains(KapyAccountKind.codex));
      ai.pickModel(codex.model);
      expect(ai.model, codex.model);
    });
  });

  group('chats', () {
    test('title, rename, delete, clear and a round trip', () async {
      final ai = await build();
      await ai.ask('  What did I\n plan   for Lisbon?  ');
      final chat = ai.current!;
      expect(chat.title, 'What did I plan for Lisbon?');
      expect(chat.messages.first.text, 'What did I\n plan   for Lisbon?');

      ai.renameChat(chat.id, '  Trip  ');
      expect(ai.current!.title, 'Trip');
      ai.renameChat(chat.id, '   ');
      expect(ai.current!.title, 'Trip');

      final reopened = await build();
      expect(reopened.chats.single.title, 'Trip');
      expect(reopened.chats.single.messages.last.text, 'device answer');
      expect(reopened.chats.single.messages.last.read.single.noteId, 'lisbon');
      expect(reopened.chats.single.messages.last.model, FakeDeviceModel.apple);

      ai.newChat();
      await ai.ask('Second');
      expect(ai.chats.map((c) => c.title), ['Second', 'Trip']);
      ai.deleteChat(chat.id);
      expect(ai.chats.map((c) => c.title), ['Second']);
      final deleted = (store.data['kapyAi.chats.v1']! as Map)['deleted'] as Map;
      expect(deleted.keys, [chat.id]);

      await ai.clearHistory();
      expect(ai.chats, isEmpty);
      expect(ai.current, isNull);
      expect(((await build()).chats), isEmpty);
      expect(
        ((store.data['kapyAi.chats.v1']! as Map)['deleted'] as Map).length,
        2,
      );
    });

    test('a long first question is clipped for the title', () async {
      final ai = await build();
      await ai.ask('x' * 100);
      expect(ai.current!.title, '${'x' * 60}…');
    });

    test('picking with no chat open sets the next chat\'s model', () async {
      final ai = await build(billing: await billingOn(pro: true));
      ai.pickModel(FakeDeviceModel.apple);
      expect(ai.model, FakeDeviceModel.apple);
      await ai.ask('Lisbon?');
      expect(ai.current!.model, FakeDeviceModel.apple);
      ai.newChat();
      expect(ai.model, KapyModel.cloud);
    });

    test('the switch is remembered', () async {
      final ai = await build();
      expect(ai.enabled, isTrue);
      ai.enabled = false;
      expect((await build()).enabled, isFalse);
    });
  });

  test('construction starts nothing', () async {
    final ai = await build(billing: await billingOn(pro: true));
    await settle();
    expect(sent, isEmpty);
    expect(ai.chats, isEmpty);
  });
}
