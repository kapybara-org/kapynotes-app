import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/images/note_image_provider.dart';
import 'package:kapy_notes/ui/editor/note_image_layout.dart';
import 'package:kapy_notes/ui/editor/note_video_view.dart';
import 'package:material_ui/material_ui.dart';

import '../test_fonts.dart';

void main() {
  final bytes = Uint8List.fromList(List.generate(64, (i) => i));
  final kept = BlobStore.hashOf(bytes);
  late BlobStore store;

  setUpAll(() async {
    await loadTestFonts();
    store = BlobStore(
      directory: await Directory.systemTemp.createTemp('video-view'),
    );
    await store.put(bytes, extension: 'mp4');
  });
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  NoteVideoRef video(String hash) => NoteVideoRef(
    offset: 0,
    hash: hash,
    key: Uint8List(32),
    mime: 'video/mp4',
    bytes: bytes.length,
    width: 1280,
    height: 720,
    durationMs: 65000,
  );

  /// A video in its place in a note, on a phone or a desktop as [platform]
  /// says, once it has looked for its file.
  Future<void> pumpVideo(
    WidgetTester tester, {
    required TargetPlatform platform,
    required double scale,
    required String hash,
    NoteImageFetcher? fetch,
    bool dark = false,
    bool increaseContrast = false,
  }) async {
    AppPlatform.debugTargetPlatformOverride = platform;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final width = platform == TargetPlatform.android ? 372.0 : 680.0;
    await tester.pumpWidget(
      MaterialApp(
        theme: dark
            ? KapyTheme.dark(increaseContrast: increaseContrast)
            : KapyTheme.light(increaseContrast: increaseContrast),
        home: Scaffold(
          body: Center(
            child: NoteVideoView(
              ref: video(hash),
              box: NoteImageBox(
                width: width,
                height: width * 9 / 16,
                cropped: false,
              ),
              store: store,
              fetch: fetch,
              onOpen: () {},
              onRemove: () {},
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  final play = find.byWidgetPredicate(
    (widget) => widget is KapyIcon && widget.icon == KapyIcons.playRounded,
  );
  final mark = find.byWidgetPredicate(
    (widget) => widget is KapyIcon && widget.icon == KapyIcons.videoOutlined,
  );

  /// [above] sits over [words], clear of them, and both are inside the video.
  void stacked(WidgetTester tester, Finder above, String words) {
    final video = tester.getRect(find.byType(NoteVideoView));
    final top = tester.getRect(above);
    final label = tester.getRect(find.text(words));
    expect(top.bottom, lessThanOrEqualTo(label.top), reason: words);
    for (final part in [top, label]) {
      expect(video.contains(part.topLeft), isTrue, reason: words);
      expect(video.contains(part.bottomRight), isTrue, reason: words);
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    final where = platform == TargetPlatform.android ? 'a phone' : 'a desktop';
    for (final scale in [1.0, 1.3]) {
      testWidgets('on $where at ${scale}x, a video still loading says so '
          'under its mark, with no play button', (tester) async {
        await pumpVideo(
          tester,
          platform: platform,
          scale: scale,
          hash: 'loading',
          fetch: (_) => Completer<Uint8List?>().future,
        );
        expect(play, findsNothing);
        stacked(tester, mark, 'Loading video…');
      });

      testWidgets('on $where at ${scale}x, a video that cannot be read says '
          'so under its mark, with no play button', (tester) async {
        await pumpVideo(
          tester,
          platform: platform,
          scale: scale,
          hash: 'missing',
        );
        expect(play, findsNothing);
        stacked(tester, mark, 'Video unavailable');
      });
    }
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets('on Linux at ${scale}x, a video that opens in the video '
        'player says so under the play glyph', (tester) async {
      await pumpVideo(
        tester,
        platform: TargetPlatform.linux,
        scale: scale,
        hash: kept,
      );
      expect(mark, findsNothing);
      expect(tester.getSize(play), const Size.square(26));
      stacked(tester, play, 'Opens in your video player');
    });
  }

  testWidgets('the mark and its words keep one light ink on the black card, '
      'in light and in dark, stronger with Increase contrast', (tester) async {
    for (final contrast in [false, true]) {
      final dark = KapyTheme.darkPalette;
      final ink = (contrast ? dark.withIncreasedContrast() : dark).textTertiary;
      for (final appearance in [false, true]) {
        // A fresh app each time, so the ink isn't read halfway through
        // the theme's change from the last case.
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpVideo(
          tester,
          platform: TargetPlatform.android,
          scale: 1,
          hash: 'missing',
          dark: appearance,
          increaseContrast: contrast,
        );
        final reason = '${appearance ? 'dark' : 'light'}, contrast $contrast';
        final words = tester.widget<Text>(find.text('Video unavailable'));
        expect(words.style?.color, ink, reason: reason);
        expect(tester.widget<KapyIcon>(mark).color, ink, reason: reason);
      }
    }
    expect(
      KapyTheme.darkPalette.withIncreasedContrast().textTertiary,
      isNot(KapyTheme.darkPalette.textTertiary),
    );
  });
}
