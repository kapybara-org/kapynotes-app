import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';

NoteVoiceRef recording({
  int durationMs = 134000,
  Uint8List? peaks,
  VoiceSummary? summary,
}) => NoteVoiceRef(
  offset: 0,
  hash: 'v1',
  key: Uint8List(32),
  bytes: 2048,
  durationMs: durationMs,
  peaks: peaks,
  summary: summary,
);

Widget harness(
  NoteVoiceRef ref, {
  VoiceChipState state = VoiceChipState.idle,
  bool playing = false,
  double? progress,
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
      ),
    ),
  ),
);

void main() {
  group('what the chip says', () {
    testWidgets('an untranscribed recording is just a voice note', (tester) async {
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
    });

    testWidgets('every waiting state says something true', (tester) async {
      const expected = {
        VoiceChipState.transcribing: 'Transcribing…',
        VoiceChipState.summarising: 'Summarising…',
        VoiceChipState.waiting: 'Waiting for connection',
        VoiceChipState.failed: "Couldn't transcribe",
        VoiceChipState.outOfMinutes: 'Out of minutes',
      };
      for (final entry in expected.entries) {
        await tester.pumpWidget(harness(recording(), state: entry.key));
        expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
      }
    });

    testWidgets('someone who declined still has a voice note', (tester) async {
      // Not an error state: a recording made without transcription is a
      // complete thing, and the chip must not nag about it.
      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.needsConsent),
      );
      expect(find.text('Voice note'), findsOneWidget);
    });
  });

  group('the duration it shows', () {
    testWidgets('reads as minutes and seconds', (tester) async {
      await tester.pumpWidget(harness(recording(durationMs: 5000)));
      expect(find.text('0:05'), findsOneWidget);
    });

    testWidgets('pads the seconds, so the column does not jump', (tester) async {
      await tester.pumpWidget(harness(recording(durationMs: 61000)));
      expect(find.text('1:01'), findsOneWidget);
    });
  });

  test('formatVoiceDuration covers the shapes a chip can meet', () {
    expect(formatVoiceDuration(Duration.zero), '0:00');
    expect(formatVoiceDuration(const Duration(seconds: 9)), '0:09');
    expect(formatVoiceDuration(const Duration(minutes: 2, seconds: 14)), '2:14');
    expect(formatVoiceDuration(const Duration(minutes: 30)), '30:00');
    // Only reachable from another client, but it must not render as "90:00".
    expect(formatVoiceDuration(const Duration(hours: 1, minutes: 5)), '1:05:00');
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

  group('the painter repaints only when it must', () {
    VoiceWaveformPainter painter({double? progress, Uint8List? peaks}) =>
        VoiceWaveformPainter(
          peaks: peaks,
          progress: progress,
          played: const Color(0xFFFFFFFF),
          unplayed: const Color(0xFF888888),
        );

    test('a moved play head repaints', () {
      expect(painter(progress: 0.5).shouldRepaint(painter(progress: 0.6)), isTrue);
    });

    test('an unchanged one does not', () {
      // Position arrives four times a second; repainting on every identical
      // frame is the whole cost this guards against.
      expect(painter(progress: 0.5).shouldRepaint(painter(progress: 0.5)), isFalse);
    });
  });
}
