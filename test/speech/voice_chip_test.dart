import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';

NoteVoiceRef recording({
  int durationMs = 134000,
  Uint8List? peaks,
  VoiceSummary? summary,
  VoiceTranscript? transcript,
}) => NoteVoiceRef(
  offset: 0,
  hash: 'v1',
  key: Uint8List(32),
  bytes: 2048,
  durationMs: durationMs,
  peaks: peaks,
  summary: summary,
  transcript: transcript,
);

Widget harness(
  NoteVoiceRef ref, {
  VoiceChipState state = VoiceChipState.idle,
  bool playing = false,
  double? progress,
  VoidCallback? onOpen,
  VoidCallback? onPlayPause,
  VoidCallback? onRemove,
  ValueChanged<double>? onSeekFraction,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: SizedBox(
      width: 400,
      child: NoteVoiceChip(
        ref: ref,
        state: state,
        playing: playing,
        progress: ValueNotifier<double?>(progress),
        onOpen: onOpen,
        onPlayPause: onPlayPause,
        onRemove: onRemove,
        onSeekFraction: onSeekFraction,
      ),
    ),
  ),
);

/// Parks a mouse over [finder] and reports the cursor the app asks for.
Future<MouseCursor> cursorOver(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    pointer: 1,
  );
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump();
  return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;
}

/// Hovers [finder] long enough for a tooltip to make up its mind.
Future<void> hover(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    pointer: 2,
  );
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

void main() {
  group('what the chip says', () {
    testWidgets('an untranscribed recording is just a voice note', (
      tester,
    ) async {
      await tester.pumpWidget(harness(recording()));
      expect(find.text('Voice note'), findsOneWidget);
      expect(find.text('2:14'), findsOneWidget);
    });

    testWidgets('a summarised one is titled by its summary', (tester) async {
      await tester.pumpWidget(
        harness(
          recording(
            summary: VoiceSummary(
              engine: 'cf/llama',
              at: 1,
              title: 'Standup thoughts',
              points: const ['Ship it.'],
            ),
          ),
          state: VoiceChipState.done,
        ),
      );
      expect(find.text('Standup thoughts'), findsOneWidget);
      expect(find.text('Ship it.'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-summary-more')), findsOneWidget);
    });

    testWidgets('every waiting state says something true', (tester) async {
      const expected = {
        VoiceChipState.transcribing: 'Transcribing…',
        VoiceChipState.summarising: 'Summarising…',
        VoiceChipState.waiting: 'Waiting for connection',
        VoiceChipState.retrying: 'Trying again soon',
        VoiceChipState.failed: "Couldn't transcribe",
        VoiceChipState.outOfMinutes: 'Out of minutes',
      };
      for (final entry in expected.entries) {
        await tester.pumpWidget(harness(recording(), state: entry.key));
        expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
      }
    });

    testWidgets('without consent the chip says how to get one', (tester) async {
      // This reverses the earlier rule that the chip must never nag someone
      // who declined. Asked for deliberately: the alternative was a row that
      // said "Voice note" and gave no hint that text was ever on offer.
      // Still not drawn as an error — the recording is complete and plays.
      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.needsConsent),
      );
      expect(find.text('Turn on transcription'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });
  });

  group('what the chip says when it cannot transcribe', () {
    testWidgets('signed out asks for a sign-in, not for patience', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.needsAccount),
      );
      expect(find.text('Sign in to transcribe'), findsOneWidget);
      expect(find.text('Transcribing…'), findsNothing);
    });

    testWidgets('no consent yet asks for the switch', (tester) async {
      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.needsConsent),
      );
      expect(find.text('Turn on transcription'), findsOneWidget);
    });

    testWidgets('a recording that was transcribed keeps its title', (
      tester,
    ) async {
      // The two states above are about the account, not the recording: one
      // that already has a summary must never be relabelled.
      await tester.pumpWidget(
        harness(
          recording(
            summary: VoiceSummary(
              engine: 'cf/llama',
              at: 1,
              title: 'Standup thoughts',
              points: const ['Ship it.'],
            ),
          ),
          state: VoiceChipState.done,
        ),
      );
      expect(find.text('Standup thoughts'), findsOneWidget);
    });
  });

  group('the duration it shows', () {
    testWidgets('reads as minutes and seconds', (tester) async {
      await tester.pumpWidget(harness(recording(durationMs: 5000)));
      expect(find.text('0:05'), findsOneWidget);
    });

    testWidgets('pads the seconds, so the column does not jump', (
      tester,
    ) async {
      await tester.pumpWidget(harness(recording(durationMs: 61000)));
      expect(find.text('1:01'), findsOneWidget);
    });
  });

  test('formatVoiceDuration covers the shapes a chip can meet', () {
    expect(formatVoiceDuration(Duration.zero), '0:00');
    expect(formatVoiceDuration(const Duration(seconds: 9)), '0:09');
    expect(
      formatVoiceDuration(const Duration(minutes: 2, seconds: 14)),
      '2:14',
    );
    expect(formatVoiceDuration(const Duration(minutes: 30)), '30:00');
    // Only reachable from another client, but it must not render as "90:00".
    expect(
      formatVoiceDuration(const Duration(hours: 1, minutes: 5)),
      '1:05:00',
    );
  });

  group('the play button', () {
    testWidgets('offers play, and pause while playing', (tester) async {
      await tester.pumpWidget(harness(recording()));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      await tester.pumpWidget(harness(recording(), playing: true));
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    });
  });

  group('the waveform', () {
    testWidgets('draws without peaks rather than failing', (tester) async {
      // A recording from a client that never wrote peaks, or one still being
      // adopted. It must render, just without a shape.
      await tester.pumpWidget(harness(recording()));
      expect(tester.takeException(), isNull);
    });

    testWidgets('draws with peaks and a play head', (tester) async {
      final peaks = Uint8List.fromList(
        List.generate(100, (i) => (i * 2) & 0xFF),
      );
      await tester.pumpWidget(harness(recording(peaks: peaks), progress: 0.5));
      expect(tester.takeException(), isNull);
    });
  });

  group('what the pointer is told', () {
    testWidgets('the row is a hand, not an I-beam', (tester) async {
      await tester.pumpWidget(harness(recording(), onOpen: () {}));
      await tester.pumpAndSettle();

      expect(
        await cursorOver(tester, find.byType(NoteVoiceChip)),
        SystemMouseCursors.click,
      );
    });

    testWidgets('a recording nothing can be done with defers', (tester) async {
      await tester.pumpWidget(harness(recording()));
      await tester.pumpAndSettle();

      expect(
        await cursorOver(tester, find.byType(NoteVoiceChip)),
        SystemMouseCursors.basic,
        reason: 'deferring leaves the cursor to whatever holds the chip',
      );
    });

    testWidgets('hovering the row says where a click goes', (tester) async {
      await tester.pumpWidget(harness(recording(), onOpen: () {}));
      await tester.pumpAndSettle();

      await hover(tester, find.text('Voice note'));
      expect(find.text('Open this recording'), findsOneWidget);
    });

    testWidgets('a transcribed one offers what it holds', (tester) async {
      await tester.pumpWidget(
        harness(
          recording(
            summary: VoiceSummary(
              engine: 'cf/llama',
              at: 1,
              title: 'Standup thoughts',
              points: const ['Ship it.'],
            ),
            transcript: VoiceTranscript(
              lang: 'en',
              engine: 'cf/deepgram-nova-3',
              at: 1,
              segments: const [TranscriptSegment(s: 0, e: 900, t: 'Ship it.')],
            ),
          ),
          state: VoiceChipState.done,
          onOpen: () {},
        ),
      );
      await tester.pumpAndSettle();

      await hover(tester, find.text('Standup thoughts'));
      expect(find.text('Read the transcript'), findsOneWidget);
    });

    testWidgets('one waiting on consent says so', (tester) async {
      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.needsConsent, onOpen: () {}),
      );
      await tester.pumpAndSettle();

      await hover(tester, find.text('Turn on transcription'));
      expect(find.text('Turn transcription on in Settings'), findsOneWidget);
    });

    testWidgets('the waveform says it seeks, not that it opens', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          recording(peaks: Uint8List.fromList(List.filled(100, 200))),
          onOpen: () {},
          onSeekFraction: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      await hover(tester, find.byType(CustomPaint).last);
      expect(find.text('Skip to a point'), findsOneWidget);
      expect(find.text('Open this recording'), findsNothing);
    });

    testWidgets('the play button names itself', (tester) async {
      await tester.pumpWidget(
        harness(recording(), onOpen: () {}, onPlayPause: () {}),
      );
      await tester.pumpAndSettle();

      await hover(tester, find.byIcon(Icons.play_arrow_rounded));
      expect(find.text('Play'), findsOneWidget);
    });
  });

  group('the menu the chip carries', () {
    testWidgets('the visible close button removes the recording', (
      tester,
    ) async {
      var removed = false;
      await tester.pumpWidget(
        harness(recording(), onRemove: () => removed = true),
      );

      await tester.tap(find.byKey(const ValueKey('remove-voice-note')));
      expect(removed, isTrue);
    });

    testWidgets('a press-and-hold still opens it, not a tooltip', (
      tester,
    ) async {
      // The hover hint sits above this gesture in the tree; a tooltip that
      // brought its own long-press recogniser would take the menu away on
      // every touch device.
      await tester.pumpWidget(
        harness(recording(), onOpen: () {}, onRemove: () {}),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(NoteVoiceChip));
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Open this recording'), findsNothing);
    });

    testWidgets('a right-click opens it too', (tester) async {
      var removed = false;
      await tester.pumpWidget(
        harness(recording(), onOpen: () {}, onRemove: () => removed = true),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(
        tester.getCenter(find.byType(NoteVoiceChip)),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(removed, isTrue);
    });
  });

  group('the painter repaints only when it must', () {
    VoiceWaveformPainter painter({double? progress, Uint8List? peaks}) =>
        VoiceWaveformPainter(
          peaks: peaks,
          progress: progress,
          played: const Color(0xFFFFFFFF),
          unplayed: const Color(0xFF888888),
        );

    test('a moved play head repaints', () {
      expect(
        painter(progress: 0.5).shouldRepaint(painter(progress: 0.6)),
        isTrue,
      );
    });

    test('an unchanged one does not', () {
      // Position arrives four times a second; repainting on every identical
      // frame is the whole cost this guards against.
      expect(
        painter(progress: 0.5).shouldRepaint(painter(progress: 0.5)),
        isFalse,
      );
    });
  });
}
