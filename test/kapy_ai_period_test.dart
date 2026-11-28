import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/period_scope.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_kapy_ai.dart';
import 'recaps/recap_fixtures.dart';
import 'test_fonts.dart';

/// Kapy AI asked about a period: the composer's chip, the empty chat, the
/// card of what an answer read, and what each answer cost.

final _now = DateTime(2026, 11, 19, 12);
final _week = periodOf(DateTime(2026, 11, 19), RecapKind.week);
final _month = periodOf(DateTime(2026, 11, 19), RecapKind.month);
final _usage412 = CloudUsage(
  remaining: 412,
  limit: 500,
  resetsAt: DateTime(2026, 12),
);

late RecapWorld _world;

KapyPeriodRead _read(RecapPeriod period) =>
    KapyPeriodRead(_world.material(period), _world.digest(period));

KapyMessage _question(String id, String text) =>
    KapyMessage(id: id, role: KapyRole.user, text: text, at: _now);

KapyMessage _answer(
  String id, {
  KapyModel model = KapyModel.cloud,
  int read = 0,
  int matching = 0,
}) => KapyMessage(
  id: id,
  role: KapyRole.assistant,
  text: 'An answer.',
  at: _now,
  model: model,
  read: [
    for (var i = 0; i < read; i++)
      KapyNoteRef(noteId: 'n$i', title: '', edited: _now),
  ],
  matching: matching,
);

KapyChat _chat(List<KapyMessage> messages, {RecapPeriod? scope}) => KapyChat(
  id: 'chat',
  title: 'Chat',
  createdAt: _now,
  updatedAt: _now,
  model: KapyModel.cloud,
  messages: messages,
  scope: scope,
);

Future<(FakeKapyAi, KapyAiPanelController)> _open(
  WidgetTester tester, {
  RecapPeriod? period,
  KapyChat? chat,
  KapyModel model = KapyModel.cloud,
  bool counted = true,
}) async {
  final ai = FakeKapyAi(pro: true, usage: counted ? _usage412 : null)
    ..periods = _read
    ..set(model: model, current: chat);
  final controller = KapyAiPanelController()..open(period: period);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 700,
            child: KapyAiPanel(
              kapyAi: ai,
              controller: controller,
              noteTitle: (id) => 'Note $id',
              onOpenNote: (_) {},
              onManageAccounts: () {},
              onClose: controller.close,
              now: () => _now,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (ai, controller);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    _world = RecapWorld();
    await _world.tags.load();
    await _world.folders.load();
    for (var i = 0; i < 20; i++) {
      _world.note(
        'n$i',
        '2026-11-${(i % 10 + 1).toString().padLeft(2, '0')}T09:00:00Z',
        body: 'Note $i',
      );
    }
    _world.note('call', '2026-11-17T09:00:00Z', body: 'Call with Arjun');
    _world.note('deck', '2026-11-18T09:00:00Z', body: 'Deck\n☐ Send it');
    _world.tags.setTags('call', [_world.tags.create('Acme')!.id]);
    await _world.load();
  });

  group('the chip', () {
    testWidgets('names the period, and asks about it', (tester) async {
      final (ai, _) = await _open(tester, period: _week);
      expect(find.byKey(const ValueKey('kapy-ai-period-chip')), findsOneWidget);
      expect(find.text('16–22 Nov'), findsOneWidget);
      expect(find.byKey(const ValueKey('kapy-ai-chip')), findsNothing);
      expect(find.widgetWithText(TextField, 'Ask about this week…'), findsOne);

      await tester.enterText(find.byType(TextField), 'Any news?');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('kapy-ai-send')));
      expect(ai.calls.last, 'askPeriod:Any news?:16–22 Nov');
    });

    testWidgets('taken off, the next question searches all notes', (
      tester,
    ) async {
      final (ai, controller) = await _open(tester, period: _week);
      await tester.tap(
        find.byKey(const ValueKey('kapy-ai-period-chip-remove')),
      );
      await tester.pump();
      expect(controller.period, isNull);
      expect(find.byKey(const ValueKey('kapy-ai-period-chip')), findsNothing);
      expect(find.byKey(const ValueKey('kapy-ai-period-empty')), findsNothing);
      expect(find.text('Ask about anything in your notes'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Any news?');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('kapy-ai-send')));
      expect(ai.calls.last, 'ask:Any news?:');
    });

    testWidgets('comes back with the chat about the period', (tester) async {
      final chat = _chat([
        _question('q', 'Any news?'),
        _answer('a'),
      ], scope: _week);
      final (ai, controller) = await _open(tester);
      expect(controller.period, isNull);
      ai.chatList = [chat];
      ai.openChat('chat');
      await tester.pump();
      expect(controller.period, _week);
      expect(find.text('16–22 Nov'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Ask a follow-up…'), findsOne);
    });
  });

  group('an empty chat about a period', () {
    testWidgets('says what it reads and offers three questions', (
      tester,
    ) async {
      final (ai, _) = await _open(tester, period: _week);
      expect(find.text('Ask about this week'), findsOneWidget);
      expect(
        find.text(
          'Answers come only from your 2 notes and 1 task from 16–22 Nov. '
          'Hidden notes are never used.',
        ),
        findsOneWidget,
      );
      for (final question in [
        'What did I get done this week?',
        'What’s still open from this week?',
        'What did I decide about Acme?',
      ]) {
        expect(find.text(question), findsOneWidget);
      }
      await tester.tap(find.text('What did I decide about Acme?'));
      expect(
        ai.calls.last,
        'askPeriod:What did I decide about Acme?:16–22 Nov',
      );
    });

    testWidgets('a long period says a narrower question does better', (
      tester,
    ) async {
      await _open(tester, period: _month);
      expect(find.text('Ask about this month'), findsOneWidget);
      expect(
        find.text(
          'November has 22 notes. Each answer reads the 12 that fit the '
          'question best, so a narrower question gets a fuller answer.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a period it cannot read promises no more than that', (
      tester,
    ) async {
      final (ai, _) = await _open(tester, period: _week);
      ai.periods = null;
      ai.set();
      await tester.pump();
      expect(
        find.text(
          'Answers come only from 16–22 Nov. Hidden notes are never used.',
        ),
        findsOneWidget,
      );
      expect(find.text('What did I get done this week?'), findsOneWidget);
    });
  });

  group('an answer about a period', () {
    testWidgets('says how many of the period it read', (tester) async {
      await _open(
        tester,
        chat: _chat([
          _question('q', 'Any news?'),
          _answer('a', read: 1, matching: 2),
        ], scope: _week),
      );
      expect(find.text('Read 1 of the 2 notes from 16–22 Nov'), findsOneWidget);
    });

    testWidgets('says when its words narrowed a long period', (tester) async {
      await _open(
        tester,
        chat: _chat([
          _question('q1', 'Pricing?'),
          _answer('a1', read: 12, matching: 15),
          _question('q2', 'Anything?'),
          _answer('a2', read: 12, matching: 22),
          _question('q3', 'Acme?'),
          _answer('a3', read: 1, matching: 1),
        ], scope: _month),
      );
      expect(
        find.text('Read 12 of the 15 matching notes from November'),
        findsOneWidget,
      );
      expect(find.text('Read 12 of the 22 notes from November'), findsOne);
      expect(find.text('Read the one matching note from November'), findsOne);
    });

    testWidgets('a chat about all notes reads as before', (tester) async {
      await _open(
        tester,
        chat: _chat([
          _question('q', 'Any?'),
          _answer('a', read: 2, matching: 7),
        ]),
      );
      expect(find.text('Read 2 of the 7 matching notes'), findsOneWidget);
    });
  });

  group('what an answer costs', () {
    testWidgets('Kapy AI Cloud: 1 credit, and what is left beside the latest', (
      tester,
    ) async {
      await _open(
        tester,
        chat: _chat([
          _question('q1', 'One?'),
          _answer('a1'),
          _question('q2', 'Two?'),
          _answer('a2'),
        ], scope: _week),
      );
      final lines = tester
          .widgetList<Text>(find.byKey(const ValueKey('kapy-ai-source')))
          .map((text) => text.data)
          .toList();
      expect(lines, [
        'Kapy AI Cloud · 1 credit',
        'Kapy AI Cloud · 1 credit · 412 of 500 left',
      ]);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('kapy-ai-credits'))).data,
        '1 credit',
        reason: 'what is left is said once, under the latest answer',
      );
    });

    testWidgets('each line starts with the composer’s cloud, never the recap '
        'icon', (tester) async {
      await _open(
        tester,
        chat: _chat([_question('q', 'One?'), _answer('a')], scope: _week),
      );
      final row = find
          .ancestor(
            of: find.byKey(const ValueKey('kapy-ai-source')),
            matching: find.byType(Row),
          )
          .first;
      final icons = tester
          .widgetList<KapyIcon>(
            find.descendant(of: row, matching: find.byType(KapyIcon)),
          )
          .map((icon) => icon.icon)
          .toList();
      expect(icons.first, KapyIcons.cloudRounded);
      expect(icons, isNot(contains(KapyIcons.recapOutlined)));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('kapy-ai-copy'))).dx,
        greaterThan(
          tester.getTopRight(find.byKey(const ValueKey('kapy-ai-source'))).dx,
        ),
        reason: 'Copy sits after the line, so the cloud leads it',
      );
      final composer = tester
          .widgetList<KapyIcon>(
            find.descendant(
              of: find.byKey(const ValueKey('kapy-ai-model-button')),
              matching: find.byType(KapyIcon),
            ),
          )
          .first;
      expect(composer.icon, icons.first);
    });

    testWidgets('a new chat about another period still says what is left', (
      tester,
    ) async {
      await _open(
        tester,
        period: _month,
        chat: _chat([_question('q', 'One?'), _answer('a')], scope: _week),
      );
      expect(find.byKey(const ValueKey('kapy-ai-period-empty')), findsOne);
      expect(find.text('1 credit · 412 left'), findsOneWidget);
    });

    testWidgets('this device and own accounts cost nothing', (tester) async {
      await _open(
        tester,
        model: FakeKapyAi.appleIntelligence,
        chat: _chat([
          _question('q1', 'One?'),
          _answer('a1', model: FakeKapyAi.appleIntelligence),
          _question('q2', 'Two?'),
          _answer('a2', model: FakeKapyAi.gpt),
        ]),
      );
      final lines = tester
          .widgetList<Text>(find.byKey(const ValueKey('kapy-ai-source')))
          .map((text) => text.data)
          .toList();
      expect(lines, ['On this device', startsWith('Codex on this ')]);
      expect(find.byKey(const ValueKey('kapy-ai-credits')), findsNothing);
      expect(find.textContaining('credit'), findsNothing);
    });

    testWidgets('the composer counts only while there are credits', (
      tester,
    ) async {
      final (ai, _) = await _open(tester);
      expect(find.text('1 credit · 412 left'), findsOneWidget);
      ai.set(
        cloudUsage: CloudUsage(
          remaining: 0,
          limit: 500,
          resetsAt: DateTime(2026, 12),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('kapy-ai-credits')), findsNothing);
      expect(find.text('Kapy AI Cloud · 0 left'), findsOneWidget);
    });

    testWidgets('no count before the server has answered', (tester) async {
      await _open(tester, counted: false);
      expect(find.byKey(const ValueKey('kapy-ai-credits')), findsNothing);
    });
  });
}
