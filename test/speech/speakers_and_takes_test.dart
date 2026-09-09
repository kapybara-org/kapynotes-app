import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/summarizer.dart';
import 'package:kapy_notes/speech/summary_instructions.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:kapy_notes/ui/voice_note_dialog.dart';

import '../test_fonts.dart';

late Directory tempDir;
late BlobStore blobs;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'speakers-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
}

TranscriptSegment said(String text, {required int at, int? by}) =>
    TranscriptSegment(s: at, e: at + 1500, t: text, speaker: by);

VoiceTranscript conversation() => VoiceTranscript(
  lang: 'en',
  engine: 'cf/deepgram-nova-3',
  at: 1,
  jobId: '11111111-1111-4111-8111-111111111111',
  segments: [
    said('We should ship the export fix today.', at: 0, by: 0),
    said('Agreed. I will book the train on Friday.', at: 4000, by: 1),
    said('Perfect, I will tell the landlord.', at: 9000, by: 0),
  ],
);

VoiceTranscript monologue() => VoiceTranscript(
  lang: 'en',
  engine: 'cf/deepgram-nova-3',
  at: 1,
  segments: [said('Just a thought before standup.', at: 0)],
);

NoteVoiceRef recording({
  VoiceTranscript? transcript,
  VoiceSummary? summary,
  List<VoiceTake> takes = const [],
}) => NoteVoiceRef(
  offset: 0,
  hash: 'a',
  key: Uint8List(32),
  bytes: 2048,
  durationMs: 60000,
  transcript: transcript,
  summary: summary,
  takes: takes,
);

VoiceSummary aSummary() => VoiceSummary(
  engine: 'cf/llama',
  at: 1,
  title: 'Standup thoughts',
  points: const ['Ship the export fix.'],
);

Widget harness(NoteVoiceRef ref, {VoiceNoteActions actions = const VoiceNoteActions()}) =>
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: VoiceNoteView(
          ref: ref,
          state: VoiceChipState.done,
          blobs: blobs,
          actions: actions,
        ),
      ),
    );

void main() {
  setUpAll(() async {
    await loadTestFonts();
    tempDir = await Directory.systemTemp.createTemp('kapy-speakers');
    blobs = BlobStore(directory: tempDir);
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  group('the transcript when more than one person spoke', () {
    testWidgets('says how many, and who said what', (tester) async {
      await tester.pumpWidget(harness(recording(transcript: conversation())));
      await tester.pumpAndSettle();

      expect(find.text('2 speakers'), findsOneWidget);
      // Twice in the bar, and again above each turn they took.
      expect(find.text('Speaker 1'), findsNWidgets(3));
      expect(find.text('Speaker 2'), findsNWidgets(2));
    });

    testWidgets('a memo recorded alone says nothing about speakers', (
      tester,
    ) async {
      // The one case where a label would only be telling somebody something
      // they already know, in the place they came to read their own words.
      await tester.pumpWidget(harness(recording(transcript: monologue())));
      await tester.pumpAndSettle();

      expect(find.textContaining('speaker'), findsNothing);
      expect(find.textContaining('Speaker'), findsNothing);
      expect(find.textContaining('Just a thought'), findsOneWidget);
    });

    testWidgets('naming one keeps it, everywhere they spoke', (tester) async {
      NoteVoiceRef? saved;
      await tester.pumpWidget(
        harness(
          recording(transcript: conversation()),
          actions: VoiceNoteActions(onChanged: (next) => saved = next),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Speaker 1').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Priya');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Priya'), findsNWidgets(3));
      expect(find.text('Speaker 1'), findsNothing);
      // And on the note, or it is gone the moment this closes.
      expect(saved!.transcript!.speakers[0], 'Priya');
    });

    testWidgets('clearing a name gives the number back', (tester) async {
      final named = conversation().renaming(0, 'Priya');
      NoteVoiceRef? saved;
      await tester.pumpWidget(
        harness(
          recording(transcript: named),
          actions: VoiceNoteActions(onChanged: (next) => saved = next),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Priya').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(find.text('Speaker 1'), findsNWidgets(3));
      expect(saved!.transcript!.speakers, isEmpty);
    });
  });

  group('making something from the transcript', () {
    testWidgets('a preset writes a post and keeps it', (tester) async {
      String? asked;
      NoteVoiceRef? saved;
      await tester.pumpWidget(
        harness(
          recording(transcript: conversation(), summary: aSummary()),
          actions: VoiceNoteActions(
            onChanged: (next) => saved = next,
            onRewrite: (instruction) async {
              asked = instruction;
              return 'Shipped the export fix today.';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Post for X'));
      await tester.pumpAndSettle();

      expect(asked, contains('260 characters'));
      expect(find.text('Shipped the export fix today.'), findsOneWidget);
      expect(saved!.takes.single.kind, VoiceTakeKind.x);
      expect(saved!.takes.single.text, 'Shipped the export fix today.');
    });

    testWidgets('a custom instruction is asked for, and recorded', (
      tester,
    ) async {
      NoteVoiceRef? saved;
      await tester.pumpWidget(
        harness(
          recording(transcript: conversation(), summary: aSummary()),
          actions: VoiceNoteActions(
            onChanged: (next) => saved = next,
            onRewrite: (instruction) async => 'A note to the team.',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Your own words…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Write it as a haiku.');
      await tester.tap(find.text('Write it'));
      await tester.pumpAndSettle();

      expect(saved!.takes.single.kind, VoiceTakeKind.custom);
      // Kept so the card still says what was asked for, days later.
      expect(saved!.takes.single.instruction, 'Write it as a haiku.');
      expect(find.text('Write it as a haiku.'), findsOneWidget);
    });

    testWidgets('a failure says why, and keeps nothing', (tester) async {
      NoteVoiceRef? saved;
      await tester.pumpWidget(
        harness(
          recording(transcript: conversation(), summary: aSummary()),
          actions: VoiceNoteActions(
            onChanged: (next) => saved = next,
            onRewrite: (instruction) async => throw StateError('nope'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Post for X'));
      await tester.pumpAndSettle();

      expect(find.textContaining('did not work'), findsOneWidget);
      expect(saved, isNull);
    });

    testWidgets('an older recording is told what would fix it', (tester) async {
      // Recordings transcribed before the job id was kept on the note cannot
      // be billed against anything, and "not made by the server" is baffling
      // to somebody whose transcript plainly was.
      await tester.pumpWidget(
        harness(
          recording(transcript: monologue(), summary: aSummary()),
          actions: VoiceNoteActions(
            onChanged: (_) {},
            onRewrite: (instruction) async => throw const SummarizerUnavailable(
              SummarizerReadiness.unsupported,
              'Transcribe this recording again to write from it.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Post for X'));
      await tester.pumpAndSettle();
      expect(find.text('Transcribe this recording again to write from it.'), findsOneWidget);
    });

    testWidgets('there is nothing to make one from without a transcript', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          recording(summary: aSummary()),
          actions: VoiceNoteActions(onRewrite: (instruction) async => 'x'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Post for X'), findsNothing);
    });
  });

  group('how summaries are written', () {
    testWidgets('the editor opens on the wording actually in use', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          recording(transcript: conversation(), summary: aSummary()),
          actions: VoiceNoteActions(
            summaryInstruction: defaultSummaryInstruction,
            onSaveSummaryInstruction: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Change how'));
      await tester.pumpAndSettle();

      // Not a description of the instruction: the instruction itself, so
      // that changing one line does what it looks like it does.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, defaultSummaryInstruction);
    });

    testWidgets('what is saved is what was typed', (tester) async {
      String? saved;
      await tester.pumpWidget(
        harness(
          recording(transcript: conversation(), summary: aSummary()),
          actions: VoiceNoteActions(
            summaryInstruction: defaultSummaryInstruction,
            onSaveSummaryInstruction: (value) => saved = value,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Change how'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Two bullet points only.');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved, 'Two bullet points only.');
    });
  });

  group('it fits', () {
    // A pane that overflows throws in a test, so these are real assertions
    // rather than a gesture: the summary tab carries a summary, three chips,
    // a caption with a button beside it and a card, and the phone gets the
    // same content in two thirds of the width.
    for (final size in const [Size(560, 640), Size(360, 720)]) {
      testWidgets('at ${size.width.toInt()} by ${size.height.toInt()}', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final ref = recording(
          transcript: conversation().renaming(0, 'Priya'),
          summary: aSummary(),
          takes: const [
            VoiceTake(
              kind: VoiceTakeKind.x,
              text: 'Spent the morning on an export bug that turned out to '
                  'be in the zip writer rather than the markdown.',
              engine: 'cf/llama',
              at: 2,
            ),
          ],
        );
        await tester.pumpWidget(
          harness(
            ref,
            actions: VoiceNoteActions(
              onChanged: (_) {},
              onRewrite: (_) async => 'x',
              summaryInstruction: defaultSummaryInstruction,
              onSaveSummaryInstruction: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The summary tab, with everything on it.
        expect(find.text('Post for X'), findsNWidgets(2));
        expect(find.text('Change how'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('Transcript'));
        await tester.pumpAndSettle();
        expect(find.text('2 speakers'), findsOneWidget);
        expect(find.text('Priya'), findsNWidgets(3));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the preference behind it', () {
    test('the standard wording is stored as no choice at all', () {
      // Otherwise somebody who opened the editor and changed nothing would be
      // pinned to today's wording forever, and never see it improved.
      final prefs = VoicePrefs(_MemoryStore())..load();
      prefs.summaryInstruction = defaultSummaryInstruction;
      expect(prefs.summaryInstruction, isNull);
      expect(prefs.effectiveSummaryInstruction, defaultSummaryInstruction);

      prefs.summaryInstruction = 'Two bullet points only.';
      expect(prefs.summaryInstruction, 'Two bullet points only.');

      prefs.summaryInstruction = '   ';
      expect(prefs.summaryInstruction, isNull);
    });
  });

  group('what a recording carries', () {
    test('a take survives being written down and read back', () {
      final ref = recording(transcript: conversation()).withTake(
        const VoiceTake(
          kind: VoiceTakeKind.linkedin,
          text: 'A post.',
          engine: 'cf/llama',
          at: 7,
        ),
      );
      final round = NoteAttachmentRef.fromJson(ref.toJson()) as NoteVoiceRef;
      expect(round.takes.single.kind, VoiceTakeKind.linkedin);
      expect(round.takes.single.text, 'A post.');
      expect(round.transcript!.jobId, ref.transcript!.jobId);
      expect(round.transcript!.segments[1].speaker, 1);
    });

    test('the oldest goes when there are too many', () {
      var ref = recording();
      for (var i = 0; i < NoteVoiceRef.maxTakes + 2; i++) {
        ref = ref.withTake(
          VoiceTake(
            kind: VoiceTakeKind.custom,
            text: 'post $i',
            engine: 'e',
            at: i,
          ),
        );
      }
      expect(ref.takes, hasLength(NoteVoiceRef.maxTakes));
      expect(ref.takes.first.text, 'post 2');
      expect(ref.takes.last.text, 'post 7');
    });

    test('renaming a speaker makes the note dirty', () {
      // Equality is what decides whether a note is worth syncing, and it is
      // deliberately cheap. A name is the one part of a transcript the user
      // edits, so it has to be one of the things that counts.
      final before = recording(transcript: conversation());
      final after = before.copyWith(
        transcript: before.transcript!.renaming(0, 'Priya'),
      );
      expect(after == before, isFalse);
    });

    test('so does writing a post', () {
      final before = recording(transcript: conversation());
      final after = before.withTake(
        const VoiceTake(
          kind: VoiceTakeKind.x,
          text: 'A post.',
          engine: 'e',
          at: 1,
        ),
      );
      expect(after == before, isFalse);
    });
  });
}
