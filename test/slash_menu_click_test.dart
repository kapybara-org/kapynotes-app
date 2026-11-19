import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/note_image_view.dart';
import 'package:kapy_notes/ui/editor/slash_commands.dart';
import 'package:material_ui/material_ui.dart';

import 'support/desk.dart';
import 'test_fonts.dart';

void main() {
  late Directory folder;
  late BlobStore store;
  late NoteImageRef picture;

  setUpAll(() async {
    await loadTestFonts();
    folder = await Directory.systemTemp.createTemp('kapy_slash_click_');
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

  final desktop = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  });
  final phones = TargetPlatformVariant({
    TargetPlatform.iOS,
    TargetPlatform.android,
  });
  final menu = find.byKey(const ValueKey('slash-command-menu'));

  Future<(Desk, List<SlashCommandType>)> openMenu(WidgetTester tester) async {
    final chosen = <SlashCommandType>[];
    final desk = Desk(tester);
    await desk.open('', images: store, onSlashCommandChosen: chosen.add);
    await desk.type('/');
    expect(menu, findsOneWidget);
    return (desk, chosen);
  }

  group('choosing from the slash menu with a mouse', () {
    testWidgets('a click on a row runs it', (tester) async {
      final (desk, chosen) = await openMenu(tester);

      await desk.clickKey('slash-command-checklist');

      expect(chosen, [SlashCommandType.checklist]);
      expect(desk.text, '- [ ] ');
      expect(menu, findsNothing);
    }, variant: desktop);

    for (final command in [
      SlashCommandType.image,
      SlashCommandType.video,
      SlashCommandType.file,
    ]) {
      final name = command.name;
      testWidgets('a click on the $name icon runs it', (tester) async {
        final (desk, chosen) = await openMenu(tester);

        await desk.clickKey('slash-command-$name');

        expect(chosen, [command]);
        expect(menu, findsNothing);
      }, variant: desktop);
    }

    testWidgets('a click on Table opens the size grid and keeps the menu', (
      tester,
    ) async {
      final (desk, chosen) = await openMenu(tester);

      await desk.clickKey('slash-command-table');

      expect(find.byKey(const ValueKey('table-size-grid')), findsOneWidget);
      expect(menu, findsOneWidget);
      expect(chosen, isEmpty);
    }, variant: desktop);

    testWidgets('a click beside the menu still closes it', (tester) async {
      final (desk, chosen) = await openMenu(tester);

      await desk.click(const Offset(700, 600));

      expect(menu, findsNothing);
      expect(chosen, isEmpty);
    }, variant: desktop);
  });

  group('the other editor popups take a mouse click', () {
    testWidgets('the link popover copies the address', (tester) async {
      final desk = Desk(tester);
      await desk.open('https://kapynotes.app/docs');
      await desk.click(desk.on('kapynotes'));
      expect(find.byKey(const ValueKey('link-popover')), findsOneWidget);

      await desk.clickKey('link-popover-copy');

      expect(desk.clipboard['text'], 'https://kapynotes.app/docs');
      expect(find.byKey(const ValueKey('link-popover')), findsNothing);
    }, variant: desktop);

    testWidgets('the picture menu removes it', (tester) async {
      final desk = Desk(tester);
      await desk.open('Title\nsome words', images: store);
      desk.editor.insertImages([picture]);
      await desk.settle();
      expect(desk.attachments, hasLength(1));

      final image = tester.getCenter(find.byType(NoteImageView));
      final gesture = await tester.startGesture(
        image,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.up();
      await desk.settle();
      await desk.click(tester.getCenter(find.text('Remove image')));

      expect(desk.attachments, isEmpty);
    }, variant: desktop);
  });

  group('choosing from the slash menu by touch', () {
    testWidgets('a tap on a row runs it', (tester) async {
      final (desk, chosen) = await openMenu(tester);

      await tester.tap(find.byKey(const ValueKey('slash-command-checklist')));
      await desk.settle();

      expect(chosen, [SlashCommandType.checklist]);
      expect(desk.text, '- [ ] ');
      expect(menu, findsNothing);
    }, variant: phones);
  });
}
