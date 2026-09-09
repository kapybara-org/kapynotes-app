import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_player.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:kapy_notes/ui/voice_note_dialog.dart';
import 'package:material_ui/material_ui.dart';

import '../test_fonts.dart';

late Directory tempDir;
late BlobStore store;

/// Answers without touching the disk: real file I/O awaited inside
/// `testWidgets` runs in a fake-async zone and never completes.
class _ImmediateBlobStore extends BlobStore {
  _ImmediateBlobStore({required Directory directory})
    : _directory = directory,
      super(directory: directory);

  final Directory _directory;

  @override
  Future<File?> fileFor(String hash) async => File('${_directory.path}/$hash');
}

class _FakeBackend implements VoicePlayerBackend {
  final positionController = StreamController<Duration>.broadcast();
  final completionController = StreamController<void>.broadcast();
  int plays = 0;
  Duration? seekedTo;

  @override
  Future<Duration?> load(File file) async => const Duration(seconds: 60);
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

NoteVoiceRef recording({String hash = 'a', VoiceTranscript? transcript}) =>
    NoteVoiceRef(
      offset: 0,
      hash: hash,
      key: Uint8List(32),
      bytes: 2048,
      durationMs: 60000,
      transcript: transcript,
    );

Widget harness(NoteVoiceRef ref, VoicePlayer player) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: VoiceNoteView(
      ref: ref,
      state: VoiceChipState.done,
      blobs: store,
      player: player,
    ),
  ),
);

void main() {
  setUpAll(() async {
    await loadTestFonts();
    tempDir = await Directory.systemTemp.createTemp('kapy-voice-dialog');
    store = _ImmediateBlobStore(directory: tempDir);
  });

  tearDownAll(() => tempDir.delete(recursive: true));

  testWidgets('the elapsed time follows the recording as it plays', (
    tester,
  ) async {
    // The player deliberately does not notify its listeners as the head moves
    // — that would rebuild the editor four times a second — so this row was
    // built against a figure that only ever changed when playback started or
    // stopped. It sat at 0:00 for the whole recording.
    final backend = _FakeBackend();
    final player = VoicePlayer(backend: backend);

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
      final player = VoicePlayer(backend: backend);

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
}
