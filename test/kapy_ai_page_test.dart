import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_page.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_kapy_ai.dart';
import 'test_fonts.dart';

/// The phone's Kapy AI page (M04) on its own, the way the bar mounts it.

final _now = DateTime(2026, 11, 19, 9);

KapyChat _chat(String id, String title, DateTime at) => KapyChat(
  id: id,
  title: title,
  createdAt: at,
  updatedAt: at,
  model: KapyModel.cloud,
  messages: const [],
);

List<KapyChat> get _chats => [
  _chat('a', 'What is left on Call with Arjun', DateTime(2026, 11, 19, 8, 58)),
  _chat('b', 'What did I plan for this week?', DateTime(2026, 11, 19, 7, 40)),
  _chat('c', 'Find my notes about Lisbon', DateTime(2026, 11, 18, 18, 20)),
  _chat('d', 'Price of 40 seats a month', DateTime(2026, 11, 17, 10)),
  _chat('e', 'Summarise the offsite notes', DateTime(2026, 11, 14, 16)),
  _chat('f', 'Budget for the October trip', DateTime(2026, 10, 9, 12)),
];

FakeKapyAi _ai({bool pro = true}) =>
    FakeKapyAi(pro: pro, chatList: _chats)..set(model: KapyModel.cloud);

const _account = SizedBox.square(
  key: ValueKey('account'),
  dimension: 32,
  child: DecoratedBox(
    decoration: BoxDecoration(color: Color(0xFF2A2824), shape: BoxShape.circle),
    child: Center(
      child: Text(
        'S',
        style: TextStyle(
          fontFamily: AppFonts.ui,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Color(0xFFE2DCCF),
        ),
      ),
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  FakeKapyAi ai, {
  VoidCallback? onOpenChat,
  VoidCallback? onManage,
  double textScale = 1,
  Size size = const Size(393, 852),
  double keyboard = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: const EdgeInsets.only(top: 62, bottom: 34),
          viewInsets: EdgeInsets.only(bottom: keyboard),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: KapyAiPage(
            kapyAi: ai,
            onOpenChat: onOpenChat ?? () {},
            onManageAccounts: onManage ?? () {},
            account: _account,
            barClearance: 86,
            now: () => _now,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(loadTestFonts);

  late bool wasAvailable;
  setUp(() {
    wasAvailable = kapyAiAvailable;
    kapyAiAvailable = true;
  });
  tearDown(() => kapyAiAvailable = wasAvailable);

  testWidgets('groups past chats newest first, each with its time', (
    tester,
  ) async {
    await _pump(tester, _ai());

    final shown = [
      for (final text in tester.widgetList<Text>(find.byType(Text)))
        if (text.data != null) text.data!,
    ];
    expect(
      shown,
      containsAllInOrder([
        'Today',
        'What is left on Call with Arjun',
        '8:58',
        'What did I plan for this week?',
        '7:40',
        'Yesterday',
        'Find my notes about Lisbon',
        '18:20',
        'Previous 7 days',
        'Price of 40 seats a month',
        'Tue 17',
        'Summarise the offsite notes',
        'Sat 14',
        'October',
        'Budget for the October trip',
        '9 Oct',
        'Chats sync across your devices',
      ]),
    );
    expect(find.text('Kapy AI Cloud'), findsOneWidget);
    expect(find.byKey(const ValueKey('account')), findsOneWidget);

    List<FontVariation>? wghtOf(String label) =>
        tester.widget<Text>(find.text(label)).style?.fontVariations;
    for (final label in ['Yesterday', 'Previous 7 days', 'October']) {
      expect(wghtOf(label), [const FontVariation('wght', 520)], reason: label);
    }
    final dispatcher = tester.binding.platformDispatcher;
    dispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures.allOn;
    addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
    await _pump(tester, _ai());
    for (final label in ['Yesterday', 'Previous 7 days', 'October']) {
      expect(wghtOf(label), [const FontVariation('wght', 700)], reason: label);
    }
  });

  testWidgets('says where chats are kept when they do not sync', (
    tester,
  ) async {
    final ai = _ai()..syncing = false;
    await _pump(tester, ai);
    expect(find.textContaining('Sign in to sync them'), findsOneWidget);

    await _pump(tester, _ai(pro: false));
    expect(find.textContaining('Pro syncs them'), findsOneWidget);
  });

  testWidgets('a chat opens through Kapy AI, then the conversation shows', (
    tester,
  ) async {
    final ai = _ai();
    var opened = 0;
    await _pump(tester, ai, onOpenChat: () => opened++);

    await tester.tap(find.text('Find my notes about Lisbon'));
    expect(ai.calls, ['openChat:c']);
    expect(ai.current?.id, 'c');
    expect(opened, 1);
  });

  testWidgets('New chat starts one and shows it', (tester) async {
    final ai = _ai()..openChat('a');
    ai.calls.clear();
    var opened = 0;
    await _pump(tester, ai, onOpenChat: () => opened++);

    await tester.tap(find.byKey(const ValueKey('kapy-ai-page-new-chat')));
    expect(ai.calls, ['newChat']);
    expect(ai.current, isNull);
    expect(opened, 1);
  });

  testWidgets('a question asked here starts a new chat, never the last one', (
    tester,
  ) async {
    final ai = _ai()..openChat('a');
    ai.calls.clear();
    var opened = 0;
    await _pump(tester, ai, onOpenChat: () => opened++);

    await tester.enterText(
      find.byKey(const ValueKey('kapy-ai-page-field')),
      '  What is due on Friday?  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('kapy-ai-page-send')));
    await tester.pump();

    expect(ai.calls, ['newChat', 'ask:What is due on Friday?:']);
    expect(opened, 1);
    expect(find.text('What is due on Friday?'), findsNothing);
  });

  testWidgets('an empty question asks nothing', (tester) async {
    final ai = _ai();
    var opened = 0;
    await _pump(tester, ai, onOpenChat: () => opened++);

    await tester.enterText(
      find.byKey(const ValueKey('kapy-ai-page-field')),
      '   ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('kapy-ai-page-send')));
    await tester.pump();
    expect(ai.calls, isEmpty);
    expect(opened, 0);
  });

  testWidgets('while Kapy AI is still answering, the question waits', (
    tester,
  ) async {
    final ai = _ai()..set(answering: true);
    var opened = 0;
    await _pump(tester, ai, onOpenChat: () => opened++);

    await tester.enterText(
      find.byKey(const ValueKey('kapy-ai-page-field')),
      'Another one',
    );
    await tester.pump();
    expect(find.text('Still answering'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kapy-ai-page-send')));
    await tester.pump();
    expect(ai.calls, isEmpty);
    expect(opened, 0);
    expect(find.text('Another one'), findsOneWidget);
  });

  testWidgets('a model picked here goes to the new chat, not the open one', (
    tester,
  ) async {
    final ai = _ai()
      ..set(
        accounts: const [
          KapyAccountState(
            kind: KapyAccountKind.codex,
            status: KapyAccountStatus.connected,
            models: [FakeKapyAi.gpt],
          ),
        ],
      )
      ..openChat('a');
    ai.calls.clear();
    var managed = 0;
    await _pump(tester, ai, onManage: () => managed++);

    await tester.tap(find.byKey(const ValueKey('kapy-ai-model-button')));
    await tester.pumpAndSettle();
    expect(ai.calls, ['newChat']);
    await tester.tap(find.byKey(const ValueKey('kapy-ai-model-device-apple')));
    await tester.pumpAndSettle();
    expect(ai.calls, ['newChat', 'pickModel:apple']);
    expect(
      find.byKey(const ValueKey('kapy-ai-model-device-apple')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('kapy-ai-model-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage accounts…'));
    await tester.pumpAndSettle();
    expect(managed, 1);
  });

  testWidgets('Search finds an old chat, and says when none match', (
    tester,
  ) async {
    await _pump(tester, _ai());

    await tester.enterText(
      find.byKey(const ValueKey('kapy-ai-page-search')),
      'lisbon',
    );
    await tester.pump();
    expect(find.text('Find my notes about Lisbon'), findsOneWidget);
    expect(find.text('What did I plan for this week?'), findsNothing);
    expect(find.text('Today'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('kapy-ai-page-search')),
      'zanzibar',
    );
    await tester.pump();
    expect(find.text('No chats match'), findsOneWidget);
  });

  group('the picker on a phone', () {
    List<String> pickerText(WidgetTester tester) => [
      for (final text in tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('kapy-ai-picker')),
          matching: find.byType(Text),
        ),
      ))
        text.data!,
    ];

    Future<void> openPicker(
      WidgetTester tester,
      TargetPlatform platform,
      DeviceModelState device,
    ) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await _pump(
        tester,
        FakeKapyAi(
          chatList: _chats,
          deviceState: device,
          accountList: const [
            KapyAccountState(
              kind: KapyAccountKind.openRouter,
              status: KapyAccountStatus.connected,
              models: [FakeKapyAi.gemini],
              detail: '4f2a',
            ),
          ],
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('kapy-ai-model-button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Android: "On this device" is said once, by its row', (
      tester,
    ) async {
      await openPicker(
        tester,
        TargetPlatform.android,
        const DeviceModelState(
          status: DeviceModelStatus.ready,
          model: FakeKapyAi.gemma,
          totalBytes: 2600000000,
          receivedBytes: 2600000000,
        ),
      );

      expect(pickerText(tester), [
        'On this device',
        'Answers stay on this phone',
        'KAPY AI',
        'Kapy AI Cloud',
        'Part of Pro',
        'YOUR ACCOUNTS',
        'Fast',
        'Quick answers and short notes',
        'Manage accounts…',
      ]);
    });

    testWidgets('iOS: Apple Intelligence keeps its heading', (tester) async {
      await openPicker(
        tester,
        TargetPlatform.iOS,
        const DeviceModelState(
          status: DeviceModelStatus.builtIn,
          model: FakeKapyAi.appleIntelligence,
        ),
      );

      expect(pickerText(tester), [
        'ON THIS DEVICE',
        'Apple Intelligence',
        'Answers stay on this iPhone',
        'KAPY AI',
        'Kapy AI Cloud',
        'Part of Pro',
        'YOUR ACCOUNTS',
        'Fast',
        'Quick answers and short notes',
        'Manage accounts…',
      ]);
    });
  });

  testWidgets('every button is at least 44 × 44 to a finger', (tester) async {
    await _pump(tester, _ai());
    final handle = tester.ensureSemantics();
    for (final finder in [
      find.byKey(const ValueKey('kapy-ai-page-new-chat')),
      find.byKey(const ValueKey('kapy-ai-page-send')),
      find.bySemanticsLabel('Answers with Kapy AI Cloud'),
      find.byKey(const ValueKey('kapy-ai-page-chat-a')),
    ]) {
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(44), reason: '$finder');
      expect(size.height, greaterThanOrEqualTo(44), reason: '$finder');
    }
    handle.dispose();
  });

  testWidgets('with the keyboard up, Ask Kapy AI sits just above it', (
    tester,
  ) async {
    await _pump(tester, _ai());
    final field = find.byKey(const ValueKey('kapy-ai-page-field'));
    Rect box() => tester.getRect(
      find.ancestor(of: field, matching: find.byType(Container)).first,
    );
    expect(852 - box().bottom, 86 + 12);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await _pump(tester, _ai(), keyboard: 300);
    expect(852 - 300 - box().bottom, 12);
  });

  testWidgets('a tap anywhere on the search pill puts the cursor in it', (
    tester,
  ) async {
    await _pump(tester, _ai());
    final field = find.byKey(const ValueKey('kapy-ai-page-search'));
    final pill = tester.getRect(
      find.ancestor(of: field, matching: find.byType(Container)).first,
    );
    await tester.tapAt(pill.centerLeft + const Offset(6, 0));
    await tester.pump();
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
  });

  testWidgets('at twice the text size, chat rows keep space between them', (
    tester,
  ) async {
    await _pump(tester, _ai(), textScale: 2);
    final first = tester.getRect(find.text('What is left on Call with Arjun'));
    final second = tester.getRect(find.text('What did I plan for this week?'));
    expect(second.top - first.bottom, greaterThanOrEqualTo(12));
  });

  testWidgets('with no chats yet, it says so', (tester) async {
    await _pump(tester, FakeKapyAi(pro: true)..set(model: KapyModel.cloud));
    expect(find.text('No chats yet'), findsOneWidget);
  });

  for (final (name, size) in [
    ('iPhone', Size(393, 852)),
    ('small phone', Size(360, 640)),
  ]) {
    testWidgets('fits a $name at twice the text size', (tester) async {
      final ai = _ai();
      var opened = 0;
      await _pump(
        tester,
        ai,
        textScale: 2,
        size: size,
        onOpenChat: () => opened++,
      );
      expect(tester.takeException(), isNull);
      // The label gives way before the row overflows; the button stays.
      expect(find.text('New chat'), findsNothing);
      expect(find.bySemanticsLabel('New chat'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('kapy-ai-page-new-chat')));
      expect(opened, 1);
    });
  }

  group('goldens', () {
    for (final (name, scale) in [('1x', 1.0), ('2x', 2.0)]) {
      testWidgets('the page, dark, $name text', (tester) async {
        await _pump(tester, _ai(), textScale: scale);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/kapy_ai_page_dark_$name.png'),
        );
      });
    }
  });
}
