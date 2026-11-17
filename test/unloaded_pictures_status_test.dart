import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_image_view.dart';
import 'package:kapy_notes/ui/tonal_button.dart';
import 'package:kapy_notes/ui/unloaded_pictures_status.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

void main() {
  setUpAll(() async => loadTestFonts());

  Widget status(ThemeData theme, {int count = 1, VoidCallback? onPressed}) =>
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          body: Center(
            child: UnloadedPicturesStatus(
              count: count,
              onPressed: onPressed ?? () {},
            ),
          ),
        ),
      );

  testWidgets('it counts the pictures and shows the first when pressed', (
    tester,
  ) async {
    var shown = 0;
    await tester.pumpWidget(
      status(KapyTheme.light(), onPressed: () => shown++),
    );

    expect(find.text("1 picture didn't load"), findsOneWidget);
    await tester.tap(find.byType(UnloadedPicturesStatus));
    expect(shown, 1);

    await tester.pumpWidget(status(KapyTheme.light(), count: 3));
    expect(find.text("3 pictures didn't load"), findsOneWidget);
  });

  testWidgets(
    'the page says it in place of Saved until the last one loads or goes',
    (tester) async {
      // A file stands in for the web, which the test binding answers with 400.
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kapy_unloaded_'),
      ))!;
      addTearDown(() => folder.delete(recursive: true));
      final photo = File('${folder.path}/photo.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 120, height: 90)));

      const anchor = NoteAttachmentRef.placeholder;
      final lines = [for (var i = 1; i <= 40; i++) 'Line $i'].join('\n');
      final body = 'Field trip\n$lines\n$anchor\n$lines\n$anchor\n$lines';
      final first = body.indexOf(anchor);
      final second = body.lastIndexOf(anchor);
      NoteImageRef unloaded(int offset, String address) => NoteImageRef(
        offset: offset,
        hash: BlobStore.hashOf(Uint8List.fromList(utf8.encode(address))),
        key: Uint8List(32),
        mime: 'image/png',
        width: 360,
        height: 240,
        bytes: 0,
        src: address,
      );

      final store = MemoryStore()
        ..data[Onboarding.storeKey] = Onboarding.welcomeRevision;
      final notes = NotesStore(store, blobs: BlobStore(directory: folder));
      final prefs = LayoutPrefs(store);
      final shortcuts = ShortcutPrefs(store);
      await notes.load();
      prefs.load();
      shortcuts.load();
      final id = notes.create().id;
      notes.updateDocument(id, body, const [], [
        unloaded(first, photo.uri.toString()),
        unloaded(second, 'https://example.com/gone.png'),
      ]);
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: RatesRepository(store),
          prefs: prefs,
          shortcuts: shortcuts,
        ),
      );
      await tester.pumpAndSettle();

      Finder picture(int offset) => find.byWidgetPredicate(
        (widget) => widget is NoteImageView && widget.ref.offset == offset,
      );
      // Where the field lays the picture out, less how far it has scrolled:
      // the field paints its pictures shifted by its scroll, which their
      // transform leaves out, so their global rect is where they'd be
      // unscrolled.
      bool inView(int offset) {
        var child = tester.renderObject(picture(offset));
        while (child.parent is! RenderEditable) {
          child = child.parent!;
        }
        final field = child.parent! as RenderEditable;
        final top =
            (child.parentData! as TextParentData).offset!.dy -
            field.offset.pixels;
        return top >= 0 &&
            top + (child as RenderBox).size.height <= field.size.height;
      }

      final saved = find.byKey(const ValueKey('page-saved'));
      expect(saved, findsNothing);
      expect(find.text("2 pictures didn't load"), findsOneWidget);
      expect(inView(first), isFalse);

      await tester.tap(find.byType(UnloadedPicturesStatus));
      await tester.pumpAndSettle();
      expect(inView(first), isTrue);
      expect(inView(second), isFalse);

      await tester.runAsync(() async {
        tester
            .widget<TonalButton>(
              find.descendant(
                of: picture(first),
                matching: find.byKey(const ValueKey('retry-image-download')),
              ),
            )
            .onPressed!();
        bool loading() => switch (notes.byId(id)!.attachments.first) {
          NoteImageRef(:final src, :final isPreparing) =>
            src != null || isPreparing,
          _ => false,
        };
        for (var i = 0; i < 500 && loading(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(tester.widget<NoteImageView>(picture(first)).ref.src, isNull);
      expect(find.text("1 picture didn't load"), findsOneWidget);

      tester
          .state<NoteEditorState>(find.byType(NoteEditor))
          .removeAttachment(second);
      await tester.pumpAndSettle();
      expect(find.byType(UnloadedPicturesStatus), findsNothing);
      expect(
        find.descendant(of: saved, matching: find.text('Saved')),
        findsOneWidget,
      );
    },
  );

  for (final (name, theme) in [
    ('light', KapyTheme.light),
    ('dark', KapyTheme.dark),
  ]) {
    testWidgets('pictures not loaded status, $name', (tester) async {
      await tester.binding.setSurfaceSize(const Size(220, 64));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(status(theme()));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/unloaded_pictures_status_$name.png'),
      );
    });
  }
}
