import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_player.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:material_ui/material_ui.dart';

import '../test_fonts.dart';

const anchor = NoteAttachmentRef.placeholder;

late CalcEngine engine;
late ShortcutPrefs shortcutPrefs;
late Directory tempDir;
late BlobStore store;
late String recordingHash;
late BlobStore immediateStore;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'voice-editor-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// A store that answers without touching the disk.
///
/// Real file I/O awaited inside `testWidgets` never completes — the body runs
/// in a fake-async zone — so the editor's `fileFor` would hang rather than
/// fail. The bytes are on disk from `setUpAll`; this only skips the `exists`
/// round trip that cannot finish here.
class _ImmediateBlobStore extends BlobStore {
  _ImmediateBlobStore({required super.directory, required this.file});

  final File file;

  @override
  Future<File?> fileFor(String hash) async => file;
}

class _FakeBackend implements VoicePlayerBackend {
  final positionController = StreamController<Duration>.broadcast();
  final completionController = StreamController<void>.broadcast();
  int plays = 0;
  Duration? seekedTo;

  @override
  Future<Duration?> load(File file) async => const Duration(seconds: 10);
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

NoteVoiceRef voice(int offset) => NoteVoiceRef(
  offset: offset,
  hash: recordingHash,
  key: Uint8List(32),
  bytes: 2048,
  durationMs: 10000,
  peaks: Uint8List.fromList(List.generate(100, (i) => 40 + i % 60)),
);

Widget harness(
  String body,
  List<NoteAttachmentRef> attachments, {
  VoicePlayer? player,
  BlobStore? images,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: NoteEditor(
      key: ValueKey(body),
      noteId: 'test',
      initialBody: body,
      initialAttachments: attachments,
      images: images ?? store,
      player: player,
      engine: engine,
      highlighter: Highlighter(engine.registry),
      gutterWidth: 160,
      resultsVisible: true,
      writingFont: WritingFont.handwritten,
      shortcuts: shortcutPrefs,
      onDocumentChanged: (body, formats, refs) {},
      onGutterWidthChanged: (_) {},
      onResultsVisibilityChanged: (_) {},
      onGutterWidthReset: () {},
      onSettingsPressed: () {},
    ),
  ),
);

EditableTextState field(WidgetTester tester) =>
    tester.state<EditableTextState>(find.byType(EditableText));

Rect caretFor(WidgetTester tester, int offset) => field(
  tester,
).renderEditable.getLocalRectForCaret(TextPosition(offset: offset));

void main() {
  setUpAll(() async {
    await loadTestFonts();
    engine = CalcEngine();
    tempDir = await Directory.systemTemp.createTemp('kapy-voice-editor');
    store = BlobStore(directory: tempDir);
    recordingHash = await store.put(
      Uint8List.fromList(List.filled(2048, 7)),
      extension: '.m4a',
    );
    immediateStore = _ImmediateBlobStore(
      directory: tempDir,
      file: (await store.fileFor(recordingHash))!,
    );
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  tearDownAll(() => tempDir.delete(recursive: true));

  group('the line after a recording', () {
    testWidgets('exists, and is where a click below the chip lands', (
      tester,
    ) async {
      // What recording at the end of a note leaves behind: the chip, then one
      // empty line. Flutter will not lay that line out if the placeholder
      // above it fills the width to the pixel — the caret collapses onto the
      // chip's own line, behind the chip, where the chip's tap handler eats
      // the click and opens the recording instead. There was nowhere to write.
      await tester.pumpWidget(harness('$anchor\n', [voice(0)]));
      await tester.pumpAndSettle();

      final chip = tester.getRect(find.byType(NoteVoiceChip));
      final editable = tester.getRect(find.byType(EditableText));
      final caret = caretFor(tester, 2);

      // The behaviour below follows from this, and only from this. Without it
      // the chip is a placeholder filling its line to the pixel, and the line
      // under it is never laid out at all.
      // Four, not noteAttachmentColumnSlack: a test that measures itself
      // against the constant it is guarding passes whatever the constant says,
      // including zero. Four is the measured floor — the line under a
      // placeholder survives from three pixels of slack and disappears at two,
      // at every font size from 12pt to 40pt.
      expect(
        editable.width - chip.width,
        greaterThan(4),
        reason: 'a chip must not fill its line edge to edge',
      );

      expect(
        caret.left,
        lessThan(4),
        reason:
            'the empty line starts at the left margin, not at the far edge '
            'of the line above it',
      );
      expect(
        caret.top + editable.top,
        greaterThanOrEqualTo(chip.bottom - 1),
        reason: 'and sits below the chip rather than inside it',
      );

      await tester.tapAt(
        Offset(editable.left + 40, editable.top + caret.top + caret.height / 2),
      );
      await tester.pumpAndSettle();

      expect(field(tester).textEditingValue.selection.baseOffset, 2);
    });

    testWidgets('is still there under a picture', (tester) async {
      // The same shape, and the same fix: an image is a placeholder too, and
      // a note ending in one had the same missing line.
      await tester.pumpWidget(
        harness('$anchor\n', [
          NoteImageRef(
            offset: 0,
            hash: 'nope',
            key: Uint8List(32),
            mime: 'image/png',
            width: 800,
            height: 600,
            bytes: 1024,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(caretFor(tester, 2).left, lessThan(4));
    });

    testWidgets('a recording mid-note still reads normally', (tester) async {
      await tester.pumpWidget(harness('$anchor\nafter', [voice(0)]));
      await tester.pumpAndSettle();

      final caret = caretFor(tester, 2);
      expect(caret.left, lessThan(4));
      expect(caret.top, greaterThan(caretFor(tester, 0).top + 30));
    });
  });

  group('the chip and the player', () {
    testWidgets('stops offering to pause once the recording ends', (
      tester,
    ) async {
      // Nothing listened to the player, so the chip kept the pause button it
      // was last built with after the audio had finished.
      final backend = _FakeBackend();
      final player = VoicePlayer(backend: backend);

      await tester.pumpWidget(
        harness(
          '$anchor\n',
          [voice(0)],
          player: player,
          images: immediateStore,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Play'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);

      backend.completionController.add(null);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Play'), findsOneWidget);
      expect(find.bySemanticsLabel('Pause'), findsNothing);

      // Released here rather than in a tearDown: a finished recording arms the
      // five minute idle timer, and the test binding checks for pending timers
      // before tearDowns run.
      player.dispose();
    });

    testWidgets('starts from the point tapped on an untouched waveform', (
      tester,
    ) async {
      // A tap on a waveform aims at a moment. It used to be dropped unless
      // that recording was already the one loaded, which is the one case where
      // the user has least reason to aim.
      final backend = _FakeBackend();
      final player = VoicePlayer(backend: backend);

      await tester.pumpWidget(
        harness(
          '$anchor\n',
          [voice(0)],
          player: player,
          images: immediateStore,
        ),
      );
      await tester.pumpAndSettle();

      final waveform = tester.getRect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is VoiceWaveformPainter,
        ),
      );
      await tester.tapAt(waveform.center);
      await tester.pumpAndSettle();

      expect(player.activeHash, recordingHash);
      expect(backend.plays, 1);
      expect(
        backend.seekedTo!.inMilliseconds,
        closeTo(5000, 900),
        reason: 'halfway along a ten second recording',
      );

      player.dispose();
    });
  });
}
