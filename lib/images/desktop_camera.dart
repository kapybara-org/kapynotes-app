import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camera_macos/camera_macos_arguments.dart' as mac;
import 'package:camera_macos/camera_macos_device.dart' as mac;
import 'package:camera_macos/camera_macos_method_channel.dart' as mac;
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraPlatform, VideoCaptureOptions;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/platform.dart';
import 'camera_capture.dart';

/// One camera a computer can use: its own, or one plugged in or nearby.
@immutable
class DesktopCameraDevice {
  const DesktopCameraDevice({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is DesktopCameraDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

enum DesktopCameraTrouble { accessOff, busy }

/// Why a camera couldn't be listed or opened.
class DesktopCameraException implements Exception {
  const DesktopCameraException(this.trouble);

  final DesktopCameraTrouble trouble;

  @override
  String toString() => 'DesktopCameraException(${trouble.name})';
}

/// A computer's camera, as the camera window sees it. Each platform's package
/// has its own shape, and this is the little the window needs of either.
abstract class DesktopCamera {
  /// The cameras there are, in the system's order. Throws a
  /// [DesktopCameraException] when the camera isn't allowed.
  Future<List<DesktopCameraDevice>> cameras();

  /// Opens [device] for photos, or for a video with or without sound. Throws
  /// a [DesktopCameraException] when it can't.
  Future<DesktopCameraSession> open(
    DesktopCameraDevice device, {
    required bool video,
    required bool sound,
  });

  /// The computer's own settings, where Kapy Notes is allowed the camera or
  /// the microphone.
  Future<void> openPrivacySettings({required bool microphone});
}

/// One camera, open.
abstract class DesktopCameraSession {
  Widget preview();

  /// Width over height of [preview].
  double get aspectRatio;

  /// Takes a photo and keeps it at [path], a JPEG.
  Future<XFile> takePhoto(String path);

  /// Starts a video written as it grows to [path], an MP4.
  Future<void> startRecording(String path);

  Future<XFile> stopRecording();

  /// Lets the camera go, dropping a recording that is still going.
  Future<void> close();
}

/// The camera for this computer, or null where there is none to offer.
DesktopCamera? desktopCameraForThisComputer() {
  if (AppPlatform.isMacOS) return MacCamera();
  if (AppPlatform.isWindows) return WindowsCamera();
  return null;
}

/// Windows, through the Flutter team's camera_windows, which answers as the
/// same camera platform the phone camera uses.
class WindowsCamera implements DesktopCamera {
  WindowsCamera({this.loadCameras = availableCameras});

  final CameraListLoader loadCameras;
  List<CameraDescription> _descriptions = const [];

  @override
  Future<List<DesktopCameraDevice>> cameras() async {
    try {
      _descriptions = await loadCameras();
    } on CameraException catch (error) {
      throw DesktopCameraException(_troubleFor(error));
    }
    return [
      for (final description in _descriptions)
        DesktopCameraDevice(
          id: description.name,
          // camera_windows names a camera "Friendly name <device path>".
          name: description.name.replaceFirst(RegExp(r'\s*<[^>]*>$'), ''),
        ),
    ];
  }

  @override
  Future<DesktopCameraSession> open(
    DesktopCameraDevice device, {
    required bool video,
    required bool sound,
  }) async {
    final description = _descriptions.firstWhere(
      (description) => description.name == device.id,
      orElse: () =>
          throw const DesktopCameraException(DesktopCameraTrouble.busy),
    );
    final controller = CameraController(
      description,
      noteVideoSettings.resolutionPreset!,
      enableAudio: video && sound,
      fps: video ? noteVideoSettings.fps : null,
      videoBitrate: video ? noteVideoSettings.videoBitrate : null,
      audioBitrate: video && sound ? noteVideoSettings.audioBitrate : null,
    );
    try {
      await controller.initialize();
    } on CameraException catch (error) {
      await controller.dispose();
      throw DesktopCameraException(_troubleFor(error));
    }
    return _WindowsSession(controller);
  }

  @override
  Future<void> openPrivacySettings({required bool microphone}) => _launch(
    microphone
        ? 'ms-settings:privacy-microphone'
        : 'ms-settings:privacy-webcam',
  );

  static DesktopCameraTrouble _troubleFor(CameraException error) =>
      error.code == 'CameraAccessDenied'
      ? DesktopCameraTrouble.accessOff
      : DesktopCameraTrouble.busy;
}

class _WindowsSession implements DesktopCameraSession {
  _WindowsSession(this._controller);

  final CameraController _controller;
  String? _recording;

  @override
  Widget preview() => _controller.buildPreview();

  @override
  double get aspectRatio => _controller.value.aspectRatio;

  @override
  Future<XFile> takePhoto(String path) async {
    // camera_windows keeps photos in the person's Pictures folder; the note
    // gets its own copy, so nothing is left there.
    final taken = await _controller.takePicture();
    await _move(File(taken.path), path);
    return XFile(path);
  }

  @override
  Future<void> startRecording(String path) async {
    await CameraPlatform.instance.startVideoCapturing(
      VideoCaptureOptions(_controller.cameraId, videoOutputPath: path),
    );
    _recording = path;
  }

  @override
  Future<XFile> stopRecording() async {
    final file = await CameraPlatform.instance.stopVideoRecording(
      _controller.cameraId,
    );
    _recording = null;
    return file;
  }

  @override
  Future<void> close() async {
    if (_recording case final path?) {
      try {
        await stopRecording();
      } catch (_) {
        // Already stopped; the file goes either way.
      }
      _delete(path);
    }
    await _controller.dispose();
  }
}

/// A Mac, through camera_macos, which has an API of its own: one camera at a
/// time, opened with what it records, and a texture for its picture.
class MacCamera implements DesktopCamera {
  MacCamera({mac.MethodChannelCameraMacOS? plugin})
    : _plugin = plugin ?? mac.MethodChannelCameraMacOS();

  final mac.MethodChannelCameraMacOS _plugin;

  @override
  Future<List<DesktopCameraDevice>> cameras() async {
    final List<mac.CameraMacOSDevice> devices;
    try {
      devices = await _plugin.listDevices(
        deviceType: mac.CameraMacOSDeviceType.video,
      );
    } catch (_) {
      // Listing asks for the camera first, and fails only when it is refused.
      throw const DesktopCameraException(DesktopCameraTrouble.accessOff);
    }
    return [
      for (final device in devices)
        DesktopCameraDevice(
          id: device.deviceId,
          name: device.localizedName ?? 'Camera',
        ),
    ];
  }

  @override
  Future<DesktopCameraSession> open(
    DesktopCameraDevice device, {
    required bool video,
    required bool sound,
  }) async {
    final mac.CameraMacOSArguments? arguments;
    try {
      arguments = await _plugin.initialize(
        deviceId: device.id,
        cameraMacOSMode: video
            ? mac.CameraMacOSMode.video
            : mac.CameraMacOSMode.photo,
        enableAudio: video && sound,
        resolution: mac.PictureResolution.high,
        videoFormat: mac.VideoFormat.mp4,
        audioFormat: mac.AudioFormat.kAudioFormatMPEG4AAC,
        isVideoMirrored: false,
      );
    } catch (error) {
      // camera_macos fails some openings after it has registered the picture
      // and added the camera, such as a refused microphone, and keeps both.
      try {
        await _plugin.destroy();
      } catch (_) {
        // Nothing was set up to let go of.
      }
      throw DesktopCameraException(
        '$error'.contains('Permission not granted')
            ? DesktopCameraTrouble.accessOff
            : DesktopCameraTrouble.busy,
      );
    }
    final texture = arguments?.textureId;
    if (arguments == null || texture == null) {
      throw const DesktopCameraException(DesktopCameraTrouble.busy);
    }
    return _MacSession(_plugin, texture, arguments.size, sound: video && sound);
  }

  @override
  Future<void> openPrivacySettings({required bool microphone}) => _launch(
    'x-apple.systempreferences:com.apple.preference.security?'
    '${microphone ? 'Privacy_Microphone' : 'Privacy_Camera'}',
  );
}

class _MacSession implements DesktopCameraSession {
  _MacSession(this._plugin, this._texture, this._size, {required this.sound});

  final mac.MethodChannelCameraMacOS _plugin;
  final int _texture;
  final Size _size;
  final bool sound;
  String? _recording;

  @override
  Widget preview() => Texture(textureId: _texture);

  @override
  double get aspectRatio =>
      _size.width > 0 && _size.height > 0 ? _size.width / _size.height : 16 / 9;

  @override
  Future<XFile> takePhoto(String path) async {
    final photo = await _plugin.takePicture(format: mac.PictureFormat.jpg);
    final bytes = photo?.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw const DesktopCameraException(DesktopCameraTrouble.busy);
    }
    await File(path).writeAsBytes(bytes, flush: true);
    return XFile(path);
  }

  @override
  Future<void> startRecording(String path) async {
    await _plugin.startVideoRecording(url: path, enableAudio: sound);
    _recording = path;
  }

  @override
  Future<XFile> stopRecording() async {
    final path = _recording;
    final video = await _plugin.stopVideoRecording();
    _recording = null;
    return XFile(video?.url ?? path ?? '');
  }

  @override
  Future<void> close() async {
    if (_recording case final path?) {
      try {
        await stopRecording();
      } catch (_) {
        // Already stopped; the file goes either way.
      }
      _delete(path);
    }
    try {
      await _plugin.destroy();
    } catch (_) {
      // Nothing was open to let go of.
    }
  }
}

Future<void> _launch(String address) async {
  try {
    await launchUrl(Uri.parse(address));
  } catch (_) {
    // The window still says where the setting is.
  }
}

Future<void> _move(File from, String to) async {
  try {
    await from.rename(to);
  } on FileSystemException {
    await from.copy(to);
    _delete(from.path);
  }
}

void _delete(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}
