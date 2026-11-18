import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/file_chip.dart';
import 'package:kapy_notes/ui/editor/note_image_view.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:material_ui/material_ui.dart';

import 'support/desk.dart';
import 'test_fonts.dart';

const anchor = NoteAttachmentRef.placeholder;

/// A note with one of every block the editor draws.
const _blocks =
    'Selection\n'
    '# Heading\n'
    'Words with **bold**, `code`, a [link](https://x.example) and '
    'https://example.com/page\n'
    '- a bullet\n'
    '- [ ] a task\n'
    '1. a step\n'
    '> a quote\n'
    '---\n'
    '```dart\n'
    'foo()\n'
    '```\n'
    '| Item | Cost |\n'
    '| --- | ---: |\n'
    '| tea | 4 |\n'
    '| cake | 6 |\n'
    '\n'
    'price = 3 * 4\n'
    r'$$'
    '\n'
    'x^2\n'
    r'$$'
    '\n';
const _body = '$_blocks$anchor\n$anchor\n$anchor\nafter';

void main() {
  late Directory folder;
  late BlobStore store;
  late List<NoteAttachmentRef> attachments;

  setUpAll(() async {
    await loadTestFonts();
    folder = await Directory.systemTemp.createTemp('kapy_selection_');
    store = BlobStore(directory: folder);
    final photo = img.Image(width: 320, height: 180, numChannels: 3);
    img.fill(photo, color: img.ColorRgb8(20, 120, 200));
    final bytes = Uint8List.fromList(img.encodePng(photo, level: 1));
    attachments = [
      NoteImageRef(
        offset: _blocks.length,
        hash: await store.put(bytes),
        key: Uint8List(32),
        mime: 'image/png',
        width: 320,
        height: 180,
        bytes: bytes.length,
      ),
      NoteFileRef(
        offset: _blocks.length + 2,
        hash: 'file-that-is-not-local',
        key: Uint8List(32),
        mime: 'application/pdf',
        bytes: 2400000,
        name: 'Q3 report.pdf',
      ),
      NoteVoiceRef(
        offset: _blocks.length + 4,
        hash: 'voice-that-is-not-local',
        key: Uint8List(32),
        bytes: 2048,
        durationMs: 134000,
      ),
    ];
  });

  tearDownAll(() => folder.delete(recursive: true));

  bool phone() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => true,
    _ => false,
  };

  Future<Desk> open(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    bool readOnly = false,
  }) async {
    final desk = Desk(tester);
    await desk.open(
      _body,
      results: true,
      window: phone() ? const Size(390, 1560) : const Size(760, 1320),
      images: store,
      initialAttachments: attachments,
      readOnly: readOnly,
      brightness: brightness,
      now: () => DateTime(2026, 11, 18, 9, 41),
    );
    desk.note.state.widget.focusNode.requestFocus();
    desk.place(_body.length);
    await desk.settle();
    return desk;
  }

  Future<void> selectAll(Desk desk) async {
    if (phone()) {
      desk.note.state.selectAll(SelectionChangedCause.keyboard);
    } else {
      await desk.key(LogicalKeyboardKey.keyA, primary: true);
    }
    await desk.settle();
  }

  /// The colour of each pixel the screen shows at [points].
  Future<List<Color>> pixels(WidgetTester tester, List<Offset> points) async {
    final bytes = (await tester.runAsync(() async {
      final image = await captureImage(
        find.byType(MaterialApp).evaluate().single,
      );
      final data = await image.toByteData();
      final width = image.width;
      image.dispose();
      return (data!, width);
    }))!;
    return [
      for (final point in points)
        () {
          final at = (point.dy.round() * bytes.$2 + point.dx.round()) * 4;
          return Color.fromARGB(
            bytes.$1.getUint8(at + 3),
            bytes.$1.getUint8(at),
            bytes.$1.getUint8(at + 1),
            bytes.$1.getUint8(at + 2),
          );
        }(),
    ];
  }

  /// [under] with [tint] laid over it.
  Color over(Color under, Color tint) => Color.alphaBlend(tint, under);

  Matcher looksLike(Color expected) => predicate<Color>(
    (color) =>
        ((color.r - expected.r) * 255).abs() <= 3 &&
        ((color.g - expected.g) * 255).abs() <= 3 &&
        ((color.b - expected.b) * 255).abs() <= 3,
    'within 3 of $expected',
  );

  /// Points inside each block the grid or a widget draws, rather than the
  /// writing: the image, the file and voice chips, and a table's cell.
  List<Offset> blockPoints(Desk desk) {
    final row = desk.text.indexOf('| tea');
    final cell = desk.note.boxesFor(
      TextSelection(baseOffset: row, extentOffset: row + 1),
    );
    return [
      for (final type in [NoteImageView, NoteFileChip, NoteVoiceChip])
        desk.tester.getCenter(find.byType(type)),
      desk.note.toGlobal(
        Offset(cell.first.left + 6, cell.first.toRect().center.dy),
      ),
    ];
  }

  testWidgets('Select All highlights every block, widgets and tables too', (
    tester,
  ) async {
    final desk = await open(tester);
    final before = await pixels(tester, blockPoints(desk));
    await selectAll(desk);
    expect(
      desk.selection,
      TextSelection(baseOffset: 0, extentOffset: _body.length),
    );
    final tint = desk.note.selectionColor!;
    final after = await pixels(tester, blockPoints(desk));
    for (var i = 0; i < before.length; i++) {
      expect(after[i], looksLike(over(before[i], tint)), reason: 'block $i');
    }
  }, variant: desktopPlatforms);

  testWidgets('a line whose writing is all hidden shows selected', (
    tester,
  ) async {
    final desk = await open(tester, readOnly: true);
    final rule = desk.text.indexOf('---\n');
    Offset onRule() {
      final row = desk.note.boxesFor(
        TextSelection(baseOffset: rule, extentOffset: rule + 3),
      );
      return desk.note.toGlobal(
        Offset(desk.note.columnWidth / 2, row.first.top + 2),
      );
    }

    final before = await pixels(tester, [onRule()]);
    await selectAll(desk);
    final after = await pixels(tester, [onRule()]);
    expect(
      after.single,
      looksLike(over(before.single, desk.note.selectionColor!)),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'part of a table shows selected as the cells and words it holds',
    (tester) async {
      final desk = await open(tester);
      final tea = desk.text.indexOf('tea');
      final cake = desk.text.indexOf('cake');
      final before = await pixels(tester, blockPoints(desk));
      desk.note.controller.selection = TextSelection(
        baseOffset: tea + 1,
        extentOffset: cake + 2,
      );
      await desk.settle();
      final after = await pixels(tester, blockPoints(desk));
      // The cell's padding is outside the words selected in it.
      expect(after.last, looksLike(before.last));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/selection_table_part_dark.png'),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final brightness in Brightness.values) {
    final name = brightness.name;
    testWidgets('Select All over every block, desktop $name', (tester) async {
      final desk = await open(tester, brightness: brightness);
      await selectAll(desk);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/selection_blocks_desktop_$name.png'),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Select All over every block, phone $name', (tester) async {
      final desk = await open(tester, brightness: brightness);
      await selectAll(desk);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/selection_blocks_phone_$name.png'),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }
}
