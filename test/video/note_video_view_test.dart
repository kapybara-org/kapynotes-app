import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/images/note_image_provider.dart';
import 'package:kapy_notes/ui/editor/note_image_layout.dart';
import 'package:kapy_notes/ui/editor/note_video_view.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart' show VideoProgressIndicator;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../test_fonts.dart';
import 'fake_video_player.dart';

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
  late FakeVideoPlayer player;
  setUp(() => VideoPlayerPlatform.instance = player = FakeVideoPlayer());
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

  /// [ref] in a note [width] wide on an 800-tall screen, sized by the photos'
  /// own rule, with [extra] scrolling room under it.
  Future<NoteImageBox> pumpCard(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
    NoteVideoRef? ref,
    NoteImageBox? box,
    ValueListenable<double?>? progress,
    double extra = 0,
  }) async {
    AppPlatform.debugTargetPlatformOverride = platform;
    final shown = ref ?? video(kept);
    final sized =
        box ??
        imageBoxFor(
          countOnLine: 1,
          columnWidth: 372,
          aspectRatio: shown.aspectRatio,
          maxHeight: 800 * 0.6,
        );
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: NoteVideoView(
                    ref: shown,
                    box: sized,
                    store: store,
                    uploadProgress: progress,
                    onRemove: () {},
                  ),
                ),
                SizedBox(height: extra),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    return sized;
  }

  final card = find.byType(NoteVideoView);
  Finder inCard(Finder of) => find.descendant(of: card, matching: of);
  final playButton = find.byKey(const ValueKey('video-play'));
  final playPause = find.byKey(const ValueKey('note-video-play-pause'));
  final time = find.byKey(const ValueKey('video-time'));
  String timeText(WidgetTester tester) =>
      tester.widget<Text>(time).textSpan!.toPlainText();

  KapyIconData iconOf(WidgetTester tester, Finder button) => tester
      .widget<KapyIcon>(
        find.descendant(of: button, matching: find.byType(KapyIcon)),
      )
      .icon;

  /// Lets file reads started by the app finish, a step at a time.
  Future<void> settleFiles(WidgetTester tester) async {
    for (var step = 0; step < 4; step++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
    }
    await tester.pump();
  }

  Future<void> startPlaying(WidgetTester tester) async {
    await tester.tap(playButton);
    await tester.pump();
  }

  group('the card follows the photos', () {
    NoteVideoRef shaped(int width, int height) => NoteVideoRef(
      offset: 0,
      hash: kept,
      key: Uint8List(32),
      mime: 'video/mp4',
      bytes: bytes.length,
      width: width,
      height: height,
      durationMs: 65000,
    );

    void looksLike(WidgetTester tester, NoteImageBox box, double radius) {
      final clip = inCard(find.byType(ClipRRect)).first;
      expect(tester.getSize(clip), Size(box.width, box.height));
      expect(
        tester.widget<ClipRRect>(clip).borderRadius,
        BorderRadius.circular(radius),
      );
      expect(
        tester.widget<FittedBox>(inCard(find.byType(FittedBox)).first).fit,
        box.cropped ? BoxFit.cover : BoxFit.contain,
      );
    }

    testWidgets('a wide video fills the column, corners 10', (tester) async {
      final box = await pumpCard(tester, ref: shaped(1280, 720));
      expect(box.width, 372);
      expect(box.height, closeTo(372 * 720 / 1280, 0.01));
      looksLike(tester, box, 10);
    });

    testWidgets('a tall video stops at 60% of the screen, corners 10', (
      tester,
    ) async {
      final box = await pumpCard(tester, ref: shaped(720, 1280));
      expect(box.height, 480);
      expect(box.width, closeTo(480 * 720 / 1280, 0.01));
      looksLike(tester, box, 10);
    });

    testWidgets('a cropped video fills its tile, corners 8', (tester) async {
      final box = imageBoxFor(
        countOnLine: 2,
        columnWidth: 372,
        aspectRatio: 16 / 9,
        maxHeight: 480,
      );
      expect(box.cropped, isTrue);
      await pumpCard(tester, box: box);
      looksLike(tester, box, 8);
    });
  });

  testWidgets('it never plays by itself: its first frame, play and its '
      'length wait for a tap', (tester) async {
    await pumpCard(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(player.calls, isNot(contains('play')));
    expect(playButton, findsOneWidget);
    expect(inCard(find.text('1:05')), findsOneWidget);
    expect(playPause, findsNothing);
  });

  testWidgets('play starts it in the note with sound, and pause stops it', (
    tester,
  ) async {
    await pumpCard(tester);
    await startPlaying(tester);

    expect(player.calls, contains('play'));
    expect(player.calls, isNot(contains('volume 0.0')));
    expect(playButton, findsNothing);
    expect(iconOf(tester, playPause), KapyIcons.pauseRounded);
    expect(timeText(tester), '0:00 / 1:05');
    for (final key in ['video-sound', 'video-full-screen']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }

    await tester.tap(playPause);
    await tester.pump();
    expect(player.calls.last, 'pause');
    expect(iconOf(tester, playPause), KapyIcons.playRounded);

    await tester.tap(find.byKey(const ValueKey('video-sound')));
    await tester.pump();
    expect(player.calls.last, 'volume 0.0');
    expect(
      iconOf(tester, find.byKey(const ValueKey('video-sound'))),
      KapyIcons.volumeOffRounded,
    );
  });

  testWidgets('scrolling it out of sight pauses it', (tester) async {
    await pumpCard(tester, extra: 3000);
    await startPlaying(tester);
    expect(player.calls.last, 'play');

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    await tester.pump();
    expect(player.calls.last, 'play', reason: 'still in sight');

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1200),
    );
    await tester.pump();
    expect(player.calls.last, 'pause');
  });

  testWidgets('on a computer the bar shows under the pointer, or paused', (
    tester,
  ) async {
    await pumpCard(tester, platform: TargetPlatform.macOS);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(card));
    await tester.pump();
    await startPlaying(tester);
    expect(playPause, findsOneWidget);

    await mouse.moveTo(const Offset(790, 790));
    await tester.pump();
    expect(playPause, findsNothing, reason: 'playing, pointer away');
    expect(find.byKey(const ValueKey('video-played')), findsOneWidget);

    await tester.tap(card);
    await tester.pump();
    expect(player.calls.last, 'pause');
    expect(playPause, findsOneWidget, reason: 'paused');
  });

  testWidgets('full screen pauses the card and opens the player at the same '
      'moment', (tester) async {
    await pumpCard(tester);
    await startPlaying(tester);
    await tester.tap(find.byKey(const ValueKey('video-full-screen')));
    await settleFiles(tester);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(NoteVideoViewer), findsOneWidget);
    expect(player.calls.where((call) => call == 'pause'), isNotEmpty);
    expect(player.calls.last, 'play', reason: '${player.calls}');
  });

  for (final how in ['Close', 'back']) {
    testWidgets('full screen closed by $how hands its moment back', (
      tester,
    ) async {
      await pumpCard(tester);
      await startPlaying(tester);
      await tester.tap(find.byKey(const ValueKey('video-full-screen')));
      await settleFiles(tester);
      await tester.pump(const Duration(milliseconds: 200));
      final viewer = player.made - 1;
      player.positions[viewer] = const Duration(seconds: 7);
      await tester.pump(const Duration(milliseconds: 600));
      if (how == 'Close') {
        tester
            .widgetList<IconButton>(find.byType(IconButton))
            .firstWhere((button) => button.tooltip == 'Close')
            .onPressed!();
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(find.byType(NoteVideoViewer), findsNothing);
      expect(player.positions[0], const Duration(seconds: 7));
    });
  }

  testWidgets('full screen has the time at both ends of its bar', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      MaterialApp(
        home: NoteVideoViewer(
          ref: video(kept),
          store: store,
          start: const Duration(seconds: 12),
          play: false,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    final elapsed = find.byKey(const ValueKey('video-viewer-elapsed'));
    final length = find.byKey(const ValueKey('video-viewer-length'));
    expect(tester.widget<Text>(elapsed).data, '0:12');
    expect(tester.widget<Text>(length).data, '1:05');
    expect(player.calls, isNot(contains('play')));
    final bar = tester.getRect(find.byType(VideoProgressIndicator));
    expect(tester.getRect(elapsed).right, lessThan(bar.left));
    expect(tester.getRect(length).left, greaterThan(bar.right));
  });

  testWidgets('on Linux the card makes no player, and a tap hands the video '
      'to the person\'s own', (tester) async {
    await pumpCard(tester, platform: TargetPlatform.linux);
    expect(player.made, 0);
    expect(inCard(find.text('Opens in your video player')), findsOneWidget);

    await tester.tap(card);
    await settleFiles(tester);
    expect(player.made, 0);
    expect(playPause, findsNothing);
    // No system player in a test, so the app says it could not open one.
    expect(find.text('Could not open the video'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  group('uploading', () {
    SettingsPie pie(WidgetTester tester) => tester.widget<SettingsPie>(
      find.byKey(const ValueKey('video-upload-pie')),
    );

    testWidgets('a 14 px pie by the length fills, with no cover over the '
        'picture', (tester) async {
      final progress = ValueNotifier<double?>(0.25);
      addTearDown(progress.dispose);
      await pumpCard(tester, progress: progress);

      expect(pie(tester).fraction, 0.25);
      expect(tester.getSize(find.byType(SettingsPie)), const Size.square(14));
      final pill = tester.getRect(inCard(find.text('1:05')));
      final face = tester.getRect(find.byType(SettingsPie));
      expect(face.right, lessThan(pill.left));
      expect((face.center.dy - pill.center.dy).abs(), lessThan(2));
      expect(find.textContaining('%'), findsNothing);

      progress.value = 0.8;
      await tester.pump();
      expect(pie(tester).fraction, 0.8);
      expect(playButton, findsOneWidget, reason: 'it plays while uploading');
    });

    testWidgets('an uploaded video shows no pie', (tester) async {
      final progress = ValueNotifier<double?>(1);
      addTearDown(progress.dispose);
      await pumpCard(
        tester,
        ref: video(kept).copyWith(attachmentId: 'a1'),
        progress: progress,
      );
      expect(find.byType(SettingsPie), findsNothing);
      expect(inCard(find.text('1:05')), findsOneWidget);
    });
  });
  for (final (name, theme) in [
    ('light', KapyTheme.light),
    ('dark', KapyTheme.dark),
  ]) {
    testWidgets('a video in a phone note, just added and playing, $name', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      await tester.binding.setSurfaceSize(const Size(640, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final progress = ValueNotifier<double?>(0.4);
      addTearDown(progress.dispose);
      const box = NoteImageBox(
        width: 300,
        height: 300 * 9 / 16,
        cropped: false,
      );
      Widget card(Key key) => NoteVideoView(
        key: key,
        ref: video(kept),
        box: box,
        store: store,
        uploadProgress: progress,
        onRemove: () {},
      );
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  card(const ValueKey('added')),
                  const SizedBox(width: 16),
                  card(const ValueKey('playing')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('playing')),
          matching: playButton,
        ),
      );
      await tester.pump();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/note_video_phone_$name.png'),
      );
    });
  }
}
