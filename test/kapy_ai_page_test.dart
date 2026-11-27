import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_page.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_kapy_ai.dart';
import 'test_fonts.dart';

/// The phone's Kapy AI page (M04) on its own, the way the bar mounts it.

final _now = DateTime(2026, 11, 19, 9);

KapyChat _chat(
  String id,
  String title,
  DateTime at, {
  List<KapyMessage> messages = const [],
}) => KapyChat(
  id: id,
  title: title,
  createdAt: at,
  updatedAt: at,
  model: KapyModel.cloud,
  messages: messages,
);

KapyMessage _said(KapyRole role, String text) =>
    KapyMessage(id: '$role-$text', role: role, text: text, at: _now);

List<KapyChat> get _chats => [
  _chat(
    'a',
    'What is left on Call with Arjun',
    DateTime(2026, 11, 19, 8, 58),
    messages: [
      _said(KapyRole.user, 'What is left on Call with Arjun?'),
      _said(KapyRole.assistant, 'Send the deck and book the room.'),
    ],
  ),
  _chat('b', 'What did I plan for this week?', DateTime(2026, 11, 19, 7, 40)),
  _chat(
    'c',
    'Find my notes about Lisbon',
    DateTime(2026, 11, 18, 18, 20),
    messages: [
      _said(KapyRole.user, 'Find my notes about Lisbon'),
      _said(
        KapyRole.assistant,
        '\n\n- **Four days** in [May](kapy://note/9), from the _Lisbon trip_ note',
      ),
    ],
  ),
  _chat('d', 'Price of 40 seats a month', DateTime(2026, 11, 17, 10)),
  _chat('e', 'Summarise the offsite notes', DateTime(2026, 11, 14, 16)),
  _chat('f', 'Budget for the October trip', DateTime(2026, 10, 9, 12)),
];

FakeKapyAi _ai({bool pro = true, List<KapyChat>? chats}) =>
    FakeKapyAi(pro: pro, chatList: chats ?? _chats)
      ..set(model: KapyModel.cloud);

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
  double textScale = 1,
  Size size = const Size(393, 852),
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
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          extendBody: true,
          body: KapyAiPage(
            kapyAi: ai,
            onOpenChat: onOpenChat ?? () {},
            account: _account,
            now: () => _now,
          ),
          bottomNavigationBar: const SizedBox(height: 86),
        ),
      ),
    ),
  );
  await tester.pump();
}

List<String> _shown(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(find.byType(Text)))
    if (text.data != null) text.data!,
];

void main() {
  setUpAll(loadTestFonts);

  late bool wasAvailable;
  setUp(() {
    wasAvailable = kapyAiAvailable;
    kapyAiAvailable = true;
  });
  tearDown(() => kapyAiAvailable = wasAvailable);

  testWidgets('heads it as Notes is: its name and the account, then search', (
    tester,
  ) async {
    await _pump(tester, _ai());

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('phone-list-title'))).data,
      'Kapy AI',
    );
    expect(find.byKey(const ValueKey('account')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-search-box')), findsOneWidget);
    expect(find.text('Search chats'), findsOneWidget);
    expect(find.text('New chat'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is KapyIcon && widget.icon == KapyIcons.sparklesOutlined,
      ),
      findsNothing,
    );
    expect(find.text('Ask Kapy AI'), findsNothing);
  });

  testWidgets('lists past chats a day at a time, newest first, each with its '
      'time and how its last answer starts', (tester) async {
    await _pump(tester, _ai());

    expect(
      _shown(tester),
      containsAllInOrder([
        'Today',
        'Thu 19',
        'What is left on Call with Arjun',
        '8:58',
        'Send the deck and book the room.',
        'What did I plan for this week?',
        '7:40',
        'Yesterday',
        'Wed 18',
        'Find my notes about Lisbon',
        '18:20',
        'Four days in May, from the Lisbon trip note',
        'Tue 17 Nov',
        'Price of 40 seats a month',
        '10:00',
        'Sat 14 Nov',
        'Summarise the offsite notes',
        '16:00',
        'Fri 9 Oct',
        'Budget for the October trip',
        '12:00',
      ]),
    );
    expect(find.byKey(const ValueKey('phone-day-heading')), findsNWidgets(5));
    // A chat with no answer yet has no second line.
    final row = find.byKey(const ValueKey('kapy-ai-page-chat-b'));
    expect(
      find.descendant(of: row, matching: find.byType(Text)),
      findsNWidgets(2),
    );
    expect(find.textContaining('sync'), findsNothing);
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
    expect(find.byKey(const ValueKey('kapy-ai-page-example-0')), findsNothing);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.text('Price of 40 seats a month'), findsOneWidget);
  });

  group('with no chats yet', () {
    testWidgets('it says so, and offers three questions to start from', (
      tester,
    ) async {
      await _pump(tester, _ai(chats: const []));
      expect(
        _shown(tester),
        containsAllInOrder([
          'No chats yet',
          'Chats sync across your devices',
          'What did I plan for this week?',
          'Find my notes about Lisbon',
          'Summarise what I wrote yesterday',
        ]),
      );
    });

    testWidgets('it says they sync only where they do', (tester) async {
      await _pump(tester, _ai(chats: const [])..syncing = false);
      expect(find.text('No chats yet'), findsOneWidget);
      expect(find.textContaining('sync'), findsNothing);

      await _pump(tester, _ai(pro: false, chats: const []));
      expect(find.text('No chats yet'), findsOneWidget);
      expect(find.textContaining('sync'), findsNothing);
    });

    testWidgets(
      'a question tapped is asked in a new chat, never the last one',
      (tester) async {
        final ai = _ai(chats: const []);
        var opened = 0;
        await _pump(tester, ai, onOpenChat: () => opened++);

        await tester.tap(find.byKey(const ValueKey('kapy-ai-page-example-1')));
        expect(ai.calls, ['newChat', 'ask:Find my notes about Lisbon:']);
        expect(opened, 1);
      },
    );

    testWidgets('while Kapy AI is still answering, a tap asks nothing', (
      tester,
    ) async {
      final ai = _ai(chats: const [])..set(answering: true);
      var opened = 0;
      await _pump(tester, ai, onOpenChat: () => opened++);

      await tester.tap(find.byKey(const ValueKey('kapy-ai-page-example-0')));
      expect(ai.calls, isEmpty);
      expect(opened, 0);
    });
  });

  testWidgets('every target is at least 44 × 44 to a finger', (tester) async {
    await _pump(tester, _ai());
    final targets = [
      find.byKey(const ValueKey('sidebar-search-box')),
      find.byKey(const ValueKey('kapy-ai-page-chat-a')),
      find.byKey(const ValueKey('kapy-ai-page-chat-b')),
    ];
    for (final finder in targets) {
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(44), reason: '$finder');
      expect(size.height, greaterThanOrEqualTo(44), reason: '$finder');
    }
    await _pump(tester, _ai(chats: const []));
    for (var i = 0; i < 3; i++) {
      final size = tester.getSize(
        find.byKey(ValueKey('kapy-ai-page-example-$i')),
      );
      expect(size.height, greaterThanOrEqualTo(44), reason: 'example $i');
    }
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'on ${platform.name} a screen reader presses a chat and a starting '
      'question as a tap does (KAP-365)',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = platform;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        final semantics = tester.ensureSemantics();
        SemanticsNode node(String key) =>
            tester.getSemantics(find.byKey(ValueKey(key)));
        Future<void> press(String key) async {
          final id = node(key).id;
          tester.semantics.tap(find.semantics.byPredicate((n) => n.id == id));
          await tester.pump();
        }

        final ai = _ai();
        var opened = 0;
        await _pump(tester, ai, onOpenChat: () => opened++);
        expect(node('kapy-ai-page-chat-c'), isSemantics(hasTapAction: true));
        await press('kapy-ai-page-chat-c');
        expect(ai.calls, ['openChat:c']);
        expect(opened, 1);

        final empty = _ai(chats: const []);
        await _pump(tester, empty, onOpenChat: () => opened++);
        expect(
          node('kapy-ai-page-example-0'),
          isSemantics(
            label: 'What did I plan for this week?',
            isButton: true,
            hasTapAction: true,
          ),
        );
        await press('kapy-ai-page-example-0');
        expect(empty.calls, ['newChat', 'ask:What did I plan for this week?:']);
        expect(opened, 2);
        semantics.dispose();
      },
    );
  }

  testWidgets('a tap anywhere on the search well puts the cursor in it', (
    tester,
  ) async {
    await _pump(tester, _ai());
    final well = tester.getRect(
      find.byKey(const ValueKey('sidebar-search-box')),
    );
    await tester.tapAt(well.centerLeft + const Offset(6, 0));
    await tester.pump();
    final field = find.byKey(const ValueKey('kapy-ai-page-search'));
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
  });

  testWidgets('at twice the text size, chat rows keep space between them', (
    tester,
  ) async {
    await _pump(tester, _ai(), textScale: 2);
    final first = tester.getRect(find.text('Send the deck and book the room.'));
    final second = tester.getRect(find.text('What did I plan for this week?'));
    expect(second.top - first.bottom, greaterThanOrEqualTo(12));
  });

  for (final (name, size) in [
    ('iPhone', Size(393, 852)),
    ('small phone', Size(360, 640)),
  ]) {
    testWidgets('fits a $name at twice the text size', (tester) async {
      await _pump(tester, _ai(), textScale: 2, size: size);
      expect(tester.takeException(), isNull);
      await _pump(tester, _ai(chats: const []), textScale: 2, size: size);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('kapy-ai-page-example-2')),
      );
      expect(tester.takeException(), isNull);
    });
  }

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

    Future<void> showPicker(
      WidgetTester tester,
      TargetPlatform platform,
      DeviceModelState device,
    ) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Material(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: KapyAiPicker(
                kapyAi: FakeKapyAi(
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
                onPick: (_) {},
                onManageAccounts: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Android: "On this device" is said once, by its row', (
      tester,
    ) async {
      await showPicker(
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
      await showPicker(
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

  group('goldens', () {
    for (final (name, scale, chats) in [
      ('1x', 1.0, _chats),
      ('2x', 2.0, _chats),
      ('empty', 1.0, const <KapyChat>[]),
    ]) {
      testWidgets('the page, dark, $name', (tester) async {
        await _pump(tester, _ai(chats: chats), textScale: scale);
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
