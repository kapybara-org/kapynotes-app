import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_picker.dart';
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
  Future<String> Function(String instruction)? onRewrite,
  void Function(NoteVoiceRef next)? onChanged,
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
        onRewrite: onRewrite,
        onChanged: onChanged,
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
        find.descendant(of: _drawer, matching: find.text('Kapy AI Cloud')),
        findsOneWidget,
      );
      expect(find.text(' · Read the whole transcript'), findsOneWidget);
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
    expect(find.text(' · Read the first 1 minute of 3'), findsOneWidget);
  });

  testWidgets('the model under an answer picks another, which answers again', (
    tester,
  ) async {
    final ai = FakeKapyAi(pro: true);
    await _show(tester, _window(ai));
    await tester.tap(find.text('What did we decide?'));
    _answer(ai, 'Annual first.');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-ask-model')));
    await tester.pumpAndSettle();
    final picker = find.byType(KapyAiPicker);
    expect(picker, findsOneWidget);
    tester.widget<KapyAiPicker>(picker).onPick(FakeKapyAi.appleIntelligence);
    await tester.pumpAndSettle();
    expect(ai.calls.last, 'answerWith:apple');
    expect(picker, findsNothing);
  });

  testWidgets(
    'on a sheet the answer\'s model has its own line, and Earlier its label',
    (tester) async {
      final ai = FakeKapyAi(pro: true);
      await _show(tester, _window(ai, asSheet: true, onInsert: (_) {}));
      await tester.tap(find.text('What did we decide?'));
      _answer(ai, 'Annual first.');
      await tester.pumpAndSettle();
      final model = tester.getRect(
        find.byKey(const ValueKey('voice-ask-model')),
      );
      final insert = tester.getRect(
        find.byKey(const ValueKey('voice-ask-insert')),
      );
      expect(model.top, greaterThanOrEqualTo(insert.bottom));
      expect(model.height, greaterThanOrEqualTo(44));
      expect(find.text(' · Read the whole transcript'), findsOneWidget);
      final earlier = find.descendant(of: _drawer, matching: _earlier);
      expect(
        find.descendant(of: earlier, matching: find.text('Earlier')),
        findsOneWidget,
      );
      expect(tester.getSize(earlier).height, greaterThanOrEqualTo(44));
    },
  );

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
      final ai = await held(tester, const KapyCloudConsent(recording: true));
      expect(find.text('Before the first answer'), findsOneWidget);
      expect(
        find.text(
          'Kapy AI sends your question and this transcript through Kapy '
          'cloud, where an AI service answers it. Kapy keeps nothing, and it '
          'is never used to train AI.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Hidden notes'), findsNothing);
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

  group('posts', () {
    late List<String> asked;
    late NoteVoiceRef? saved;
    var written = 0;

    Future<String> write(String instruction) async {
      asked.add(instruction);
      written++;
      return 'Post number $written.';
    }

    setUp(() {
      asked = [];
      saved = null;
      written = 0;
    });

    double left(WidgetTester tester, String label) =>
        tester.getTopLeft(find.text(label)).dx;

    testWidgets('sit among the questions in the starters, in order', (
      tester,
    ) async {
      await _show(tester, _window(FakeKapyAi(), onRewrite: write));
      final labels = [
        'What did we decide?',
        'Create X Post',
        'What are the next steps?',
        'Create LinkedIn Post',
        'What did Arjun ask for?',
        'Your own words…',
      ];
      for (var i = 1; i < labels.length; i++) {
        await tester.dragUntilVisible(
          find.text(labels[i]),
          find.byKey(const ValueKey('voice-ask-starters')),
          const Offset(-120, 0),
        );
        expect(
          left(tester, labels[i]),
          greaterThan(left(tester, labels[i - 1])),
          reason: labels[i],
        );
      }
      expect(find.text('MAKE SOMETHING FROM THIS'), findsNothing);
    });

    testWidgets(
      'a starter writes one into the drawer, where it can be tried again or removed',
      (tester) async {
        await _show(
          tester,
          _window(
            FakeKapyAi(),
            onRewrite: write,
            onChanged: (next) => saved = next,
            onInsert: (_) {},
          ),
        );
        await tester.tap(find.text('Create X Post'));
        await tester.pumpAndSettle();
        expect(asked.single, contains('260 characters'));
        expect(
          find.descendant(of: _drawer, matching: find.text('Create X Post')),
          findsOneWidget,
        );
        expect(find.text('Post number 1.'), findsOneWidget);
        expect(saved!.takes.single.kind, VoiceTakeKind.x);
        for (final key in [
          'voice-ask-insert',
          'voice-ask-copy',
          'voice-ask-again',
          'voice-ask-remove',
        ]) {
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        }
        Rect at(String key) => tester.getRect(find.byKey(ValueKey(key)));
        expect(
          at('voice-ask-again').left - at('voice-ask-copy').right,
          lessThan(16),
          reason: 'Try again sits with Insert and Copy',
        );
        expect(
          at('voice-ask-remove').left - at('voice-ask-again').right,
          greaterThan(100),
          reason: 'the bin stands apart, on the right',
        );
        expect(_hint(tester), 'Ask about this recording');

        await tester.tap(find.byKey(const ValueKey('voice-ask-again')));
        await tester.pumpAndSettle();
        expect(asked, hasLength(2));
        expect(asked.last, asked.first, reason: 'the same instruction');
        expect(find.text('Post number 2.'), findsOneWidget);
        expect(saved!.takes, hasLength(2));

        await tester.tap(find.byKey(const ValueKey('voice-ask-remove')));
        await tester.pumpAndSettle();
        expect(saved!.takes.single.text, 'Post number 1.');
        expect(_drawer, findsNothing);

        await tester.ensureVisible(find.text('Create LinkedIn Post'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create LinkedIn Post'));
        await tester.pumpAndSettle();
        expect(asked.last, contains('LinkedIn'));
        expect(saved!.takes.last.kind, VoiceTakeKind.linkedin);
      },
    );

    testWidgets('Your own words… takes the instruction from the bar', (
      tester,
    ) async {
      await _show(
        tester,
        _window(
          FakeKapyAi(),
          onRewrite: write,
          onChanged: (next) => saved = next,
        ),
      );
      await tester.dragUntilVisible(
        find.text('Your own words…'),
        find.byKey(const ValueKey('voice-ask-starters')),
        const Offset(-120, 0),
      );
      await tester.ensureVisible(find.text('Your own words…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Your own words…'));
      await tester.pumpAndSettle();
      expect(_hint(tester), 'What should it create?');
      expect(find.byKey(const ValueKey('voice-ask-own-words')), findsOneWidget);

      await tester.tap(find.byTooltip('Ask a question instead'));
      await tester.pumpAndSettle();
      expect(_hint(tester), 'Ask about this recording');
      expect(find.text('What did we decide?'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('Your own words…'),
        find.byKey(const ValueKey('voice-ask-starters')),
        const Offset(-120, 0),
      );
      await tester.ensureVisible(find.text('Your own words…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Your own words…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('voice-ask-field')),
        'A two-line update for the team',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('voice-ask-send')));
      await tester.pumpAndSettle();
      expect(asked.single, 'A two-line update for the team');
      expect(saved!.takes.single.instruction, 'A two-line update for the team');
      expect(
        find.descendant(
          of: _drawer,
          matching: find.text('A two-line update for the team'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Earlier lists old takes beside the questions, newest first', (
      tester,
    ) async {
      final ref = _recording();
      final withTakes = ref
          .withTake(
            VoiceTake(
              kind: VoiceTakeKind.x,
              text: 'Reworking our pricing page.',
              engine: 'test',
              at: DateTime(2026, 11, 19, 10, 50).millisecondsSinceEpoch,
            ),
          )
          .withTake(
            VoiceTake(
              kind: VoiceTakeKind.custom,
              instruction: 'A two-line update for the team',
              text: 'Pricing page: annual first.',
              engine: 'test',
              at: DateTime(2026, 11, 19, 10, 31).millisecondsSinceEpoch,
            ),
          );
      final ai = FakeKapyAi(
        chatList: [
          _chat('c1', 'What did Arjun ask for?', answer: 'Three things.'),
        ],
      );
      await _show(tester, _window(ai, ref: withTakes, onRewrite: write));
      expect(find.text('Reworking our pricing page.'), findsNothing);
      await tester.tap(_earlier);
      await tester.pumpAndSettle();
      final rows = [
        'Create X Post',
        'What did Arjun ask for?',
        'A two-line update for the team',
      ];
      for (var i = 1; i < rows.length; i++) {
        expect(
          tester.getTopLeft(find.text(rows[i])).dy,
          greaterThan(tester.getTopLeft(find.text(rows[i - 1])).dy),
          reason: rows[i],
        );
      }
      await tester.tap(find.text('Create X Post'));
      await tester.pumpAndSettle();
      expect(find.text('Reworking our pricing page.'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-ask-again')), findsOneWidget);
    });

    testWidgets('keep working in a hidden note, where questions are off', (
      tester,
    ) async {
      await _show(
        tester,
        _window(
          FakeKapyAi(),
          hidden: true,
          onRewrite: write,
          onChanged: (next) => saved = next,
        ),
      );
      expect(find.text('What did we decide?'), findsNothing);
      expect(find.text('Your own words…'), findsNothing);
      expect(find.text('Create LinkedIn Post'), findsOneWidget);
      expect(_hint(tester), 'What should it create?');
      await tester.tap(find.text('Create X Post'));
      await tester.pumpAndSettle();
      expect(saved!.takes.single.kind, VoiceTakeKind.x);
    });

    testWidgets('keep working when Kapy AI is out of answers', (tester) async {
      final ai = FakeKapyAi(pro: true)
        ..set(pending: KapyLimitReached(resetsAt: DateTime(2026, 12, 1)));
      await _show(
        tester,
        _window(ai, onRewrite: write, onChanged: (next) => saved = next),
      );
      await tester.tap(find.text('Create X Post'));
      await tester.pumpAndSettle();
      expect(saved!.takes.single.text, 'Post number 1.');
      expect(find.textContaining('No answers left'), findsNothing);
    });
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
