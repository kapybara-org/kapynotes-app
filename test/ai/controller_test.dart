import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/device_model.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_ai_controller.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/ai/local_tools.dart';
import 'package:kapy_notes/ai/recording_context.dart';
import 'package:kapy_notes/ai/tool_helper.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/speech/moments.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_panel.dart';
import 'package:material_ui/material_ui.dart';

import '../billing/billing_fakes.dart';
import 'ai_fakes.dart';
import 'fake_cli.dart';

final _resetsAt = testNow.add(const Duration(days: 14));
final _usage = {
  'used': 3,
  'limit': 500,
  'remaining': 497,
  'resetsAt': _resetsAt.toUtc().toIso8601String(),
};

const _link = KapyRecordingRef(noteId: 'standup', hash: 'pricing-call');

/// A recording of [minutes], a paragraph every ten seconds, Sanjay and Arjun
/// in turn.
NoteVoiceRef _voice({int minutes = 1, bool transcribed = true}) => NoteVoiceRef(
  offset: 8,
  hash: _link.hash,
  key: Uint8List(32),
  bytes: 2048,
  durationMs: minutes * 60000,
  transcript: transcribed
      ? VoiceTranscript(
          lang: 'en',
          engine: 'test',
          at: 0,
          segments: [
            for (var i = 0; i < minutes * 6; i++)
              TranscriptSegment(
                s: i * 10000,
                e: i * 10000 + 2000,
                t: i == 1
                    ? 'Can we split the first invoice across two months?'
                    : 'Line $i is about the pricing page, the annual plan '
                          'for next quarter, and what finance said about '
                          'the first invoice.',
                speaker: i % 2,
              ),
          ],
          speakers: const {0: 'Sanjay', 1: 'Arjun'},
        )
      : null,
  summary: VoiceSummary(
    engine: 'test',
    at: 0,
    title: 'Pricing call',
    points: ['Annual plan first'],
  ),
);

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
    KapyChatBook? chats,
    Map<String, String> environment = const {},
    ToolHelper? toolHelper,
    bool realTools = false,
    String? Function()? token,
  }) async {
    final controller = KapyAiController(
      store: local ?? store,
      chats: chats,
      notes: await notesWith(
        notes ?? [noteJson('lisbon', 'Lisbon trip\nflights')],
        store: local ?? store,
      ),
      device: device,
      billing: billing,
      token: token ?? () => 'session-token',
      client: MockClient((request) async {
        sent.add(request);
        return server(request);
      }),
      secrets: secrets,
      codex: realTools ? null : codex,
      claudeCode: realTools ? null : claude,
      apiBaseUrl: Uri.parse('https://api.test/'),
      now: () => testNow,
      environment: environment,
      toolHelper: toolHelper ?? FakeToolHelper(answers: false),
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

    test('Free keeps a stored Cloud pick and cannot use it', () async {
      final ai = await build(billing: await billingOn(pro: false));
      expect(ai.isPro, isFalse);
      expect(ai.defaultModel, FakeDeviceModel.apple);
      ai.defaultModel = KapyModel.cloud;
      // Kept rather than swapped for something they did not pick, and held
      // with the device offered as the way forward.
      expect(ai.defaultModel, KapyModel.cloud);
      expect(ai.cloudUsage, isNull);
      await ai.ask('Lisbon?');
      final locked = ai.pending! as KapyCloudLocked;
      expect(locked.upgrade, isTrue);
      expect(locked.signIn, isFalse);
      expect(locked.fallbacks, [FakeDeviceModel.apple]);
      expect(sent.where((r) => r.url.path.contains('/ai/')), isEmpty);
    });

    test('signed out, Cloud asks them to sign in and upgrade', () async {
      final ai = await build(
        billing: billingFor(FakeSession(), FakeBillingApi()),
        token: () => null,
      );
      ai.defaultModel = KapyModel.cloud;
      await ai.ask('Lisbon?');
      final locked = ai.pending! as KapyCloudLocked;
      expect(locked.signIn, isTrue);
      expect(locked.upgrade, isTrue);
      expect(sent, isEmpty);
    });

    test('signing in to Pro from the card moves the question on', () async {
      final session = FakeSession();
      final api = FakeBillingApi()..answer = () => entitlementsFor(pro: true);
      final ai = await build(
        billing: billingFor(session, api),
        token: () => session.userId == null ? null : 'session-token',
      );
      ai.defaultModel = KapyModel.cloud;
      await ai.ask('Lisbon?');
      expect(ai.pending, isA<KapyCloudLocked>());
      session.signIn('user-1');
      await settle();
      // Next is Cloud's own first-use notice, and nothing has been sent.
      expect(ai.pending, isA<KapyCloudConsent>());
      expect(sent.where((r) => r.method == 'POST'), isEmpty);
    });

    test('signed in without Pro, the card asks only for Pro', () async {
      final session = FakeSession();
      final api = FakeBillingApi()..answer = () => entitlementsFor(pro: false);
      final ai = await build(
        billing: billingFor(session, api),
        token: () => session.userId == null ? null : 'session-token',
      );
      ai.defaultModel = KapyModel.cloud;
      await ai.ask('Lisbon?');
      expect((ai.pending! as KapyCloudLocked).signIn, isTrue);
      session.signIn('user-1');
      await settle();
      final locked = ai.pending! as KapyCloudLocked;
      expect(locked.signIn, isFalse);
      expect(locked.upgrade, isTrue);
    });

    Future<KapyPending?> cloudSays(int status, [String body = '{}']) async {
      server = (request) => request.url.path.endsWith('/ai/usage')
          ? http.Response(jsonEncode(_usage), 200)
          : http.Response(body, status);
      final ai = await build(billing: await billingOn(pro: true));
      await ai.ask('Lisbon?');
      await ai.proceed();
      return ai.pending;
    }

    test('the server saying no Pro asks for an upgrade', () async {
      final locked = await cloudSays(402) as KapyCloudLocked;
      expect(locked.upgrade, isTrue);
      expect(locked.signIn, isFalse);
    });

    test('the server ending the session asks them to sign in', () async {
      final locked =
          await cloudSays(401, '{"error":"unauthorized"}') as KapyCloudLocked;
      expect(locked.signIn, isTrue);
      expect(locked.upgrade, isFalse);
    });

    test("a 401 that isn't the server's, from a Wi-Fi sign-in page, is "
        'tried again', () async {
      final failed =
          await cloudSays(401, '<html>Sign in to the Wi-Fi</html>')
              as KapyFailed;
      expect(failed.retry, isTrue);
    });

    test('only what a retry can fix is tried again', () async {
      final update = await cloudSays(426) as KapyFailed;
      expect(update.message, 'Update Kapy Notes to use Kapy AI Cloud.');
      expect(update.retry, isFalse);
      expect((await cloudSays(502) as KapyFailed).retry, isTrue);
    });

    test('a Free chat on Cloud is held, not swapped', () async {
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
      expect(ai.model, KapyModel.cloud);
      await ai.ask('Lisbon?');
      expect((ai.pending! as KapyCloudLocked).fallbacks, [
        FakeDeviceModel.apple,
      ]);
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
      // Gemma is gone but this device can still answer, and it was a device
      // model that was picked: the cloud is not what that person chose.
      expect(ai.defaultModel, FakeDeviceModel.apple);
    });

    test('Pro that picked the device still answers on it', () async {
      final ai = await build(billing: await billingOn(pro: true));
      ai.defaultModel = FakeDeviceModel.apple;
      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.ready,
          model: FakeDeviceModel.gemma,
        ),
      );
      expect(ai.defaultModel, FakeDeviceModel.gemma);
      await ai.ask('Lisbon?');
      expect(sent, isEmpty);
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('a device that cannot answer is offered, never switched to', () async {
      final ai = await build(billing: await billingOn(pro: true));
      ai.defaultModel = FakeDeviceModel.gemma;
      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.needsSystemFeature,
          note: PlatformDeviceModel.appleOffNoRoom,
        ),
      );
      // Their choice stands: nothing leaves the device until they tap.
      expect(ai.defaultModel, FakeDeviceModel.gemma);
      await ai.ask('Lisbon?');
      final failed = ai.pending! as KapyFailed;
      expect(failed.message, PlatformDeviceModel.appleOffNoRoom);
      expect(failed.fallbacks, [KapyModel.cloud]);
      expect(sent, isEmpty);
      // Tapping the cloud asks its consent, and only then sends.
      await ai.answerWith(KapyModel.cloud);
      expect(ai.pending, isA<KapyCloudConsent>());
      expect(sent, isEmpty);
      await ai.proceed();
      expect(ai.current!.messages.last.text, 'cloud answer');
    });

    test('Free is offered no cloud on a device that cannot answer', () async {
      final ai = await build(billing: await billingOn(pro: false));
      ai.defaultModel = FakeDeviceModel.gemma;
      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.needsSystemFeature,
          note: PlatformDeviceModel.appleOffNoRoom,
        ),
      );
      await ai.ask('Lisbon?');
      final failed = ai.pending! as KapyFailed;
      expect(failed.fallbacks, isEmpty);
      expect(sent, isEmpty);
    });

    test('a device that cannot answer offers the accounts too', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      final ai = await build(
        billing: await billingOn(pro: true),
        environment: const {
          'APP_SANDBOX_CONTAINER_ID': 'com.kapybara.kapynotes',
        },
        toolHelper: FakeToolHelper(),
        realTools: true,
      );
      ai.accounts;
      await settle();
      final codex = ai.accounts.firstWhere(
        (a) => a.kind == KapyAccountKind.codex,
      );
      ai.defaultModel = FakeDeviceModel.gemma;
      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.needsSystemFeature,
          note: PlatformDeviceModel.appleOffNoRoom,
        ),
      );
      await ai.ask('Lisbon?');
      final failed = ai.pending! as KapyFailed;
      // The cloud and the account are both offered, and neither has been used.
      expect(failed.fallbacks, contains(KapyModel.cloud));
      expect(failed.fallbacks, contains(codex.models.first));
      expect(sent.where((r) => r.method == 'POST'), isEmpty);
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

    test(
      'waiting for Wi-Fi hands the download over and clears the ask',
      () async {
        device.state = const DeviceModelState(
          status: DeviceModelStatus.notDownloaded,
          model: FakeDeviceModel.gemma,
          totalBytes: 2600,
        );
        device.mobileData = true;
        final ai = await build();
        await ai.ask('Lisbon?');
        expect(ai.pending, isA<KapyDownloadAsk>());
        expect(await ai.deviceDownloadOnMobileData(), isTrue);

        ai.downloadDeviceModelOnWifi();

        expect(device.wifiDownloads, 1);
        expect(device.downloads, 0);
        expect(ai.pending, isNull);
      },
    );

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
      expect(limit.resetsAt, _resetsAt);
      expect(limit.fallback, FakeDeviceModel.apple);
      expect(ai.cloudUsage!.remaining, 0);
      await ai.proceed();
      expect(ai.current!.messages.last.text, 'device answer');
    });

    test('no room and Apple Intelligence off is not a dead end', () async {
      device.set(
        const DeviceModelState(
          status: DeviceModelStatus.needsSystemFeature,
          note: PlatformDeviceModel.appleOffNoRoom,
        ),
      );
      final ai = await build();
      await ai.ask('Lisbon?');
      expect((ai.pending! as KapyFailed).message, device.state.note);
      expect(sent, isEmpty);
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

  group('Windows', () {
    test(
      'Codex and Claude Code are not offered, and a stored one is kept',
      () async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        store.data['kapyAi.v1'] = {'defaultModel': codex.model.toJson()};
        final ai = await build(environment: const {'HOME': 'C:/Users/someone'});
        await settle();
        expect(ai.accounts.map((a) => a.kind), [KapyAccountKind.openRouter]);
        expect(ai.defaultModel, codex.model);
        ai.pickModel(claude.model);
        await ai.ask('Lisbon?');
        final failed = ai.pending! as KapyAccountError;
        expect(failed.fallbacks, [FakeDeviceModel.apple]);
        expect(codex.asked, isEmpty);
        expect(claude.asked, isEmpty);
      },
    );
  });

  group('a model Codex no longer offers', () {
    const gone = KapyModel(
      kind: KapyModelKind.codex,
      id: 'gpt-6-luna',
      label: 'GPT-6 Luna',
    );

    void storeChatOn(KapyModel model) {
      store.data['kapyAi.v1'] = {'defaultModel': model.toJson()};
      store.data['kapyAi.chats.v1'] = {
        'chats': [
          {
            'id': 'c',
            'title': 't',
            'createdAt': 0,
            'updatedAt': 0,
            'model': model.toJson(),
            'messages': [],
          },
        ],
      };
    }

    test('is Codex\'s one offered model, in a stored chat and as the '
        'default', () async {
      storeChatOn(gone);
      final ai = await build(environment: const {'HOME': '/Users/someone'});
      ai.accounts;
      await settle();
      expect(
        ai.accounts.firstWhere((a) => a.kind == KapyAccountKind.codex).models,
        [codex.model],
      );
      expect(ai.defaultModel, codex.model);
      ai.openChat('c');
      expect(ai.model, codex.model);
      await ai.ask('Lisbon?');
      expect(ai.pending, isA<KapyAccountConsent>());
      await ai.proceed();
      await settle();
      expect(ai.pending, isNull);
      expect(codex.asked, hasLength(1));
      expect(ai.current!.messages.last.text, 'tool answer');
    });

    test('is kept while Codex offers nothing', () async {
      storeChatOn(gone);
      codex.status = KapyAccountStatus.error;
      final ai = await build(environment: const {'HOME': '/Users/someone'});
      ai.accounts;
      await settle();
      expect(ai.defaultModel, gone);
      ai.openChat('c');
      expect(ai.model, gone);
    });

    testWidgets('reopened, shows Codex and its answer, and nothing technical', (
      tester,
    ) async {
      storeChatOn(gone);
      final ai = (await tester.runAsync(() async {
        final ai = await build(environment: const {'HOME': '/Users/someone'});
        ai.accounts;
        await settle();
        ai.openChat('c');
        await ai.ask('Lisbon?');
        await ai.proceed();
        await settle();
        return ai;
      }))!;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: KapyAiPanel(
              kapyAi: ai,
              controller: KapyAiPanelController()..open(),
              noteTitle: (_) => 'Lisbon trip',
              onOpenNote: (_) {},
              onManageAccounts: () {},
              onClose: () {},
              now: () => testNow,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('tool answer'), findsOneWidget);
      expect(find.text('Codex'), findsWidgets);
      expect(find.text(codex.model.label), findsNothing);
      for (final technical in [
        gone.id,
        gone.label,
        'signed out',
        'Couldn’t answer',
        'Exception',
        'Error',
      ]) {
        expect(find.textContaining(technical), findsNothing, reason: technical);
      }
    });
  });

  group('a sandboxed Mac with its helper', () {
    const sandbox = {'APP_SANDBOX_CONTAINER_ID': 'com.kapybara.kapynotes'};

    setUp(() {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    });

    test('offers Codex and Claude Code and runs them there', () async {
      final helper = FakeToolHelper();
      final ai = await build(
        environment: sandbox,
        toolHelper: helper,
        realTools: true,
      );
      ai.accounts;
      await settle();
      expect(ai.accounts.map((a) => a.kind), [
        KapyAccountKind.codex,
        KapyAccountKind.claudeCode,
        KapyAccountKind.openRouter,
      ]);
      expect(helper.requests.map((r) => r.tool).toSet(), {'codex', 'claude'});
      final claudeAccount = ai.accounts.firstWhere(
        (a) => a.kind == KapyAccountKind.claudeCode,
      );
      expect(claudeAccount.status, KapyAccountStatus.connected);
      final codexAccount = ai.accounts.firstWhere(
        (a) => a.kind == KapyAccountKind.codex,
      );
      expect(codexAccount.status, KapyAccountStatus.connected);

      ai.pickModel(claudeAccount.models.first);
      await ai.ask('Lisbon?');
      await ai.proceed();
      expect(ai.current!.messages.last.text, 'helper answer');
      expect(helper.requests.last.expectedVersion, '2.1.326 (Claude Code)');

      ai.pickModel(codexAccount.models.first);
      await ai.ask('Porto?');
      await ai.proceed();
      expect(ai.current!.messages.last.text, 'helper answer');
      expect(helper.requests.last.arguments, [
        'exec',
        '--model',
        'gpt-x',
        ...CodexCli.lockedDown,
        '-',
      ]);
      expect(helper.requests.last.expectedVersion, 'codex-cli 0.160.0');
    });

    test(
      'a helper that does not answer offers neither and runs nothing',
      () async {
        final helper = FakeToolHelper(answers: false);
        final ai = await build(
          environment: sandbox,
          toolHelper: helper,
          realTools: true,
        );
        ai.accounts;
        await settle();
        expect(helper.pings, 1);
        expect(ai.accounts.map((a) => a.kind), [KapyAccountKind.openRouter]);
        expect(helper.requests, isEmpty);
      },
    );

    test('an app that is not sandboxed never asks the helper', () async {
      final helper = FakeToolHelper();
      final ai = await build(toolHelper: helper);
      ai.accounts;
      await settle();
      expect(helper.pings, 0);
      expect(ai.accounts.map((a) => a.kind), contains(KapyAccountKind.codex));
    });
  });

  group('sandboxed app', () {
    const sandbox = {'APP_SANDBOX_CONTAINER_ID': 'com.kapybara.kapynotes'};

    test('Codex and Claude Code are not offered', () async {
      final ai = await build(environment: sandbox);
      await settle();
      expect(ai.accounts.map((a) => a.kind), [KapyAccountKind.openRouter]);
    });

    test('a stored chat or default on either is kept', () async {
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
      expect(ai.defaultModel, codex.model);
      ai.openChat('c');
      // The chat's own model is kept too, not swapped for the device.
      expect(ai.model, claude.model);
      ai.pickModel(codex.model);
      await ai.ask('Lisbon?');
      expect(ai.pending, isA<KapyAccountError>());
      expect(codex.asked, isEmpty);
      expect(claude.asked, isEmpty);
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

    test('a recap stays out of the chat list', () async {
      final book = KapyChatBook(store);
      await book.load();
      final at = testNow.subtract(const Duration(days: 1));
      book.put(
        KapyChat(
          id: 'recap',
          title: 'Recap · Mon 16',
          createdAt: at,
          updatedAt: at,
          model: KapyModel.cloud,
          recap: const {'kind': 'day'},
        ),
      );
      final ai = await build();
      expect(ai.chats, isEmpty);
      expect(ai.hasRecaps, isTrue);
      await ai.ask('Lisbon?');
      expect(ai.chats.map((c) => c.title), ['Lisbon?']);
      ai.openChat('recap');
      expect(ai.current!.id, isNot('recap'));
      expect((await build()).chats.map((c) => c.title), ['Lisbon?']);
      expect(
        (store.data['kapyAi.chats.v1']! as Map)['chats'] as List,
        hasLength(2),
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

  group('chats and sync', () {
    test(
      'chats sync only while the book says so, and the controller follows',
      () async {
        final book = KapyChatBook(store);
        final ai = await build(
          billing: await billingOn(pro: true),
          chats: book,
        );
        var told = 0;
        ai.addListener(() => told++);
        expect(ai.chatsSync, isFalse, reason: 'Pro, but nothing is syncing');

        var on = true;
        book.attach(() => on, () async {}, (key) => key);
        expect(ai.chatsSync, isTrue);
        expect(told, greaterThan(0));
        on = false;
        expect(ai.chatsSync, isFalse);
        book.detach();
        expect(ai.chatsSync, isFalse);
      },
    );

    test(
      'a rename and a model pick stamp their own time, and an answer moves neither',
      () async {
        var now = testNow;
        final ai = KapyAiController(
          store: store,
          notes: await notesWith([
            noteJson('lisbon', 'Lisbon trip\nflights'),
          ], store: store),
          device: device,
          billing: await billingOn(pro: true),
          token: () => 'session-token',
          client: MockClient((request) async => server(request)),
          secrets: secrets,
          codex: codex,
          claudeCode: claude,
          apiBaseUrl: Uri.parse('https://api.test/'),
          now: () => now,
          environment: const {},
        );
        addTearDown(ai.dispose);
        await ai.ask('Lisbon?');
        final first = ai.current!;
        expect(first.titleAt, first.createdAt);
        expect(first.modelAt, first.createdAt);

        now = now.add(const Duration(minutes: 5));
        ai.renameChat(first.id, 'Lisbon plans');
        expect(ai.current!.titleAt, now);
        expect(ai.current!.modelAt, first.modelAt);

        now = now.add(const Duration(minutes: 5));
        ai.pickModel(FakeDeviceModel.apple);
        expect(ai.current!.modelAt, now);
        expect(ai.current!.titleAt, now.subtract(const Duration(minutes: 5)));

        now = now.add(const Duration(minutes: 5));
        await ai.ask('And Porto?');
        expect(ai.current!.updatedAt, now);
        expect(ai.current!.titleAt, now.subtract(const Duration(minutes: 10)));
        expect(ai.current!.modelAt, now.subtract(const Duration(minutes: 5)));
      },
    );

    test('a Hidden note never reaches what a chat would send', () async {
      const secret = 'HIDDEN-SECRET-4410';
      store.data['kapyAi.v1'] = {'cloudConsent': true};
      final book = KapyChatBook(store);
      final ai = await build(
        billing: await billingOn(pro: true),
        chats: book,
        notes: [
          noteJson('lisbon', 'Lisbon trip\nflights'),
          noteJson('hidden', 'Lisbon $secret\nthe door code', hidden: true),
        ],
      );
      await ai.ask('What is in my Lisbon notes?');
      book.attach(() => true, () async {}, (key) => key);
      final owed = book.owed();
      expect(ai.current!.messages, hasLength(2), reason: 'it was answered');
      expect(owed, isNotEmpty);
      final sent = jsonEncode([for (final item in owed) item.payload]);
      expect(sent, isNot(contains(secret)));
      expect(sent, isNot(contains('door code')));
      expect(sent, isNot(contains('"hidden"')));
      expect(
        sent,
        contains('"noteId":"lisbon"'),
        reason: 'the open note is listed',
      );
      expect(sent, isNot(contains('"title":"Lisbon trip"')));
    });

    test(
      'Clear history and a deletion are remembered as deletions, and a chat that was never synced owes nothing',
      () async {
        final book = KapyChatBook(store);
        final ai = await build(
          billing: await billingOn(pro: true),
          chats: book,
        );
        await ai.ask('One?');
        ai.newChat();
        await ai.ask('Two?');
        final id = ai.current!.id;
        ai.deleteChat(id);
        expect(ai.chats, hasLength(1));
        await ai.clearHistory();
        expect(ai.chats, isEmpty);
        expect(book.owed(), isEmpty);
        expect(
          (await build(
            billing: await billingOn(pro: true),
            chats: KapyChatBook(store),
          )).chats,
          isEmpty,
        );
      },
    );
  });

  test('construction starts nothing', () async {
    final ai = await build(billing: await billingOn(pro: true));
    await settle();
    expect(sent, isEmpty);
    expect(ai.chats, isEmpty);
  });

  group('a recording', () {
    List<Map<String, Object?>> notes({
      NoteVoiceRef? voice,
      bool hidden = false,
    }) => [
      noteJson('lisbon', 'Lisbon trip\nflights'),
      {
        ...noteJson(
          'standup',
          'Standup\n${NoteAttachmentRef.placeholder}',
          hidden: hidden,
        ),
        'attachments': [(voice ?? _voice()).toJson()],
      },
    ];

    Iterable<http.Request> answers() =>
        sent.where((request) => request.url.path.endsWith('/ai/answer'));

    test(
      'a question reads only its transcript, with times and speakers',
      () async {
        final ai = await build(notes: notes());
        await ai.ask('What did Arjun ask for?', recording: _link);
        final read = device.asked.single.notes.single;
        expect(read.id, 'standup');
        expect(read.title, 'Pricing call');
        expect(
          read.text,
          startsWith(
            'Summary: Pricing call\n- Annual plan first\nTranscript:\n'
            '[0:00] Sanjay: ',
          ),
        );
        expect(
          read.text,
          contains(
            '\n[0:10] Arjun: Can we split the first invoice across two months?\n',
          ),
        );
        expect(read.text, isNot(contains('Lisbon')));
        final chat = ai.current!;
        expect(chat.recording, _link);
        expect(chat.messages.last.text, 'device answer');
        expect(chat.messages.last.read.single.noteId, 'standup');
        expect(chat.messages.last.readTo, isNull);
        expect((await build(notes: notes())).chats.single.recording, _link);
      },
    );

    test(
      'follow-ups stay on its chat, and a question from elsewhere starts one',
      () async {
        final ai = await build(notes: notes());
        await ai.ask('What did we decide?', recording: _link);
        await ai.ask('And the next steps?', recording: _link);
        expect(ai.chats, hasLength(1));
        expect(ai.current!.messages, hasLength(4));

        // The panel's composer, on the same chat, still reads the recording.
        await ai.ask('Anything else?');
        expect(ai.current!.messages, hasLength(6));
        expect(device.asked.last.notes.single.id, 'standup');
        expect(device.asked.last.history, hasLength(4));

        ai.newChat();
        await ai.ask('Lisbon?');
        expect(ai.current!.recording, isNull);
        expect(device.asked.last.notes.single.id, 'lisbon');
        await ai.ask('What did we decide?', recording: _link);
        expect(ai.chats, hasLength(3));
        expect(ai.current!.recording, _link);
        expect(ai.current!.messages, hasLength(2));
      },
    );

    test(
      'a long one goes in up to four parts and says how far it read',
      () async {
        final ai = await build(
          notes: notes(voice: _voice(minutes: 90)),
          billing: await billingOn(pro: true),
        );
        await ai.ask('What did we decide?', recording: _link);
        expect(ai.pending, isA<KapyCloudConsent>());
        await ai.proceed();
        final body = jsonDecode(answers().single.body) as Map;
        final parts = (body['notes'] as List).cast<Map>();
        expect(
          [for (final part in parts) part['title']],
          [for (var i = 1; i <= 4; i++) 'Pricing call (part $i of 4)'],
        );
        final texts = [for (final part in parts) part['text'] as String];
        for (final text in texts) {
          expect(text.length, lessThanOrEqualTo(12000));
        }
        expect(texts.join().length, lessThanOrEqualTo(48000));
        final cloudRead = ai.current!.messages.last.readTo!;
        expect(cloudRead, greaterThan(const Duration(minutes: 40)));
        expect(cloudRead, lessThan(const Duration(minutes: 90)));
        expect(
          texts.last.split('\n').last,
          startsWith(
            '[${formatVoiceDuration(cloudRead - const Duration(seconds: 10))}]',
          ),
          reason: 'it stops at the start of a paragraph, and says which',
        );

        ai.newChat();
        ai.pickModel(FakeDeviceModel.apple);
        await ai.ask('What did we decide?', recording: _link);
        final onDevice = device.asked.single.notes.single;
        expect(onDevice.title, 'Pricing call');
        expect(onDevice.text.length, lessThanOrEqualTo(device.noteChars));
        final deviceRead = ai.current!.messages.last.readTo!;
        expect(deviceRead, lessThan(cloudRead));
        expect(
          onDevice.text.split('\n').last,
          startsWith(
            '[${formatVoiceDuration(deviceRead - const Duration(seconds: 10))}]',
          ),
        );
      },
    );

    test('in a hidden note it sends nothing and says why', () async {
      final ai = await build(
        notes: notes(hidden: true),
        billing: await billingOn(pro: true),
      );
      await ai.ask('What did we decide?', recording: _link);
      final failed = ai.pending! as KapyFailed;
      expect(failed.message, "Kapy AI doesn't read hidden notes.");
      expect(failed.retry, isFalse);
      expect(answers(), isEmpty);
      expect(device.asked, isEmpty);
    });

    test('without a transcript it sends nothing and says so', () async {
      final ai = await build(notes: notes(voice: _voice(transcribed: false)));
      await ai.ask('What did we decide?', recording: _link);
      expect(
        (ai.pending! as KapyFailed).message,
        'This recording has no transcript to read.',
      );
      expect(device.asked, isEmpty);
    });

    test('Kapy AI Cloud on Free holds it with the same Pro card', () async {
      final ai = await build(
        notes: notes(),
        billing: await billingOn(pro: false),
      );
      ai.defaultModel = KapyModel.cloud;
      await ai.ask('What did we decide?', recording: _link);
      final locked = ai.pending! as KapyCloudLocked;
      expect(locked.upgrade, isTrue);
      expect(locked.fallbacks, [FakeDeviceModel.apple]);
      expect(answers(), isEmpty);
    });

    test(
      'agreeing to send a transcript covers recordings, and not the notes',
      () async {
        final ai = await build(
          notes: notes(),
          billing: await billingOn(pro: true),
        );
        await ai.ask('What did we decide?', recording: _link);
        expect((ai.pending! as KapyCloudConsent).recording, isTrue);
        await ai.proceed();
        expect(answers(), hasLength(1));

        ai.newChat();
        await ai.ask('What are the next steps?', recording: _link);
        expect(ai.pending, isNull);
        expect(answers(), hasLength(2));

        ai.newChat();
        await ai.ask('Lisbon?');
        expect((ai.pending! as KapyCloudConsent).recording, isFalse);
        expect(answers(), hasLength(2));
      },
    );

    test("the panel's agreement covers recordings too", () async {
      final ai = await build(
        notes: notes(),
        billing: await billingOn(pro: true),
      );
      await ai.ask('Lisbon?');
      expect((ai.pending! as KapyCloudConsent).recording, isFalse);
      await ai.proceed();
      expect(answers(), hasLength(1));
      await ai.ask('What did we decide?', recording: _link);
      expect(ai.pending, isNull);
      expect(answers(), hasLength(2));
    });

    test('another model answers the same question again', () async {
      final ai = await build(notes: notes());
      await ai.ask('What did we decide?', recording: _link);
      await ai.answerWith(FakeDeviceModel.apple);
      final messages = ai.current!.messages;
      expect(
        [for (final message in messages) message.role],
        [KapyRole.user, KapyRole.assistant, KapyRole.user, KapyRole.assistant],
      );
      expect(messages[2].text, 'What did we decide?');
      expect(messages[2].id, isNot(messages[0].id));
      expect(messages.last.model, FakeDeviceModel.apple);
      expect(device.asked, hasLength(2));
      expect(device.asked.last.notes.single.id, 'standup');
    });

    test(
      'reads the whole of a transcript that fits, with no mark to say so',
      () async {
        final ai = await build(notes: notes());
        await ai.ask('What did we decide?', recording: _link);
        final whole = ai.current!.messages.last;
        expect(whole.readTo, isNull);
        expect(ai.readWhole(ai.current!, whole), isTrue);
      },
    );

    test(
      'reads part of one that does not fit, whether it says so or not',
      () async {
        final long = await build(notes: notes(voice: _voice(minutes: 90)));
        await long.ask('What did we decide?', recording: _link);
        final part = long.current!.messages.last;
        expect(part.readTo, isNotNull);
        expect(long.readWhole(long.current!, part), isFalse);
        // As a build from before recording chats sends it again: no mark.
        final unmarked = KapyMessage(
          id: 'unmarked',
          role: KapyRole.assistant,
          text: part.text,
          at: part.at,
          model: part.model,
        );
        expect(long.readWhole(long.current!, unmarked), isFalse);
      },
    );

    test('suggests two questions, and one about a named speaker', () {
      const two = ['What did we decide?', 'What are the next steps?'];
      VoiceTranscript said(Map<int, String> speakers, {int people = 2}) =>
          VoiceTranscript(
            lang: 'en',
            engine: 'test',
            at: 0,
            segments: [
              for (var i = 0; i < 4; i++)
                TranscriptSegment(
                  s: i * 1000,
                  e: i * 1000 + 500,
                  t: 'Line $i',
                  speaker: i % people,
                ),
            ],
            speakers: speakers,
          );
      expect(recordingQuestions(null), two);
      expect(recordingQuestions(_voice().transcript), [
        ...two,
        'What did Arjun ask for?',
      ]);
      expect(recordingQuestions(said({})), two);
      expect(recordingQuestions(said({0: 'Sanjay'})), [
        ...two,
        'What did Sanjay ask for?',
      ]);
      expect(recordingQuestions(said({0: 'Sanjay'}, people: 1)), two);
    });
  });
}
