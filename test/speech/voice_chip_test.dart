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

/// The waveform's bars, which a press anywhere around them skips through.
Finder waveform() => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is VoiceWaveformPainter,
);

/// The phone's row, which says in words what the page's pill leaves to its
/// waveform: the label, and the summary under it.
void _onPhone() {
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);
}

void main() {
  group('what the chip says', () {
    _onPhone();
    testWidgets('an untranscribed recording is a voice note of its length', (
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
      expect(find.text('Open the summary and transcript'), findsOneWidget);
    });

    testWidgets('one with only a transcript opens that', (tester) async {
      await tester.pumpWidget(
        harness(
          recording(
            transcript: VoiceTranscript(
              lang: 'en',
              engine: 'local',
              at: 1,
              segments: const [TranscriptSegment(s: 0, e: 900, t: 'Ship it.')],
            ),
          ),
          state: VoiceChipState.needsAccount,
          onOpen: () {},
        ),
      );
      await tester.pumpAndSettle();

      await hover(tester, find.text('Transcript ready'));
      expect(find.text('Open the transcript'), findsOneWidget);
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

      await hover(tester, waveform());
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

  group('the card', () {
    setUpAll(loadTestFonts);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    final peaks = Uint8List.fromList(List.filled(100, 200));
    const card = ValueKey('voice-chip-card');
    final summary = VoiceSummary(
      engine: 'cf/llama',
      at: 1,
      title: 'Standup thoughts on the pricing page and the launch',
      points: const ['Ship it.'],
    );
    final transcript = VoiceTranscript(
      lang: 'en',
      engine: 'cf/deepgram-nova-3',
      at: 1,
      segments: const [TranscriptSegment(s: 0, e: 900, t: 'Ship it.')],
    );
    const statuses = {
      VoiceChipState.transcribing: 'Transcribing…',
      VoiceChipState.summarising: 'Summarising…',
      VoiceChipState.waiting: 'Waiting for connection',
      VoiceChipState.retrying: 'Trying again soon',
      VoiceChipState.failed: "Couldn't transcribe",
      VoiceChipState.outOfMinutes: 'Out of minutes',
      VoiceChipState.needsConsent: 'Turn on transcription',
    };

    void on(TargetPlatform platform) =>
        AppPlatform.debugTargetPlatformOverride = platform;

    BoxDecoration surface(WidgetTester tester) =>
        tester.widget<Container>(find.byKey(card)).decoration! as BoxDecoration;

    CalcPalette colours(WidgetTester tester) =>
        tester.element(find.byType(NoteVoiceChip)).palette;

    double baseline(WidgetTester tester, Finder words) {
      final paragraph = tester.renderObject<RenderParagraph>(words);
      return tester.getRect(words).top +
          paragraph.getDryBaseline(
            paragraph.constraints,
            TextBaseline.alphabetic,
          )!;
    }

    bool cut(WidgetTester tester, String words) => tester
        .renderObject<RenderParagraph>(find.text(words))
        .didExceedMaxLines;

    testWidgets('is as tall in every state, with a pointer and on a phone', (
      tester,
    ) async {
      for (final (platform, height) in [
        (TargetPlatform.macOS, 60.0),
        (TargetPlatform.iOS, 68.0),
      ]) {
        on(platform);
        final states = [
          harness(recording(peaks: peaks)),
          harness(
            recording(peaks: peaks, summary: summary, transcript: transcript),
            state: VoiceChipState.done,
          ),
          harness(
            recording(peaks: peaks, summary: summary),
            state: VoiceChipState.done,
            playing: true,
            progress: 0.4,
          ),
          harness(recording(peaks: peaks), opening: true),
          harness(
            recording(peaks: peaks),
            failure: VoicePlaybackFailure.unreadable,
          ),
          for (final state in statuses.keys)
            harness(recording(peaks: peaks), state: state),
          harness(recording(peaks: peaks), onRemove: () {}),
        ];
        for (final state in states) {
          await tester.pumpWidget(state);
          expect(
            tester.getSize(find.byKey(card)).height,
            height,
            reason: '$platform',
          );
        }
        expect(noteVoiceChipHeight, height);
      }
    });

    testWidgets('is at most 460 wide with a pointer, the column on a phone', (
      tester,
    ) async {
      on(TargetPlatform.macOS);
      await tester.pumpWidget(harness(recording(peaks: peaks), width: 680));
      expect(tester.getSize(find.byKey(card)).width, 460);
      await tester.pumpWidget(harness(recording(peaks: peaks), width: 400));
      expect(tester.getSize(find.byKey(card)).width, 400);

      on(TargetPlatform.iOS);
      await tester.pumpWidget(harness(recording(peaks: peaks), width: 350));
      expect(tester.getSize(find.byKey(card)).width, 350);
    });

    testWidgets('names the recording first, with the status after its length', (
      tester,
    ) async {
      on(TargetPlatform.macOS);
      for (final MapEntry(key: state, value: words) in statuses.entries) {
        await tester.pumpWidget(
          harness(
            recording(durationMs: 72000, peaks: peaks),
            state: state,
            width: 680,
            onRemove: () {},
          ),
        );
        final name = tester.getRect(find.text('Voice note'));
        final length = tester.getRect(find.text('1:12'));
        final status = tester.getRect(find.text(words));
        expect(name.bottom, lessThanOrEqualTo(length.top), reason: words);
        expect(
          status.center.dy,
          moreOrLessEquals(length.center.dy, epsilon: 0.5),
          reason: words,
        );
        expect(status.left, greaterThan(length.right), reason: words);
        expect(cut(tester, words), isFalse, reason: words);
      }
    });

    testWidgets('on a phone ends the name\'s line with the status', (
      tester,
    ) async {
      on(TargetPlatform.iOS);
      for (final phone in [360.0, 375.0, 412.0]) {
        for (final MapEntry(key: state, value: words) in statuses.entries) {
          await tester.pumpWidget(
            harness(
              recording(durationMs: 72000, peaks: peaks),
              state: state,
              width: phone - EditorMetrics.phonePadding.horizontal,
            ),
          );
          final reason = '$words at $phone pt';
          expect(
            baseline(tester, find.text(words)),
            moreOrLessEquals(
              baseline(tester, find.text('Voice note')),
              epsilon: 0.5,
            ),
            reason: reason,
          );
          expect(
            tester.getRect(find.text(words)).right,
            moreOrLessEquals(tester.getRect(find.byKey(card)).right - 15),
            reason: reason,
          );
          expect(cut(tester, words), isFalse, reason: reason);
        }
      }
    });

    testWidgets('plays from the window\'s tonal button and waveform', (
      tester,
    ) async {
      for (final (platform, glyph) in [
        (TargetPlatform.macOS, 16.0),
        (TargetPlatform.iOS, 18.0),
      ]) {
        on(platform);
        await tester.pumpWidget(harness(recording(peaks: peaks), width: 350));
        final painter =
            tester.widget<CustomPaint>(waveform()).painter!
                as VoiceWaveformPainter;
        final context = tester.element(find.byType(NoteVoiceChip));
        expect(painter.unplayed, colours(tester).quoteBar);
        expect(painter.played, Theme.of(context).colorScheme.primary);
        expect(painter.bars, 32);
        expect(tester.getSize(waveform()).width, 160);
        expect(
          tester.getSize(findKapyIcon(KapyIcons.playRounded)),
          Size.square(glyph),
          reason: 'centred in its button rather than stretched to fill it',
        );
        expect(surface(tester).borderRadius, BorderRadius.circular(10));
      }
    });

    testWidgets('draws its bars at the floor when it has no waveform', (
      tester,
    ) async {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
        on(platform);
        await tester.pumpWidget(harness(recording(), width: 350));
        expect(
          tester.renderObject(waveform()),
          paintsExactlyCountTimes(#drawLine, 32),
          reason: '$platform',
        );
      }
    });

    testWidgets('reads the time so far and the total while it plays', (
      tester,
    ) async {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
        on(platform);
        await tester.pumpWidget(
          harness(recording(peaks: peaks), playing: true, progress: 0.5),
        );
        expect(find.text('1:07 / 2:14'), findsOneWidget, reason: '$platform');
        await tester.pumpWidget(harness(recording(peaks: peaks)));
        expect(find.text('2:14'), findsOneWidget, reason: '$platform');
      }
    });

    testWidgets('keeps its waveform on a narrow phone when playback starts', (
      tester,
    ) async {
      on(TargetPlatform.iOS);
      final long = recording(durationMs: 723000, peaks: peaks);
      await tester.pumpWidget(harness(long, width: 280));
      final idle = tester.getSize(waveform()).width;
      expect(idle, lessThan(160));

      await tester.pumpWidget(
        harness(long, width: 280, playing: true, progress: 0.9),
      );
      expect(tester.getSize(waveform()).width, idle);
      expect(cut(tester, '10:50 / 12:03'), isFalse);
    });

    testWidgets('opens from anywhere but the play button, waveform and ×', (
      tester,
    ) async {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
        on(platform);
        final pointer = platform == TargetPlatform.macOS;
        var opened = 0;
        var played = 0;
        var removed = 0;
        final skips = <double>[];
        await tester.pumpWidget(
          harness(
            recording(peaks: peaks),
            state: VoiceChipState.transcribing,
            width: pointer ? 680 : 350,
            onOpen: () => opened++,
            onPlayPause: () => played++,
            onRemove: () => removed++,
            onSeekFraction: skips.add,
          ),
        );
        await tester.pumpAndSettle();
        final box = tester.getRect(find.byKey(card));
        final bars = tester.getRect(waveform());
        final reason = '$platform';
        Future<void> tapAt(Offset at) async {
          await tester.tapAt(at);
          await tester.pumpAndSettle();
        }

        await tapAt(tester.getCenter(findKapyIcon(KapyIcons.playRounded)));
        await tapAt(bars.center);
        await tapAt(Offset(bars.center.dx, box.bottom - 2));
        await tapAt(Offset(bars.left + 4, bars.top - 3));
        expect(played, 1, reason: reason);
        expect(skips, hasLength(3), reason: reason);
        expect(skips.first, moreOrLessEquals(0.5, epsilon: 0.01));
        expect(opened, 0, reason: reason);

        await tapAt(tester.getCenter(find.text('Voice note')));
        await tapAt(tester.getCenter(find.text('2:14')));
        await tapAt(Offset(box.right - (pointer ? 60 : 20), bars.center.dy));
        await tapAt(Offset(box.center.dx, box.top + 3));
        expect(opened, 4, reason: reason);

        if (pointer) {
          await tester.tap(find.byKey(const ValueKey('remove-voice-note')));
          await tester.pumpAndSettle();
          expect(removed, 1);
          expect(opened, 4);
        } else {
          expect(find.byKey(const ValueKey('remove-voice-note')), findsNothing);
        }
      }
    });

    testWidgets('lights up under the pointer and when pressed, but not for '
        'its own controls', (tester) async {
      on(TargetPlatform.macOS);
      await tester.pumpWidget(
        harness(
          recording(peaks: peaks),
          width: 680,
          onOpen: () {},
          onPlayPause: () {},
          onSeekFraction: (_) {},
          onRemove: () {},
        ),
      );
      await tester.pumpAndSettle();
      final palette = colours(tester);
      Color? arrow() => tester
          .widget<KapyIcon>(findKapyIcon(KapyIcons.chevronRightRounded))
          .color;
      expect(surface(tester).color, palette.controlBackground);
      expect(arrow(), palette.textTertiary);

      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 3,
      );
      await mouse.addPointer(location: const Offset(700, 500));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Voice note')));
      await tester.pump();
      expect(surface(tester).color, palette.hover);
      expect(
        (surface(tester).border! as Border).top.color,
        palette.keycapBorder,
      );
      expect(arrow(), palette.textSecondary);
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(surface(tester).color, palette.controlBackground);
      expect(arrow(), palette.textTertiary);

      final press = await tester.startGesture(
        tester.getCenter(find.text('Voice note')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(surface(tester).color, palette.selectedBackground);
      await press.up();
      await tester.pumpAndSettle();
      expect(surface(tester).color, palette.controlBackground);

      for (final control in [
        findKapyIcon(KapyIcons.playRounded),
        waveform(),
        find.byKey(const ValueKey('remove-voice-note')),
      ]) {
        final hold = await tester.startGesture(tester.getCenter(control));
        await tester.pump(const Duration(milliseconds: 200));
        expect(surface(tester).color, palette.controlBackground);
        await hold.up();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('reads as one button: its name, length and any status', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        harness(
          recording(summary: summary, transcript: transcript),
          state: VoiceChipState.done,
          onOpen: () {},
          onRemove: () {},
        ),
      );
      final titled = tester.getSemantics(
        find.bySemanticsLabel(
          'Standup thoughts on the pricing page and the launch, voice note, '
          '2:14',
        ),
      );
      expect(titled.hint, 'Open the summary and transcript');

      await tester.pumpWidget(
        harness(recording(), state: VoiceChipState.waiting, onOpen: () {}),
      );
      expect(
        find.bySemanticsLabel('Voice note, 2:14, Waiting for connection'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('offers Remove to a screen reader', (tester) async {
      final semantics = tester.ensureSemantics();
      var removed = 0;
      await tester.pumpWidget(
        harness(
          recording(),
          state: VoiceChipState.waiting,
          onOpen: () {},
          onRemove: () => removed++,
        ),
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel('Voice note, 2:14, Waiting for connection'),
      );
      final remove = CustomSemanticsAction.getIdentifier(
        const CustomSemanticsAction(label: 'Remove voice note'),
      );
      expect(node.getSemanticsData().customSemanticsActionIds, [remove]);
      node.owner!.performAction(node.id, SemanticsAction.customAction, remove);
      expect(removed, 1);
      semantics.dispose();
    });

    testWidgets('keeps to its column at the largest text sizes', (
      tester,
    ) async {
      for (final (platform, widths) in [
        (TargetPlatform.macOS, [347.0, 309.0, 232.0]),
        (TargetPlatform.iOS, [173.0, 143.0, 107.0]),
      ]) {
        on(platform);
        for (final width in widths) {
          final cards = [
            harness(
              recording(peaks: peaks, summary: summary),
              state: VoiceChipState.done,
              width: width,
              onRemove: () {},
            ),
            for (final state in statuses.keys)
              harness(
                recording(peaks: peaks),
                state: state,
                width: width,
                onRemove: () {},
              ),
            for (final state in [VoiceChipState.idle, VoiceChipState.waiting])
              harness(
                recording(durationMs: 723000, peaks: peaks),
                state: state,
                playing: true,
                progress: 0.9,
                width: width,
                onRemove: () {},
              ),
          ];
          for (final card in cards) {
            await tester.pumpWidget(card);
            expect(
              tester.takeException(),
              isNull,
              reason: '$platform at $width',
            );
          }
        }
      }
    });

    testWidgets('carries no × in a note that can only be read', (tester) async {
      on(TargetPlatform.macOS);
      await tester.pumpWidget(
        harness(recording(peaks: peaks), width: 680, onOpen: () {}),
      );
      expect(find.byKey(const ValueKey('remove-voice-note')), findsNothing);
    });
  });
}
