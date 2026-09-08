import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/images/image_clipboard.dart';
import 'package:kapy_notes/images/image_picker.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_image_view.dart';
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
  ImageBatchIngestor? imageIngestor,
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
      imageIngestor: imageIngestor,
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

    testWidgets('clicking an image selects it and Ctrl-C copies its bytes', (
      tester,
    ) async {
      final ref = at(7);
      final clipboard = FakeClipboard();
      await tester.pumpWidget(
        harness(
          'before $anchor after',
          attachments: [ref],
          clipboard: clipboard,
          images: immediateStore,
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(NoteImageView));
      await tester.pump();

      expect(find.byType(NoteImageViewer), findsNothing);
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .textEditingValue
            .selection,
        const TextSelection(baseOffset: 7, extentOffset: 8),
      );

      await pressCopy(tester, clipboard);

      final copied = clipboard.writes.single;
      expect(copied.body, anchor);
      expect(copied.images, hasLength(1));
      expect(copied.images.single.offset, 0);
      expect(BlobStore.hashOf(copied.images.single.bytes), ref.hash);
      debugDefaultTargetPlatformOverride = null;
    });

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

    testWidgets('double-click opens a desktop image after selecting it', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(anchor, attachments: [at(0)], images: immediateStore),
      );
      await tester.pump();

      await tester.tap(find.byType(NoteImageView));
      await tester.pump(const Duration(milliseconds: 40));
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
