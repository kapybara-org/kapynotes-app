import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_video_view.dart';
import 'package:material_ui/material_ui.dart';

import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-video-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// A note with a video still loading and one that can't be read, at the
/// phone's own width and at Android's Large text, where each says so under
/// its mark with nothing drawn over the words.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      final look = dark ? 'dark' : 'light';
      testWidgets('videos in a note at ${scale}x, $look', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final engine = CalcEngine();
        const anchor = NoteAttachmentRef.placeholder;
        const body =
            'Trip to Goa\n$anchor\nThe beach on the first day\n$anchor\n'
            'Sunset from the fort';
        final first = body.indexOf(anchor);
        NoteVideoRef video(int offset, String hash) => NoteVideoRef(
          offset: offset,
          hash: hash,
          key: Uint8List(32),
          mime: 'video/mp4',
          bytes: 1000,
          width: 1280,
          height: 720,
          durationMs: 65000,
        );

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? KapyTheme.dark() : KapyTheme.light(),
            home: Scaffold(
              body: SafeArea(
                child: NoteEditor(
                  noteId: 'videos',
                  initialBody: body,
                  initialAttachments: [
                    video(first, 'loading'),
                    video(body.indexOf(anchor, first + 1), 'missing'),
                  ],
                  images: BlobStore(
                    directory: await Directory.systemTemp.createTemp(
                      'phone-video',
                    ),
                  ),
                  imageFetch: (hash) => hash == 'loading'
                      ? Completer<Uint8List?>().future
                      : Future<Uint8List?>.value(),
                  engine: engine,
                  highlighter: Highlighter(engine.registry),
                  resultsVisible: true,
                  writingFont: WritingFont.handwritten,
                  shortcuts: ShortcutPrefs(_MemoryStore())..load(),
                  onDocumentChanged: (_, _, _, _) {},
                  onSettingsPressed: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(seconds: 1));
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle(const Duration(seconds: 1));

        expect(find.byType(NoteVideoView), findsNWidgets(2));
        expect(find.text('Loading video…'), findsOneWidget);
        expect(find.text('Video unavailable'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await screenshot(
          'video-${scale == 1.0 ? '1x' : 'large-text'}-$look',
          device: true,
        );
      });
    }
  }
}
