import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/images/desktop_camera.dart';
import 'package:camera_macos/camera_macos_arguments.dart' show AudioFormat;
import 'package:kapy_notes/ui/desktop_camera_window.dart';
import 'package:kapy_notes/ui/tonal_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fake_camera.dart';

const _megabyte = 1024 * 1024;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FakeDesktopCamera camera;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('kapy-desktop-camera-');
    camera = FakeDesktopCamera();
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
  });
  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    directory.deleteSync(recursive: true);
  });

  final shutter = find.byKey(const ValueKey('camera-shutter'));
  final videoMode = find.byKey(const ValueKey('camera-mode-video'));
  final photoMode = find.byKey(const ValueKey('camera-mode-photo'));
  final retake = find.byKey(const ValueKey('camera-retake'));
  final use = find.byKey(const ValueKey('camera-use'));
  final timer = find.byKey(const ValueKey('camera-timer'));
  final note = find.byKey(const ValueKey('camera-review-note'));
  final microphoneOff = find.byKey(const ValueKey('camera-microphone-off'));

  /// Opens the camera window as a note does, and returns what it handed
  /// back once it has closed.
  Future<List<XFile>? Function()> open(
    WidgetTester tester, {
    bool startInVideo = false,
    String? cameraId,
    int attachmentMaxBytes = 25 * _megabyte,
    ValueChanged<bool>? onVideoChosen,
    ValueChanged<String>? onCameraChosen,
    Future<List<XFile>> Function()? chooseFiles,
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    List<XFile>? result;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? KapyTheme.dark()
            : KapyTheme.light(),
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showDesktopCamera(
                  context,
                  camera: camera,
                  attachmentMaxBytes: attachmentMaxBytes,
                  chooseFiles: chooseFiles ?? () async => const [],
                  startInVideo: startInVideo,
                  onVideoChosen: onVideoChosen,
                  cameraId: cameraId,
                  onCameraChosen: onCameraChosen,
                  captureDirectory: () async => directory,
                );
                closed = true;
              },
              child: const Text('Open camera'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open camera'));
    await tester.pumpAndSettle();
    return () => closed ? result : null;
  }

  Future<void> space(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Space takes a photo, review offers Retake and Use photo, and '
      'Use returns it', (tester) async {
    final result = await open(tester);
    expect(find.text('Camera'), findsOneWidget);
    expect(camera.calls, ['open built-in photo']);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
    expect(find.text('FaceTime HD Camera'), findsOneWidget);

    await space(tester);
    await tester.pumpAndSettle();
    expect(camera.calls.last, 'photo');
    expect(find.text('Review photo'), findsOneWidget);
    expect(find.text('Photo'), findsWidgets);
    expect(find.text('Use photo'), findsOneWidget);

    // Space does nothing in review: the photo waits for a choice.
    await space(tester);
    expect(camera.calls.where((call) => call == 'photo'), hasLength(1));

    await tester.tap(retake);
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
    expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);

    await tester.tap(shutter);
    await tester.pumpAndSettle();
    await tester.tap(use);
    await tester.pumpAndSettle();
    final kept = result()!;
    expect(kept, hasLength(1));
    expect(kept.single.path, endsWith('.jpg'));
    expect(File(kept.single.path).existsSync(), isTrue);
  });

  testWidgets('Esc closes the window and keeps nothing', (tester) async {
    final result = await open(tester);
    await space(tester);
    await tester.pumpAndSettle();
    expect(find.text('Review photo'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result(), isEmpty);
    expect(find.text('Review photo'), findsNothing);
    expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
    expect(camera.calls.last, 'close');
  });

  testWidgets('the switch changes mode, asks for the microphone only for '
      'Video, and is remembered', (tester) async {
    final modes = <bool>[];
    await open(tester, onVideoChosen: modes.add);
    expect(camera.calls, ['open built-in photo']);

    await tester.tap(videoMode);
    await tester.pumpAndSettle();
    expect(modes, [true]);
    expect(camera.calls, [
      'open built-in photo',
      'close',
      'open built-in video sound',
    ]);
    expect(
      tester.getSemantics(shutter),
      matchesSemantics(label: 'Start recording', isButton: true),
    );

    await tester.tap(photoMode);
    await tester.pumpAndSettle();
    expect(modes, [true, false]);
    expect(camera.calls.last, 'open built-in photo');
  });

  testWidgets('it opens in the mode and on the camera used last', (
    tester,
  ) async {
    await open(tester, startInVideo: true, cameraId: 'usb');
    expect(camera.calls, ['open usb video sound']);
    expect(find.text('USB Camera'), findsOneWidget);
  });

  testWidgets('a camera that has gone falls back to the first one', (
    tester,
  ) async {
    await open(tester, cameraId: 'unplugged');
    expect(camera.calls, ['open built-in photo']);
  });

  testWidgets('the camera list picks another camera and remembers it', (
    tester,
  ) async {
    final chosen = <String>[];
    await open(tester, onCameraChosen: chosen.add);
    await tester.tap(find.byKey(const ValueKey('camera-list')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB Camera').last);
    await tester.pumpAndSettle();
    expect(chosen, ['usb']);
    expect(camera.calls.last, 'open usb photo');
    expect(find.text('USB Camera'), findsOneWidget);

    // A mode change keeps the camera chosen.
    await tester.tap(videoMode);
    await tester.pumpAndSettle();
    expect(camera.calls.last, 'open usb video sound');
  });

  testWidgets('Space starts and stops a video, with its time against the '
      'minute; Retake throws it away and Use video keeps it', (tester) async {
    final result = await open(tester, startInVideo: true);
    expect(find.text('Camera'), findsOneWidget);

    await space(tester);
    expect(camera.calls.last, 'start');
    expect(timer, findsOneWidget);
    expect(
      tester.getSemantics(shutter),
      matchesSemantics(label: 'Stop recording', isButton: true),
    );
    await tester.pump(const Duration(seconds: 12));
    expect(
      find.descendant(of: timer, matching: find.textContaining('0:12')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: timer, matching: find.textContaining('1:00')),
      findsOneWidget,
    );
    // Nothing else can change while it records.
    await tester.tap(photoMode);
    await tester.pump();
    expect(camera.calls.last, 'start');

    await space(tester);
    await tester.pumpAndSettle();
    expect(camera.calls.last, 'stop');
    expect(find.text('Review video'), findsOneWidget);
    expect(find.text('Video · 0:12'), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-review-play')), findsOneWidget);
    expect(find.text('0:42'), findsOneWidget);
    final first = camera.calls.length;

    await tester.tap(retake);
    await tester.pumpAndSettle();
    expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
    expect(camera.calls.length, first, reason: 'the camera stayed open');

    await tester.tap(shutter);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(shutter);
    await tester.pumpAndSettle();
    await tester.tap(use);
    await tester.pumpAndSettle();
    expect(result()!.single.path, endsWith('.mp4'));
  });

  testWidgets('a recording stops by itself at 1:00', (tester) async {
    await open(tester, startInVideo: true);
    await space(tester);
    await tester.pump(const Duration(seconds: 59));
    expect(camera.calls.last, 'start');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(camera.calls.last, 'stop');
    expect(find.text('Review video'), findsOneWidget);
    expect(find.text('Video · 1:00'), findsOneWidget);
    expect(note, findsNothing);
  });

  testWidgets('it stops before the video outgrows the plan, and says so', (
    tester,
  ) async {
    await open(tester, startInVideo: true);
    await space(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(camera.calls.last, 'start');

    final growing = File(camera.recordingPath!).openSync(mode: FileMode.append)
      ..truncateSync(22 * _megabyte);
    growing.closeSync();
    await tester.pump(const Duration(milliseconds: 600));
    expect(camera.calls.last, 'start', reason: 'still under the margin');

    final grown = File(camera.recordingPath!).openSync(mode: FileMode.append)
      ..truncateSync(24 * _megabyte);
    grown.closeSync();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(camera.calls.last, 'stop');
    expect(
      tester.widget<Text>(note).data,
      'Recording stopped at 25 MB, the largest video your plan allows. You '
      'can keep what was recorded.',
    );
    expect(tester.widget<TonalButton>(use).onPressed, isNotNull);
  });

  testWidgets('a Pro plan lets the recording grow further', (tester) async {
    await open(tester, startInVideo: true, attachmentMaxBytes: 100 * _megabyte);
    await space(tester);
    final grown = File(camera.recordingPath!).openSync(mode: FileMode.append)
      ..truncateSync(30 * _megabyte);
    grown.closeSync();
    await tester.pump(const Duration(seconds: 1));
    expect(camera.calls.last, 'start');
    await space(tester);
    await tester.pumpAndSettle();
  });

  testWidgets('review checks the size before Use, where the growth could '
      'not be watched', (tester) async {
    camera.videoBytes = 26 * _megabyte;
    final result = await open(tester, startInVideo: true);
    await space(tester);
    await tester.pump(const Duration(seconds: 2));
    await space(tester);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(note).data,
      'This video is larger than the 25 MB attachment limit.',
    );
    expect(tester.widget<TonalButton>(use).onPressed, isNull);
    await tester.tap(use);
    await tester.pumpAndSettle();
    expect(result(), isNull, reason: 'the window is still open');
  });

  testWidgets('with the microphone off it records without sound and says how '
      'to turn it on', (tester) async {
    camera.microphoneOff = true;
    await open(tester, startInVideo: true);
    expect(camera.calls, ['open built-in video sound', 'open built-in video']);
    expect(microphoneOff, findsOneWidget);
    expect(
      find.text(
        'Your video will have no sound. To record sound, allow Kapy Notes in '
        'System Settings, under Privacy & Security, then Microphone.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Open System Settings'));
    await tester.pump();
    expect(camera.calls.last, 'settings microphone');

    await space(tester);
    expect(camera.calls.last, 'start');
    expect(microphoneOff, findsNothing, reason: 'the timer takes its place');
    await space(tester);
    await tester.pumpAndSettle();
    expect(find.text('Review video'), findsOneWidget);

    // Photos never needed it.
    await tester.tap(retake);
    await tester.pumpAndSettle();
    await tester.tap(photoMode);
    await tester.pumpAndSettle();
    expect(microphoneOff, findsNothing);
    expect(camera.calls.last, 'open built-in photo');
  });

  testWidgets('on Windows the microphone note names its own Settings', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    camera.microphoneOff = true;
    await open(tester, startInVideo: true);
    expect(
      find.text(
        'Your video will have no sound. To record sound, go to Settings, then '
        'Privacy & security, then Microphone, and turn on Let desktop apps '
        'access your microphone.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(camera.calls.last, 'settings microphone');
  });

  testWidgets('with camera access off on a Mac it names System Settings, '
      'and Choose files is a way forward', (tester) async {
    camera.listTrouble = DesktopCameraTrouble.accessOff;
    final picked = [XFile('/tmp/picked.jpg')];
    final result = await open(tester, chooseFiles: () async => picked);
    expect(find.byKey(const ValueKey('camera-problem-accessOff')), findsOne);
    expect(find.text('Camera access is off'), findsOneWidget);
    expect(
      find.text(
        'Allow Kapy Notes in System Settings, under Privacy & Security, then '
        'Camera.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Open System Settings'));
    await tester.pump();
    expect(camera.calls.last, 'settings camera');

    await tester.tap(find.text('Choose files'));
    await tester.pumpAndSettle();
    expect(result(), picked);
  });

  testWidgets('with camera access off on Windows it names Settings', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    camera.openTrouble = DesktopCameraTrouble.accessOff;
    await open(tester);
    expect(
      find.text(
        'In Settings, go to Privacy & security, then Camera, and turn on Let '
        'desktop apps access your camera.',
      ),
      findsOneWidget,
    );
    expect(find.text('Open System Settings'), findsNothing);
    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(camera.calls.last, 'settings camera');
    expect(find.text('Choose files'), findsOneWidget);
  });

  testWidgets('coming back from settings tries the camera again', (
    tester,
  ) async {
    camera.listTrouble = DesktopCameraTrouble.accessOff;
    await open(tester);
    camera.listTrouble = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
  });

  testWidgets('a busy camera says so and can try again', (tester) async {
    camera.openTrouble = DesktopCameraTrouble.busy;
    await open(tester);
    expect(find.text('The camera is busy'), findsOneWidget);
    expect(
      find.text('Another app is using it. Close that app, then try again.'),
      findsOneWidget,
    );
    expect(find.text('Choose files'), findsOneWidget);

    camera.openTrouble = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
  });

  testWidgets('with no camera it offers your files', (tester) async {
    camera.devices = const [];
    await open(tester);
    expect(find.text('No camera found'), findsOneWidget);
    expect(
      find.text('Connect a camera, or add a photo or video from your files.'),
      findsOneWidget,
    );
    expect(find.text('Choose files'), findsOneWidget);
    expect(shutter, findsNothing);
  });

  testWidgets('closing mid-recording keeps nothing', (tester) async {
    final result = await open(tester, startInVideo: true);
    await space(tester);
    await tester.tap(find.byKey(const ValueKey('camera-close')));
    await tester.pumpAndSettle();
    expect(result(), isEmpty);
    expect(camera.calls.last, 'close');
  });

  group('Windows, through the camera platform', () {
    late FakeCameraPlatform platform;

    setUp(() {
      platform = FakeCameraPlatform(directory)
        ..cameras = const [
          CameraDescription(
            name: 'Integrated Camera <usb#vid_04f2>',
            lensDirection: CameraLensDirection.external,
            sensorOrientation: 0,
          ),
        ];
      CameraPlatform.instance = platform;
    });

    test('lists cameras by their names, and records 720p with sound to the '
        'path asked for', () async {
      final windows = WindowsCamera();
      final cameras = await windows.cameras();
      expect(cameras.single.name, 'Integrated Camera');

      final session = await windows.open(
        cameras.single,
        video: true,
        sound: true,
      );
      final settings = platform.opened.single!;
      expect(settings.resolutionPreset, ResolutionPreset.high);
      expect(settings.enableAudio, isTrue);
      expect(settings.fps, 30);
      expect(settings.videoBitrate, 2500000);

      final path = '${directory.path}/video.mp4';
      await session.startRecording(path);
      expect(platform.capture!.videoOutputPath, path);
      await session.stopRecording();
      await session.close();
      expect(platform.calls, ['startVideo', 'stopVideo', 'dispose']);
    });

    test('a photo never asks for sound, and moves to where the note wants '
        'it', () async {
      final windows = WindowsCamera();
      final session = await windows.open(
        (await windows.cameras()).single,
        video: false,
        sound: false,
      );
      expect(platform.opened.single!.enableAudio, isFalse);
      final path = '${directory.path}/photo.jpg';
      final photo = await session.takePhoto(path);
      expect(photo.path, path);
      expect(File(path).existsSync(), isTrue);
      expect(directory.listSync().whereType<File>().map((file) => file.path), [
        path,
      ]);
      await session.close();
    });

    test('refused access and anything else are told apart', () async {
      final windows = WindowsCamera();
      final device = (await windows.cameras()).single;
      platform.openError = CameraException('CameraAccessDenied', 'no');
      await expectLater(
        windows.open(device, video: false, sound: false),
        throwsA(
          isA<DesktopCameraException>().having(
            (error) => error.trouble,
            'trouble',
            DesktopCameraTrouble.accessOff,
          ),
        ),
      );
      platform.openError = CameraException('camera_error', 'in use');
      await expectLater(
        windows.open(device, video: false, sound: false),
        throwsA(
          isA<DesktopCameraException>().having(
            (error) => error.trouble,
            'trouble',
            DesktopCameraTrouble.busy,
          ),
        ),
      );
    });
  });

  group('Mac, through camera_macos', () {
    const channel = MethodChannel('camera_macos');
    final calls = <MethodCall>[];
    Object? Function(MethodCall call)? answer;

    setUp(() {
      calls.clear();
      answer = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (answer?.call(call) case final value?) return value;
            return switch (call.method) {
              'listDevices' => {
                'devices': [
                  {
                    'deviceId': 'facetime',
                    'localizedName': 'FaceTime HD Camera',
                    'deviceType': 0,
                  },
                  {
                    'deviceId': 'iphone',
                    'localizedName': 'iPhone Camera',
                    'deviceType': 0,
                  },
                ],
              },
              'initialize' => {
                'textureId': 7,
                'size': {'width': 1280.0, 'height': 720.0},
                'devices': <Object>[],
              },
              'takePicture' => {
                'imageData': Uint8List.fromList(List.filled(64, 1)),
              },
              'startRecording' => <String, Object?>{},
              'stopRecording' => {
                'url':
                    (calls
                            .lastWhere(
                              (call) => call.method == 'startRecording',
                            )
                            .arguments
                        as Map)['url'],
              },
              'destroy' => true,
              _ => null,
            };
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('lists built-in and other cameras, and opens one at 720p with AAC '
        'sound only for video', () async {
      final mac = MacCamera();
      final cameras = await mac.cameras();
      expect(cameras.map((camera) => camera.name), [
        'FaceTime HD Camera',
        'iPhone Camera',
      ]);

      final photo = await mac.open(cameras.last, video: false, sound: false);
      final opened = calls.last.arguments as Map;
      expect(opened['deviceId'], 'iphone');
      expect(opened['enableAudio'], isFalse);
      expect(photo.aspectRatio, 16 / 9);
      final path = '${directory.path}/photo.jpg';
      await photo.takePhoto(path);
      expect(File(path).lengthSync(), 64);
      expect(calls.last.arguments, containsPair('format', 'jpg'));
      await photo.close();
      expect(calls.last.method, 'destroy');

      final video = await mac.open(cameras.first, video: true, sound: true);
      final videoArguments = calls.last.arguments as Map;
      expect(videoArguments['enableAudio'], isTrue);
      expect(videoArguments['resolution'], 'high');
      expect(videoArguments['vformat'], 'mp4');
      expect(videoArguments['aformat'], AudioFormat.kAudioFormatMPEG4AAC.index);
      final file = '${directory.path}/video.mp4';
      await video.startRecording(file);
      expect((calls.last.arguments as Map)['url'], file);
      expect((await video.stopRecording()).path, file);
      await video.close();
    });

    test('a refused camera is access off, anything else is busy', () async {
      final mac = MacCamera();
      answer = (call) => call.method == 'listDevices'
          ? {
              'error': {
                'code': 'CAMERA_INITIALIZATION_ERROR',
                'message': 'Permission not granted',
              },
            }
          : null;
      await expectLater(
        mac.cameras(),
        throwsA(
          isA<DesktopCameraException>().having(
            (error) => error.trouble,
            'trouble',
            DesktopCameraTrouble.accessOff,
          ),
        ),
      );

      const device = DesktopCameraDevice(id: 'facetime', name: 'FaceTime');
      answer = (call) => call.method == 'initialize'
          ? {
              'error': {
                'code': 'CAMERA_INITIALIZATION_ERROR',
                'message': 'Permission not granted',
              },
            }
          : null;
      await expectLater(
        mac.open(device, video: false, sound: false),
        throwsA(
          isA<DesktopCameraException>().having(
            (error) => error.trouble,
            'trouble',
            DesktopCameraTrouble.accessOff,
          ),
        ),
      );
      answer = (call) => call.method == 'initialize'
          ? {
              'error': {
                'code': 'CAMERA_INITIALIZATION_ERROR',
                'message': 'Could not find a suitable camera on this device',
              },
            }
          : null;
      await expectLater(
        mac.open(device, video: false, sound: false),
        throwsA(
          isA<DesktopCameraException>().having(
            (error) => error.trouble,
            'trouble',
            DesktopCameraTrouble.busy,
          ),
        ),
      );
    });
  });

  test('only a Mac and a Windows PC have the camera window', () {
    for (final (platform, kind) in [
      (TargetPlatform.macOS, MacCamera),
      (TargetPlatform.windows, WindowsCamera),
      (TargetPlatform.linux, null),
      (TargetPlatform.iOS, null),
      (TargetPlatform.android, null),
    ]) {
      AppPlatform.debugTargetPlatformOverride = platform;
      expect(
        desktopCameraForThisComputer()?.runtimeType,
        kind,
        reason: platform.name,
      );
      expect(AppPlatform.hasDesktopCamera, kind != null, reason: platform.name);
    }
  });
}
