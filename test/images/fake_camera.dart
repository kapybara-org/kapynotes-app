import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:kapy_notes/images/camera_capture.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

const backCamera = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const frontCamera = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

/// A phone camera with no hardware behind it. Photos and videos it "takes"
/// are small files in [directory].
class FakeCameraPlatform extends CameraPlatform {
  FakeCameraPlatform(this.directory);

  final Directory directory;
  List<CameraDescription> cameras = const [backCamera, frontCamera];

  /// Every camera opened, with what it was opened with.
  final List<MediaSettings?> opened = [];

  /// Thrown by every opening while set.
  CameraException? openError;

  /// Thrown by an opening that asks for sound while set.
  CameraException? soundError;

  /// What the camera was asked to do, in order.
  final List<String> calls = [];
  FlashMode flash = FlashMode.off;
  int videoBytes = 1024;

  final _events = StreamController<CameraEvent>.broadcast();
  final _errors = StreamController<CameraErrorEvent>.broadcast();
  int _nextId = 0;
  int _files = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async => cameras;

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings? mediaSettings,
  ) async {
    if (openError case final error?) throw error;
    if (mediaSettings?.enableAudio ?? false) {
      if (soundError case final error?) throw error;
    }
    opened.add(mediaSettings);
    return ++_nextId;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    _events.add(
      CameraInitializedEvent(
        cameraId,
        1280,
        720,
        ExposureMode.auto,
        true,
        FocusMode.auto,
        true,
      ),
    );
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) => _events
      .stream
      .where(
        (event) =>
            event is CameraInitializedEvent && event.cameraId == cameraId,
      )
      .cast<CameraInitializedEvent>();

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<XFile> takePicture(int cameraId) async {
    calls.add('takePicture');
    return _file('jpg', 64);
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    calls.add('startVideo');
  }

  @override
  Future<void> pauseVideoRecording(int cameraId) async => calls.add('pause');

  @override
  Future<void> resumeVideoRecording(int cameraId) async => calls.add('resume');

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    calls.add('stopVideo');
    return _file('mp4', videoBytes);
  }

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {
    flash = mode;
  }

  @override
  Future<void> pausePreview(int cameraId) async {}

  @override
  Future<void> resumePreview(int cameraId) async {}

  @override
  Widget buildPreview(int cameraId) =>
      const SizedBox.expand(key: ValueKey('fake-preview'));

  @override
  Future<void> dispose(int cameraId) async => calls.add('dispose');

  XFile _file(String extension, int bytes) {
    final file = File('${directory.path}/capture-${_files++}.$extension')
      ..writeAsBytesSync(List.filled(bytes, 1));
    return XFile(file.path);
  }
}

/// The phone around the camera, answered by the test.
class FakeCameraPhone extends CameraPhone {
  int? free;
  bool call = false;
  int? recorded;
  int settingsOpened = 0;

  @override
  Future<int?> freeBytes() async => free;

  @override
  Future<bool> inCall() async => call;

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<int?> recordingBytes(DateTime since) async => recorded;
}

/// A video player that opens anything as a 42-second portrait clip.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<String> calls = [];
  final _events = <int, StreamController<VideoEvent>>{};
  int _nextId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final events = _events[id] = StreamController<VideoEvent>();
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 42),
        size: const Size(720, 1280),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand(key: ValueKey('fake-player'));

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }
}
