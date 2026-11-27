// The phone camera, drawn on a real phone over a camera faked in Dart, since
// an emulator in CI has none and a simulator never has: each mode and each
// thing that can get in the way, for a reviewer to look at. Its channel to
// the phone (free space and calls) is the real one.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_camera_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Open Settings is left alone: it leaves the app.
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/images/camera_capture.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../test/images/fake_camera.dart';
import 'screenshot.dart';

const _megabyte = 1024 * 1024;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late FakeCameraPlatform camera;
  late FakeCameraPhone phone;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('phone-camera');
    camera = FakeCameraPlatform(directory);
    phone = FakeCameraPhone();
    CameraPlatform.instance = camera;
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
  });
  tearDown(() => directory.deleteSync(recursive: true));

  final shutter = find.byKey(const ValueKey('camera-shutter'));

  Future<void> open(WidgetTester tester, {bool video = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: CameraCapturePage(
          phone: phone,
          startInVideo: video,
          attachmentMaxBytes: 25 * _megabyte,
          chooseFromLibrary: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> wait(WidgetTester tester, Duration duration) async {
    await Future<void>.delayed(duration);
    await tester.pump();
  }

  testWidgets('the channel answers on this phone', (tester) async {
    const real = CameraPhone();
    expect(await real.freeBytes(), greaterThan(0));
    expect(await real.inCall(), isFalse);

    // Where this phone's camera writes a growing recording.
    final temporary = await getTemporaryDirectory();
    final folder = Platform.isIOS
        ? Directory('${temporary.path}/camera/videos')
        : temporary;
    folder.createSync(recursive: true);
    final since = DateTime.now().subtract(const Duration(seconds: 1));
    final file = File('${folder.path}/REC_phone_camera_test.mp4')
      ..writeAsBytesSync(List.filled(4096, 0));
    addTearDown(file.deleteSync);
    expect(await real.recordingBytes(since), 4096);
  });

  testWidgets('Photo, Video, recording and paused', (tester) async {
    await open(tester);
    await screenshot('camera-photo');

    await tester.tap(find.byKey(const ValueKey('camera-mode-video')));
    await tester.pumpAndSettle();
    await screenshot('camera-video');

    await tester.tap(shutter);
    await wait(tester, const Duration(seconds: 3));
    expect(find.text('0:03 / 1:00'), findsOneWidget);
    await screenshot('camera-recording');

    await tester.tap(find.byKey(const ValueKey('camera-pause')));
    await tester.pump();
    await screenshot('camera-paused');

    await tester.tap(shutter);
    await tester.pumpAndSettle();
    expect(find.text('Review video'), findsOneWidget);
    await screenshot('camera-review-video');
  });

  testWidgets('stopped at the size limit', (tester) async {
    await open(tester, video: true);
    await tester.tap(shutter);
    await wait(tester, const Duration(seconds: 1));
    phone.recorded = 24 * _megabyte;
    await wait(tester, const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('camera-review-note')), findsOneWidget);
    await screenshot('camera-review-size');
  });

  testWidgets('microphone off and phone almost full', (tester) async {
    camera.soundError = CameraException('AudioAccessDenied', 'denied');
    await open(tester, video: true);
    expect(find.byKey(const ValueKey('camera-mic-off')), findsOneWidget);
    await screenshot('camera-mic-off');

    phone.free = _megabyte;
    await tester.tap(find.byKey(const ValueKey('camera-mode-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('camera-mode-video')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('camera-phone-full')), findsOneWidget);
    await screenshot('camera-phone-full');
  });

  testWidgets('camera access off and camera busy', (tester) async {
    camera.openError = CameraException('CameraAccessDenied', 'denied');
    await open(tester);
    expect(find.text('Camera access is off'), findsOneWidget);
    await screenshot('camera-access-off');

    camera.openError = CameraException('cameraInUse', 'in use');
    await tester.pumpWidget(const SizedBox());
    await open(tester);
    expect(find.text('The camera is busy'), findsOneWidget);
    await screenshot('camera-busy');
  });
}
