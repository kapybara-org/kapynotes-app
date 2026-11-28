import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/images/camera_capture.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fake_camera.dart';

const _megabyte = 1024 * 1024;

void main() {
  late Directory directory;
  late FakeCameraPlatform camera;
  late FakeCameraPhone phone;
  late FakeVideoPlayerPlatform player;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('kapy-camera-');
    camera = FakeCameraPlatform(directory);
    phone = FakeCameraPhone();
    player = FakeVideoPlayerPlatform();
    CameraPlatform.instance = camera;
    VideoPlayerPlatform.instance = player;
  });
  tearDown(() => directory.deleteSync(recursive: true));

  final shutter = find.byKey(const ValueKey('camera-shutter'));
  final library = find.byKey(const ValueKey('camera-library'));
  final pause = find.byKey(const ValueKey('camera-pause'));
  final retake = find.byKey(const ValueKey('camera-retake'));
  final useVideo = find.byKey(const ValueKey('camera-use-video'));
  final videoMode = find.byKey(const ValueKey('camera-mode-video'));
  final photoMode = find.byKey(const ValueKey('camera-mode-photo'));

  /// Opens the camera as a note does, and returns what it handed back once
  /// it has closed.
  Future<List<XFile>? Function()> open(
    WidgetTester tester, {
    bool startInVideo = false,
    int attachmentMaxBytes = 25 * _megabyte,
    ValueChanged<bool>? onVideoChosen,
    ImageLibraryPicker? chooseFromLibrary,
  }) async {
    List<XFile>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showNoteCamera(
                  context,
                  phone: phone,
                  startInVideo: startInVideo,
                  attachmentMaxBytes: attachmentMaxBytes,
                  onVideoChosen: onVideoChosen,
                  chooseFromLibrary: chooseFromLibrary ?? () async => const [],
                );
              },
              child: const Text('Open camera'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open camera'));
    await tester.pumpAndSettle();
    return () => result;
  }

  /// Taps the shutter in Video and lets the recording start.
  Future<void> record(WidgetTester tester) async {
    await tester.tap(shutter);
    await tester.pump();
    await tester.pump();
  }

  String shutterLabel(WidgetTester tester) => tester
      .widget<Semantics>(
        find.ancestor(of: shutter, matching: find.byType(Semantics)).first,
      )
      .properties
      .label!;

  testWidgets('with no camera, Photos is still there and it can try again', (
    tester,
  ) async {
    camera.cameras = const [];
    var libraryOpens = 0;
    await open(
      tester,
      chooseFromLibrary: () async {
        libraryOpens++;
        return const [];
      },
    );

    expect(find.text('No camera was found on this device.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('camera-choose-photos')));
    await tester.pumpAndSettle();
    expect(libraryOpens, 1);

    camera.cameras = const [backCamera];
    await tester.tap(find.byKey(const ValueKey('camera-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
  });

  testWidgets('Photos picks photos and videos and returns them as they are', (
    tester,
  ) async {
    final picked = [XFile('/tiles.jpg'), XFile('/leak.mov')];
    final result = await open(tester, chooseFromLibrary: () async => picked);

    expect(find.text('Photos'), findsOneWidget);
    await tester.tap(library);
    await tester.pumpAndSettle();

    expect(result(), picked);
    expect(find.byType(CameraCapturePage), findsNothing);
  });

  testWidgets('Photo is the camera it was: flash, flip, then Use photo', (
    tester,
  ) async {
    final result = await open(tester);
    expect(camera.opened.single!.enableAudio, isFalse);
    expect(find.byKey(const ValueKey('camera-flash')), findsOneWidget);
    expect(find.text('Flip'), findsOneWidget);
    expect(shutterLabel(tester), 'Take photo');

    await tester.tap(find.byKey(const ValueKey('camera-flash')));
    await tester.pumpAndSettle();
    expect(camera.flash, FlashMode.auto);

    await tester.tap(shutter);
    await tester.pumpAndSettle();
    expect(find.text('Review photo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('camera-use-photo')));
    await tester.pumpAndSettle();
    expect(result()!.single.path, endsWith('.jpg'));
  });

  testWidgets('the switch and a sideways swipe change mode, and each change '
      'is remembered', (tester) async {
    final chosen = <bool>[];
    await open(tester, onVideoChosen: chosen.add);

    await tester.tap(videoMode);
    await tester.pumpAndSettle();
    expect(chosen, [true]);
    expect(shutterLabel(tester), 'Start recording');
    expect(find.byKey(const ValueKey('camera-flash')), findsNothing);
    expect(find.byKey(const ValueKey('camera-light')), findsOneWidget);
    final settings = camera.opened.last!;
    expect(settings.resolutionPreset, ResolutionPreset.high);
    expect(settings.fps, 30);
    expect(settings.videoBitrate, 2500000);
    expect(settings.audioBitrate, 128000);
    expect(settings.enableAudio, isTrue);

    await tester.tap(find.byKey(const ValueKey('camera-light')));
    await tester.pumpAndSettle();
    expect(camera.flash, FlashMode.torch);

    final picture = find.byKey(const ValueKey('camera-picture'));
    await tester.fling(picture, const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(chosen, [true, false]);
    expect(shutterLabel(tester), 'Take photo');
    expect(camera.flash, FlashMode.off);

    await tester.fling(picture, const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(chosen, [true, false, true]);
    expect(shutterLabel(tester), 'Start recording');
  });

  testWidgets('it opens in the mode used last', (tester) async {
    await open(tester, startInVideo: true);
    expect(shutterLabel(tester), 'Start recording');
    expect(camera.opened.single!.enableAudio, isTrue);
  });

  testWidgets('a recording shows its time against the minute, and stops by '
      'itself at 1:00', (tester) async {
    final result = await open(tester, startInVideo: true);
    await record(tester);
    expect(camera.calls, contains('startVideo'));
    expect(shutterLabel(tester), 'Stop recording');
    expect(videoMode, findsNothing, reason: 'no switching mid-recording');
    expect(find.text('Flip'), findsNothing);

    await tester.pump(const Duration(seconds: 42));
    expect(find.text('0:42 / 1:00'), findsOneWidget);
    expect(camera.calls, isNot(contains('stopVideo')));

    await tester.pump(const Duration(seconds: 18));
    await tester.pump();
    expect(camera.calls.where((call) => call == 'stopVideo'), hasLength(1));
    expect(find.text('Review video'), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-review-note')), findsNothing);
    await tester.pumpAndSettle();

    await tester.tap(useVideo);
    await tester.pumpAndSettle();
    expect(result()!.single.path, endsWith('.mp4'));
  });

  testWidgets('tapping the shutter stops the recording', (tester) async {
    await open(tester, startInVideo: true);
    await record(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(shutter);
    await tester.pumpAndSettle();
    expect(camera.calls.last, 'stopVideo');
    expect(find.text('Review video'), findsOneWidget);
  });

  testWidgets('it stops before the video outgrows the plan, and says so', (
    tester,
  ) async {
    await open(tester, startInVideo: true);
    await record(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(camera.calls, isNot(contains('stopVideo')));

    phone.recorded = 24 * _megabyte;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(camera.calls.last, 'stopVideo');
    expect(
      find.text(
        'Recording stopped at 25 MB, the largest video your plan allows. '
        'You can keep what was recorded.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(useVideo).onPressed, isNotNull);
  });

  testWidgets('a bigger plan lets the recording grow further', (tester) async {
    await open(tester, startInVideo: true, attachmentMaxBytes: 100 * _megabyte);
    await record(tester);
    phone.recorded = 24 * _megabyte;
    await tester.pump(const Duration(seconds: 2));
    expect(camera.calls, isNot(contains('stopVideo')));
    expect(find.text('0:02 / 1:00'), findsOneWidget);
    await tester.tap(shutter);
    await tester.pumpAndSettle();
  });

  testWidgets('review checks the size before Use, where it could not be '
      'watched', (tester) async {
    camera.videoBytes = _megabyte + 1;
    await open(tester, startInVideo: true, attachmentMaxBytes: _megabyte);
    await record(tester);
    await tester.tap(shutter);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This video is too big to add (1 MB). Notes can hold videos up to '
        '1 MB. Try a shorter clip.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(useVideo).onPressed, isNull);
  });

  testWidgets('Pause and Resume carry on the same video', (tester) async {
    await open(tester, startInVideo: true);
    await record(tester);
    await tester.pump(const Duration(seconds: 5));

    await tester.tap(pause);
    await tester.pump();
    expect(camera.calls.last, 'pause');
    expect(find.text('Paused 0:05 / 1:00'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Paused 0:05 / 1:00'), findsOneWidget);

    await tester.tap(pause);
    await tester.pump();
    expect(camera.calls.last, 'resume');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('0:07 / 1:00'), findsOneWidget);

    await tester.tap(shutter);
    await tester.pumpAndSettle();
    expect(camera.calls.where((call) => call == 'startVideo'), hasLength(1));
    expect(camera.calls.where((call) => call == 'stopVideo'), hasLength(1));
  });

  testWidgets('with the microphone off it records without sound and says '
      'so', (tester) async {
    camera.soundError = CameraException('AudioAccessDenied', 'denied');
    await open(tester, startInVideo: true);

    expect(camera.opened.single!.enableAudio, isFalse);
    expect(
      find.text(
        'Your video will have no sound. To record sound, allow the '
        'microphone for Kapy Notes in Settings.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('camera-notice-action')));
    expect(phone.settingsOpened, 1);

    await record(tester);
    expect(camera.calls, contains('startVideo'));
    await tester.tap(shutter);
    await tester.pumpAndSettle();
    expect(find.text('Review video'), findsOneWidget);
  });

  testWidgets('the microphone is never asked for a photo', (tester) async {
    camera.soundError = CameraException('AudioAccessDenied', 'denied');
    await open(tester);
    expect(camera.opened.single!.enableAudio, isFalse);
    expect(find.byKey(const ValueKey('camera-mic-off')), findsNothing);
  });

  testWidgets('with camera access off it offers Settings and Photos', (
    tester,
  ) async {
    camera.openError = CameraException('CameraAccessDenied', 'denied');
    var libraryOpens = 0;
    await open(
      tester,
      chooseFromLibrary: () async {
        libraryOpens++;
        return const [];
      },
    );

    expect(find.text('Camera access is off'), findsOneWidget);
    expect(
      find.text(
        'To take photos and record videos here, allow the camera for Kapy '
        'Notes in Settings.',
      ),
      findsOneWidget,
    );
    expect(shutter, findsNothing);
    await tester.tap(find.text('Open Settings'));
    expect(phone.settingsOpened, 1);
    await tester.tap(find.text('Choose from Photos'));
    await tester.pumpAndSettle();
    expect(libraryOpens, 1);
  });

  testWidgets('a busy camera says so and can try again', (tester) async {
    camera.openError = CameraException('cameraInUse', 'in use');
    await open(tester);

    expect(find.text('The camera is busy'), findsOneWidget);
    expect(
      find.text("Another app or a call is using it. Try again when it's free."),
      findsOneWidget,
    );
    expect(find.text('Choose from Photos'), findsOneWidget);

    camera.openError = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('The camera is busy'), findsNothing);
    expect(shutter, findsOneWidget);
  });

  testWidgets('on an almost full phone a video cannot start, but a photo '
      'can', (tester) async {
    phone.free = 30 * _megabyte;
    await open(tester, startInVideo: true);

    expect(
      find.text(
        'Your phone is almost full. Free up some space to record a video. '
        'Photos still work.',
      ),
      findsOneWidget,
    );
    await tester.tap(shutter);
    await tester.pump();
    expect(camera.calls, isNot(contains('startVideo')));

    await tester.tap(photoMode);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('camera-phone-full')), findsNothing);
    await tester.tap(shutter);
    await tester.pumpAndSettle();
    expect(find.text('Review photo'), findsOneWidget);
  });

  testWidgets('leaving the app stops the recording and keeps it for review', (
    tester,
  ) async {
    await open(tester, startInVideo: true);
    await record(tester);
    await tester.pump(const Duration(seconds: 4));

    // Something over the app, such as a permission question, isn't leaving.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 1));
    expect(camera.calls, isNot(contains('stopVideo')));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(camera.calls.last, 'stopVideo');
    expect(
      find.text(
        'Recording stopped when you left the app. You can keep what was '
        'recorded.',
      ),
      findsOneWidget,
    );
    expect(useVideo, findsOneWidget);
  });

  testWidgets('a call coming in stops the recording and keeps it for review', (
    tester,
  ) async {
    await open(tester, startInVideo: true);
    await record(tester);
    await tester.pump(const Duration(seconds: 3));

    phone.call = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Recording stopped when a call came in. You can keep what was '
        'recorded.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a call already on when it starts doesn\'t stop it', (
    tester,
  ) async {
    phone.call = true;
    await open(tester, startInVideo: true);
    await record(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(camera.calls, isNot(contains('stopVideo')));
    expect(find.text('0:05 / 1:00'), findsOneWidget);
    await tester.tap(shutter);
    await tester.pumpAndSettle();
  });

  testWidgets('review plays the video; Retake throws it away and Use keeps '
      'the next', (tester) async {
    final result = await open(tester, startInVideo: true);
    await record(tester);
    await tester.tap(shutter);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fake-player')), findsOneWidget);
    expect(find.text('0:42'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('camera-review-play')));
    await tester.pump();
    expect(player.calls, contains('play'));

    final first = directory.listSync().whereType<File>().single.path;
    await tester.tap(retake);
    await tester.pumpAndSettle();
    expect(File(first).existsSync(), isFalse);
    expect(shutterLabel(tester), 'Start recording');
    expect(result(), isNull);

    await record(tester);
    await tester.tap(shutter);
    await tester.pumpAndSettle();
    await tester.tap(useVideo);
    await tester.pumpAndSettle();
    expect(result()!.single.path, isNot(first));
    expect(File(result()!.single.path).existsSync(), isTrue);
  });

  testWidgets('closing mid-recording keeps nothing', (tester) async {
    final result = await open(tester, startInVideo: true);
    await record(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(const ValueKey('camera-close')));
    await tester.pumpAndSettle();
    expect(result(), isEmpty);
    expect(camera.calls, containsAllInOrder(['stopVideo', 'dispose']));
    expect(directory.listSync(), isEmpty);
  });

  group('the camera channel', () {
    const channel = MethodChannel('kapynotes/camera');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    void answer(Object? Function(MethodCall call) reply) => messenger
        .setMockMethodCallHandler(channel, (call) async => reply(call));

    test('asks the phone for free space, calls and Settings', () async {
      final asked = <String>[];
      answer((call) {
        asked.add(call.method);
        return switch (call.method) {
          'freeBytes' => 5 * _megabyte,
          'inCall' => true,
          _ => null,
        };
      });
      const phone = CameraPhone();
      expect(await phone.freeBytes(), 5 * _megabyte);
      expect(await phone.inCall(), isTrue);
      await phone.openSettings();
      expect(asked, ['freeBytes', 'inCall', 'openSettings']);
    });

    test('with no answer, a video may start and no call is on', () async {
      const phone = CameraPhone();
      expect(await phone.freeBytes(), isNull);
      expect(await phone.inCall(), isFalse);
      await phone.openSettings();
    });

    test('a platform error reads the same as no answer', () async {
      answer((call) => throw PlatformException(code: 'failed'));
      const phone = CameraPhone();
      expect(await phone.freeBytes(), isNull);
      expect(await phone.inCall(), isFalse);
      await phone.openSettings();
    });

    test('a phone that says nothing about a call has none', () async {
      answer((call) => null);
      expect(await const CameraPhone().inCall(), isFalse);
    });
  });

  group('the size of a recording as it grows', () {
    late Directory temporary;
    setUp(() => temporary = Directory.systemTemp.createTempSync('kapy-rec-'));
    tearDown(() {
      temporary.deleteSync(recursive: true);
      AppPlatform.debugTargetPlatformOverride = null;
    });

    CameraPhone phoneOver(Directory folder) =>
        CameraPhone(temporaryDirectory: () async => folder);

    test('on Android it is the newest REC file in the cache', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      final since = DateTime.now().subtract(const Duration(seconds: 1));
      File(
        '${temporary.path}/REC123.mp4',
      ).writeAsBytesSync(List.filled(300, 0));
      File('${temporary.path}/other.mp4').writeAsBytesSync(List.filled(900, 0));
      final old = File('${temporary.path}/REC000.mp4')
        ..writeAsBytesSync(List.filled(700, 0));
      old.setLastModifiedSync(since.subtract(const Duration(minutes: 5)));

      expect(await phoneOver(temporary).recordingBytes(since), 300);
    });

    test('on iOS it is in camera/videos', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      final since = DateTime.now().subtract(const Duration(seconds: 1));
      expect(await phoneOver(temporary).recordingBytes(since), isNull);
      final videos = Directory('${temporary.path}/camera/videos')
        ..createSync(recursive: true);
      File('${videos.path}/REC_A1B2.mp4').writeAsBytesSync(List.filled(500, 0));
      expect(await phoneOver(temporary).recordingBytes(since), 500);
    });
  });
}
