import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/recaps/recap_lines.dart';
import 'package:kapy_notes/recaps/recap_record.dart';
import 'package:kapy_notes/recaps/recap_story.dart';
import 'package:kapy_notes/ui/recaps/recap_story_view.dart';
import 'package:material_ui/material_ui.dart';

import 'recap_story_samples.dart';

/// What the viewer handed the app.
class _Calls {
  _Calls(this.credits);

  final int credits;
  final List<String> opened = [];
  var remade = 0;
  final List<RecapQuote> played = [];
  final List<RecapNote> saved = [];
  final List<(Uint8List, String)> shared = [];
  final List<KapyChat> pruned = [];

  late final actions = RecapStoryActions(
    openNote: opened.add,
    play: played.add,
    saveAsNote: saved.add,
    shareImage: (png, name) async => shared.add((png, name)),
    onRemake: () => remade++,
    remakeCredits: credits,
    onPruned: pruned.add,
  );
}

/// What each kind's cards say first, in order.
const _eyebrows = {
  'day': [
    'Thursday, 19 November',
    'Your day in numbers',
    'Highlights',
    'Tasks',
    'From a voice note',
    'What’s next',
  ],
  'week': ['16–22 November', 'Your week', 'Highlights', 'Next week'],
  'month': ['November 2026', 'Days you wrote', 'In November', 'December'],
  'year': [
    'Your year in Kapy Notes',
    'Your year in numbers',
    'Month by month',
    'What your year was about',
    'A few moments',
    'Your line of the year',
    'Into 2027',
  ],
};

final _samples = <String, RecapStory Function()>{
  'day': sampleDay,
  'week': sampleWeek,
  'month': sampleMonth,
  'year': sampleYear,
};

void main() {
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  /// Lets a tap's or a key's change of card, or the story closing, finish.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  /// Opens [story] from a page, the way the app does, on a phone unless
  /// [desktop].
  Future<_Calls> open(
    WidgetTester tester,
    RecapStory story, {
    bool desktop = false,
    Size size = const Size(393, 852),
    double text = 1,
    int credits = 0,
  }) async {
    AppPlatform.debugTargetPlatformOverride = desktop
        ? TargetPlatform.macOS
        : TargetPlatform.iOS;
    tester.view
      ..physicalSize = desktop ? const Size(1440, 900) : size
      ..devicePixelRatio = 1
      ..padding = desktop
          ? FakeViewPadding.zero
          : const FakeViewPadding(top: 54, bottom: 34);
    tester.platformDispatcher.textScaleFactorTestValue = text;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final calls = _Calls(credits);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () =>
                  showRecapStory(context, story: story, actions: calls.actions),
              child: const Text('Open recap'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open recap'));
    await settle(tester);
    return calls;
  }

  bool showing(String text) => find.text(text).evaluate().isNotEmpty;

  Future<void> next(WidgetTester tester) async {
    await tester.tapAt(const Offset(300, 160));
    await settle(tester);
  }

  Future<void> back(WidgetTester tester) async {
    await tester.tapAt(const Offset(40, 160));
    await settle(tester);
  }

  group('on a phone', () {
    testWidgets('a tap on the right moves on, on the left goes back', (
      tester,
    ) async {
      await open(tester, sampleDay());
      expect(showing('Thursday, 19 November'), isTrue);
      await back(tester);
      expect(showing('Thursday, 19 November'), isTrue, reason: 'the first');
      await next(tester);
      expect(showing('Your day in numbers'), isTrue);
      expect(showing('Thursday, 19 November'), isFalse);
      await back(tester);
      expect(showing('Thursday, 19 November'), isTrue);
    });

    testWidgets('each card moves on by itself, and holding one pauses it', (
      tester,
    ) async {
      await open(tester, sampleDay());
      await tester.pump(const Duration(seconds: 7));
      await settle(tester);
      expect(showing('Your day in numbers'), isTrue);
      final hold = await tester.startGesture(const Offset(200, 500));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 10));
      expect(showing('Your day in numbers'), isTrue, reason: 'held');
      await hold.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 7));
      await settle(tester);
      expect(showing('Highlights'), isTrue);
    });

    testWidgets('the last card stays until it is closed', (tester) async {
      await open(tester, sampleWeek());
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 7));
        await settle(tester);
      }
      expect(showing('Next week'), isTrue);
      await next(tester);
      expect(showing('Next week'), isTrue);
    });

    testWidgets('swiping down closes it', (tester) async {
      await open(tester, sampleDay());
      await tester.fling(
        find.byType(RecapStoryView),
        const Offset(0, 300),
        1500,
      );
      await settle(tester);
      expect(find.byType(RecapStoryView), findsNothing);
    });

    testWidgets('a short pull springs back', (tester) async {
      await open(tester, sampleDay());
      await tester.drag(find.byType(RecapStoryView), const Offset(0, 40));
      await settle(tester);
      expect(find.byType(RecapStoryView), findsOneWidget);
    });

    testWidgets('✕ closes it', (tester) async {
      await open(tester, sampleDay());
      await tester.tap(find.bySemanticsLabel('Close recap'));
      await settle(tester);
      expect(find.byType(RecapStoryView), findsNothing);
    });

    testWidgets('with reduced motion, nothing moves by itself or fades', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await open(tester, sampleDay());
      await tester.pump(const Duration(seconds: 30));
      expect(showing('Thursday, 19 November'), isTrue);
      await tester.tapAt(const Offset(300, 160));
      await tester.pump();
      expect(showing('Your day in numbers'), isTrue);
      expect(
        showing('Thursday, 19 November'),
        isFalse,
        reason: 'the cards change at once',
      );
    });

    testWidgets('with a screen reader, nothing moves by itself', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final semantics = tester.ensureSemantics();
      await open(tester, sampleDay());
      await tester.pump(const Duration(seconds: 30));
      expect(showing('Thursday, 19 November'), isTrue);
      expect(find.bySemanticsLabel(RegExp('^Card 1 of 6')), findsOneWidget);
      expect(find.bySemanticsLabel('Close recap'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('on a desktop', () {
    testWidgets('← and → move, Space pauses, Esc closes', (tester) async {
      await open(tester, sampleDay(), desktop: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(showing('Your day in numbers'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(showing('Thursday, 19 November'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(seconds: 20));
      expect(showing('Thursday, 19 November'), isTrue, reason: 'paused');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(seconds: 7));
      await settle(tester);
      expect(showing('Your day in numbers'), isTrue, reason: 'playing');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(RecapStoryView), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the side arrows move, and are gone at either end', (
      tester,
    ) async {
      await open(tester, sampleWeek(), desktop: true);
      expect(find.bySemanticsLabel('Previous card'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Next card'));
      await settle(tester);
      expect(showing('Your week'), isTrue);
      await tester.tap(find.bySemanticsLabel('Previous card'));
      await settle(tester);
      expect(showing('16–22 November'), isTrue);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.bySemanticsLabel('Next card'));
        await settle(tester);
      }
      expect(showing('Next week'), isTrue);
      expect(find.bySemanticsLabel('Next card'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the frame is 393 × 740, centred over the dimmed app', (
      tester,
    ) async {
      await open(tester, sampleDay(), desktop: true);
      final frame = find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.constraints?.maxWidth == RecapStoryView.frame.width,
      );
      expect(tester.getSize(frame), RecapStoryView.frame);
      expect(tester.getCenter(frame).dx, 720);
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).last,
      );
      expect(barrier.color, recapScrim);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Tab keeps the focus in the frame', (tester) async {
      await open(tester, sampleDay(), desktop: true);
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        expect(
          focused?.findAncestorWidgetOfExactType<RecapStoryView>(),
          isNotNull,
          reason: 'Tab $i',
        );
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Enter on a focused highlight opens it, not the story', (
      tester,
    ) async {
      final calls = await open(tester, sampleDay(), desktop: true);
      for (var i = 0; i < 2; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await settle(tester);
      for (var i = 0; i < 12 && calls.opened.isEmpty; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        final label = focused
            ?.findAncestorWidgetOfExactType<Semantics>()
            ?.properties
            .label;
        if (label?.startsWith('Open Call with Arjun') ?? false) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await settle(tester);
        }
      }
      expect(calls.opened, ['arjun']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('each kind', () {
    for (final MapEntry(key: kind, value: sample) in _samples.entries) {
      testWidgets('$kind: its cards, in order', (tester) async {
        final story = sample();
        await open(tester, story);
        expect(story.cards.length, _eyebrows[kind]!.length);
        for (final eyebrow in _eyebrows[kind]!) {
          expect(showing(eyebrow), isTrue, reason: eyebrow);
          await next(tester);
        }
        expect(tester.takeException(), isNull);
      });

      for (final (size, text) in [
        (const Size(320, 568), 1.0),
        (const Size(320, 568), 2.0),
        (const Size(393, 852), 3.0),
      ]) {
        testWidgets('$kind: nothing clips at ${text}x text on a '
            '${size.width.round()} pt phone', (tester) async {
          final story = sample();
          await open(tester, story, size: size, text: text);
          for (var i = 0; i < story.cards.length; i++) {
            expect(tester.takeException(), isNull, reason: 'card ${i + 1}');
            await next(tester);
          }
        });
      }

      testWidgets('$kind: on a desktop too', (tester) async {
        final story = sample();
        await open(tester, story, desktop: true);
        for (var i = 0; i < story.cards.length; i++) {
          expect(showing(_eyebrows[kind]![i]), isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await settle(tester);
        }
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }
  });

  group('actions', () {
    testWidgets('a highlight closes the story and opens its note', (
      tester,
    ) async {
      final calls = await open(tester, sampleDay());
      await next(tester);
      await next(tester);
      await tester.tap(find.text('Quote for the deck'));
      await settle(tester);
      expect(calls.opened, ['quote']);
      expect(find.byType(RecapStoryView), findsNothing);
    });

    testWidgets('Play this part plays the quote at its moment, and pauses', (
      tester,
    ) async {
      final calls = await open(tester, sampleDay());
      for (var i = 0; i < 4; i++) {
        await next(tester);
      }
      expect(find.text('Morning pages · at 1:42'), findsOneWidget);
      await tester.tap(find.text('Play this part'));
      await tester.pump(const Duration(seconds: 20));
      expect(calls.played.single.at, const Duration(minutes: 1, seconds: 42));
      expect(calls.played.single.hash, 'morning');
      expect(showing('From a voice note'), isTrue, reason: 'paused');
    });

    testWidgets('Save as note hands over one note with the recap’s words', (
      tester,
    ) async {
      final calls = await open(tester, sampleDay());
      for (var i = 0; i < 5; i++) {
        await next(tester);
      }
      await tester.tap(find.text('Save as note'));
      await tester.pump();
      final note = calls.saved.single;
      expect(note.body, startsWith('Recap · Thu 19\nA full day'));
      expect(note.body, contains('- Call with Arjun: Pricing page is due'));
      expect(note.body, contains('- Send the deck'));
      expect(note.names, ['arjun', 'quote', 'morning']);
    });

    for (final (credits, label) in [
      (0, 'Remake'),
      (1, 'Remake · 1 credit'),
      (3, 'Remake · 3 credits'),
    ]) {
      testWidgets('with no words left, $label in place of Save as note', (
        tester,
      ) async {
        final day = sampleDay();
        final story = RecapStory(
          record: day.record,
          lines: const RecapLines(),
          done: day.done,
          open: day.open,
          wordsGone: true,
        );
        final calls = await open(
          tester,
          story,
          credits: credits,
          text: credits == 3 ? 3.0 : 1,
        );
        while (!showing('What’s next')) {
          expect(tester.takeException(), isNull);
          await next(tester);
        }
        expect(tester.takeException(), isNull, reason: 'nothing clips');
        expect(
          showing(
            'Some notes in this recap are hidden or gone now, so its words '
            'were left out.',
          ),
          isTrue,
        );
        expect(showing('Save as note'), isFalse);
        expect(showing('Share as image'), isTrue);
        await tester.tap(find.text(label));
        await settle(tester);
        expect(calls.remade, 1);
        expect(find.byType(RecapStoryView), findsNothing);
      });
    }

    testWidgets('a story that left words out hands its chat back, once', (
      tester,
    ) async {
      final day = sampleDay();
      final chat = recapChat(
        null,
        record: day.record,
        answer: 'TITLE: A full day\nNEXT: Pay for it before Friday',
        model: KapyModel.cloud,
        now: DateTime(2026, 11, 20),
      );
      final story = RecapStory(
        record: day.record,
        lines: const RecapLines(title: 'A full day'),
        chat: chat,
        dropped: true,
      );
      final calls = await open(tester, story);
      await next(tester);
      await next(tester);
      final kept = calls.pruned.single;
      expect(kept.id, chat.id);
      expect(recapAnswer(kept), 'TITLE: A full day');
    });

    testWidgets('a story that left nothing out hands nothing back', (
      tester,
    ) async {
      final day = sampleDay();
      final chat = recapChat(
        null,
        record: day.record,
        answer: day.lines.text,
        model: KapyModel.cloud,
        now: DateTime(2026, 11, 20),
      );
      final calls = await open(
        tester,
        RecapStory(record: day.record, lines: day.lines, chat: chat),
      );
      await next(tester);
      expect(calls.pruned, isEmpty);
    });

    testWidgets('with words left, no Remake', (tester) async {
      await open(tester, sampleDay());
      for (var i = 0; i < 5; i++) {
        await next(tester);
      }
      expect(showing('What’s next'), isTrue);
      expect(showing('Save as note'), isTrue);
      expect(find.textContaining('Remake'), findsNothing);
      expect(find.textContaining('hidden or gone'), findsNothing);
    });

    testWidgets('Share as image draws the card on the device as a PNG', (
      tester,
    ) async {
      final calls = await open(tester, sampleDay());
      for (var i = 0; i < 5; i++) {
        await next(tester);
      }
      await tester.tap(find.text('Share as image'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      final (png, name) = calls.shared.single;
      expect(name, 'Recap · Thu 19.png');
      expect(png.take(4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });

  group('Kapy AI’s words', () {
    final long = List.filled(40, 'very').join(' ');
    RecapStory untrusted() => sampleDay(
      lines: RecapLines(
        title: '**Bold** [a link](https://example.com) <b>html</b> $long',
        highlights: [
          RecapHighlight(
            noteId: 'arjun',
            title: '# Call with Arjun\u202e $long',
            line: '[tap me](javascript:alert(1)) \x60code\x60 $long $long',
          ),
        ],
        quote: RecapQuote(
          noteId: 'morning',
          hash: 'morning',
          title: 'Morning pages',
          at: const Duration(seconds: 3),
          line: 'Visit https://example.com\u0000 now $long $long',
        ),
        next: '- [ ] **Next** $long',
      ),
    );

    testWidgets('show as plain text: no links, no markdown, no controls', (
      tester,
    ) async {
      await open(tester, untrusted());
      for (var i = 0; i < 6; i++) {
        for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
          text.text.visitChildren((span) {
            expect((span as TextSpan).recognizer, isNull);
            return true;
          });
          final plain = text.text.toPlainText();
          expect(plain, isNot(contains('\u202e')));
          expect(plain, isNot(contains('\u0000')));
        }
        expect(tester.takeException(), isNull);
        if (i == 0) {
          expect(
            find.textContaining('**Bold** [a link](https://example.com)'),
            findsOneWidget,
          );
        }
        if (i == 2) {
          expect(find.textContaining('[tap me](javascript'), findsOneWidget);
        }
        await next(tester);
      }
    });

    testWidgets('long lines are cut short, never past the card', (
      tester,
    ) async {
      await open(tester, untrusted(), size: const Size(320, 568), text: 1.5);
      for (var i = 0; i < 6; i++) {
        expect(tester.takeException(), isNull);
        await next(tester);
      }
    });
  });
}
