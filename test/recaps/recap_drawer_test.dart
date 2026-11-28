import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/ui/recaps/recap_drawer.dart';
import 'package:kapy_notes/ui/recaps/recap_story_view.dart';
import 'package:material_ui/material_ui.dart';

import 'recap_fixtures.dart';
import 'recap_maker_fixtures.dart';

/// What the drawer handed the app.
class _Calls {
  final List<RecapPeriod> asked = [];
  final List<String> went = [];

  late final hooks = RecapDrawerHooks(
    onAsk: asked.add,
    openNote: (id) => went.add('note:$id'),
    play: (_) => went.add('play'),
    saveAsNote: (_) => went.add('save'),
    shareImage: (_, _) async => went.add('share'),
    onManageAccounts: () => went.add('accounts'),
    onSignIn: () => went.add('sign in'),
    onUpgrade: () => went.add('upgrade'),
  );
}

void main() {
  late MakerWorld w;

  setUp(() => w = MakerWorld());
  tearDown(() {
    w.maker.dispose();
    AppPlatform.debugTargetPlatformOverride = null;
  });

  Future<void> start(
    WidgetTester tester, {
    AnswerEngine? engine,
    int? left = 412,
  }) => tester.runAsync(
    () => w.start(engine: engine ?? ScriptedEngine([dayAnswer]), left: left),
  );

  /// Opens the drawer on [period] from a page, on a phone unless [desktop].
  Future<_Calls> open(
    WidgetTester tester,
    RecapPeriod period, {
    bool desktop = false,
  }) async {
    AppPlatform.debugTargetPlatformOverride = desktop
        ? TargetPlatform.macOS
        : TargetPlatform.iOS;
    tester.view
      ..physicalSize = desktop ? const Size(1440, 900) : const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = _Calls();
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Builder(
          builder: (context) => Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              onTap: () => showRecapDrawer(
                context,
                period,
                maker: w.maker,
                hooks: calls.hooks,
                anchor: const Rect.fromLTWH(300, 200, 24, 24),
              ),
              child: const Text('Recap icon'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Recap icon'));
    await tester.pumpAndSettle();
    return calls;
  }

  Finder text(String it) => find.text(it);
  Finder key(String it) => find.byKey(ValueKey(it));
  Finder sentence(String part) => find.textContaining(part);

  testWidgets('quotes the cost and what goes in before anything is spent', (
    tester,
  ) async {
    final ai = ScriptedEngine([dayAnswer]);
    await start(tester, engine: ai);
    await open(tester, w.day);

    expect(text('Mon 16 recap'), findsOneWidget);
    expect(text('Yesterday · Monday, 16 November'), findsOneWidget);
    for (final label in ['Mon 16', '16–22 Nov', 'November', '2026']) {
      expect(text(label), findsOneWidget);
    }
    expect(text('Notes'), findsOneWidget);
    expect(text('3'), findsOneWidget);
    expect(text('Hidden notes are never used.'), findsOneWidget);
    expect(text('Uses 1 Kapy AI credit'), findsOneWidget);
    expect(text('412 of 500 left'), findsOneWidget);
    expect(
      sentence(
        'sends the notes, tasks and voice notes from this day through '
        'Kapy cloud',
      ),
      findsOneWidget,
    );
    expect(text('Ask Kapy AI about Mon 16'), findsOneWidget);
    expect(sentence('each answer uses 1 credit'), findsOneWidget);
    expect(ai.asked, isEmpty);

    await tester.tap(text('Create recap'));
    await tester.pumpAndSettle();
    expect(ai.paid, 1);
    expect(text('Ready to watch'), findsOneWidget);
  });

  testWidgets('the period switch quotes each period', (tester) async {
    await start(tester);
    await open(tester, w.day);
    await tester.tap(text('16–22 Nov'));
    await tester.pumpAndSettle();
    expect(text('16–22 Nov recap'), findsOneWidget);
    expect(text('Uses 2 Kapy AI credits'), findsOneWidget);
  });

  testWidgets('making it shows its parts, keeps going closed, and stops', (
    tester,
  ) async {
    final ai = GatedEngine();
    await start(tester, engine: ai);
    await open(tester, w.week);
    await tester.tap(text('Create recap'));
    await tester.pump();

    expect(text('Making your recap'), findsOneWidget);
    expect(text('Part 1 of 2'), findsOneWidget);
    expect(sentence('Reading 5 notes'), findsOneWidget);
    ai.reply('A digest.');
    await tester.pump();
    expect(text('Part 2 of 2'), findsOneWidget);

    await tester.tap(key('recap-drawer-close'));
    await tester.pumpAndSettle();
    expect(key('recap-drawer'), findsNothing);
    expect(w.maker.progressOf(w.week), (made: 1, parts: 2));

    await tester.tap(text('Recap icon'));
    await tester.pumpAndSettle();
    await tester.tap(text('Stop'));
    await tester.pump();
    expect(text('Stopping…'), findsOneWidget);
    ai.reply('TITLE: Your week');
    await tester.pumpAndSettle();
    expect(w.maker.hasRecap(w.week), isTrue);
  });

  testWidgets('Stop before the last part goes back to Create, for less', (
    tester,
  ) async {
    final ai = GatedEngine();
    await start(tester, engine: ai);
    await open(tester, w.week);
    await tester.tap(text('Create recap'));
    await tester.pump();
    await tester.tap(text('Stop'));
    ai.reply('A digest.');
    await tester.pumpAndSettle();
    expect(text('Uses 1 Kapy AI credit'), findsOneWidget);
    expect(text('Create recap'), findsOneWidget);
  });

  testWidgets('made: Watch is free, and again quotes its cost', (tester) async {
    await start(tester);
    await tester.runAsync(() => w.make(w.day));
    w.world.store.updateBody('a', 'Alpha plan\nShipped');
    final calls = await open(tester, w.day);

    expect(text('Ready to watch'), findsOneWidget);
    expect(sentence('It opens free, as often as you like.'), findsOneWidget);
    expect(text('Make it again · 1 credit'), findsOneWidget);
    expect(text('1 note changed since then'), findsOneWidget);
    expect(text('Ask Kapy AI about Mon 16'), findsOneWidget);

    await tester.tap(text('Watch recap'));
    await tester.pumpAndSettle();
    expect(key('recap-drawer'), findsNothing);
    expect(find.byType(RecapStoryView), findsOneWidget);
    expect(calls.asked, isEmpty);
  });

  testWidgets('too little: a small drawer where Ask is the only action', (
    tester,
  ) async {
    await start(tester);
    final friday = dayOf(DateTime(2026, 11, 20));
    final calls = await open(tester, friday);

    expect(text('Fri 20'), findsNWidgets(2));
    expect(text('Too little for a recap'), findsOneWidget);
    expect(sentence('Fri 20 has 2 notes'), findsOneWidget);
    expect(text('Create recap'), findsNothing);
    expect(text('Each answer uses 1 credit · 412 of 500 left'), findsOneWidget);

    await tester.tap(text('Ask Kapy AI about Fri 20'));
    await tester.pumpAndSettle();
    expect(calls.asked, [friday]);
    expect(key('recap-drawer'), findsNothing);
  });

  testWidgets('not enough credits offers what Kapy AI’s card does', (
    tester,
  ) async {
    await start(tester, left: 0);
    w.ai.trial = true;
    final calls = await open(tester, w.day);

    expect(text('Not enough credits for this one'), findsOneWidget);
    expect(
      sentence(
        'A day recap uses 1 credit, and you have 0 credits left until 1 Dec.',
      ),
      findsOneWidget,
    );
    expect(text('Sign in'), findsNothing);
    expect(text('Create recap'), findsNothing);
    await tester.tap(text('Upgrade'));
    await tester.pumpAndSettle();
    expect(calls.went, ['upgrade']);
  });

  testWidgets('one credit short says credit in the singular', (tester) async {
    await start(tester, left: 1);
    await open(tester, w.week);

    expect(text('Not enough credits for this one'), findsOneWidget);
    expect(
      sentence(
        'A week recap uses 2 credits, and you have 1 credit left until 1 Dec.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('signed out on Free: Sign in, Upgrade and own account', (
    tester,
  ) async {
    await start(tester);
    w.ai.held = const KapyCloudLocked(signIn: true, upgrade: true);
    final calls = await open(tester, w.day);

    expect(text('Kapy AI Cloud is part of Pro'), findsOneWidget);
    expect(text('Sign in'), findsOneWidget);
    expect(text('Upgrade'), findsOneWidget);
    await tester.tap(text('Use your own account'));
    await tester.pumpAndSettle();
    expect(calls.went, ['accounts']);
  });

  testWidgets('offline: nothing was used, and Try again', (tester) async {
    final ai = ScriptedEngine([const AnswerOffline(), dayAnswer]);
    await start(tester, engine: ai);
    await open(tester, w.day);
    await tester.tap(text('Create recap'));
    await tester.pumpAndSettle();

    expect(text('You’re offline'), findsOneWidget);
    expect(sentence('Nothing was used.'), findsOneWidget);
    await tester.tap(text('Try again'));
    await tester.pumpAndSettle();
    expect(text('Ready to watch'), findsOneWidget);
    expect(ai.paid, 1);
  });

  testWidgets('an error keeps its parts, and Try again quotes what is left', (
    tester,
  ) async {
    final ai = GatedEngine();
    await start(tester, engine: ai);
    await open(tester, w.week);
    await tester.tap(text('Create recap'));
    await tester.pump();
    ai.reply('A digest.');
    await tester.pump();
    ai.fail(const AnswerFailed('Busy.'));
    await tester.pumpAndSettle();

    expect(text('Couldn’t finish the recap'), findsOneWidget);
    expect(sentence('Part 2 of 2 couldn’t be made.'), findsOneWidget);
    expect(sentence('Try again only makes what’s left'), findsOneWidget);
    w.ai.engine = ScriptedEngine(['TITLE: Your week']);
    await tester.tap(text('Try again · 1 credit'));
    await tester.pumpAndSettle();
    expect(text('Ready to watch'), findsOneWidget);
    expect(ai.paid, 1);
  });

  testWidgets('their own account: no credits, and its own consent line', (
    tester,
  ) async {
    await start(tester, left: null);
    w.ai.defaultModel = const KapyModel(
      kind: KapyModelKind.claudeCode,
      id: 's',
      label: 'Claude Sonnet',
    );
    await open(tester, w.day);
    expect(text('Uses your own account'), findsOneWidget);
    expect(
      sentence('through Claude Code. Hidden notes never leave.'),
      findsOneWidget,
    );
    expect(sentence('Kapy cloud'), findsNothing);
  });

  testWidgets('their own account signed out says so', (tester) async {
    await start(tester);
    w.ai.held = const KapyAccountError(
      account: KapyAccountKind.codex,
      model: KapyModel(kind: KapyModelKind.codex, id: 'g', label: 'G'),
    );
    await open(tester, w.day);
    expect(text('Codex is signed out'), findsOneWidget);
    expect(text('Open Settings'), findsOneWidget);
  });

  testWidgets('one recap at a time: another period waits', (tester) async {
    final ai = GatedEngine();
    await start(tester, engine: ai);
    await open(tester, w.day);
    await tester.tap(text('Create recap'));
    await tester.pump();
    await tester.tap(text('16–22 Nov'));
    await tester.pump();
    expect(
      text('One recap is made at a time. The Mon 16 recap is being made now.'),
      findsOneWidget,
    );
    VoidCallback? create() => tester
        .widget<TextButton>(
          find.descendant(
            of: key('recap-create'),
            matching: find.byType(TextButton),
          ),
        )
        .onPressed;
    expect(create(), isNull);
    ai.reply(dayAnswer);
    await tester.pumpAndSettle();
    expect(create(), isNotNull);
  });

  testWidgets('on a desktop it is a 372 px popover beside the icon', (
    tester,
  ) async {
    await start(tester);
    await open(tester, w.week, desktop: true);
    final box = tester.getRect(key('recap-drawer'));
    expect(box.width, recapPopoverWidth);
    expect(box.left, 332);
    expect(text('Ask Kapy AI'), findsOneWidget);
    expect(
      tester.getTopLeft(text('Ask Kapy AI')).dy,
      closeTo(tester.getTopLeft(text('Create recap')).dy, 1),
    );
    expect(text('This week so far · 16 to 22 November'), findsOneWidget);
  });
}
