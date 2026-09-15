import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout, kSecondaryButton;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/attachment_limits.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/images/image_clipboard.dart';
import 'package:kapy_notes/images/image_codec.dart';
import 'package:kapy_notes/images/image_ingest.dart';
import 'package:kapy_notes/images/image_picker.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_image_view.dart';
import 'package:kapy_notes/ui/editor/note_video_view.dart';
import 'package:kapy_notes/video/video_ingest.dart';
import 'package:kapy_notes/video/video_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../test_fonts.dart';

const anchor = NoteAttachmentRef.placeholder;

late CalcEngine engine;
late ShortcutPrefs shortcutPrefs;
late Directory tempDir;
late BlobStore store;
late BlobStore immediateStore;

/// Refs prepared once, outside any test body.
///
/// Every byte of this has to be written before `testWidgets` starts: a test
/// body runs inside a fake-async zone where real file I/O never completes, so
/// awaiting a disk write in there hangs the run rather than failing it.
late List<NoteImageRef> refs;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'note-image-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

class _ImmediateBlobStore extends BlobStore {
  _ImmediateBlobStore({required Directory directory, required this.bytesByHash})
    : super(directory: directory);

  final Map<String, Uint8List> bytesByHash;

  @override
  Future<Uint8List?> read(String hash) async => bytesByHash[hash];

  @override
  Future<String> put(Uint8List bytes, {String extension = ''}) async {
    final hash = BlobStore.hashOf(bytes);
    bytesByHash[hash] = bytes;
    return hash;
  }
}

/// A real, decodable PNG of the given size, so the editor is exercising the
/// actual image pipeline rather than a stub.
Uint8List pngOf(int width, int height, {int seed = 0}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(20 + seed * 40, 120, 200));
  return Uint8List.fromList(img.encodePng(image, level: 1));
}

Future<NoteImageRef> storeImage({
  int width = 800,
  int height = 600,
  int seed = 0,
}) async {
  final bytes = pngOf(width, height, seed: seed);
  final hash = await store.put(bytes);
  return NoteImageRef(
    offset: 0,
    hash: hash,
    key: Uint8List(32),
    mime: 'image/png',
    width: width,
    height: height,
    bytes: bytes.length,
  );
}

/// Ctrl/Cmd-Z through the real shortcut path, so the test exercises what a
/// user's keyboard does rather than a method only tests call.
/// One of the prepared images, anchored where the caller needs it.
NoteImageRef at(int offset, {int which = 0}) =>
    refs[which].copyWith(offset: offset);

NoteVideoRef videoAt(int offset) => NoteVideoRef(
  offset: offset,
  hash: 'video-that-is-not-local',
  key: Uint8List(32),
  mime: 'video/mp4',
  bytes: 1024,
  width: 1920,
  height: 1080,
  durationMs: 95000,
);

Future<void> sendShortcut(WidgetTester tester, ShortcutBinding binding) async {
  if (binding.meta) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  }
  if (binding.control) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  }
  if (binding.alt) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  }
  if (binding.shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyEvent(binding.logicalKey);
  if (binding.shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  if (binding.alt) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  }
  if (binding.control) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  if (binding.meta) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }
}

/// A clipboard that holds whatever a test puts on it.
class FakeClipboard implements ImageClipboard {
  FakeClipboard({
    this.image,
    this.files = const [],
    this.fragment,
    this.onReadImage,
  });

  ClipboardImage? image;
  List<String> files;
  NoteClipboardFragment? fragment;
  VoidCallback? onReadImage;
  int reads = 0;
  final List<NoteClipboardFragment> writes = [];
  Completer<void>? _nextWrite;

  Future<void> waitForWrite() {
    if (writes.isNotEmpty) return Future.value();
    return (_nextWrite ??= Completer<void>()).future;
  }

  @override
  Future<NoteClipboardFragment?> readFragment() async => fragment;

  @override
  Future<void> writeFragment(NoteClipboardFragment fragment) async {
    writes.add(fragment);
    _nextWrite?.complete();
    _nextWrite = null;
  }

  @override
  Future<ClipboardImage?> readImage() async {
    reads++;
    onReadImage?.call();
    return image;
  }

  @override
  Future<List<String>> readImageFiles() async => files;
}

Widget harness(
  String body, {
  required List<NoteAttachmentRef> attachments,
  BlobStore? images,
  ImageClipboard? clipboard,
  ValueChanged<List<NoteAttachmentRef>>? onAttachmentsChanged,
  GlobalKey<NoteEditorState>? editorKey,
  ImageFileAcquirer? imageAcquirer,
  ImageBatchIngestor? imageIngestor,
  Future<ImageIngestResult> Function(StagedImage staged, BlobStore store)?
  imageFinalizer,
  ImagePrepared? onImagePrepared,
  VideoFileAcquirer? videoAcquirer,
  VideoBatchIngestor? videoIngestor,
  int Function()? videoAttachmentMaxBytes,
  AttachmentUploadProgressFor? uploadProgressFor,
  bool startAtEnd = false,
  bool readOnly = false,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: NoteEditor(
      // Keyed by body so re-pumping with different text remounts the editor,
      // the way switching notes does in the app.
      key: editorKey ?? ValueKey(body),
      noteId: 'test',
      initialBody: body,
      initialAttachments: attachments,
      images: images ?? store,
      clipboard: clipboard ?? FakeClipboard(),
      imageAcquirer: imageAcquirer,
      imageIngestor: imageIngestor,
      imageFinalizer: imageFinalizer,
      onImagePrepared: onImagePrepared,
      videoAcquirer: videoAcquirer,
      videoIngestor: videoIngestor,
      videoAttachmentMaxBytes: videoAttachmentMaxBytes,
      uploadProgressFor: uploadProgressFor,
      startAtEnd: startAtEnd,
      readOnly: readOnly,
      engine: engine,
      highlighter: Highlighter(engine.registry),
      gutterWidth: 160,
      resultsVisible: true,
      writingFont: WritingFont.handwritten,
      shortcuts: shortcutPrefs,
      onDocumentChanged: (body, formats, refs) =>
          onAttachmentsChanged?.call(refs),
      onGutterWidthChanged: (_) {},
      onResultsVisibilityChanged: (_) {},
      onGutterWidthReset: () {},
      onSettingsPressed: () {},
    ),
  ),
);

/// Top of the line containing [offset], in the editable's own coordinates.
///
/// The render box itself is no use here: the field expands to fill the pane,
/// so its height is the viewport's whatever the note contains. Caret geometry
/// is what actually moves when a line grows to hold a picture.
double lineTop(WidgetTester tester, int offset) => tester
    .state<EditableTextState>(find.byType(EditableText))
    .renderEditable
    .getLocalRectForCaret(TextPosition(offset: offset))
    .top;

void main() {
  setUpAll(() async {
    await loadTestFonts();
    engine = CalcEngine();
    tempDir = await Directory.systemTemp.createTemp('kapy-image-test');
    store = BlobStore(directory: tempDir);
    refs = [for (var seed = 0; seed < 4; seed++) await storeImage(seed: seed)];
    immediateStore = _ImmediateBlobStore(
      directory: tempDir,
      bytesByHash: {
        for (final ref in refs) ref.hash: (await store.read(ref.hash))!,
      },
    );
  });

  tearDownAll(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  setUp(() {
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  testWidgets('an image renders in place of its placeholder', (tester) async {
    final ref = at(6);
    await tester.pumpWidget(
      harness('above\n$anchor\nbelow', attachments: [ref]),
    );
    await tester.pump();

    expect(find.byType(NoteImageView), findsOneWidget);
  });

  testWidgets('the image line grows to hold it', (tester) async {
    // A plain three-line note: every row is the editor's fixed 29px.
    await tester.pumpWidget(
      harness('above\nmiddle\nbelow', attachments: const []),
    );
    await tester.pump();
    final plainRow = lineTop(tester, 13) - lineTop(tester, 6);

    await tester.pumpWidget(
      harness('above\n$anchor\nbelow', attachments: [at(6)]),
    );
    await tester.pump();
    final imageRow = lineTop(tester, 8) - lineTop(tester, 6);

    expect(plainRow, closeTo(EditorMetrics.lineHeight, 0.5));
    // A 4:3 image across the writing column is far taller than a row of text.
    // With the strut still forced this would also come out at 29px, and the
    // picture would paint straight through "below".
    expect(imageRow, greaterThan(120));
  });

  testWidgets('one image fills the column; three become tiles', (tester) async {
    final single = at(0);
    await tester.pumpWidget(harness(anchor, attachments: [single]));
    await tester.pump();
    final wide = tester.getSize(find.byType(NoteImageView)).width;

    await tester.pumpWidget(
      harness(
        '$anchor$anchor$anchor',
        attachments: [at(0, which: 1), at(1, which: 2), at(2, which: 3)],
      ),
    );
    await tester.pump();

    final tiles = tester.widgetList<NoteImageView>(find.byType(NoteImageView));
    expect(tiles, hasLength(3));
    final tileWidth = tester.getSize(find.byType(NoteImageView).first).width;
    // Three across, so each is comfortably under half the single-image width.
    expect(tileWidth, lessThan(wide / 2));
    for (final tile in tiles) {
      expect(tile.box.cropped, isTrue);
    }
  });

  testWidgets('deleting the placeholder removes the image', (tester) async {
    final ref = at(1);
    List<NoteAttachmentRef>? reported;
    await tester.pumpWidget(
      harness(
        'a${anchor}b',
        attachments: [ref],
        onAttachmentsChanged: (refs) => reported = refs,
      ),
    );
    await tester.pump();
    expect(find.byType(NoteImageView), findsOneWidget);

    final state = tester.state<EditableTextState>(find.byType(EditableText));
    state.updateEditingValue(
      const TextEditingValue(
        text: 'ab',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();

    expect(reported, isEmpty);
    expect(find.byType(NoteImageView), findsNothing);
  });

  testWidgets('inserting images puts them on their own line', (tester) async {
    final editorKey = GlobalKey<NoteEditorState>();
    List<NoteAttachmentRef>? reported;
    await tester.pumpWidget(
      harness(
        'a note',
        attachments: const [],
        editorKey: editorKey,
        onAttachmentsChanged: (refs) => reported = refs,
      ),
    );
    await tester.pump();

    // Caret in the middle of the word, which the insert must not split around.
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    state.updateEditingValue(
      const TextEditingValue(
        text: 'a note',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();

    editorKey.currentState!.insertImages([at(0, which: 1), at(0, which: 2)]);
    await tester.pump();

    expect(reported, hasLength(2));
    expect(find.byType(NoteImageView), findsNWidgets(2));
    final text = tester
        .state<EditableTextState>(find.byType(EditableText))
        .textEditingValue
        .text;
    expect(text, 'a n\n$anchor$anchor\note');
  });

  testWidgets('typing beside an image moves the words under it', (
    tester,
  ) async {
    final ref = at(0);
    List<NoteAttachmentRef>? reported;
    await tester.pumpWidget(
      harness(
        anchor,
        attachments: [ref],
        onAttachmentsChanged: (refs) => reported = refs,
      ),
    );
    await tester.pump();

    // The caret is beside the picture and a letter arrives, the way the
    // keyboard delivers one.
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    state.updateEditingValue(
      TextEditingValue(
        text: '${anchor}h',
        selection: const TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    final value = tester
        .state<EditableTextState>(find.byType(EditableText))
        .textEditingValue;
    expect(value.text, '$anchor\nh');
    // The caret went with the letter, so typing simply continues.
    expect(value.selection.baseOffset, 3);
    // And the picture is still a picture, anchored where it always was.
    expect(find.byType(NoteImageView), findsOneWidget);
    expect(reported?.single.offset, 0);
  });

  testWidgets('typing before an image moves the words above it', (
    tester,
  ) async {
    await tester.pumpWidget(harness(anchor, attachments: [at(0)]));
    await tester.pump();

    final state = tester.state<EditableTextState>(find.byType(EditableText));
    state.updateEditingValue(
      TextEditingValue(
        text: 'h$anchor',
        selection: const TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();

    final value = tester
        .state<EditableTextState>(find.byType(EditableText))
        .textEditingValue;
    expect(value.text, 'h\n$anchor');
    expect(value.selection.baseOffset, 1);
    expect(find.byType(NoteImageView), findsOneWidget);
  });

  testWidgets('a line under an image cannot be merged onto it', (tester) async {
    await tester.pumpWidget(harness('$anchor\nwords', attachments: [at(0)]));
    await tester.pump();

    // Backspace at the start of the line below, which would otherwise put the
    // words on the picture's own row.
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    state.updateEditingValue(
      TextEditingValue(
        text: '${anchor}words',
        selection: const TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();

    final value = tester
        .state<EditableTextState>(find.byType(EditableText))
        .textEditingValue;
    expect(value.text, '$anchor\nwords');
    expect(find.byType(NoteImageView), findsOneWidget);
  });

  testWidgets('shows image progress and completion while a file is added', (
    tester,
  ) async {
    final editorKey = GlobalKey<NoteEditorState>();
    final ingest = Completer<ImageBatch>();
    await tester.pumpWidget(
      harness(
        'a note',
        attachments: const [],
        editorKey: editorKey,
        imageIngestor: (_, _) => ingest.future,
      ),
    );
    await tester.pump();

    final adding = editorKey.currentState!.insertFiles([
      XFile.fromData(Uint8List(0), name: 'photo.png'),
    ]);
    await tester.pump();

    expect(find.text('Adding image…'), findsOneWidget);
    expect(find.byKey(const ValueKey('insert-image-progress')), findsOneWidget);

    ingest.complete(ImageBatch(images: [at(0)], rejections: const []));
    await tester.pump();
    await adding;
    await tester.pump();

    expect(find.text('Image added'), findsOneWidget);
    expect(find.byKey(const ValueKey('insert-image-progress')), findsNothing);
    expect(find.byType(NoteImageView), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('shows a blurred local preview before preparation finishes', (
    tester,
  ) async {
    final editorKey = GlobalKey<NoteEditorState>();
    final finishing = Completer<ImageIngestResult>();
    StagedImage? staged;
    List<NoteAttachmentRef> reported = const [];
    await tester.pumpWidget(
      harness(
        'a note',
        attachments: const [],
        images: immediateStore,
        editorKey: editorKey,
        imageFinalizer: (image, _) {
          staged = image;
          return finishing.future;
        },
        onAttachmentsChanged: (attachments) => reported = attachments,
      ),
    );
    await tester.pump();

    late Future<void> adding;
    await tester.runAsync(() async {
      adding = editorKey.currentState!.insertFiles([
        XFile.fromData(
          pngOf(320, 180, seed: 9),
          name: 'instant.png',
          mimeType: 'image/png',
        ),
      ]);
      while (staged == null) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    await tester.pump();

    expect(reported, hasLength(1));
    final preview = reported.single as NoteImageRef;
    expect(preview.isPreparing, isTrue);
    expect(preview.previewBytes, isNotEmpty);
    expect(find.byType(NoteImageView), findsOneWidget);
    expect(find.byKey(const ValueKey('image-preparing')), findsOneWidget);
    expect(
      tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
      isTrue,
    );

    final ready = staged!.ref.copyWith(isPreparing: false, previewBytes: null);
    finishing.complete(
      ImageIngestResult.ok(
        IngestedImage(
          ref: ready,
          originalBytes: staged!.source.length,
          kind: ImageKind.graphic,
          reencoded: false,
        ),
      ),
    );
    await tester.runAsync(() => adding);
    await tester.pump();

    expect((reported.single as NoteImageRef).isPreparing, isFalse);
    expect(find.byKey(const ValueKey('image-preparing')), findsNothing);
    expect(
      tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
      isFalse,
    );
  });

  testWidgets(
    'shows real upload percentage and clears the blur at completion',
    (tester) async {
      final progress = ValueNotifier<double?>(0.37);
      addTearDown(progress.dispose);
      final ref = at(0);
      await tester.pumpWidget(
        harness(
          anchor,
          attachments: [ref],
          images: immediateStore,
          uploadProgressFor: (_) => progress,
        ),
      );
      await tester.pump();

      expect(find.text('Uploading 37%'), findsOneWidget);
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
        isTrue,
      );

      progress.value = 1;
      await tester.pump();
      expect(find.text('Uploading 100%'), findsOneWidget);
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
        isFalse,
      );

      await tester.pumpWidget(
        harness(
          anchor,
          attachments: [ref.copyWith(attachmentId: 'uploaded')],
          images: immediateStore,
          uploadProgressFor: (_) => progress,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('image-upload-percentage')),
        findsNothing,
      );
    },
  );

  testWidgets('the video footer action inserts a playable video block', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      harness(
        'a note',
        attachments: const [],
        videoAcquirer: () async {
          opened++;
          return [XFile.fromData(Uint8List(0), name: 'clip.mp4')];
        },
        videoIngestor: (_, _) async =>
            VideoBatch(videos: [videoAt(0)], rejections: const []),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('insert-video')));
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(find.byType(NoteVideoView), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a Pro-sized video rejection names the 100 MB ceiling', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        'a note',
        attachments: const [],
        videoAttachmentMaxBytes: () => proAttachmentMaxBytes,
        videoAcquirer: () async => [
          XFile.fromData(Uint8List(0), name: 'large.mp4'),
        ],
        videoIngestor: (_, _) async => const VideoBatch(
          videos: [],
          rejections: [(name: 'large.mp4', reason: VideoRejection.tooLarge)],
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('insert-video')));
    await tester.pumpAndSettle();

    expect(find.textContaining('100 MB attachment limit'), findsOneWidget);
  });

  testWidgets('clicking a video opens its full-screen player', (tester) async {
    await tester.pumpWidget(harness(anchor, attachments: [videoAt(0)]));
    await tester.pump();

    await tester.tap(find.byType(NoteVideoView));
    await tester.pumpAndSettle();

    expect(find.byType(NoteVideoViewer), findsOneWidget);
  });

  testWidgets('the mobile insert menu opens capture and inserts its result', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    var opened = 0;
    await tester.pumpWidget(
      harness(
        'a note',
        attachments: const [],
        imageAcquirer: (_) async {
          opened++;
          return [XFile.fromData(Uint8List(0), name: 'camera.jpg')];
        },
        imageIngestor: (_, _) async =>
            ImageBatch(images: [at(0)], rejections: const []),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('insert-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('slash-command-list')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('slash-command-image')));
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(find.byKey(const ValueKey('insert-menu')), findsOneWidget);
    expect(find.byType(NoteImageView), findsOneWidget);
  });

  testWidgets('the image shortcut opens the same picker as the footer', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      harness(
        'a note',
        attachments: const [],
        startAtEnd: true,
        imageAcquirer: (_) async {
          opened++;
          return const [];
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(EditableText));
    await tester.pump();

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.insertImage)!,
    );
    await tester.pump();

    expect(opened, 1);
  });

  group('copying', () {
    setUp(() {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        AppPlatform.debugTargetPlatformOverride = null;
        debugDefaultTargetPlatformOverride = null;
      });
    });

    Future<void> pressCopy(WidgetTester tester, FakeClipboard clipboard) async {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC, platform: 'windows');
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.runAsync(
        () => clipboard.waitForWrite().timeout(const Duration(seconds: 1)),
      );
      await tester.pump();
    }

    testWidgets(
      'single-clicking an image selects it and opens it full-screen',
      (tester) async {
        final ref = at(7);
        await tester.pumpWidget(
          harness(
            'before $anchor after',
            attachments: [ref],
            images: immediateStore,
          ),
        );
        await tester.pump();

        await tester.tap(find.byType(NoteImageView));
        await tester.pumpAndSettle();

        expect(find.byType(NoteImageViewer), findsOneWidget);
        expect(
          tester
              .state<EditableTextState>(
                find.byType(EditableText, skipOffstage: false),
              )
              .textEditingValue
              .selection,
          const TextSelection(baseOffset: 7, extentOffset: 8),
        );
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('a view-only image has a right-click Copy Image action', (
      tester,
    ) async {
      final clipboard = FakeClipboard();
      await tester.pumpWidget(
        harness(
          anchor,
          attachments: [at(0)],
          clipboard: clipboard,
          images: immediateStore,
          readOnly: true,
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(NoteImageView), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Copy Image'), findsOneWidget);
      await tester.tap(find.text('Copy Image'));
      await tester.runAsync(
        () => clipboard.waitForWrite().timeout(const Duration(seconds: 1)),
      );
      expect(clipboard.writes.single.images, hasLength(1));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('right-clicking a selected image opens its menu at once', (
      tester,
    ) async {
      // The second right-click was the slow one. Selecting an image that is
      // already selected changes nothing, so nothing scheduled a frame, and
      // the post-frame callback that opens the menu waited for whatever came
      // next — in practice the caret's next blink.
      await tester.pumpWidget(
        harness(anchor, attachments: [at(0)], images: immediateStore),
      );
      await tester.pump();

      await tester.tap(find.byType(NoteImageView), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Open Image'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      // Settled: nothing is pending, so the next frame has to be asked for
      // rather than inherited from something already in flight.
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);

      await tester.tap(find.byType(NoteImageView), buttons: kSecondaryButton);
      expect(
        SchedulerBinding.instance.hasScheduledFrame,
        isTrue,
        reason: 'without this the menu waits for an unrelated frame',
      );

      await tester.pumpAndSettle();
      expect(find.text('Open Image'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Ctrl-C preserves text and multiple images in document order', (
      tester,
    ) async {
      final body = 'before $anchor middle $anchor after';
      final clipboard = FakeClipboard();
      final editorKey = GlobalKey<NoteEditorState>();
      await tester.pumpWidget(
        harness(
          body,
          attachments: [at(7), at(16, which: 1)],
          clipboard: clipboard,
          images: immediateStore,
          editorKey: editorKey,
        ),
      );
      await tester.pump();
      editorKey.currentState!.focusAtEnd();
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: body.length,
      );
      await tester.pump();

      await pressCopy(tester, clipboard);

      final copied = clipboard.writes.single;
      expect(copied.body, body);
      expect(copied.images.map((image) => image.offset), [7, 16]);
      expect(copied.images.map((image) => BlobStore.hashOf(image.bytes)), [
        refs[0].hash,
        refs[1].hash,
      ]);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('right-click preserves and copies a mixed selection', (
      tester,
    ) async {
      final body = 'before $anchor after';
      final clipboard = FakeClipboard();
      final editorKey = GlobalKey<NoteEditorState>();
      await tester.pumpWidget(
        harness(
          body,
          attachments: [at(7)],
          clipboard: clipboard,
          images: immediateStore,
          editorKey: editorKey,
        ),
      );
      await tester.pump();
      editorKey.currentState!.focusAtEnd();
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: body.length,
      );
      await tester.pump();

      await tester.tap(find.byType(NoteImageView), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(controller.selection.start, 0);
      expect(controller.selection.end, body.length);
      await tester.tap(find.text('Copy Image'));
      await tester.runAsync(
        () => clipboard.waitForWrite().timeout(const Duration(seconds: 1)),
      );
      expect(clipboard.writes.single.body, body);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('one click opens a desktop image after selecting it', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(anchor, attachments: [at(0)], images: immediateStore),
      );
      await tester.pump();

      await tester.tap(find.byType(NoteImageView));
      await tester.pumpAndSettle();

      expect(find.byType(NoteImageViewer), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('resizing', () {
    // A pointer, because the handle is a desktop affordance, and a tall
    // window so the 60%-of-viewport height cap never becomes the thing under
    // test instead of the width.
    setUp(() {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    });

    Future<void> pumpWide(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(1100, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(child);
      await tester.pump();
    }

    testWidgets('a lone image is resizable; a tile in a row is not', (
      tester,
    ) async {
      await pumpWide(tester, harness(anchor, attachments: [at(0)]));
      expect(
        tester.widget<NoteImageView>(find.byType(NoteImageView)).resizable,
        isTrue,
      );

      await pumpWide(
        tester,
        harness('$anchor$anchor', attachments: [at(0), at(1, which: 1)]),
      );
      for (final tile in tester.widgetList<NoteImageView>(
        find.byType(NoteImageView),
      )) {
        expect(tile.resizable, isFalse);
      }
    });

    testWidgets('a stored width narrows the picture', (tester) async {
      await pumpWide(tester, harness(anchor, attachments: [at(0)]));
      final full = tester.getSize(find.byType(NoteImageView)).width;

      await pumpWide(
        tester,
        harness(anchor, attachments: [at(0).copyWith(widthFactor: 0.5)]),
      );
      final half = tester.getSize(find.byType(NoteImageView)).width;

      expect(half, closeTo(full / 2, 1));
    });

    testWidgets('dragging the handle resizes, and saves once at the end', (
      tester,
    ) async {
      final reported = <List<NoteAttachmentRef>>[];
      await pumpWide(
        tester,
        harness(
          anchor,
          attachments: [at(0)],
          onAttachmentsChanged: reported.add,
        ),
      );
      final before = tester.getSize(find.byType(NoteImageView)).width;

      // The handle only exists under a pointer, so the image has to be
      // hovered before it can be grabbed — the same order a hand does it in.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(NoteImageView)));
      await tester.pump();
      expect(find.byKey(const ValueKey('image-width-handle')), findsOneWidget);

      final image = tester.getRect(find.byType(NoteImageView));
      final grip = Offset(image.right - 9, image.center.dy);
      await mouse.moveTo(grip);
      await tester.pump();
      await mouse.down(grip);
      await tester.pump();
      await mouse.moveBy(const Offset(-120, 0));
      await tester.pump();

      final during = tester.getSize(find.byType(NoteImageView)).width;
      expect(during, lessThan(before - 100));
      // Nothing saved yet: a drag is one edit, not sixty.
      expect(reported, isEmpty);

      await mouse.up();
      await tester.pump();
      expect(reported, hasLength(1));
      expect((reported.single.single as NoteImageRef).widthFactor, lessThan(1));
    });
  });

  group('removing', () {
    testWidgets('the image has a one-click remove button', (tester) async {
      List<NoteAttachmentRef>? reported;
      final ref = at(0);
      await tester.pumpWidget(
        harness(
          anchor,
          attachments: [ref],
          startAtEnd: true,
          onAttachmentsChanged: (refs) => reported = refs,
        ),
      );
      await tester.pump();

      final remove = find.byKey(
        ValueKey('remove-image-${ref.hash}-${ref.offset}'),
      );
      expect(remove, findsOneWidget);
      await tester.tap(remove);
      await tester.pump();

      expect(reported, isEmpty);
      expect(find.byType(NoteImageView), findsNothing);
    });

    testWidgets('Ctrl-Z restores an image removed in one click', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        AppPlatform.debugTargetPlatformOverride = null;
        debugDefaultTargetPlatformOverride = null;
      });
      final ref = at(0);
      List<NoteAttachmentRef>? reported;
      await tester.pumpWidget(
        harness(
          anchor,
          attachments: [ref],
          startAtEnd: true,
          onAttachmentsChanged: (refs) => reported = refs,
        ),
      );
      await tester.pump();
      // Let EditableText commit the initial value as the undo baseline.
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(
        find.byKey(ValueKey('remove-image-${ref.hash}-${ref.offset}')),
      );
      await tester.pump();
      expect(find.byType(NoteImageView), findsNothing);
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);

      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ, platform: 'windows');
      await tester.pump();
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;

      expect(reported, hasLength(1));
      expect(reported!.single.hash, ref.hash);
      expect(find.byType(NoteImageView), findsOneWidget);
    });

    testWidgets('removeAttachment deletes the right one of three', (
      tester,
    ) async {
      final editorKey = GlobalKey<NoteEditorState>();
      List<NoteAttachmentRef>? reported;
      await tester.pumpWidget(
        harness(
          '$anchor$anchor$anchor',
          attachments: [at(0), at(1, which: 1), at(2, which: 2)],
          editorKey: editorKey,
          onAttachmentsChanged: (refs) => reported = refs,
        ),
      );
      await tester.pump();

      // The middle one, with the caret nowhere near it: the offset is stated,
      // so a diff never gets the chance to guess wrong.
      editorKey.currentState!.removeAttachment(1);
      await tester.pump();

      expect(reported, hasLength(2));
      expect(reported!.map((r) => r.hash), [refs[0].hash, refs[2].hash]);
      expect(find.byType(NoteImageView), findsNWidgets(2));
    });
  });

  group('full-screen viewer', () {
    for (final target in [TargetPlatform.windows, TargetPlatform.android]) {
      testWidgets('tapping outside closes it on ${target.name}', (
        tester,
      ) async {
        AppPlatform.debugTargetPlatformOverride = target;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        final size = target == TargetPlatform.android
            ? const Size(390, 844)
            : const Size(1100, 700);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            theme: KapyTheme.dark(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => NoteImageViewer.open(
                    context,
                    ref: refs.first,
                    store: store,
                  ),
                  child: const Text('Open image'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open image'));
        await tester.pumpAndSettle();
        expect(find.byType(NoteImageViewer), findsOneWidget);
        final viewport = find.byType(InteractiveViewer);
        expect(tester.getTopLeft(viewport), Offset.zero);
        expect(tester.getSize(viewport), size);
        expect(
          find.ancestor(of: viewport, matching: find.byType(Padding)),
          findsNothing,
        );
        expect(
          find.ancestor(of: viewport, matching: find.byType(SafeArea)),
          findsNothing,
        );

        final outside = target == TargetPlatform.android
            ? const Offset(195, 100)
            : const Offset(40, 350);
        await tester.tapAt(outside);
        await tester.pumpAndSettle();

        expect(find.byType(NoteImageViewer), findsNothing);
      });
    }
  });

  group('undo restores the attachment, not just its character', () {
    // Driven by putting the exact prior text back through the text input,
    // rather than by sending ctrl/cmd-Z. Flutter's UndoHistory does not
    // record a programmatic `controller.value` change under `flutter test` —
    // verified with a bare focused TextField — so a keystroke here would
    // assert on the framework's test-mode behaviour instead of on ours.
    // Restoring the exact prior text is precisely what undo hands the
    // editor, and it is the condition `_restoreUndone` matches on.

    Future<void> restore(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(EditableText), text);
      await tester.pump();
    }

    testWidgets('a removed picture comes back with its hash', (tester) async {
      final editorKey = GlobalKey<NoteEditorState>();
      List<NoteAttachmentRef>? reported;
      await tester.pumpWidget(
        harness(
          'a$anchor b',
          attachments: [at(1)],
          editorKey: editorKey,
          onAttachmentsChanged: (refs) => reported = refs,
        ),
      );
      await tester.pump();

      editorKey.currentState!.removeAttachment(1);
      await tester.pump();
      expect(reported, isEmpty);

      await restore(tester, 'a$anchor b');
      expect(reported, hasLength(1));
      expect(reported!.single.hash, refs[0].hash);
      expect(reported!.single.offset, 1);
      expect(find.byType(NoteImageView), findsOneWidget);
    });

    testWidgets('an edit in between does not lose it', (tester) async {
      final editorKey = GlobalKey<NoteEditorState>();
      List<NoteAttachmentRef>? reported;
      await tester.pumpWidget(
        harness(
          'a$anchor b',
          attachments: [at(1)],
          editorKey: editorKey,
          onAttachmentsChanged: (refs) => reported = refs,
        ),
      );
      await tester.pump();

      editorKey.currentState!.removeAttachment(1);
      await tester.pump();
      await restore(tester, 'a b typed');
      expect(reported, isEmpty);

      await restore(tester, 'a$anchor b');
      expect(reported!.map((r) => r.hash), [refs[0].hash]);
    });

    testWidgets('two adjacent removals come back one step at a time', (
      tester,
    ) async {
      final editorKey = GlobalKey<NoteEditorState>();
      List<NoteAttachmentRef>? reported;
      await tester.pumpWidget(
        harness(
          '$anchor$anchor',
          attachments: [at(0), at(1, which: 1)],
          editorKey: editorKey,
          onAttachmentsChanged: (refs) => reported = refs,
        ),
      );
      await tester.pump();

      editorKey.currentState!.removeAttachment(1);
      await tester.pump();
      editorKey.currentState!.removeAttachment(0);
      await tester.pump();
      expect(reported, isEmpty);

      // Undo walks back through the states it passed, so the test does too.
      await restore(tester, anchor);
      expect(reported!.map((r) => r.hash), [refs[0].hash]);

      await restore(tester, '$anchor$anchor');
      expect(reported!.map((r) => r.hash), [refs[0].hash, refs[1].hash]);
      expect(reported!.map((r) => r.offset), [0, 1]);
    });

    testWidgets('removing it again after a restore is remembered again', (
      tester,
    ) async {
      // The redo half: the second removal arrives as an ordinary rebase drop
      // rather than through removeAttachment, and has to be recorded just the same
      // or the next undo restores nothing.
      final editorKey = GlobalKey<NoteEditorState>();
      List<NoteAttachmentRef>? reported;
      await tester.pumpWidget(
        harness(
          'a$anchor b',
          attachments: [at(1)],
          editorKey: editorKey,
          onAttachmentsChanged: (refs) => reported = refs,
        ),
      );
      await tester.pump();

      editorKey.currentState!.removeAttachment(1);
      await tester.pump();
      await restore(tester, 'a$anchor b');
      expect(reported, hasLength(1));

      await restore(tester, 'a b');
      expect(reported, isEmpty);

      await restore(tester, 'a$anchor b');
      expect(reported!.single.hash, refs[0].hash);
    });
  });

  group('pasting', () {
    testWidgets('Paste Text ignores a rich fragment and its image', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      const fragmentBody = 'text $anchor done';
      final fragment = NoteClipboardFragment(
        body: fragmentBody,
        images: [
          ClipboardFragmentImage(
            offset: fragmentBody.indexOf(anchor),
            bytes: pngOf(120, 90, seed: 6),
            mime: 'image/png',
            width: 120,
            height: 90,
            widthFactor: 0.6,
          ),
        ],
      );
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        return switch (call.method) {
          'Clipboard.hasStrings' => <String, Object?>{'value': true},
          'Clipboard.getData' => <String, Object?>{'text': fragment.plainText},
          _ => null,
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final editorKey = GlobalKey<NoteEditorState>();
      await tester.pumpWidget(
        harness(
          'before ',
          attachments: const [],
          clipboard: FakeClipboard(fragment: fragment),
          editorKey: editorKey,
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final beforePaste = editable.textEditingValue;
      expect(beforePaste.selection.isCollapsed, isTrue);
      final expected = beforePaste.text.replaceRange(
        beforePaste.selection.start,
        beforePaste.selection.end,
        fragment.plainText,
      );

      await tester.tap(find.text('Paste Text').hitTestable());
      await tester.pumpAndSettle();

      expect(editable.textEditingValue.text, expected);
      expect(find.byType(NoteImageView), findsNothing);
    });

    testWidgets(
      'a copied mixed fragment pastes text and every image in place',
      (tester) async {
        final firstBytes = pngOf(120, 90, seed: 7);
        final secondBytes = pngOf(90, 120, seed: 8);
        final fragmentBody = 'text $anchor between $anchor done';
        final clipboard = FakeClipboard(
          fragment: NoteClipboardFragment(
            body: fragmentBody,
            images: [
              ClipboardFragmentImage(
                offset: fragmentBody.indexOf(anchor),
                bytes: firstBytes,
                mime: 'image/png',
                width: 120,
                height: 90,
                widthFactor: 0.6,
              ),
              ClipboardFragmentImage(
                offset: fragmentBody.lastIndexOf(anchor),
                bytes: secondBytes,
                mime: 'image/png',
                width: 90,
                height: 120,
                widthFactor: 1,
              ),
            ],
          ),
        );
        final editorKey = GlobalKey<NoteEditorState>();
        List<NoteAttachmentRef>? reported;
        await tester.pumpWidget(
          harness(
            'before ',
            attachments: const [],
            clipboard: clipboard,
            editorKey: editorKey,
            onAttachmentsChanged: (attachments) => reported = attachments,
          ),
        );
        await tester.pump();
        editorKey.currentState!.focusAtEnd();
        await tester.pump();

        await tester.runAsync(
          () => editorKey.currentState!.handlePaste(SelectionChangedCause.tap),
        );
        await tester.pump();

        final text = tester
            .state<EditableTextState>(find.byType(EditableText))
            .textEditingValue
            .text;
        expect(text, 'before $fragmentBody');
        expect(clipboard.reads, 0);
        expect(reported, hasLength(2));
        expect(reported!.map((ref) => ref.offset), [
          7 + fragmentBody.indexOf(anchor),
          7 + fragmentBody.lastIndexOf(anchor),
        ]);
        expect(find.byType(NoteImageView), findsNWidgets(2));
        await tester.pump(const Duration(seconds: 2));
      },
    );

    testWidgets('an image on the clipboard is inserted', (tester) async {
      final editorKey = GlobalKey<NoteEditorState>();
      final clipboard = FakeClipboard(
        image: ClipboardImage(bytes: pngOf(120, 90, seed: 9), name: 'x.png'),
      );
      await tester.pumpWidget(
        harness(
          'before',
          attachments: const [],
          clipboard: clipboard,
          editorKey: editorKey,
        ),
      );
      await tester.pump();

      await tester.runAsync(
        () => editorKey.currentState!.handlePaste(SelectionChangedCause.tap),
      );
      await tester.pump();

      expect(clipboard.reads, 1);
      expect(find.byType(NoteImageView), findsOneWidget);
      final text = tester
          .state<EditableTextState>(find.byType(EditableText))
          .textEditingValue
          .text;
      expect(text, contains(anchor));
    });

    testWidgets('an empty clipboard falls through to the text paste', (
      tester,
    ) async {
      final editorKey = GlobalKey<NoteEditorState>();
      final clipboard = FakeClipboard();
      await tester.pumpWidget(
        harness(
          'before',
          attachments: const [],
          clipboard: clipboard,
          editorKey: editorKey,
        ),
      );
      await tester.pump();

      await tester.runAsync(
        () => editorKey.currentState!.handlePaste(SelectionChangedCause.tap),
      );
      await tester.pump();

      expect(clipboard.reads, 1);
      expect(find.byType(NoteImageView), findsNothing);
      // The note is untouched: nothing was on the clipboard to paste.
      final text = tester
          .state<EditableTextState>(find.byType(EditableText))
          .textEditingValue
          .text;
      expect(text, 'before');
    });

    testWidgets('auto-paste captures dictated text before it is restored', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var clipboardText = 'dictated words';
      var textReads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            textReads++;
            return <String, Object?>{'text': clipboardText};
          }
          if (call.method == 'Clipboard.hasStrings') {
            return <String, Object?>{'value': clipboardText.isNotEmpty};
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

      final editorKey = GlobalKey<NoteEditorState>();
      final clipboard = FakeClipboard(
        // Dictation tools restore the previous clipboard as soon as the
        // receiving app has read their promised text. Image inspection must
        // not postpone Kapy Notes' one chance to capture that text.
        onReadImage: () => clipboardText = 'previous clipboard',
      );
      await tester.pumpWidget(
        harness(
          'before ',
          attachments: const [],
          clipboard: clipboard,
          editorKey: editorKey,
        ),
      );
      await tester.pump();
      editorKey.currentState!.focusAtEnd();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      expect(textReads, 1);
      expect(clipboard.reads, 1);
      final text = tester
          .state<EditableTextState>(find.byType(EditableText))
          .textEditingValue
          .text;
      expect(text, 'before dictated words');
    });

    testWidgets('a dictated transcript outranks the clipboard it replaced', (
      tester,
    ) async {
      // What a dictation app does: hold the transcript only long enough for its
      // Cmd+V to land, then put back the picture that was on the clipboard
      // before. The bitmap read arrives after that swap, so it describes the
      // older clipboard and must not outrank what the person just said.
      var clipboardText = 'dictated words';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': clipboardText};
          }
          if (call.method == 'Clipboard.hasStrings') {
            return <String, Object?>{'value': clipboardText.isNotEmpty};
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

      final editorKey = GlobalKey<NoteEditorState>();
      List<NoteAttachmentRef>? reported;
      final clipboard = FakeClipboard(
        image: ClipboardImage(bytes: pngOf(120, 90, seed: 4), name: 'old.png'),
        onReadImage: () => clipboardText = 'previous clipboard',
      );
      await tester.pumpWidget(
        harness(
          'before ',
          attachments: const [],
          clipboard: clipboard,
          editorKey: editorKey,
          onAttachmentsChanged: (refs) => reported = refs,
        ),
      );
      await tester.pump();

      await tester.runAsync(
        () => editorKey.currentState!.handlePaste(SelectionChangedCause.tap),
      );
      await tester.pump();

      final text = tester
          .state<EditableTextState>(find.byType(EditableText))
          .textEditingValue
          .text;
      expect(text, 'before dictated words');
      expect(find.byType(NoteImageView), findsNothing);
      expect(reported, anyOf(isNull, isEmpty));
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('auto-paste survives an accessibility focus round trip', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      late TextEditingController controller;
      var textReads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            textReads++;
            // Dictation apps explicitly refocus the AXTextArea immediately
            // before synthesizing Cmd+V. Flutter can briefly clear the
            // selection while that accessibility focus reaches EditableText.
            controller.selection = const TextSelection.collapsed(offset: -1);
            return <String, Object?>{'text': 'dictated words'};
          }
          if (call.method == 'Clipboard.hasStrings') {
            return <String, Object?>{'value': true};
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

      final editorKey = GlobalKey<NoteEditorState>();
      final clipboard = FakeClipboard();
      await tester.pumpWidget(
        harness(
          'before after',
          attachments: const [],
          clipboard: clipboard,
          editorKey: editorKey,
        ),
      );
      await tester.pump();
      controller = tester.widget<TextField>(find.byType(TextField)).controller!;
      editorKey.currentState!.focusAtEnd();
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 7);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      expect(textReads, 1);
      expect(clipboard.reads, 1);
      expect(controller.text, 'before dictated wordsafter');
      expect(controller.selection, const TextSelection.collapsed(offset: 21));
    });
  });
}
