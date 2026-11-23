import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_player.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';

import '../kapy_icon_finder.dart';
import '../test_fonts.dart';

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
  bool opening = false,
  VoicePlaybackFailure? failure,
  double? progress,
  VoidCallback? onOpen,
  VoidCallback? onPlayPause,
  VoidCallback? onRemove,
  ValueChanged<double>? onSeekFraction,
  double width = 400,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: SizedBox(
      width: width,
      child: NoteVoiceChip(
        ref: ref,
        state: state,
        playing: playing,
        opening: opening,
        failure: failure,
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

/// The phone's row, which says in words what the page's pill leaves to its
/// waveform: the label, and the summary under it.
void _onPhone() {
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);
}

void main() {
  group('what the chip says', () {
    _onPhone();
    testWidgets('an untranscribed recording is just its length', (
      tester,
    ) async {
      await tester.pumpWidget(harness(recording()));
      expect(find.text('Voice note'), findsNothing);
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
      expect(find.text('Ship it.'), findsNothing);
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
      expect(findKapyIcon(KapyIcons.playRounded), findsOneWidget);
    });
  });

  group('what the chip says when it cannot transcribe', () {
    _onPhone();
    testWidgets('signed out offers transcription without assuming the engine', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.needsAccount),
      );
      expect(find.text('Turn on transcription'), findsOneWidget);
      expect(find.text('Transcribing…'), findsNothing);
    });

    testWidgets('no consent yet asks for the switch', (tester) async {
      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.needsConsent),
      );
      expect(find.text('Turn on transcription'), findsOneWidget);
    });

    testWidgets('a local transcript stays readable while its summary waits', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          recording(
            transcript: VoiceTranscript(
              lang: 'en',
              engine: 'local',
              at: 1,
              segments: const [
                TranscriptSegment(s: 0, e: 900, t: 'Kept on this device.'),
              ],
            ),
          ),
          state: VoiceChipState.needsAccount,
        ),
      );

      expect(find.text('Transcript ready'), findsOneWidget);
      expect(find.text('Turn on transcription'), findsNothing);
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
      expect(findKapyIcon(KapyIcons.playRounded), findsOneWidget);

      await tester.pumpWidget(harness(recording(), playing: true));
      expect(findKapyIcon(KapyIcons.pauseRounded), findsOneWidget);
    });

    testWidgets(
      'spins while the recording is on its way, and offers to cancel',
      (tester) async {
        await tester.pumpWidget(
          harness(recording(), opening: true, onPlayPause: () {}),
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(findKapyIcon(KapyIcons.playRounded), findsNothing);
        expect(find.bySemanticsLabel('Cancel'), findsOneWidget);
      },
    );

    testWidgets('says why the last press did not start it', (tester) async {
      await tester.pumpWidget(
        harness(
          recording(),
          failure: VoicePlaybackFailure.notDownloaded,
          onPlayPause: () {},
        ),
      );
      expect(findKapyIcon(KapyIcons.cloudOffRounded), findsOneWidget);
      expect(
        find.bySemanticsLabel("Couldn't download. Try again"),
        findsOneWidget,
      );

      await tester.pumpWidget(
        harness(
          recording(),
          failure: VoicePlaybackFailure.unreadable,
          onPlayPause: () {},
        ),
      );
      expect(findKapyIcon(KapyIcons.warningRounded), findsOneWidget);
      expect(
        find.bySemanticsLabel("Couldn't play this recording"),
        findsOneWidget,
      );
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

      await hover(tester, find.text('2:14'));
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

    testWidgets('one without an account opens the engine choices', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.needsAccount, onOpen: () {}),
      );
      await tester.pumpAndSettle();

      await hover(tester, find.text('Turn on transcription'));
      expect(find.text('Choose transcription in Settings'), findsOneWidget);
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

      await hover(tester, findKapyIcon(KapyIcons.playRounded));
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

  group('a status on a phone', () {
    _onPhone();
    setUpAll(loadTestFonts);

    double column(double phone) =>
        phone - EditorMetrics.phonePadding.horizontal;

    Future<void> pumpAt(
      WidgetTester tester,
      double phone,
      VoiceChipState state, {
      NoteVoiceRef? ref,
    }) => tester.pumpWidget(
      harness(
        ref ?? recording(durationMs: 123000),
        state: state,
        width: column(phone),
      ),
    );

    double drawn(WidgetTester tester) =>
        tester.getSize(find.byKey(const ValueKey('voice-chip-pill'))).height;

    double promised(WidgetTester tester, double phone) => tester
        .widget<NoteVoiceChip>(find.byType(NoteVoiceChip))
        .heightIn(tester.element(find.byType(NoteVoiceChip)), column(phone));

    bool cut(WidgetTester tester, String words) => tester
        .renderObject<RenderParagraph>(find.text(words))
        .didExceedMaxLines;

    testWidgets('reads in full on every phone, at large text and in bold', (
      tester,
    ) async {
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      const statuses = {
        VoiceChipState.needsConsent: 'Turn on transcription',
        VoiceChipState.waiting: 'Waiting for connection',
        VoiceChipState.failed: "Couldn't transcribe",
        VoiceChipState.retrying: 'Trying again soon',
      };
      for (final bold in [false, true]) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(boldText: bold);
        for (final scale in [1.0, 1.3]) {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          for (final phone in [320.0, 375.0, 412.0]) {
            for (final MapEntry(key: state, value: words) in statuses.entries) {
              await pumpAt(tester, phone, state);
              final reason = '$words at $phone pt, ${scale}x, bold $bold';
              expect(cut(tester, words), isFalse, reason: reason);
              expect(drawn(tester), promised(tester, phone), reason: reason);
            }
          }
        }
      }
    });

    testWidgets('one that fits keeps the single row', (tester) async {
      await pumpAt(tester, 412, VoiceChipState.transcribing);
      expect(drawn(tester), 56);
      expect(
        tester.getCenter(find.text('Transcribing…')).dy,
        moreOrLessEquals(tester.getCenter(find.text('2:03')).dy, epsilon: 0.5),
      );
    });

    const title = 'Standup thoughts on the pricing page and the launch';
    final summarised = recording(
      durationMs: 123000,
      summary: VoiceSummary(
        engine: 'cf/llama',
        at: 1,
        title: title,
        points: const ['Ship it.'],
      ),
    );

    testWidgets('is as tall at its title as all the way there', (tester) async {
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final path = <(VoiceChipState, NoteVoiceRef?)>[
        (VoiceChipState.transcribing, null),
        (VoiceChipState.summarising, null),
        (VoiceChipState.done, summarised),
        (VoiceChipState.done, null),
        (VoiceChipState.idle, null),
      ];
      for (final bold in [false, true]) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(boldText: bold);
        for (final scale in [1.0, 1.3]) {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          for (final phone in [320.0, 375.0, 412.0]) {
            final reason = '$phone pt, ${scale}x, bold $bold';
            final heights = <double>{};
            for (final (state, ref) in path) {
              await pumpAt(tester, phone, state, ref: ref);
              expect(drawn(tester), promised(tester, phone), reason: reason);
              heights.add(drawn(tester));
            }
            expect(heights, hasLength(1), reason: reason);
          }
        }
      }
    });

    testWidgets(
      "a summary's title takes the second line wherever its statuses do, "
      "across the card's width",
      (tester) async {
        await pumpAt(tester, 320, VoiceChipState.done, ref: summarised);
        final pill = tester.getRect(
          find.byKey(const ValueKey('voice-chip-pill')),
        );
        final words = tester.getRect(find.text(title));
        expect(drawn(tester), 83);
        expect(cut(tester, title), isTrue);
        expect(
          words.top,
          greaterThanOrEqualTo(tester.getRect(find.text('2:03')).bottom),
        );
        expect(words.left, moreOrLessEquals(pill.left + 9, epsilon: 0.5));
        expect(words.right, moreOrLessEquals(pill.right - 17, epsilon: 0.5));

        await pumpAt(tester, 320, VoiceChipState.done);
        expect(drawn(tester), 83);
        expect(find.text('Voice note'), findsNothing);

        await pumpAt(tester, 412, VoiceChipState.done, ref: summarised);
        expect(drawn(tester), 56);
        expect(cut(tester, title), isTrue);
        expect(
          tester.getCenter(find.text(title)).dy,
          moreOrLessEquals(
            tester.getCenter(find.text('2:03')).dy,
            epsilon: 0.5,
          ),
        );

        await pumpAt(tester, 412, VoiceChipState.done);
        expect(drawn(tester), 56);
        expect(find.text('Voice note'), findsNothing);
      },
    );
  });
}
