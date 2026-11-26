import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:kapy_notes/ui/voice_note_ask.dart';
import 'package:kapy_notes/ui/voice_note_dialog.dart';
import 'package:material_ui/material_ui.dart';

import '../fake_kapy_ai.dart';
import '../test_fonts.dart';

const _hash = 'pricing-call';
const _link = KapyRecordingRef(noteId: 'note-1', hash: _hash);

NoteVoiceRef _recording({bool transcribed = true}) => NoteVoiceRef(
  offset: 0,
  hash: _hash,
  key: Uint8List(32),
  bytes: 2048,
  durationMs: 123000,
  peaks: Uint8List.fromList(List.filled(100, 128)),
  transcript: transcribed
      ? VoiceTranscript(
          lang: 'en',
          engine: 'test',
          at: 1,
          speakers: const {0: 'Me', 1: 'Arjun'},
          segments: const [
            TranscriptSegment(
              s: 0,
              e: 4000,
              t: 'Thanks for jumping on before Friday.',
              speaker: 0,
            ),
            TranscriptSegment(
              s: 8000,
              e: 14000,
              t: 'The annual plan goes first, with the monthly price underneath.',
              speaker: 1,
            ),
            TranscriptSegment(
              s: 38000,
              e: 44000,
              t: 'Can billing split the first invoice across two months?',
              speaker: 1,
            ),
          ],
        )
      : null,
  summary: VoiceSummary(
    engine: 'test',
    at: 1,
    title: 'Pricing page plan',
    points: const ['Show the annual plan first.'],
  ),
);

KapyChat _chat(
  String id,
  String question, {
  String? answer,
  KapyModel model = KapyModel.cloud,
  Duration? readTo,
  KapyRecordingRef? recording = _link,
  int minute = 42,
}) {
  final at = DateTime(2026, 11, 19, 10, minute);
  return KapyChat(
    id: id,
    title: question,
    createdAt: at,
    updatedAt: at,
    model: model,
    recording: recording,
    messages: [
      KapyMessage(id: '$id-q', role: KapyRole.user, text: question, at: at),
      if (answer != null)
        KapyMessage(
          id: '$id-a',
          role: KapyRole.assistant,
          text: answer,
          at: at,
          model: model,
          readTo: readTo,
        ),
    ],
  );
}

/// The window itself, so what it decides about Ask is under test too.
Widget _window(
  FakeKapyAi ai, {
  NoteVoiceRef? ref,
  bool hidden = false,
  bool asSheet = false,
  VoiceChipState state = VoiceChipState.done,
  void Function(String text)? onInsert,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  // As in the app, where the window is a route of its own, nothing around
  // it makes room for the keyboard.
  home: Scaffold(
    resizeToAvoidBottomInset: false,
    body: VoiceNoteView(
      ref: ref ?? _recording(),
      state: state,
      asSheet: asSheet,
      actions: VoiceNoteActions(
        onInsert: onInsert,
        ask: VoiceAskActions(
          kapyAi: ai,
          noteId: _link.noteId,
          hidden: hidden,
          onManageAccounts: () => ai.calls.add('manageAccounts'),
          onSignIn: () => ai.calls.add('signIn'),
          onUpgrade: () => ai.calls.add('upgrade'),
        ),
      ),
    ),
  ),
);

/// The window at its own size, with room around it.
Future<void> _show(WidgetTester tester, Widget window) async {
  tester.view
    ..physicalSize = const Size(1000, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(window);
}

final _drawer = find.byKey(const ValueKey('voice-ask-drawer'));
final _earlier = find.byKey(const ValueKey('voice-ask-earlier'));

String _hint(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('voice-ask-field')))
    .decoration!
    .hintText!;

/// Hands the question just asked its answer.
void _answer(FakeKapyAi ai, String text, {Duration? readTo}) {
  final asked = ai.current!;
  final answered = KapyChat(
    id: asked.id,
    title: asked.title,
    createdAt: asked.createdAt,
    updatedAt: asked.updatedAt,
    model: asked.model,
    recording: asked.recording,
    messages: [
      ...asked.messages,
      KapyMessage(
        id: '${asked.id}-a${asked.messages.length}',
        role: KapyRole.assistant,
        text: text,
        at: asked.updatedAt,
        model: KapyModel.cloud,
        readTo: readTo,
      ),
    ],
  );
  ai.set(
    current: answered,
    chats: [answered, ...ai.chats.where((c) => c.id != asked.id)],
    answering: false,
  );
}

const _cited =
    'Arjun wants the annual plan first with the monthly price underneath. '
    'He also asked billing to split the first invoice across two months.';

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  testWidgets('a starter asks about this recording in a chat of its own', (
    tester,
  ) async {
    final ai = FakeKapyAi(pro: true);
    await _show(tester, _window(ai));
    expect(_hint(tester), 'Ask about this recording');
    expect(find.text('What did we decide?'), findsOneWidget);
    expect(find.text('What are the next steps?'), findsOneWidget);
    expect(find.text('What did Arjun ask for?'), findsOneWidget);
    expect(_earlier, findsNothing, reason: 'nothing asked yet');
    expect(_drawer, findsNothing);

    await tester.tap(find.text('What did Arjun ask for?'));
    ai.set(answering: true);
    await tester.pump();
    expect(ai.calls, [
      'newChat',
      'askRecording:What did Arjun ask for?:$_hash',
    ]);
    expect(_drawer, findsOneWidget);
    expect(
      find.descendant(
        of: _drawer,
        matching: find.text('What did Arjun ask for?'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice-ask-thinking')), findsOneWidget);
    expect(_hint(tester), 'Ask a follow-up…');
    expect(find.text('What are the next steps?'), findsNothing);

    // A follow-up goes on the same chat.
    _answer(ai, 'The annual plan first.');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('voice-ask-field')),
      'And?',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('voice-ask-send')));
    await tester.pump();
    expect(ai.calls.last, 'askRecording:And?:$_hash');
    expect(ai.calls.where((call) => call == 'newChat'), hasLength(1));
    expect(ai.chats, hasLength(1));
  });

  testWidgets(
    'an answer plays its moments, edges and shows the lines it drew on, and inserts or copies',
    (tester) async {
      final ai = FakeKapyAi(pro: true);
      String? inserted;
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _show(tester, _window(ai, onInsert: (text) => inserted = text));
      expect(find.text('Show the annual plan first.'), findsOneWidget);

      await tester.tap(find.text('What did Arjun ask for?'));
      _answer(ai, _cited);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('voice-ask-moment-8000')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('voice-ask-moment-38000')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('voice-ask-moment-0')), findsNothing);
      expect(
        find.text('Kapy AI Cloud · Read the whole transcript'),
        findsOneWidget,
      );
      // On a computer the window turns to the transcript, at the lines.
      expect(find.text('Show the annual plan first.'), findsNothing);
      expect(
        find.text('Can billing split the first invoice across two months?'),
        findsOneWidget,
      );
      final edged = tester
          .widgetList<Container>(find.byType(Container))
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration! as BoxDecoration).border is Border &&
                ((box.decoration! as BoxDecoration).border! as Border)
                        .left
                        .width ==
                    2,
          );
      expect(edged, hasLength(2));

      await tester.tap(find.byKey(const ValueKey('voice-ask-copy')));
      await tester.pump();
      expect(copied, [_cited]);

      await tester.tap(find.byKey(const ValueKey('voice-ask-insert')));
      await tester.pumpAndSettle();
      expect(inserted, _cited);
    },
  );

  testWidgets('an answer that read part of a long recording says how much', (
    tester,
  ) async {
    final ai = FakeKapyAi();
    await _show(tester, _window(ai));
    await tester.tap(find.text('What did we decide?'));
    _answer(
      ai,
      'Annual first.',
      readTo: const Duration(minutes: 1, seconds: 5),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Kapy AI Cloud · Read the first 1 minute of 3'),
      findsOneWidget,
    );
  });

  group('every hold is Kapy AI\'s own card', () {
    Future<FakeKapyAi> held(WidgetTester tester, KapyPending pending) async {
      final ai = FakeKapyAi(pro: true);
      await _show(tester, _window(ai));
      await tester.tap(find.text('What did we decide?'));
      ai.set(pending: pending);
      await tester.pumpAndSettle();
      return ai;
    }

    testWidgets('before the first answer', (tester) async {
      final ai = await held(tester, const KapyCloudConsent());
      expect(find.text('Before the first answer'), findsOneWidget);
      await tester.tap(find.text('Go ahead'));
      await tester.pump();
      expect(ai.calls.last, 'proceed');
    });

    testWidgets('no Pro', (tester) async {
      final ai = await held(
        tester,
        const KapyCloudLocked(signIn: false, upgrade: true),
      );
      expect(find.text('Kapy AI Cloud is part of Pro'), findsOneWidget);
      await tester.tap(find.text('Upgrade'));
      await tester.pump();
      expect(ai.calls.last, 'upgrade');
    });

    testWidgets('signed out', (tester) async {
      final ai = await held(
        tester,
        const KapyCloudLocked(signIn: true, upgrade: false),
      );
      expect(find.text('Sign in to use Kapy AI Cloud'), findsOneWidget);
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      expect(ai.calls.last, 'signIn');
    });

    testWidgets('offline', (tester) async {
      final ai = await held(
        tester,
        const KapyOffline(fallback: FakeKapyAi.appleIntelligence),
      );
      expect(find.text('You’re offline'), findsOneWidget);
      await tester.tap(find.text('Use Apple Intelligence'));
      await tester.pump();
      expect(ai.calls.last, 'answerWith:apple');
    });

    testWidgets('out of answers', (tester) async {
      await held(tester, KapyLimitReached(resetsAt: DateTime(2026, 12, 1)));
      expect(
        find.textContaining('No answers left until 1 Dec'),
        findsOneWidget,
      );
    });

    testWidgets('a hidden note or a missing transcript', (tester) async {
      await held(
        tester,
        const KapyFailed("Kapy AI doesn't read hidden notes.", retry: false),
      );
      expect(find.text("Kapy AI doesn't read hidden notes."), findsOneWidget);
    });
  });

  group('Earlier', () {
    final past = [
      _chat('c2', 'When is the page due?', answer: 'Friday.', minute: 29),
      _chat(
        'other',
        'Lisbon?',
        answer: 'Flights.',
        recording: const KapyRecordingRef(noteId: 'note-1', hash: 'another'),
      ),
      _chat(
        'c1',
        'What did Arjun ask for?',
        answer: 'Three things.',
        minute: 42,
      ),
    ];

    testWidgets(
      'lists this recording\'s questions, and opens one in the drawer',
      (tester) async {
        final ai = FakeKapyAi(chatList: past);
        await _show(tester, _window(ai));
        expect(find.text('Earlier'), findsOneWidget);
        await tester.tap(_earlier);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('voice-ask-earlier-c2')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('voice-ask-earlier-c1')),
          findsOneWidget,
        );
        expect(find.text('Lisbon?'), findsNothing);
        expect(find.text('Friday.'), findsOneWidget);
        expect(_hint(tester), 'Ask about this recording');

        await tester.tap(find.text('When is the page due?'));
        await tester.pumpAndSettle();
        expect(ai.calls.last, 'openChat:c2');
        expect(
          find.descendant(of: _drawer, matching: find.text('Friday.')),
          findsOneWidget,
        );
        // The drawer's own Earlier goes back to the list; the chevron folds it.
        await tester.tap(find.descendant(of: _drawer, matching: _earlier));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('voice-ask-earlier-c1')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('voice-ask-fold')));
        await tester.pumpAndSettle();
        expect(_drawer, findsNothing);
        expect(find.text('What did we decide?'), findsOneWidget);
      },
    );

    testWidgets('on a sheet it is the clock alone, with a 44 pt target', (
      tester,
    ) async {
      final ai = FakeKapyAi(chatList: past);
      await _show(tester, _window(ai, asSheet: true));
      expect(find.text('Earlier'), findsNothing);
      expect(tester.getSize(_earlier), const Size(44, 44));
      expect(find.byTooltip('Earlier'), findsOneWidget);
      expect(find.bySemanticsLabel('Earlier'), findsOneWidget);
    });
  });

  testWidgets('on a sheet the keyboard lifts the bar above it', (tester) async {
    await _show(tester, _window(FakeKapyAi(), asSheet: true));
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byKey(const ValueKey('voice-ask-field')));
    expect(bar.bottom, lessThan(1000 - 320));
    expect(find.text('What did we decide?'), findsOneWidget);
  });

  testWidgets('closing the window gives the panel its chat back', (
    tester,
  ) async {
    final open = _chat(
      'panel',
      'Trip budget?',
      answer: 'Two.',
      recording: null,
    );
    final ai = FakeKapyAi(chatList: [open])..set(current: open);
    await _show(tester, _window(ai));
    await tester.tap(find.text('What did we decide?'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(ai.calls.last, 'openChat:panel');
  });

  group('questions are off', () {
    testWidgets('in a hidden note, and say why', (tester) async {
      final ai = FakeKapyAi();
      await _show(tester, _window(ai, hidden: true));
      expect(_hint(tester), "Kapy AI doesn't read hidden notes");
      expect(find.text('What did we decide?'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('voice-ask-field')))
            .enabled,
        isFalse,
      );
    });

    testWidgets('until the transcript is ready, or without one', (
      tester,
    ) async {
      final ai = FakeKapyAi();
      await _show(
        tester,
        _window(
          ai,
          ref: _recording(transcribed: false),
          state: VoiceChipState.transcribing,
        ),
      );
      expect(_hint(tester), 'Ask once the transcript is ready');
      await _show(
        tester,
        _window(
          ai,
          ref: _recording(transcribed: false),
          state: VoiceChipState.failed,
        ),
      );
      expect(_hint(tester), 'Ask needs a transcript');
      expect(find.text('What did we decide?'), findsNothing);
    });
  });
}
