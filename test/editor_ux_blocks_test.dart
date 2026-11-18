import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/ui/editor/note_image_view.dart';
import 'package:material_ui/material_ui.dart';

import 'support/desk.dart';
import 'test_fonts.dart';

const anchor = NoteAttachmentRef.placeholder;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'editor-ux-blocks-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  late Directory folder;
  late BlobStore store;
  late NoteImageRef picture;

  setUpAll(() async {
    await loadTestFonts();
    folder = await Directory.systemTemp.createTemp('kapy_ux_blocks_');
    store = BlobStore(directory: folder);
    final photo = img.Image(width: 320, height: 240, numChannels: 3);
    img.fill(photo, color: img.ColorRgb8(20, 120, 200));
    final bytes = Uint8List.fromList(img.encodePng(photo, level: 1));
    picture = NoteImageRef(
      offset: 0,
      hash: await store.put(bytes),
      key: Uint8List(32),
      mime: 'image/png',
      width: 320,
      height: 240,
      bytes: bytes.length,
    );
  });

  tearDownAll(() => folder.delete(recursive: true));

  group('code blocks', () {
    const body = 'Title\n```dart\nfoo\n```\nafter';

    testWidgets('typing and Enter inside a fence stay inside the block', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(body);
      await desk.click(desk.on('foo', 3));
      expect(desk.selection.baseOffset, body.indexOf('foo') + 3);
      await desk.type('bar');
      expect(desk.text, 'Title\n```dart\nfoobar\n```\nafter');
      await desk.enter();
      await desk.type('baz');
      expect(desk.text, 'Title\n```dart\nfoobar\nbaz\n```\nafter');
    }, variant: desktopPlatforms);

    testWidgets('the Copy button copies the code', (tester) async {
      final desk = Desk(tester);
      await desk.open(body);
      await desk.click(desk.on('after', 2));
      expect(find.byKey(const ValueKey('code-copy')), findsOneWidget);
      await desk.clickKey('code-copy');
      expect(desk.clipboard['text'], 'foo');
    }, variant: desktopPlatforms);

    testWidgets('Tab inside a block indents instead of changing focus', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(body);
      await desk.click(desk.on('foo', 3));
      await desk.key(LogicalKeyboardKey.tab);
      await desk.settle();
      expect(desk.text, 'Title\n```dart\nfoo  \n```\nafter');
      expect(desk.editor.widget.autofocus, isTrue);
      expect(desk.note.state.widget.focusNode.hasFocus, isTrue);
      await desk.type('x');
      expect(desk.text, 'Title\n```dart\nfoo  x\n```\nafter');
    }, variant: desktopPlatforms);

    testWidgets('Tab and Shift+Tab indent and outdent the selected lines', (
      tester,
    ) async {
      const lines = 'Title\n```dart\none\ntwo\n```\nafter';
      final desk = Desk(tester);
      await desk.open(lines);
      await desk.click(desk.on('one'));
      await desk.drag(desk.on('one', 1), desk.on('two', 2));
      await desk.key(LogicalKeyboardKey.tab);
      expect(desk.text, 'Title\n```dart\n  one\n  two\n```\nafter');
      expect(desk.selection.textInside(desk.text), 'ne\n  tw');
      await desk.key(LogicalKeyboardKey.tab, shift: true);
      expect(desk.text, lines);
      await desk.key(LogicalKeyboardKey.tab, shift: true);
      expect(desk.text, lines, reason: 'nothing left to take back');
    }, variant: desktopPlatforms);

    testWidgets('Tab on a line outside the block is not claimed', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(body);
      await desk.click(desk.on('after', 5));
      await desk.key(LogicalKeyboardKey.tab);
      expect(desk.text, body);
    }, variant: desktopPlatforms);

    testWidgets('Tab at the start of the closing fence leaves the fence', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(body);
      desk.place(body.lastIndexOf('```'));
      await desk.settle();
      await desk.key(LogicalKeyboardKey.tab);
      await desk.settle();
      expect(desk.text, body);
    }, variant: desktopPlatforms);

    testWidgets('Tab in an empty code block leaves its fences', (tester) async {
      const empty = 'Title\n```\n```\nafter';
      final desk = Desk(tester);
      await desk.open(empty);
      for (final at in [empty.indexOf('```') + 3, empty.lastIndexOf('```')]) {
        desk.place(at);
        await desk.settle();
        await desk.key(LogicalKeyboardKey.tab);
        await desk.settle();
        expect(desk.text, empty, reason: 'at $at');
      }
    }, variant: desktopPlatforms);

    testWidgets('in a read-only note, Tab in a code block moves focus on', (
      tester,
    ) async {
      final desk = Desk(tester);
      final next = FocusNode();
      addTearDown(next.dispose);
      await desk.open(
        body,
        readOnly: true,
        below: TextButton(
          focusNode: next,
          onPressed: () {},
          child: const Text('Next'),
        ),
      );
      final focus = desk.note.state.widget.focusNode;
      desk.place(body.indexOf('foo') + 1);
      focus.requestFocus();
      await desk.settle();
      expect(focus.hasFocus, isTrue);
      await desk.key(LogicalKeyboardKey.tab);
      await desk.settle();
      expect(desk.text, body);
      expect(next.hasFocus, isTrue);
    }, variant: desktopPlatforms);
  });

  group('tables', () {
    const body = 'Title\n\n| a | b |\n| --- | --- |\n| Tea | 4 |\n\nafter';
    final cell = find.byKey(const ValueKey('table-cell-editor'));
    String editing(WidgetTester tester) =>
        tester.widget<TextField>(cell).controller!.text;

    testWidgets('typing in a cell, Tab and Shift+Tab between cells', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(body);
      await desk.click(desk.at(body.indexOf('| Tea')));
      expect(cell, findsOneWidget);
      expect(editing(tester), 'Tea');
      await desk.typeInField('!');
      expect(desk.text, contains('| Tea! | 4 |'));
      await desk.key(LogicalKeyboardKey.tab);
      await desk.settle();
      expect(editing(tester), '4');
      await desk.typeInField('2');
      expect(desk.text, contains('| Tea! | 42 |'));
      await desk.key(LogicalKeyboardKey.tab, shift: true);
      await desk.settle();
      expect(editing(tester), 'Tea!');
    }, variant: desktopPlatforms);

    testWidgets('Tab past the last cell adds a row and moves into it', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(body);
      await desk.click(desk.at(body.indexOf('| Tea')));
      await desk.key(LogicalKeyboardKey.tab);
      await desk.key(LogicalKeyboardKey.tab);
      await desk.settle();
      expect(desk.text, contains('| Tea | 4 |\n|  |  |'));
      expect(editing(tester), isEmpty);
      await desk.typeInField('x');
      expect(desk.text, contains('|  |  |'.replaceFirst('  |', ' x |')));
      expect(desk.text, endsWith('\n\nafter'));
    }, variant: desktopPlatforms);

    testWidgets('Return goes down a column; Escape returns to the note', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(body);
      await desk.click(desk.at(body.indexOf('| Tea')));
      await desk.key(LogicalKeyboardKey.enter);
      await desk.settle();
      expect(desk.text, contains('| Tea | 4 |\n|  |  |'));
      await desk.key(LogicalKeyboardKey.escape);
      await desk.settle();
      expect(cell, findsNothing);
      await desk.type('z');
      expect(desk.text, endsWith('after'));
      expect(desk.text, contains('z'));
      expect(desk.text, isNot(contains('| z')));
    }, variant: desktopPlatforms);
  });

  group('pictures and files', () {
    final body = 'Title\n$anchor\nafter';

    testWidgets('inserting a picture puts it on its own line, caret after', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('Title\nsome words', images: store);
      await desk.click(desk.on('words', 2));
      desk.editor.insertImages([picture]);
      await desk.settle();
      expect(desk.text, 'Title\nsome wo\n$anchor\nrds');
      expect(desk.attachments, hasLength(1));
      expect(find.byType(NoteImageView), findsOneWidget);
      await desk.type('caption');
      expect(desk.text, 'Title\nsome wo\n$anchor\ncaptionrds');
    }, variant: desktopPlatforms);

    testWidgets('a picture that cannot load offers Retry', (tester) async {
      final desk = Desk(tester);
      final lost = NoteImageRef(
        offset: 6,
        hash: 'not-in-the-store',
        key: Uint8List(32),
        mime: 'image/png',
        width: 320,
        height: 240,
        bytes: 0,
        src: 'https://example.com/photo.png',
      );
      await desk.open(body, images: store, initialAttachments: [lost]);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await desk.settle();
      expect(
        find.byKey(const ValueKey('retry-image-download')),
        findsOneWidget,
      );
    }, variant: desktopPlatforms);

    testWidgets(
      'Backspace right after a picture removes it; Undo restores it',
      (tester) async {
        final desk = Desk(tester);
        await desk.open(
          body,
          images: store,
          initialAttachments: [picture.copyWith(offset: 6)],
        );
        expect(find.byType(NoteImageView), findsOneWidget);
        desk.place(7);
        await desk.settle();
        await desk.key(LogicalKeyboardKey.backspace);
        await desk.settle();
        expect(desk.text, 'Title\n\nafter');
        expect(find.byType(NoteImageView), findsNothing);
        expect(desk.attachments, isEmpty);
        await desk.undo();
        expect(desk.text, body);
        expect(find.byType(NoteImageView), findsOneWidget);
        expect(desk.attachments.single.hash, picture.hash);
      },
      variant: desktopPlatforms,
    );
  });

  group('title and tags', () {
    testWidgets('typing in the title and Enter at its end move into the body', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('Plans\nbody text');
      await desk.click(desk.on('Plans', 5));
      await desk.type(' for May');
      expect(desk.text, 'Plans for May\nbody text');
      await desk.lineKey(end: true);
      await desk.enter();
      expect(desk.selection.baseOffset, 'Plans for May\n'.length);
      await desk.type('first');
      expect(desk.text, startsWith('Plans for May\nfirst'));
    }, variant: desktopPlatforms);

    testWidgets('a tag is created from the picker and shows on the row', (
      tester,
    ) async {
      final tags = TagStore(_MemoryStore());
      await tags.load();
      final desk = Desk(tester);
      await desk.open('Plans\nbody', tags: tags);
      await desk.clickKey('note-add-tag');
      expect(find.byKey(const ValueKey('tag-picker')), findsOneWidget);
      await desk.typeInField('Work');
      await desk.enter();
      expect(tags.tagsOf('ux').map((tag) => tag.name.v), ['Work']);
      expect(find.text('Work'), findsWidgets);
      await desk.click(desk.on('body', 2));
      expect(find.byKey(const ValueKey('tag-picker')), findsNothing);
      await desk.type('!');
      expect(desk.text, 'Plans\nbo!dy');
    }, variant: desktopPlatforms);
  });

  group('long notes', () {
    final long =
        'Long note\n${[for (var i = 1; i <= 300; i++) 'line $i'].join('\n')}';

    ScrollPosition position(WidgetTester tester) => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(Scaffold),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;

    Future<void> documentEdge(Desk desk, {required bool end}) async {
      await (desk.mac
          ? desk.key(
              end ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.arrowUp,
              primary: true,
            )
          : desk.key(
              end ? LogicalKeyboardKey.end : LogicalKeyboardKey.home,
              primary: true,
            ));
      await desk.settle();
    }

    int lineOf(Desk desk) =>
        desk.text.substring(0, desk.selection.baseOffset).split('\n').length;

    testWidgets('typing and Enter at the end keep the caret in view', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(long);
      await documentEdge(desk, end: true);
      expect(desk.selection.baseOffset, desk.text.length);
      final view = tester.getRect(find.byType(Scaffold));
      final before = position(tester).pixels;
      for (var i = 0; i < 40; i++) {
        await desk.type('more');
        await desk.enter();
        final caret = desk.at(desk.selection.baseOffset);
        expect(
          caret.dy,
          allOf(greaterThan(view.top + 80), lessThan(view.bottom)),
          reason: 'after ${i + 1} lines the caret is at $caret in $view',
        );
      }
      expect(position(tester).pixels, greaterThan(before));
    }, variant: desktopPlatforms);

    testWidgets(
      'the start and end of the note land on the very top and bottom',
      (tester) async {
        final desk = Desk(tester);
        await desk.open(long);
        await documentEdge(desk, end: false);
        expect(desk.selection.baseOffset, 0);
        expect(position(tester).pixels, 0);
        await documentEdge(desk, end: true);
        expect(position(tester).pixels, position(tester).maxScrollExtent);
      },
      variant: desktopPlatforms,
    );

    testWidgets('Page Down and Page Up move a page at a time', (tester) async {
      final desk = Desk(tester);
      await desk.open(long);
      await documentEdge(desk, end: false);
      expect(desk.selection.baseOffset, 0);
      final view = tester.getRect(find.byType(Scaffold));
      final page = position(tester).viewportDimension;
      final steps = <int>[];
      for (var i = 0; i < 3; i++) {
        await desk.key(LogicalKeyboardKey.pageDown);
        await desk.settle();
        steps.add(lineOf(desk));
        expect(desk.at(desk.selection.baseOffset).dy, lessThan(view.bottom));
      }
      if (desk.mac) {
        expect(steps, [1, 1, 1], reason: 'on a Mac the caret stays put');
        expect(position(tester).pixels, closeTo(page * 0.8 * 3, 1));
      } else {
        expect(steps.first, greaterThan(10));
        expect(steps[1] - steps[0], closeTo(steps[0] - 1, 2));
        expect(steps[2] - steps[1], closeTo(steps[0] - 1, 2));
      }
      for (var i = 0; i < 3; i++) {
        await desk.key(LogicalKeyboardKey.pageUp);
        await desk.settle();
      }
      expect(lineOf(desk), 1);
      expect(position(tester).pixels, 0);
    }, variant: desktopPlatforms);

    testWidgets('typing after a page scroll brings the caret back into view', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open(long);
      await documentEdge(desk, end: false);
      for (var i = 0; i < 4; i++) {
        await desk.key(LogicalKeyboardKey.pageDown);
      }
      await desk.settle();
      await desk.key(LogicalKeyboardKey.arrowDown);
      await desk.type('x');
      final view = tester.getRect(find.byType(Scaffold));
      final caret = desk.at(desk.selection.baseOffset);
      expect(caret.dy, allOf(greaterThan(view.top), lessThan(view.bottom)));
    }, variant: desktopPlatforms);
  });
}
