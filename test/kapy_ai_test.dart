import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_chats.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_conversation.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_markdown.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_kapy_ai.dart';
import 'test_fonts.dart';

/// The panel, its picker, its chats, its notices and its answers, one piece
/// at a time. Where each sits on the page, and what Settings says about it,
/// is in kapy_ai_app_test.dart.

final _now = DateTime(2026, 11, 17, 12);

KapyChat _chat(
  String id,
  String title, {
  DateTime? at,
  List<KapyMessage> messages = const [],
  KapyModel model = FakeKapyAi.appleIntelligence,
}) => KapyChat(
  id: id,
  title: title,
  createdAt: at ?? _now,
  updatedAt: at ?? _now,
  model: model,
  messages: messages,
);

KapyMessage _question(String text) =>
    KapyMessage(id: 'q', role: KapyRole.user, text: text, at: _now);

KapyMessage _answer(
  String text, {
  KapyModel? model = FakeKapyAi.appleIntelligence,
  List<KapyNoteRef> read = const [],
  int matching = 0,
}) => KapyMessage(
  id: 'a',
  role: KapyRole.assistant,
  text: text,
  at: _now,
  read: read,
  matching: matching,
  model: model,
);

const _codexConnected = KapyAccountState(
  kind: KapyAccountKind.codex,
  status: KapyAccountStatus.connected,
  models: [FakeKapyAi.gpt, FakeKapyAi.gptMini],
);
const _claudeConnected = KapyAccountState(
  kind: KapyAccountKind.claudeCode,
  status: KapyAccountStatus.connected,
  models: [FakeKapyAi.sonnet],
);
const _routerConnected = KapyAccountState(
  kind: KapyAccountKind.openRouter,
  status: KapyAccountStatus.connected,
  models: [FakeKapyAi.gemini],
  detail: '4f2a',
);

Widget _harness(Widget child) => MaterialApp(
  theme: KapyTheme.dark(),
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, height: 700, child: child)),
  ),
);

KapyAiPanel _panel(
  FakeKapyAi ai,
  KapyAiPanelController controller, {
  VoidCallback? onClose,
  VoidCallback? onManage,
  String? shortcut = '⌘J',
  Map<String, String> titles = const {'n1': 'Trip budget'},
  void Function(String)? onOpenNote,
}) => KapyAiPanel(
  kapyAi: ai,
  controller: controller,
  noteTitle: (id) => titles[id],
  onOpenNote: onOpenNote ?? (_) {},
  onManageAccounts: onManage ?? () {},
  onClose: onClose ?? controller.close,
  shortcut: shortcut,
  now: () => _now,
);

void main() {
  setUpAll(loadTestFonts);

  late bool wasAvailable;
  setUp(() {
    wasAvailable = kapyAiAvailable;
    kapyAiAvailable = true;
  });
  tearDown(() => kapyAiAvailable = wasAvailable);

  group('panel', () {
    testWidgets('asks with the note the chip names, and ↵ sends', (
      tester,
    ) async {
      final ai = FakeKapyAi();
      final controller = KapyAiPanelController()..open(noteId: 'n1');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(_panel(ai, controller)));

      expect(find.text('This note · Trip budget'), findsOneWidget);
      expect(find.text('⌘J opens and closes Kapy AI'), findsOneWidget);
      expect(find.text('Summarise this note'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('kapy-ai-field')),
        'What did I budget?',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(ai.calls, ['ask:What did I budget?:n1']);
    });

    testWidgets('the chip’s ✕ asks across every note', (tester) async {
      final ai = FakeKapyAi();
      final controller = KapyAiPanelController()..open(noteId: 'n1');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(_panel(ai, controller)));

      await tester.tap(find.byKey(const ValueKey('kapy-ai-chip-remove')));
      await tester.pump();

      expect(find.byKey(const ValueKey('kapy-ai-chip')), findsNothing);
      expect(controller.noteId, isNull);
    });

    testWidgets('a note this device cannot open gets no chip', (tester) async {
      final ai = FakeKapyAi();
      final controller = KapyAiPanelController()..open(noteId: 'hidden');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(_panel(ai, controller)));

      expect(find.byKey(const ValueKey('kapy-ai-chip')), findsNothing);
    });

    testWidgets('a blank question is not sent, and ⇧↵ is a new line', (
      tester,
    ) async {
      final ai = FakeKapyAi();
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(_panel(ai, controller)));
      final field = find.byKey(const ValueKey('kapy-ai-field'));

      await tester.tap(field);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.tap(find.byKey(const ValueKey('kapy-ai-send')));
      await tester.pump();
      expect(ai.calls, isEmpty);

      await tester.enterText(field, 'one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(ai.calls, isEmpty);
    });

    testWidgets('a suggestion asks', (tester) async {
      final ai = FakeKapyAi();
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(_panel(ai, controller)));

      await tester.tap(find.text('Find my notes about Lisbon'));
      await tester.pump();

      expect(ai.calls, ['ask:Find my notes about Lisbon:']);
    });

    testWidgets('Esc closes the picker first, then the panel', (tester) async {
      final ai = FakeKapyAi();
      var closed = 0;
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(_panel(ai, controller, onClose: () => closed++)),
      );
      await tester.tap(find.byKey(const ValueKey('kapy-ai-model-button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('kapy-ai-picker')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('kapy-ai-picker')), findsNothing);
      expect(closed, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 1);
    });

    testWidgets('✕ closes the panel', (tester) async {
      final ai = FakeKapyAi();
      var closed = 0;
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(_panel(ai, controller, onClose: () => closed++)),
      );

      await tester.tap(find.byKey(const ValueKey('kapy-ai-close')));
      expect(closed, 1);
    });

    testWidgets('the new chat button starts one', (tester) async {
      final ai = FakeKapyAi();
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(_panel(ai, controller)));

      await tester.tap(find.byKey(const ValueKey('kapy-ai-new-chat')));
      expect(ai.calls, ['newChat']);
    });

    testWidgets('an answer shows the notes it read, and each opens', (
      tester,
    ) async {
      final opened = <String>[];
      final ai = FakeKapyAi();
      ai.set(
        current: _chat(
          'c1',
          'Trip budget',
          messages: [
            _question('What did I budget?'),
            _answer(
              'You set aside **900** for the flights.',
              read: [
                KapyNoteRef(
                  noteId: 'n1',
                  title: 'Trip budget',
                  edited: DateTime(2026, 11, 16),
                ),
                KapyNoteRef(
                  noteId: 'gone',
                  title: 'Old plans',
                  edited: DateTime(2026, 10, 2),
                ),
              ],
              matching: 7,
            ),
          ],
        ),
      );
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(_panel(ai, controller, onOpenNote: opened.add)),
      );

      expect(find.text('What did I budget?'), findsOneWidget);
      expect(
        find.textContaining('flights', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Read 2 of the 7 matching notes'), findsOneWidget);
      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('Note not available'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('kapy-ai-read-n1')));
      await tester.tap(find.byKey(const ValueKey('kapy-ai-read-gone')));
      expect(opened, ['n1']);
    });

    testWidgets('each model names where an answer came from', (tester) async {
      final ai = FakeKapyAi();
      ai.set(
        current: _chat(
          'c1',
          'Sources',
          messages: [
            _answer('one', model: KapyModel.cloud),
            _answer('two', model: FakeKapyAi.gpt),
            _answer('three', model: FakeKapyAi.sonnet),
            _answer('four', model: FakeKapyAi.gemini),
          ],
        ),
      );
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(_panel(ai, controller)));

      expect(find.text('Kapy AI Cloud'), findsWidgets);
      expect(find.text('GPT-5.5 · Codex on this Mac'), findsOneWidget);
      expect(find.text('Sonnet 5.5 · Claude Code on this Mac'), findsOneWidget);
      expect(
        find.text('Gemini 3.8 Flash · your OpenRouter key'),
        findsOneWidget,
      );
    });
  });

  group('picker', () {
    Future<FakeKapyAi> open(
      WidgetTester tester,
      FakeKapyAi ai, {
      VoidCallback? onManage,
    }) async {
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(_panel(ai, controller, onManage: onManage)),
      );
      await tester.tap(find.byKey(const ValueKey('kapy-ai-model-button')));
      await tester.pump();
      return ai;
    }

    testWidgets('Free: Cloud is dimmed, part of Pro, and cannot be picked', (
      tester,
    ) async {
      final ai = await open(tester, FakeKapyAi());

      expect(find.text('Kapy AI Cloud'), findsOneWidget);
      expect(find.text('Part of Pro'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('kapy-ai-model-cloud-cloud')),
        warnIfMissed: false,
      );
      expect(ai.calls, isEmpty);
    });

    testWidgets('Pro: Cloud counts its answers, and picks', (tester) async {
      final ai = await open(
        tester,
        FakeKapyAi(
          pro: true,
          usage: CloudUsage(
            remaining: 412,
            limit: 500,
            resetsAt: DateTime(2026, 12),
          ),
        ),
      );

      expect(find.text('412 of 500 answers left this month'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('kapy-ai-model-cloud-cloud')));
      expect(ai.calls, ['pickModel:cloud']);
    });

    testWidgets('names the device, and where each account’s models run', (
      tester,
    ) async {
      await open(
        tester,
        FakeKapyAi(
          pro: true,
          accountList: const [
            _codexConnected,
            _claudeConnected,
            _routerConnected,
          ],
        ),
      );

      expect(find.text('ON THIS DEVICE'), findsOneWidget);
      expect(find.text('Apple Intelligence'), findsWidgets);
      expect(find.text('Codex on this Mac'), findsNWidgets(2));
      expect(find.text('Claude Code on this Mac'), findsOneWidget);
      expect(find.text('Your OpenRouter key'), findsOneWidget);
      expect(find.text('Manage accounts…'), findsOneWidget);
    });

    testWidgets('Free with no account yet: connect rows, no Manage', (
      tester,
    ) async {
      var managed = 0;
      await open(
        tester,
        FakeKapyAi(
          deviceState: const DeviceModelState(
            status: DeviceModelStatus.ready,
            model: FakeKapyAi.gemma,
            totalBytes: 2600000000,
            receivedBytes: 2600000000,
          ),
          accountList: const [
            KapyAccountState(
              kind: KapyAccountKind.codex,
              status: KapyAccountStatus.notConnected,
            ),
            KapyAccountState(
              kind: KapyAccountKind.claudeCode,
              status: KapyAccountStatus.notConnected,
            ),
            KapyAccountState(
              kind: KapyAccountKind.openRouter,
              status: KapyAccountStatus.notConnected,
            ),
          ],
        ),
        onManage: () => managed++,
      );

      expect(find.text('Use Codex'), findsOneWidget);
      expect(find.text('Use Claude Code'), findsOneWidget);
      expect(find.text('Add an OpenRouter key'), findsOneWidget);
      expect(find.text('Manage accounts…'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('kapy-ai-connect-codex')));
      await tester.pump();
      expect(managed, 1);
    });

    testWidgets('a phone with no on-device model says so, and offers a key', (
      tester,
    ) async {
      await open(
        tester,
        FakeKapyAi(
          deviceState: const DeviceModelState(
            status: DeviceModelStatus.unavailable,
          ),
          accountList: const [
            KapyAccountState(
              kind: KapyAccountKind.openRouter,
              status: KapyAccountStatus.notConnected,
            ),
          ],
        ),
      );

      expect(find.text('On-device model'), findsOneWidget);
      expect(find.text('Part of Pro'), findsOneWidget);
      expect(find.text('Add an OpenRouter key'), findsOneWidget);
      expect(find.text('Use Codex'), findsNothing);
      expect(find.text('Use Claude Code'), findsNothing);
    });

    testWidgets('a pick sticks to the chat, and closes the picker', (
      tester,
    ) async {
      final ai = await open(
        tester,
        FakeKapyAi(accountList: const [_codexConnected]),
      );

      await tester.tap(
        find.byKey(const ValueKey('kapy-ai-model-codex-gpt-5.5')),
      );
      await tester.pump();

      expect(ai.calls, ['pickModel:gpt-5.5']);
      expect(find.byKey(const ValueKey('kapy-ai-picker')), findsNothing);
    });

    testWidgets('a Codex that Kapy may not use offers none of its models', (
      tester,
    ) async {
      await open(
        tester,
        FakeKapyAi(
          accountList: const [
            KapyAccountState(
              kind: KapyAccountKind.codex,
              status: KapyAccountStatus.connected,
              models: [FakeKapyAi.gpt],
              enabled: false,
            ),
          ],
        ),
      );

      expect(find.text('GPT-5.5'), findsNothing);
    });
  });

  group('what holds a question up', () {
    Future<FakeKapyAi> hold(
      WidgetTester tester,
      KapyPending pending, {
      FakeKapyAi? ai,
      VoidCallback? onManage,
    }) async {
      final fake = ai ?? FakeKapyAi(pro: true);
      fake.set(
        current: _chat(
          'c1',
          'Trip',
          messages: [_question('What did I budget?')],
          model: fake.model,
        ),
        pending: pending,
      );
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(_panel(fake, controller, onManage: onManage)),
      );
      return fake;
    }

    testWidgets('Cloud’s first use: the notice, Go ahead and Use this device', (
      tester,
    ) async {
      final ai = await hold(tester, const KapyCloudConsent());

      expect(find.text('Before the first answer'), findsOneWidget);
      expect(
        find.textContaining(
          'through Kapy’s server to the AI model that answers',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Hidden notes are never used'),
        findsOneWidget,
      );
      expect(find.textContaining('Gemini'), findsNothing);

      await tester.tap(find.text('Go ahead'));
      await tester.pump();
      expect(ai.calls, ['proceed']);
    });

    testWidgets('↵ in an empty field is Go ahead on the Cloud notice', (
      tester,
    ) async {
      final ai = await hold(tester, const KapyCloudConsent());

      await tester.tap(find.byKey(const ValueKey('kapy-ai-field')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(ai.calls, ['proceed']);
    });

    testWidgets('Use this device answers on the device', (tester) async {
      final ai = await hold(tester, const KapyCloudConsent());

      await tester.tap(find.text('Use this device'));
      await tester.pump();

      expect(ai.calls, ['answerWith:apple']);
    });

    testWidgets('Codex’s first use names OpenAI and the ChatGPT plan', (
      tester,
    ) async {
      final ai = await hold(
        tester,
        const KapyAccountConsent(KapyAccountKind.codex),
      );

      expect(find.text('Goes to OpenAI'), findsOneWidget);
      expect(
        find.text(
          'Your question and the notes it reads go to OpenAI through Codex on '
          'this Mac, under your ChatGPT plan. Hidden notes never do.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Go ahead'));
      expect(ai.calls, ['proceed']);
    });

    testWidgets('Claude Code’s first use names Anthropic', (tester) async {
      await hold(tester, const KapyAccountConsent(KapyAccountKind.claudeCode));

      expect(find.text('Goes to Anthropic'), findsOneWidget);
      expect(
        find.textContaining('through Claude Code on this Mac'),
        findsOneWidget,
      );
    });

    testWidgets('OpenRouter’s first use names OpenRouter and the maker', (
      tester,
    ) async {
      await hold(
        tester,
        const KapyAccountConsent(KapyAccountKind.openRouter),
        ai: FakeKapyAi(accountList: const [_routerConnected])
          ..set(model: FakeKapyAi.gemini),
      );

      expect(find.text('Goes to OpenRouter'), findsOneWidget);
      expect(find.textContaining('OpenRouter and Google'), findsOneWidget);
    });

    testWidgets('Pick another opens the picker', (tester) async {
      await hold(tester, const KapyAccountConsent(KapyAccountKind.codex));

      await tester.tap(find.text('Pick another'));
      await tester.pump();

      expect(find.byKey(const ValueKey('kapy-ai-picker')), findsOneWidget);
    });

    testWidgets('the download ask: Download 2.6 GB and Not now', (
      tester,
    ) async {
      final ai = await hold(
        tester,
        const KapyDownloadAsk(2600000000),
        ai: FakeKapyAi(
          deviceState: const DeviceModelState(
            status: DeviceModelStatus.notDownloaded,
            model: FakeKapyAi.gemma,
            totalBytes: 2600000000,
          ),
        ),
      );

      expect(find.text('Download Gemma first'), findsOneWidget);
      await tester.tap(find.text('Download 2.6 GB'));
      await tester.tap(find.text('Not now'));
      expect(ai.calls, ['proceed', 'dismissPending']);
    });

    testWidgets('the download in progress can be cancelled', (tester) async {
      final ai = await hold(
        tester,
        const KapyDownloading(received: 1100000000, total: 2600000000),
        ai: FakeKapyAi(
          deviceState: const DeviceModelState(
            status: DeviceModelStatus.downloading,
            model: FakeKapyAi.gemma,
            totalBytes: 2600000000,
            receivedBytes: 1100000000,
          ),
        ),
      );

      expect(find.text('Getting Gemma ready'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(ai.calls, ['cancelDeviceDownload', 'dismissPending']);
    });

    testWidgets('the limit names the day, and offers the device', (
      tester,
    ) async {
      final ai = await hold(
        tester,
        KapyLimitReached(
          resetsAt: DateTime(2026, 12),
          fallback: FakeKapyAi.appleIntelligence,
        ),
      );

      expect(find.text('No answers left until 1 Dec'), findsOneWidget);
      await tester.tap(find.text('Use Apple Intelligence'));
      expect(ai.calls, ['answerWith:apple']);
    });

    testWidgets('the limit says the allowance the account has, not 500', (
      tester,
    ) async {
      final ai = FakeKapyAi(
        pro: true,
        usage: CloudUsage(
          remaining: 0,
          limit: 50,
          resetsAt: DateTime(2026, 12),
        ),
      );
      await hold(
        tester,
        KapyLimitReached(
          resetsAt: DateTime(2026, 12),
          fallback: FakeKapyAi.appleIntelligence,
        ),
        ai: ai,
      );

      expect(find.textContaining('gives 50 answers a month'), findsOneWidget);
      expect(find.textContaining('500'), findsNothing);
    });

    testWidgets('a trial’s picker counts from its own limit', (tester) async {
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      final ai = FakeKapyAi(
        pro: true,
        usage: CloudUsage(
          remaining: 41,
          limit: 50,
          resetsAt: DateTime(2026, 12),
        ),
      );
      await tester.pumpWidget(_harness(_panel(ai, controller)));
      await tester.tap(find.byKey(const ValueKey('kapy-ai-model-button')));
      await tester.pump();

      expect(find.text('41 of 50 answers left this month'), findsOneWidget);
    });

    testWidgets('offline: Use the device, or Try again', (tester) async {
      final ai = await hold(
        tester,
        const KapyOffline(fallback: FakeKapyAi.appleIntelligence),
      );

      expect(find.text('You’re offline'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.tap(find.text('Use Apple Intelligence'));
      expect(ai.calls, ['proceed', 'answerWith:apple']);
    });

    testWidgets('a signed-out Codex: Check again looks, then answers', (
      tester,
    ) async {
      final ai = await hold(
        tester,
        const KapyAccountError(
          account: KapyAccountKind.codex,
          model: FakeKapyAi.gpt,
        ),
      );

      expect(find.text('Codex is signed out'), findsOneWidget);
      expect(
        find.text(
          'Sign in inside Codex, then check again, or pick another model.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Check again'));
      await tester.pump();
      expect(ai.calls, ['checkCodex', 'proceed']);
    });

    testWidgets('a signed-out Claude Code checks Claude Code', (tester) async {
      final ai = await hold(
        tester,
        const KapyAccountError(
          account: KapyAccountKind.claudeCode,
          model: FakeKapyAi.sonnet,
        ),
      );

      expect(find.text('Claude Code is signed out'), findsOneWidget);
      await tester.tap(find.text('Check again'));
      await tester.pump();
      expect(ai.calls, ['checkClaudeCode', 'proceed']);
    });

    testWidgets('a rejected key sends to Settings', (tester) async {
      var managed = 0;
      await hold(
        tester,
        const KapyAccountError(
          account: KapyAccountKind.openRouter,
          model: FakeKapyAi.gemini,
        ),
        onManage: () => managed++,
      );

      expect(
        find.text('Check the key in Settings, or pick another model.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Open Settings'));
      expect(managed, 1);
    });

    testWidgets('a failure shows its message and can be tried again', (
      tester,
    ) async {
      final ai = await hold(tester, const KapyFailed('Something broke.'));

      expect(find.text('Something broke.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(ai.calls, ['proceed']);
    });
  });

  group('chats', () {
    final chats = [
      _chat('today', 'Trip budget', at: _now),
      _chat('yesterday', 'Lisbon ideas', at: DateTime(2026, 11, 16, 9)),
      _chat('week', 'Weekly plan', at: DateTime(2026, 11, 12)),
      _chat('october', 'Boiler quote', at: DateTime(2026, 10, 3)),
      _chat('old', 'Tax notes', at: DateTime(2025, 3, 9)),
    ];

    Future<FakeKapyAi> open(WidgetTester tester, {bool pro = false}) async {
      final ai = FakeKapyAi(pro: pro, chatList: chats);
      await tester.pumpWidget(
        _harness(KapyAiChats(kapyAi: ai, now: _now, onOpened: () {})),
      );
      return ai;
    }

    testWidgets('groups by day, then month, with the year when it differs', (
      tester,
    ) async {
      await open(tester);

      for (final label in [
        'TODAY',
        'YESTERDAY',
        'PREVIOUS 7 DAYS',
        'OCTOBER',
        'MARCH 2025',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Kept on this Mac. Pro syncs them'), findsOneWidget);
    });

    testWidgets('Pro says its chats sync', (tester) async {
      await open(tester, pro: true);

      expect(find.text('Chats sync across your devices'), findsOneWidget);
    });

    testWidgets('searches by title', (tester) async {
      await open(tester);

      await tester.enterText(
        find.byKey(const ValueKey('kapy-ai-chat-search')),
        'lisb',
      );
      await tester.pump();

      expect(find.text('Lisbon ideas'), findsOneWidget);
      expect(find.text('Trip budget'), findsNothing);
      expect(find.text('YESTERDAY'), findsOneWidget);
      expect(find.text('TODAY'), findsNothing);
    });

    testWidgets('opens a chat', (tester) async {
      final ai = await open(tester);

      await tester.tap(find.byKey(const ValueKey('kapy-ai-chat-week')));
      expect(ai.calls, ['openChat:week']);
    });

    Future<void> hover(WidgetTester tester, String id) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(ValueKey('kapy-ai-chat-$id'))),
      );
      await tester.pump();
    }

    testWidgets('renames in place: ↵ saves', (tester) async {
      final ai = await open(tester);
      await hover(tester, 'today');

      await tester.tap(find.byKey(const ValueKey('kapy-ai-rename-today')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('kapy-ai-rename-field')),
        'Flights',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(ai.calls, ['renameChat:today:Flights']);
      expect(find.byKey(const ValueKey('kapy-ai-rename-field')), findsNothing);
    });

    testWidgets('renames in place: Esc keeps the old name', (tester) async {
      final ai = await open(tester);
      await hover(tester, 'today');

      await tester.tap(find.byKey(const ValueKey('kapy-ai-rename-today')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('kapy-ai-rename-field')),
        'Flights',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(ai.calls, isEmpty);
      expect(find.text('Trip budget'), findsOneWidget);
    });

    testWidgets('delete asks first, and Cancel keeps the chat', (tester) async {
      final ai = await open(tester);
      await hover(tester, 'today');

      await tester.tap(find.byKey(const ValueKey('kapy-ai-delete-today')));
      await tester.pump();
      expect(
        find.text('Delete “Trip budget”? This can’t be undone.'),
        findsOneWidget,
      );
      expect(ai.calls, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(ai.calls, isEmpty);
      expect(find.text('Trip budget'), findsOneWidget);
    });

    testWidgets('delete confirms, then deletes', (tester) async {
      final ai = await open(tester);
      await hover(tester, 'today');

      await tester.tap(find.byKey(const ValueKey('kapy-ai-delete-today')));
      await tester.pump();
      await tester.tap(find.text('Delete'));
      await tester.pump();

      expect(ai.calls, ['deleteChat:today']);
      expect(find.text('Trip budget'), findsNothing);
    });
  });

  group('answers are untrusted', () {
    final launched = <Uri>[];
    setUp(launched.clear);

    Future<void> show(WidgetTester tester, String text) => tester.pumpWidget(
      _harness(
        SingleChildScrollView(
          child: KapyAiMarkdown(text, launch: (uri) async => launched.add(uri)),
        ),
      ),
    );

    /// Taps every link in the text that holds [label], the way a click on it
    /// would: through the recogniser, which is all a link has.
    void tapLinksIn(WidgetTester tester, String label) {
      final rich = tester.widget<RichText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains(label),
        ),
      );
      void walk(InlineSpan span) {
        if (span is! TextSpan) return;
        final recognizer = span.recognizer;
        if (recognizer is TapGestureRecognizer) recognizer.onTap?.call();
        span.children?.forEach(walk);
      }

      walk(rich.text);
    }

    testWidgets('an https link opens only when tapped', (tester) async {
      await show(tester, 'See [the docs](https://example.com/a).');
      expect(launched, isEmpty);

      tapLinksIn(tester, 'the docs');
      expect(launched, [Uri.parse('https://example.com/a')]);
    });

    testWidgets('mailto opens when tapped', (tester) async {
      await show(tester, 'Write to [me](mailto:me@example.com).');

      tapLinksIn(tester, 'Write to');
      expect(launched, [Uri.parse('mailto:me@example.com')]);
    });

    for (final bad in [
      'javascript:alert(1)',
      'file:///etc/passwd',
      'kapynotes://hide-all',
      'data:text/html;base64,AAAA',
      'tel:+123',
      'https:///nohost',
      '//example.com',
      'example.com',
    ]) {
      testWidgets('$bad is plain text, and nothing launches', (tester) async {
        await show(tester, 'Run [this link]($bad) now.');

        expect(
          find.textContaining('this link', findRichText: true),
          findsOneWidget,
        );
        tapLinksIn(tester, 'this link');
        expect(launched, isEmpty);
      });
    }

    testWidgets('HTML is shown as the text it is', (tester) async {
      await show(
        tester,
        '<img src="https://evil.example/pixel.png"> <script>alert(1)</script>',
      );

      expect(find.byType(Image), findsNothing);
      expect(
        find.textContaining(
          '<img src="https://evil.example/pixel.png">',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('<script>alert(1)</script>', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('a markdown image is not fetched or drawn', (tester) async {
      await show(tester, 'Look: ![tracker](https://evil.example/p.png)');

      expect(find.byType(Image), findsNothing);
      expect(launched, isEmpty);
    });

    testWidgets('headings, lists, emphasis and code render as text', (
      tester,
    ) async {
      await show(
        tester,
        '# Plan\n\n- one\n- **two**\n\n1. first\n2. second\n\nUse `calc` and *this*.\n\n```\nlet x = 1;\n```',
      );

      for (final text in [
        'Plan',
        'one',
        'two',
        'first',
        'second',
        'let x = 1;',
      ]) {
        expect(
          find.textContaining(text, findRichText: true),
          findsWidgets,
          reason: text,
        );
      }
    });
  });

  group('empty', () {
    testWidgets('offers its suggestions, and asks with the one tapped', (
      tester,
    ) async {
      String? asked;
      await tester.pumpWidget(
        _harness(
          KapyAiEmpty(
            suggestions: const ['One', 'Two'],
            onAsk: (text) => asked = text,
          ),
        ),
      );

      await tester.tap(find.text('Two'));
      expect(asked, 'Two');
    });
  });

  group('goldens', () {
    final frame = GlobalKey();

    Future<void> shoot(
      WidgetTester tester,
      String name,
      Widget panel, {
      Brightness brightness = Brightness.dark,
      Future<void> Function()? then,
    }) async {
      tester.view.physicalSize = const Size(400, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.dark
              ? KapyTheme.dark()
              : KapyTheme.light(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => Container(
                  key: frame,
                  width: 360,
                  height: 720,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: context.palette.sidebarBackground,
                    border: Border.all(color: context.palette.separator),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: panel,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      if (then != null) await then();
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(
        find.byKey(frame),
        matchesGoldenFile('goldens/kapy_ai_$name.png'),
      );
    }

    FakeKapyAi withAnswer({bool pro = true}) =>
        FakeKapyAi(
          pro: pro,
          usage: CloudUsage(
            remaining: 412,
            limit: 500,
            resetsAt: DateTime(2026, 12),
          ),
        )..set(
          model: KapyModel.cloud,
          current: _chat(
            'c1',
            'Trip budget',
            messages: [
              _question('How much have I set aside for flights?'),
              _answer(
                'You have set aside **900** for flights across two notes: '
                '600 for the outbound leg and 300 for the return. The hotel is '
                'budgeted separately.',
                model: KapyModel.cloud,
                matching: 7,
                read: [
                  KapyNoteRef(
                    noteId: 'n1',
                    title: 'Trip budget',
                    edited: DateTime(2026, 11, 16),
                  ),
                  KapyNoteRef(
                    noteId: 'n2',
                    title: 'Lisbon flights',
                    edited: DateTime(2026, 11, 3),
                  ),
                  KapyNoteRef(
                    noteId: 'n3',
                    title: 'Packing list',
                    edited: DateTime(2026, 10, 21),
                  ),
                ],
              ),
            ],
          ),
        );

    Widget panelFor(FakeKapyAi ai, {String? noteId}) {
      final controller = KapyAiPanelController()..open(noteId: noteId);
      addTearDown(controller.dispose);
      return _panel(
        ai,
        controller,
        titles: const {
          'n1': 'Trip budget',
          'n2': 'Lisbon flights',
          'n3': 'Packing list',
        },
      );
    }

    for (final brightness in Brightness.values) {
      final suffix = brightness.name;

      testWidgets('the panel with an answer, $suffix', (tester) async {
        await shoot(
          tester,
          'panel_answer_$suffix',
          panelFor(withAnswer(), noteId: 'n1'),
          brightness: brightness,
        );
      });

      testWidgets('the empty panel, $suffix', (tester) async {
        await shoot(
          tester,
          'empty_$suffix',
          panelFor(FakeKapyAi(pro: true), noteId: 'n1'),
          brightness: brightness,
        );
      });

      testWidgets('the chats, $suffix', (tester) async {
        final ai = FakeKapyAi(
          chatList: [
            _chat('today', 'Trip budget', at: _now),
            _chat('today2', 'What did I plan for Friday?', at: _now),
            _chat('yesterday', 'Lisbon ideas', at: DateTime(2026, 11, 16, 9)),
            _chat('week', 'Weekly plan', at: DateTime(2026, 11, 12)),
            _chat('october', 'Boiler quote', at: DateTime(2026, 10, 3)),
          ],
        )..set(current: _chat('today', 'Trip budget'));
        await shoot(
          tester,
          'chats_$suffix',
          KapyAiChats(kapyAi: ai, now: _now, onOpened: () {}),
          brightness: brightness,
        );
      });
    }

    Future<void> picker(
      WidgetTester tester,
      String name,
      FakeKapyAi ai, {
      Brightness brightness = Brightness.dark,
    }) => shoot(
      tester,
      name,
      panelFor(ai, noteId: 'n1'),
      brightness: brightness,
      then: () async {
        await tester.tap(find.byKey(const ValueKey('kapy-ai-model-button')));
        await tester.pump();
      },
    );

    final pro = FakeKapyAi(
      pro: true,
      usage: CloudUsage(
        remaining: 412,
        limit: 500,
        resetsAt: DateTime(2026, 12),
      ),
      accountList: const [_codexConnected, _claudeConnected, _routerConnected],
    )..set(model: KapyModel.cloud);

    testWidgets('the picker on Pro with accounts, dark', (tester) async {
      await picker(tester, 'picker_pro_dark', pro);
    });

    testWidgets('the picker on Pro with accounts, light', (tester) async {
      await picker(
        tester,
        'picker_pro_light',
        pro,
        brightness: Brightness.light,
      );
    });

    testWidgets('the picker on Free with no account', (tester) async {
      await picker(
        tester,
        'picker_free_dark',
        FakeKapyAi(
          deviceState: const DeviceModelState(
            status: DeviceModelStatus.ready,
            model: FakeKapyAi.gemma,
            totalBytes: 2600000000,
            receivedBytes: 2600000000,
          ),
          accountList: const [
            KapyAccountState(
              kind: KapyAccountKind.codex,
              status: KapyAccountStatus.notConnected,
            ),
            KapyAccountState(
              kind: KapyAccountKind.claudeCode,
              status: KapyAccountStatus.notConnected,
            ),
            KapyAccountState(
              kind: KapyAccountKind.openRouter,
              status: KapyAccountStatus.notConnected,
            ),
          ],
        ),
      );
    });

    testWidgets('the picker on a phone with no on-device model', (
      tester,
    ) async {
      await picker(
        tester,
        'picker_phone_dark',
        FakeKapyAi(
          deviceState: const DeviceModelState(
            status: DeviceModelStatus.unavailable,
          ),
          accountList: const [
            KapyAccountState(
              kind: KapyAccountKind.openRouter,
              status: KapyAccountStatus.connected,
              models: [FakeKapyAi.gemini],
              detail: '4f2a',
            ),
          ],
        )..set(model: FakeKapyAi.gemini),
      );
    });

    Future<void> held(
      WidgetTester tester,
      String name,
      KapyPending pending, {
      FakeKapyAi? ai,
      Brightness brightness = Brightness.dark,
    }) {
      final fake = ai ?? FakeKapyAi(pro: true);
      fake.set(
        current: _chat(
          'c1',
          'Trip',
          messages: [_question('What did I budget?')],
        ),
        pending: pending,
      );
      return shoot(
        tester,
        name,
        panelFor(fake, noteId: 'n1'),
        brightness: brightness,
      );
    }

    testWidgets('Cloud’s first-use notice', (tester) async {
      await held(tester, 'state_cloud_consent_dark', const KapyCloudConsent());
    });

    testWidgets('a signed-out Codex', (tester) async {
      await held(
        tester,
        'state_codex_signed_out_dark',
        const KapyAccountError(
          account: KapyAccountKind.codex,
          model: FakeKapyAi.gpt,
        ),
      );
    });

    testWidgets('the limit reached', (tester) async {
      await held(
        tester,
        'state_limit_dark',
        KapyLimitReached(
          resetsAt: DateTime(2026, 12),
          fallback: FakeKapyAi.appleIntelligence,
        ),
        ai: FakeKapyAi(
          pro: true,
          usage: CloudUsage(
            remaining: 0,
            limit: 500,
            resetsAt: DateTime(2026, 12),
          ),
        ),
      );
    });

    testWidgets('Codex’s first use, light', (tester) async {
      await held(
        tester,
        'state_codex_consent_light',
        const KapyAccountConsent(KapyAccountKind.codex),
        ai: FakeKapyAi(accountList: const [_codexConnected])
          ..set(model: FakeKapyAi.gpt),
        brightness: Brightness.light,
      );
    });

    testWidgets('the download in progress, light', (tester) async {
      await held(
        tester,
        'state_downloading_light',
        const KapyDownloading(received: 1100000000, total: 2600000000),
        ai: FakeKapyAi(
          deviceState: const DeviceModelState(
            status: DeviceModelStatus.downloading,
            model: FakeKapyAi.gemma,
            totalBytes: 2600000000,
            receivedBytes: 1100000000,
          ),
        ),
        brightness: Brightness.light,
      );
    });
  });
}
