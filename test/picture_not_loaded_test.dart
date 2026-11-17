import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/note_image_layout.dart';
import 'package:kapy_notes/ui/editor/note_image_view.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

/// A pasted picture known only by its address, downloading or not loaded.
NoteImageRef _picture({required bool downloading}) => NoteImageRef(
  offset: 0,
  hash: 'h',
  key: Uint8List(32),
  mime: 'image/png',
  width: 334,
  height: 200,
  bytes: 0,
  isPreparing: downloading,
  src: 'https://wikimedia.org/photo.jpg',
);

void main() {
  late Directory folder;
  late BlobStore store;

  setUpAll(() async {
    await loadTestFonts();
    folder = await Directory.systemTemp.createTemp('kapy_not_loaded_');
    store = BlobStore(directory: folder);
  });

  tearDownAll(() => folder.delete(recursive: true));

  /// Both states side by side, as Paper's editor-7 artboard has them.
  Widget tiles(ThemeData theme, {VoidCallback? onRetry}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      body: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            for (final downloading in [true, false])
              NoteImageView(
                ref: _picture(downloading: downloading),
                box: const NoteImageBox(
                  width: 334,
                  height: 200,
                  cropped: false,
                ),
                store: store,
                onRetry: onRetry ?? () {},
              ),
          ],
        ),
      ),
    ),
  );

  testWidgets('a picture downloading says where from', (tester) async {
    await tester.pumpWidget(tiles(KapyTheme.light()));

    expect(find.byKey(const ValueKey('image-downloading')), findsOneWidget);
    expect(find.text('Downloading from wikimedia.org…'), findsOneWidget);
  });

  testWidgets("a picture that didn't load offers another try and its page", (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(tiles(KapyTheme.light(), onRetry: () => retries++));

    expect(find.text("Couldn't load image from wikimedia.org"), findsOneWidget);
    expect(find.byKey(const ValueKey('open-image-address')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-image-download')));
    expect(retries, 1);
  });

  for (final (name, theme) in [
    ('light', KapyTheme.light),
    ('dark', KapyTheme.dark),
  ]) {
    testWidgets('pictures not loaded, $name', (tester) async {
      await tester.binding.setSurfaceSize(const Size(760, 280));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(tiles(theme()));
      // Far enough into the spinner's turn that its arc shows.
      await tester.pump(const Duration(milliseconds: 250));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/picture_not_loaded_$name.png'),
      );
    });
  }
}
