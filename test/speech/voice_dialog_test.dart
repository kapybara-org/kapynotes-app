import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_player.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:kapy_notes/ui/voice_note_dialog.dart';
import 'package:material_ui/material_ui.dart';

import '../test_fonts.dart';

/// Hands the player a file without touching the disk: real file I/O awaited
/// inside `testWidgets` runs in a fake-async zone and never completes. The
/// fake backend never reads it.
Future<File?> _alreadyHere(String hash) async => File('/tmp/$hash.m4a');

class _FakeBackend implements VoicePlayerBackend {
  final positionController = StreamController<Duration>.broadcast();
  final completionController = StreamController<void>.broadcast();
  int plays = 0;
  Duration? seekedTo;

  Duration length = const Duration(seconds: 60);

  @override
  Future<Duration?> load(File file) async => length;
  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async => seekedTo = position;
  @override
  Future<void> setSpeed(double value) async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<Duration> get positions => positionController.stream;
  @override
  Stream<void> get completions => completionController.stream;
  @override
  Future<void> dispose() async {}
}

NoteVoiceRef recording({
  String hash = 'a',
  VoiceTranscript? transcript,
  VoiceSummary? summary,
}) => NoteVoiceRef(
  offset: 0,
  hash: hash,
  key: Uint8List(32),
  bytes: 2048,
  durationMs: 60000,
  peaks: Uint8List.fromList(List.filled(100, 128)),
  transcript: transcript,
  summary: summary,
);

Widget harness(
  NoteVoiceRef ref,
  VoicePlayer player, {
  VoiceChipState state = VoiceChipState.done,
  VoiceNoteActions actions = const VoiceNoteActions(),
  DateTime? recordedAt,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: VoiceNoteView(
      ref: ref,
      state: state,
      player: player,
      actions: actions,
      recordedAt: recordedAt,
    ),
  ),
);

VoiceTranscript twoLines() => VoiceTranscript(
  lang: 'en',
  engine: 'test',
  at: 1,
  segments: const [
    TranscriptSegment(s: 0, e: 1000, t: 'First thing.'),
    TranscriptSegment(s: 30000, e: 31000, t: 'Second thing.'),
  ],
);

/// Forty paragraphs ten seconds apart, more than the window shows at once.
VoiceTranscript long() => VoiceTranscript(
  lang: 'en',
  engine: 'test',
  at: 1,
  segments: [
    for (var i = 0; i < 40; i++)
      TranscriptSegment(
        s: i * 10000,
        e: i * 10000 + 2000,
        t: 'Paragraph $i says what it says.',
      ),
  ],
);

VoiceSummary aSummary() => VoiceSummary(
  engine: 'test',
  at: 1,
  title: 'Standup',
  points: const ['Book the train for Friday.', 'Call the landlord about rent.'],
);

VoiceTranscript planning() => VoiceTranscript(
  lang: 'en',
  engine: 'test',
  at: 1,
  segments: const [
    TranscriptSegment(s: 0, e: 2000, t: 'We should ship the export fix today.'),
    TranscriptSegment(
      s: 30000,
      e: 32000,
      t: 'I will book the train on Friday morning.',
    ),
  ],
);

final _scrubber = find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is VoiceWaveformPainter,
);

Future<void> openMore(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  testWidgets('the elapsed time follows the recording as it plays', (
    tester,
  ) async {
    // The player deliberately does not notify its listeners as the head moves
    // — that would rebuild the editor four times a second — so this row was
    // built against a figure that only ever changed when playback started or
    // stopped. It sat at 0:00 for the whole recording.
    final backend = _FakeBackend();
    final player = VoicePlayer(backend: backend, files: _alreadyHere);

    await tester.pumpWidget(harness(recording(), player));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();
    expect(find.text('0:00 / 1:00'), findsOneWidget);

    backend.positionController.add(const Duration(seconds: 21));
    await tester.pumpAndSettle();

    expect(find.text('0:21 / 1:00'), findsOneWidget);

    player.dispose();
  });

  testWidgets('says when a recording from another device could not come down', (
    tester,
  ) async {
    // No connection, or not uploaded yet by the device that recorded it. The
    // button used to stay an ordinary play button that did nothing at all.
    final backend = _FakeBackend();
    final player = VoicePlayer(backend: backend, files: (_) async => null);

    await tester.pumpWidget(harness(recording(), player));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();

    expect(find.byTooltip("Couldn't download. Try again"), findsOneWidget);
    expect(backend.plays, 0);

    player.dispose();
  });

  testWidgets('a local transcript remains readable while cloud summary waits', (
    tester,
  ) async {
    final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
    final ref = recording(
      transcript: VoiceTranscript(
        lang: 'en',
        engine: 'local',
        at: 1,
        segments: [TranscriptSegment(s: 0, e: 900, t: 'Kept on this device.')],
      ),
    );

    await tester.pumpWidget(
      harness(ref, player, state: VoiceChipState.needsAccount),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Kept on this device.'), findsOneWidget);
    expect(find.text('Sign in to get text and a summary.'), findsNothing);
    player.dispose();
  });

  testWidgets('signed out points to the transcription choice, not sign in', (
    tester,
  ) async {
    final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
    var openedSettings = false;

    await tester.pumpWidget(
      harness(
        recording(),
        player,
        state: VoiceChipState.needsAccount,
        actions: VoiceNoteActions(
          onTurnOnTranscription: () => openedSettings = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Choose cloud or local transcription in Settings.'),
      findsOneWidget,
    );
    expect(find.textContaining('Sign in'), findsNothing);
    await tester.tap(find.text('Turn on transcription'));
    expect(openedSettings, isTrue);
    player.dispose();
  });

  group('tapping a line of the transcript', () {
    final transcript = VoiceTranscript(
      lang: 'en',
      engine: 'test',
      at: 1,
      segments: const [
        TranscriptSegment(s: 0, e: 1000, t: 'First thing.'),
        TranscriptSegment(s: 30000, e: 31000, t: 'Second thing.'),
      ],
    );

    testWidgets('starts this recording there when nothing is playing', (
      tester,
    ) async {
      // It used to go straight to the player, which only seeks what it is
      // already holding — so reading the transcript and tapping the line you
      // wanted to hear did nothing at all.
      final backend = _FakeBackend();
      final player = VoicePlayer(backend: backend, files: _alreadyHere);

      await tester.pumpWidget(
        harness(recording(transcript: transcript), player),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Second thing'));
      await tester.pumpAndSettle();

      // play, not seek: seeking is what the old code did, and the player
      // seeks whatever it is holding — which with another note's recording
      // running was that one. Taking the player over is checked in
      // voice_player_test.dart; what matters here is which call is made.
      expect(player.activeHash, 'a');
      expect(backend.plays, 1);
      expect(backend.seekedTo, const Duration(seconds: 30));

      player.dispose();
    });
  });

  testWidgets('the header gives the day, time and length', (tester) async {
    final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
    await tester.pumpWidget(
      harness(recording(), player, recordedAt: DateTime(2025, 11, 19, 8, 55)),
    );
    expect(find.text('Wed 19 Nov 2025 · 8:55 · 1:00'), findsOneWidget);
    expect(find.text('Voice note'), findsOneWidget);

    final thisYear = DateTime(DateTime.now().year, 1, 5, 14, 3);
    await tester.pumpWidget(harness(recording(), player, recordedAt: thisYear));
    expect(find.textContaining('5 Jan · 14:03 · 1:00'), findsOneWidget);
    expect(find.textContaining('${thisYear.year}'), findsNothing);
    player.dispose();
  });

  group('the player', () {
    testWidgets('dragging a recording not yet playing starts it on release', (
      tester,
    ) async {
      final backend = _FakeBackend();
      final player = VoicePlayer(backend: backend, files: _alreadyHere);
      await tester.pumpWidget(harness(recording(), player));

      final box = tester.getRect(_scrubber);
      final gesture = await tester.startGesture(
        box.centerLeft + const Offset(4, 0),
      );
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveTo(box.center);
      await tester.pump();
      // A preview while the finger is down: nothing has started yet.
      expect(find.text('0:30 / 1:00'), findsOneWidget);
      expect(backend.plays, 0);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(backend.plays, 1);
      expect(backend.seekedTo, const Duration(seconds: 30));
      player.dispose();
    });

    testWidgets('a tap on the waveform of a playing recording seeks it', (
      tester,
    ) async {
      final backend = _FakeBackend();
      final player = VoicePlayer(backend: backend, files: _alreadyHere);
      await tester.pumpWidget(harness(recording(), player));
      await tester.tap(find.byTooltip('Play'));
      await tester.pumpAndSettle();

      await tester.tapAt(tester.getCenter(_scrubber));
      await tester.pumpAndSettle();
      expect(backend.seekedTo, const Duration(seconds: 30));
      expect(backend.plays, 1);
      player.dispose();
    });

    testWidgets('a press while it is on its way calls it off', (tester) async {
      final arriving = Completer<File?>();
      final backend = _FakeBackend();
      final player = VoicePlayer(
        backend: backend,
        files: (_) => arriving.future,
      );
      await tester.pumpWidget(harness(recording(), player));
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(find.byTooltip('Cancel'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel'));
      await tester.pump();
      arriving.complete(File('/tmp/a.m4a'));
      await tester.pumpAndSettle();
      expect(backend.plays, 0);
      expect(find.byTooltip('Play'), findsOneWidget);
      player.dispose();
    });

    testWidgets('the speed goes 1× → 1.5× → 2× and round', (tester) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      await tester.pumpWidget(harness(recording(), player));
      for (final next in ['1.5×', '2×', '1×']) {
        await tester.tap(find.byTooltip('Playback speed'));
        await tester.pumpAndSettle();
        expect(find.text(next), findsOneWidget);
      }
      player.dispose();
    });
  });

  group('the switch and Insert', () {
    testWidgets('open on Summary when there is one, and insert bullets', (
      tester,
    ) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      final inserted = <String>[];
      await tester.pumpWidget(
        harness(
          recording(transcript: planning(), summary: aSummary()),
          player,
          actions: VoiceNoteActions(onInsert: inserted.add),
        ),
      );
      expect(find.text('Insert summary'), findsOneWidget);
      expect(find.byTooltip('Search transcript'), findsNothing);

      await tester.tap(find.text('Insert summary'));
      await tester.pumpAndSettle();
      expect(inserted, [
        '• Book the train for Friday.\n• Call the landlord about rent.',
      ]);
      player.dispose();
    });

    testWidgets('Transcript inserts paragraphs, and says so', (tester) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      final inserted = <String>[];
      await tester.pumpWidget(
        harness(
          recording(transcript: twoLines(), summary: aSummary()),
          player,
          actions: VoiceNoteActions(onInsert: inserted.add),
        ),
      );
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(find.text('Insert transcript'), findsOneWidget);
      expect(find.text('Insert summary'), findsNothing);
      expect(find.byTooltip('Search transcript'), findsOneWidget);

      await tester.tap(find.text('Insert transcript'));
      await tester.pumpAndSettle();
      expect(inserted, ['First thing.\nSecond thing.']);
      player.dispose();
    });

    testWidgets('open on Transcript when there is no summary', (tester) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      await tester.pumpWidget(
        harness(recording(transcript: twoLines()), player),
      );
      expect(find.text('Insert transcript'), findsOneWidget);
      expect(find.textContaining('First thing'), findsOneWidget);
      player.dispose();
    });

    testWidgets('Insert does nothing in a note that cannot be edited', (
      tester,
    ) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      await tester.pumpWidget(
        harness(recording(transcript: twoLines(), summary: aSummary()), player),
      );
      await tester.tap(find.text('Insert summary'));
      await tester.pumpAndSettle();
      expect(find.text('Insert summary'), findsOneWidget);
      expect(tester.takeException(), isNull);
      player.dispose();
    });
  });

  group('the summary', () {
    testWidgets('times a point from the transcript, and plays it', (
      tester,
    ) async {
      final backend = _FakeBackend();
      final player = VoicePlayer(backend: backend, files: _alreadyHere);
      await tester.pumpWidget(
        harness(recording(transcript: planning(), summary: aSummary()), player),
      );

      // "Call the landlord" was never said, so it gets no time at all.
      expect(find.byTooltip('Play from 0:30'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').startsWith('Play from'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Play from 0:30'));
      await tester.pumpAndSettle();
      expect(player.activeHash, 'a');
      expect(backend.plays, 1);
      expect(backend.seekedTo, const Duration(seconds: 30));
      player.dispose();
    });

    testWidgets('has no times without a transcript to take them from', (
      tester,
    ) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      await tester.pumpWidget(harness(recording(summary: aSummary()), player));
      expect(find.textContaining('Book the train'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').startsWith('Play from'),
        ),
        findsNothing,
      );
      player.dispose();
    });
  });

  group('the transcript', () {
    testWidgets('lights the paragraph playing and keeps it in view', (
      tester,
    ) async {
      final backend = _FakeBackend()..length = const Duration(seconds: 400);
      final player = VoicePlayer(backend: backend, files: _alreadyHere);
      await tester.pumpWidget(harness(recording(transcript: long()), player));
      final palette = tester.element(find.byType(VoiceNoteView)).palette;
      Color? timeColour(String time) =>
          tester.widget<Text>(find.text(time)).style?.color;

      expect(find.textContaining('Paragraph 35 says'), findsNothing);
      await tester.tap(find.byTooltip('Play'));
      await tester.pumpAndSettle();
      expect(timeColour('0:00'), palette.accentText);

      backend.positionController.add(const Duration(seconds: 352));
      await tester.pumpAndSettle();

      final lit = find.textContaining('Paragraph 35 says');
      expect(lit, findsOneWidget);
      final list = tester.getRect(find.byType(ListView));
      final row = tester.getRect(lit);
      expect(row.top, greaterThanOrEqualTo(list.top));
      expect(row.bottom, lessThanOrEqualTo(list.bottom));
      expect(timeColour('5:50'), palette.accentText);
      expect(timeColour('5:40'), palette.textTertiary);
      player.dispose();
    });

    testWidgets('lights nothing while another recording plays', (tester) async {
      final backend = _FakeBackend();
      final player = VoicePlayer(backend: backend, files: _alreadyHere);
      await tester.pumpWidget(
        harness(recording(transcript: twoLines()), player),
      );
      final palette = tester.element(find.byType(VoiceNoteView)).palette;
      await player.play('b');
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('0:00')).style?.color,
        palette.textTertiary,
      );
      player.dispose();
    });

    testWidgets('search finds, counts and steps through matches', (
      tester,
    ) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      await tester.pumpWidget(harness(recording(transcript: long()), player));
      await tester.tap(find.byTooltip('Search transcript'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'SAYS WHAT');
      await tester.pumpAndSettle();
      expect(find.text('1 of 40'), findsOneWidget);

      await tester.tap(find.byTooltip('Previous match'));
      await tester.pumpAndSettle();
      expect(find.text('40 of 40'), findsOneWidget);
      // The last paragraph is brought into view.
      final list = tester.getRect(find.byType(ListView));
      final row = tester.getRect(find.textContaining('Paragraph 39 says'));
      expect(row.bottom, lessThanOrEqualTo(list.bottom));

      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(find.text('1 of 40'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Paragraph 38 says');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('1 of 1'), findsOneWidget);
      expect(find.textContaining('Paragraph 38 says what'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zebra');
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
      final next = find.ancestor(
        of: find.byTooltip('Next match'),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(next).onPressed, isNull);
      player.dispose();
    });

    testWidgets('search closes with its button and with Escape', (
      tester,
    ) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      await tester.pumpWidget(
        harness(recording(transcript: twoLines()), player),
      );
      await tester.tap(find.byTooltip('Search transcript'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byTooltip('Search transcript'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      player.dispose();
    });

    testWidgets('names its language', (tester) async {
      final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
      await tester.pumpWidget(
        harness(recording(transcript: twoLines()), player),
      );
      expect(find.text('Transcribed · English'), findsOneWidget);

      final unknown = VoiceTranscript(
        lang: 'xx',
        engine: 'test',
        at: 2,
        segments: const [TranscriptSegment(s: 0, e: 900, t: 'Hm.')],
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(harness(recording(transcript: unknown), player));
      expect(find.text('Transcribed · xx'), findsOneWidget);
      player.dispose();
    });

    test('speakers get two colours from the tag wheel', () {
      final palette = KapyTheme.dark().extension<CalcPalette>()!;
      expect(speakerColor(palette, 0), TagColour.teal.dot(palette));
      expect(speakerColor(palette, 1), TagColour.mustard.dot(palette));
      expect(speakerColor(palette, 0), isNot(speakerColor(palette, 1)));
    });
  });

  testWidgets('transcribing shows the small pie, not a bar', (tester) async {
    final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
    await tester.pumpWidget(
      harness(recording(), player, state: VoiceChipState.transcribing),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Transcribing…'), findsOneWidget);
    expect(find.byType(SettingsPie), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    player.dispose();
  });

  group('More', () {
    late List<String> copied;

    setUp(() {
      copied = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    Future<VoicePlayer> open(
      WidgetTester tester, {
      NoteVoiceRef? ref,
      VoiceNoteActions actions = const VoiceNoteActions(),
      VoiceFileLocator? files,
    }) async {
      final player = VoicePlayer(
        backend: _FakeBackend(),
        files: files ?? _alreadyHere,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        harness(
          ref ?? recording(transcript: twoLines(), summary: aSummary()),
          player,
          actions: actions,
        ),
      );
      await openMore(tester);
      return player;
    }

    testWidgets('is a menu on a computer, in order', (tester) async {
      await open(
        tester,
        actions: VoiceNoteActions(
          onChanged: (_) {},
          onDelete: () {},
          onTranscribeAgain: () {},
          onRegenerateSummary: () {},
        ),
      );
      expect(find.byType(BottomSheet), findsNothing);
      final labels = tester
          .widgetList<KapyMenuActionRow>(find.byType(KapyMenuActionRow))
          .map((row) => row.action.label)
          .toList();
      expect(labels, [
        'Rename',
        'Copy summary',
        'Copy transcript',
        'Save audio…',
        'Skip pauses',
        'Transcribe again',
        'Regenerate summary',
        'Delete voice note',
      ]);
      expect(find.byType(PopupMenuDivider), findsNWidgets(3));
      // Under the button, its right edge on the button's.
      final button = tester.getRect(find.byTooltip('More'));
      final menu = tester.getRect(find.byType(KapyContextMenuSurface));
      expect(menu.top, greaterThan(button.bottom));
      expect(menu.right, moreOrLessEquals(button.right, epsilon: 1));
    });

    testWidgets('is a sheet on a phone', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await open(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Save audio…'), findsOneWidget);
      await tester.tap(find.text('Copy transcript'));
      await tester.pumpAndSettle();
      expect(copied, ['First thing.\nSecond thing.']);
    });

    testWidgets('Rename names the recording and keeps it', (tester) async {
      final changed = <NoteVoiceRef>[];
      await open(tester, actions: VoiceNoteActions(onChanged: changed.add));
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Rename recording'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  Pricing plan  ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Pricing plan'), findsOneWidget);
      expect(changed.single.summary!.title, 'Pricing plan');
      expect(changed.single.summary!.named, isTrue);
      expect(changed.single.summary!.points, aSummary().points);
    });

    testWidgets('Rename keeps the name when nothing is typed', (tester) async {
      final changed = <NoteVoiceRef>[];
      await open(tester, actions: VoiceNoteActions(onChanged: changed.add));
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(changed, isEmpty);
      expect(find.text('Standup'), findsOneWidget);
    });

    testWidgets('has no Rename without a summary, or in a read-only note', (
      tester,
    ) async {
      await open(
        tester,
        ref: recording(transcript: twoLines()),
        actions: VoiceNoteActions(onChanged: (_) {}),
      );
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Copy summary'), findsNothing);
      expect(find.text('Regenerate summary'), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await open(tester);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Delete voice note'), findsNothing);
    });

    testWidgets('Copy summary copies the points', (tester) async {
      await open(tester);
      await tester.tap(find.text('Copy summary'));
      await tester.pumpAndSettle();
      expect(copied, [
        '• Book the train for Friday.\n• Call the landlord about rent.',
      ]);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('Copy transcript copies the paragraphs', (tester) async {
      await open(tester);
      await tester.tap(find.text('Copy transcript'));
      await tester.pumpAndSettle();
      expect(copied, ['First thing.\nSecond thing.']);
    });

    testWidgets('Save audio says when the audio is not on this device', (
      tester,
    ) async {
      await open(tester, files: (_) async => null);
      await tester.tap(find.text('Save audio…'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "The audio isn't on this device yet. Try again once you're online.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('Save audio says when saving failed', (tester) async {
      await open(
        tester,
        files: (_) async => throw const FileSystemException('x'),
      );
      await tester.tap(find.text('Save audio…'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't save the audio. Try again."), findsOneWidget);
    });

    testWidgets('Skip pauses is a checked toggle on the player', (
      tester,
    ) async {
      final player = await open(tester);
      KapyMenuAction skip() => tester
          .widget<KapyMenuActionRow>(
            find.ancestor(
              of: find.text('Skip pauses'),
              matching: find.byType(KapyMenuActionRow),
            ),
          )
          .action;
      expect(skip().checked, isFalse);
      await tester.tap(find.text('Skip pauses'));
      await tester.pumpAndSettle();
      expect(player.skipPauses, isTrue);

      await openMore(tester);
      expect(skip().checked, isTrue);
      await tester.tap(find.text('Skip pauses'));
      await tester.pumpAndSettle();
      expect(player.skipPauses, isFalse);
    });

    testWidgets('Transcribe again and Regenerate summary ask for them', (
      tester,
    ) async {
      final asked = <String>[];
      final actions = VoiceNoteActions(
        onTranscribeAgain: () => asked.add('again'),
        onRegenerateSummary: () => asked.add('regenerate'),
      );
      await open(tester, actions: actions);
      await tester.tap(find.text('Transcribe again'));
      await tester.pumpAndSettle();
      await openMore(tester);
      await tester.tap(find.text('Regenerate summary'));
      await tester.pumpAndSettle();
      expect(asked, ['again', 'regenerate']);
    });

    testWidgets('Delete asks first, and Cancel keeps it', (tester) async {
      var deleted = 0;
      await open(tester, actions: VoiceNoteActions(onDelete: () => deleted++));
      await tester.tap(find.text('Delete voice note'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this voice note?'), findsOneWidget);
      expect(
        find.text('Removes the audio, transcript, and summary.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deleted, 0);

      await openMore(tester);
      await tester.tap(find.text('Delete voice note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(deleted, 1);
    });
  });

  testWidgets('a phone fits both sides at 360 wide', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = VoicePlayer(backend: _FakeBackend(), files: _alreadyHere);
    await tester.pumpWidget(
      harness(
        recording(transcript: twoLines(), summary: aSummary()),
        player,
        actions: VoiceNoteActions(onInsert: (_) {}),
        recordedAt: DateTime(2025, 11, 19, 8, 55),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    expect(find.text('Insert transcript'), findsOneWidget);
    expect(find.byTooltip('Search transcript'), findsOneWidget);
    expect(tester.takeException(), isNull);
    player.dispose();
  });
}
