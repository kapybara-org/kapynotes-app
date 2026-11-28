import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show MediaSettings;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../video/video_ingest.dart';

typedef CameraListLoader = Future<List<CameraDescription>> Function();
typedef ImageLibraryPicker = Future<List<XFile>> Function();

/// How a video is recorded: 720p at 30 fps, with about 2.5 Mbps of picture
/// and 128 kbps of sound. A minute comes to about 19 MB, which fits the free
/// plan's 25 MB with about a quarter to spare. iOS takes the bitrate as it
/// is; Android hands it to CameraX as a target, which isn't a promise.
const MediaSettings noteVideoSettings = MediaSettings(
  resolutionPreset: ResolutionPreset.high,
  fps: 30,
  videoBitrate: 2500000,
  audioBitrate: 128000,
  enableAudio: true,
);

/// The longest video the camera records, on every plan.
const Duration noteVideoMaxLength = Duration(minutes: 1);

/// How far under the largest video a recording stops: what the encoder still
/// holds, and the index written as it closes, land after the last look.
const noteVideoSizeMargin = 2 * 1024 * 1024;

/// What review says after a recording stopped at the plan's largest video.
String recordingStoppedAtSize(int attachmentMaxBytes) =>
    'Recording stopped at ${attachmentMaxBytes ~/ (1024 * 1024)} MB, the '
    'largest video your plan allows. You can keep what was recorded.';

/// What the camera asks of the phone around it: free space, whether a call
/// is on, the app's page in Settings, and how big the recording has grown.
class CameraPhone {
  const CameraPhone({
    MethodChannel channel = const MethodChannel('kapynotes/camera'),
    this.temporaryDirectory = getTemporaryDirectory,
  }) : _channel = channel;

  final MethodChannel _channel;
  final Future<Directory> Function() temporaryDirectory;

  /// Bytes free where a recording is written, or null where the phone won't
  /// say, which lets the recording go ahead.
  Future<int?> freeBytes() async {
    try {
      return await _channel.invokeMethod<int>('freeBytes');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether a call is ringing or under way.
  Future<bool> inCall() async {
    try {
      return await _channel.invokeMethod<bool>('inCall') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens Kapy Notes' own page in the phone's Settings.
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  /// How big the recording started at [since] has grown, or null if its file
  /// can't be found.
  ///
  /// The camera package doesn't report it, but both phones write the file as
  /// it grows into the folder [temporaryDirectory] returns: Android's CameraX
  /// as REC….mp4 at its top (android_camera_camerax.dart:1164), and iOS as
  /// REC_….mp4 in camera/videos (camera_avfoundation's DefaultCamera.swift,
  /// setUpVideoRecording).
  Future<int?> recordingBytes(DateTime since) async {
    try {
      final temporary = await temporaryDirectory();
      final folder = AppPlatform.isIOS
          ? Directory('${temporary.path}/camera/videos')
          : temporary;
      if (!await folder.exists()) return null;
      int? bytes;
      DateTime? newest;
      await for (final entity in folder.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('REC') || !name.endsWith('.mp4')) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(since)) continue;
        if (newest == null || stat.modified.isAfter(newest)) {
          newest = stat.modified;
          bytes = stat.size;
        }
      }
      return bytes;
    } on FileSystemException {
      return null;
    }
  }
}

/// Opens the phone camera and returns the photo or video kept there, or the
/// photos and videos chosen through its Photos button.
Future<List<XFile>> showNoteCamera(
  BuildContext context, {
  required ImageLibraryPicker chooseFromLibrary,
  required int attachmentMaxBytes,
  bool startInVideo = false,
  ValueChanged<bool>? onVideoChosen,
  CameraListLoader loadCameras = availableCameras,
  CameraPhone phone = const CameraPhone(),
}) async {
  final files = await Navigator.of(context, rootNavigator: true)
      .push<List<XFile>>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CameraCapturePage(
            chooseFromLibrary: chooseFromLibrary,
            attachmentMaxBytes: attachmentMaxBytes,
            startInVideo: startInVideo,
            onVideoChosen: onVideoChosen,
            loadCameras: loadCameras,
            phone: phone,
          ),
        ),
      );
  return files ?? const [];
}

/// The phone camera for a note: a photo, or a video of up to a minute.
///
/// The whole screen is the picture, a Photo / Video switch sits above the
/// shutter, and Photos stays one tap away. Nothing is returned until **Use
/// photo** or **Use video**.
class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({
    super.key,
    required this.chooseFromLibrary,
    required this.attachmentMaxBytes,
    this.startInVideo = false,
    this.onVideoChosen,
    this.loadCameras = availableCameras,
    this.phone = const CameraPhone(),
  });

  final ImageLibraryPicker chooseFromLibrary;

  /// The largest attachment the note's plan allows, which bounds a video.
  final int attachmentMaxBytes;
  final bool startInVideo;

  /// Told each time the switch changes mode, so the next camera opens in it.
  final ValueChanged<bool>? onVideoChosen;
  final CameraListLoader loadCameras;
  final CameraPhone phone;

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

enum _Problem { accessOff, busy, noCamera }

const _recordRed = Color(0xFFF2675C);
const _cream = Color(0xFFF5F2E9);
const _ink = Color(0xFF15171A);
const _tick = Duration(milliseconds: 100);

/// Ticks between two looks at the recording's size and at calls.
const _ticksPerCheck = 5;

class _CameraCapturePageState extends State<CameraCapturePage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  CameraDescription? _activeCamera;
  _Problem? _problem;
  bool _loading = true;
  bool _busy = false;
  bool _openingLibrary = false;
  bool _flashAuto = false;
  bool _lightOn = false;
  bool _keptCapture = false;
  bool _leftApp = false;
  int _cameraGeneration = 0;

  late bool _video = widget.startInVideo;
  bool _micOff = false;
  bool _phoneFull = false;

  bool _recording = false;
  bool _paused = false;
  bool _stopping = false;
  bool _callOn = false;
  Duration _elapsed = Duration.zero;
  DateTime? _recordingSince;
  Timer? _ticker;
  int _ticks = 0;

  XFile? _captured;
  bool _capturedVideo = false;
  String? _reviewNote;
  bool _tooLarge = false;

  bool get _ready => _controller?.value.isInitialized ?? false;

  int get _largestVideo => maxVideoSourceBytesFor(widget.attachmentMaxBytes);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_captured != null) return;
    if (state == AppLifecycleState.resumed) {
      if (!_leftApp) return;
      _leftApp = false;
      // Back from Settings, perhaps with the microphone allowed.
      _micOff = false;
      unawaited(_initializeCamera(preferred: _activeCamera));
      return;
    }
    // Only leaving counts: a permission question over the camera makes it
    // inactive too.
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    if (_recording) {
      unawaited(
        _stopRecording(
          note:
              'Recording stopped when you left the app. You can keep what '
              'was recorded.',
        ),
      );
      return;
    }
    if (_leftApp) return;
    _leftApp = true;
    _releaseCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _cameraGeneration++;
    final controller = _controller;
    _controller = null;
    unawaited(_closeController(controller, discardRecording: _recording));
    if (!_keptCapture) _deleteCapture(_captured);
    super.dispose();
  }

  Future<void> _initializeCamera({CameraDescription? preferred}) async {
    final generation = ++_cameraGeneration;
    final previous = _controller;
    _controller = null;
    if (mounted) {
      setState(() {
        _loading = true;
        _problem = null;
      });
    }
    await previous?.dispose();

    try {
      final cameras = _cameras.isEmpty ? await widget.loadCameras() : _cameras;
      if (!mounted || generation != _cameraGeneration) return;
      if (cameras.isEmpty) {
        setState(() {
          _cameras = const [];
          _loading = false;
          _problem = _Problem.noCamera;
        });
        return;
      }

      final selected = preferred != null && cameras.contains(preferred)
          ? preferred
          : cameras.firstWhere(
              (camera) => camera.lensDirection == CameraLensDirection.back,
              orElse: () => cameras.first,
            );
      final video = _video;
      var phoneFull = false;
      if (video) {
        final free = await widget.phone.freeBytes();
        // A recording needs room for itself, and again for the note's copy.
        phoneFull = free != null && free < 2 * _largestVideo;
      }
      CameraController controller;
      try {
        controller = await _openController(selected, sound: video && !_micOff);
      } on CameraException catch (error) {
        if (!video || !error.code.startsWith('AudioAccess')) rethrow;
        _micOff = true;
        controller = await _openController(selected, sound: false);
      }
      if (!mounted || generation != _cameraGeneration) {
        await controller.dispose();
        return;
      }
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {
        // Some front cameras expose no flash. Capture itself still works.
      }
      setState(() {
        _cameras = cameras;
        _activeCamera = selected;
        _controller = controller;
        _flashAuto = false;
        _lightOn = false;
        _phoneFull = phoneFull;
        _loading = false;
      });
    } on CameraException catch (error) {
      if (!mounted || generation != _cameraGeneration) return;
      setState(() {
        _loading = false;
        _problem = switch (error.code) {
          'CameraAccessDenied' ||
          'CameraAccessDeniedWithoutPrompt' ||
          'CameraAccessRestricted' => _Problem.accessOff,
          _ => _Problem.busy,
        };
      });
    } catch (_) {
      if (!mounted || generation != _cameraGeneration) return;
      setState(() {
        _loading = false;
        _problem = _Problem.busy;
      });
    }
  }

  /// A photo controller never has sound, so the microphone is first asked
  /// for when someone switches to Video.
  Future<CameraController> _openController(
    CameraDescription description, {
    required bool sound,
  }) async {
    final controller = _video
        ? CameraController(
            description,
            noteVideoSettings.resolutionPreset!,
            enableAudio: sound,
            fps: noteVideoSettings.fps,
            videoBitrate: noteVideoSettings.videoBitrate,
            audioBitrate: noteVideoSettings.audioBitrate,
            imageFormatGroup: ImageFormatGroup.jpeg,
          )
        : CameraController(
            description,
            ResolutionPreset.high,
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.jpeg,
          );
    try {
      await controller.initialize();
      return controller;
    } catch (_) {
      await controller.dispose();
      rethrow;
    }
  }

  void _releaseCamera() {
    _cameraGeneration++;
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose());
    if (mounted && !_loading) setState(() => _loading = true);
  }

  Future<void> _chooseMode(bool video) async {
    if (video == _video || _recording || _busy || _captured != null) return;
    setState(() => _video = video);
    widget.onVideoChosen?.call(video);
    await _initializeCamera(preferred: _activeCamera);
  }

  void _onSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 200) return;
    unawaited(_chooseMode(velocity < 0));
  }

  void _onShutter() {
    if (!_video) {
      unawaited(_takePicture());
    } else if (_recording) {
      unawaited(_stopRecording());
    } else {
      unawaited(_startRecording());
    }
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture ||
        _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final file = await controller.takePicture();
      if (!mounted) {
        _deleteCapture(file);
        return;
      }
      try {
        await controller.pausePreview();
      } catch (_) {
        // A frozen preview is polish, not a prerequisite for review.
      }
      setState(() {
        _captured = file;
        _capturedVideo = false;
      });
    } on CameraException {
      if (mounted) _showMessage('Could not take that photo. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null || !_ready || _busy || _phoneFull) return;
    setState(() => _busy = true);
    // A second back, for file times kept to the second.
    final since = DateTime.now().subtract(const Duration(seconds: 1));
    try {
      _callOn = await widget.phone.inCall();
      await controller.startVideoRecording();
      if (!mounted) return;
      _recordingSince = since;
      _ticks = 0;
      _ticker = Timer.periodic(_tick, _onTick);
      setState(() {
        _recording = true;
        _paused = false;
        _elapsed = Duration.zero;
      });
    } on CameraException {
      if (mounted) _showMessage('Could not start recording. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onTick(Timer timer) {
    if (!_recording || _stopping) return;
    if (!_paused) setState(() => _elapsed += _tick);
    if (_elapsed >= noteVideoMaxLength) {
      unawaited(_stopRecording());
    } else if (++_ticks % _ticksPerCheck == 0) {
      unawaited(_checkRecording());
    }
  }

  /// Stops a recording before it outgrows the plan, or when a call comes in.
  Future<void> _checkRecording() async {
    final since = _recordingSince;
    if (since == null) return;
    final bytes = await widget.phone.recordingBytes(since);
    if (!mounted || !_recording || _stopping) return;
    if (bytes != null && bytes >= _largestVideo - noteVideoSizeMargin) {
      return _stopRecording(
        note: recordingStoppedAtSize(widget.attachmentMaxBytes),
      );
    }
    final call = await widget.phone.inCall();
    if (!mounted || !_recording || _stopping) return;
    if (call && !_callOn) {
      return _stopRecording(
        note:
            'Recording stopped when a call came in. You can keep what was '
            'recorded.',
      );
    }
    _callOn = call;
  }

  Future<void> _togglePause() async {
    final controller = _controller;
    if (controller == null || !_recording || _stopping) return;
    try {
      if (_paused) {
        await controller.resumeVideoRecording();
      } else {
        await controller.pauseVideoRecording();
      }
      if (mounted) setState(() => _paused = !_paused);
    } on CameraException {
      // The recording carries on as it was, and the button still says so.
    }
  }

  Future<void> _stopRecording({String? note}) async {
    final controller = _controller;
    if (controller == null || !_recording || _stopping) return;
    _stopping = true;
    _ticker?.cancel();
    try {
      final file = await controller.stopVideoRecording();
      if (!mounted) {
        _deleteCapture(file);
        return;
      }
      try {
        if (_lightOn) await controller.setFlashMode(FlashMode.off);
        await controller.pausePreview();
      } catch (_) {
        // The light and a frozen preview are polish; review goes on.
      }
      setState(() {
        _recording = false;
        _paused = false;
        _lightOn = false;
        _captured = file;
        _capturedVideo = true;
        _reviewNote = note;
        _tooLarge = _sizeOf(file) > _largestVideo;
      });
    } on CameraException {
      if (!mounted) return;
      setState(() {
        _recording = false;
        _paused = false;
      });
      _showMessage('Could not save that video. Try again.');
    } finally {
      _stopping = false;
    }
  }

  Future<void> _retake() async {
    final old = _captured;
    setState(() {
      _captured = null;
      _reviewNote = null;
      _tooLarge = false;
    });
    _deleteCapture(old);
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      await _initializeCamera(preferred: _activeCamera);
      return;
    }
    try {
      await controller.resumePreview();
    } catch (_) {
      await _initializeCamera(preferred: _activeCamera);
    }
  }

  void _keep() {
    final captured = _captured;
    if (captured == null || _tooLarge) return;
    _keptCapture = true;
    Navigator.of(context).pop(<XFile>[captured]);
  }

  Future<void> _openLibrary() async {
    if (_openingLibrary) return;
    setState(() => _openingLibrary = true);
    try {
      final files = await widget.chooseFromLibrary();
      if (!mounted || files.isEmpty) return;
      Navigator.of(context).pop(files);
    } catch (_) {
      if (mounted) _showMessage('Could not open the photo library.');
    } finally {
      if (mounted) setState(() => _openingLibrary = false);
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _loading) return;
    final current = _activeCamera;
    final index = current == null ? -1 : _cameras.indexOf(current);
    final next = _cameras[(index + 1) % _cameras.length];
    await _initializeCamera(preferred: next);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    final next = !_flashAuto;
    try {
      await controller.setFlashMode(next ? FlashMode.auto : FlashMode.off);
      if (mounted) setState(() => _flashAuto = next);
    } on CameraException {
      if (mounted) _showMessage('Flash is not available on this camera.');
    }
  }

  Future<void> _toggleLight() async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    final next = !_lightOn;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _lightOn = next);
    } on CameraException {
      if (mounted) _showMessage('This camera has no light.');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final captured = _captured;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF08090B),
        body: captured == null ? _buildCamera() : _buildReview(captured),
      ),
    );
  }

  Widget _buildCamera() {
    final problem = _problem;
    if (problem != null) {
      return SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(child: _buildProblem(problem)),
          ],
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          key: const ValueKey('camera-picture'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: _recording ? null : _onSwipe,
          child: _buildViewfinder(),
        ),
        const _CameraScrims(),
        SafeArea(
          child: Column(
            children: [
              _topBar(),
              const Spacer(),
              ?_notice(),
              if (!_recording)
                _ModeSwitch(
                  video: _video,
                  onChanged: (video) => unawaited(_chooseMode(video)),
                ),
              _bottomBar(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: _RoundCameraButton(
              key: const ValueKey('camera-close'),
              label: 'Close camera',
              icon: KapyIcons.closeRounded,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          if (_recording) _RecordingTime(elapsed: _elapsed, paused: _paused),
          if (_ready && _problem == null)
            Align(
              alignment: Alignment.centerRight,
              child: _video
                  ? _RoundCameraButton(
                      key: const ValueKey('camera-light'),
                      label: _lightOn
                          ? 'Turn off the light'
                          : 'Turn on the light',
                      icon: KapyIcons.flashlightRounded,
                      lit: _lightOn,
                      onPressed: _toggleLight,
                    )
                  : _RoundCameraButton(
                      key: const ValueKey('camera-flash'),
                      label: _flashAuto
                          ? 'Turn flash off'
                          : 'Set flash to auto',
                      icon: _flashAuto
                          ? KapyIcons.flashAutoRounded
                          : KapyIcons.flashOffRounded,
                      onPressed: _toggleFlash,
                    ),
            ),
        ],
      ),
    ),
  );

  /// What stands in the way of a video, over the switch. A full phone comes
  /// first, because nothing records until it's cleared.
  Widget? _notice() {
    if (!_video || _recording || !_ready) return null;
    if (_phoneFull) {
      return const _CameraNotice(
        key: ValueKey('camera-phone-full'),
        icon: KapyIcons.warningRounded,
        text:
            'Your phone is almost full. Free up some space to record a '
            'video. Photos still work.',
      );
    }
    if (!_micOff) return null;
    return _CameraNotice(
      key: const ValueKey('camera-mic-off'),
      icon: KapyIcons.micOffRounded,
      text:
          'Your video will have no sound. To record sound, allow the '
          'microphone for Kapy Notes in Settings.',
      action: 'Open Settings',
      onAction: () => unawaited(widget.phone.openSettings()),
    );
  }

  Widget _bottomBar() {
    final canCapture = _ready && !_loading && !(_video && _phoneFull);
    final shutterOn = canCapture && !_busy && !_stopping;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
      child: SizedBox(
        height: 86,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _recording
                  ? _SideButton(
                      key: const ValueKey('camera-pause'),
                      label: _paused ? 'Resume' : 'Pause',
                      icon: _paused
                          ? const DecoratedBox(
                              decoration: BoxDecoration(
                                color: _recordRed,
                                shape: BoxShape.circle,
                              ),
                              child: SizedBox.square(dimension: 14),
                            )
                          : const KapyIcon(
                              KapyIcons.pauseRounded,
                              color: Colors.white,
                              size: 22,
                            ),
                      onTap: () => unawaited(_togglePause()),
                    )
                  : _SideButton(
                      key: const ValueKey('camera-library'),
                      label: 'Photos',
                      semanticsLabel: 'Choose photos and videos',
                      icon: _openingLibrary
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const KapyIcon(
                              KapyIcons.photoLibraryOutlined,
                              color: Colors.white,
                              size: 22,
                            ),
                      onTap: _openingLibrary ? null : _openLibrary,
                    ),
            ),
            Semantics(
              button: true,
              enabled: shutterOn,
              label: !_video
                  ? 'Take photo'
                  : _recording
                  ? 'Stop recording'
                  : 'Start recording',
              child: GestureDetector(
                key: const ValueKey('camera-shutter'),
                onTap: shutterOn ? _onShutter : null,
                child: _Shutter(
                  video: _video,
                  recording: _recording,
                  enabled: canCapture,
                  busy: _busy && !_video,
                  progress:
                      _elapsed.inMilliseconds /
                      noteVideoMaxLength.inMilliseconds,
                ),
              ),
            ),
            if (!_recording && _ready && _cameras.length > 1)
              Align(
                alignment: Alignment.centerRight,
                child: _SideButton(
                  key: const ValueKey('camera-switch'),
                  label: 'Flip',
                  semanticsLabel: 'Switch camera',
                  icon: const KapyIcon(
                    KapyIcons.cameraSwitchRounded,
                    color: Colors.white,
                    size: 22,
                  ),
                  onTap: _switchCamera,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewfinder() {
    final controller = _controller;
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _cream));
    }
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final previewSize = controller.value.previewSize;
    if (previewSize == null) return CameraPreview(controller);
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final width = portrait ? previewSize.height : previewSize.width;
    final height = portrait ? previewSize.width : previewSize.height;
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: width,
            height: height,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Widget _buildProblem(_Problem problem) {
    final (title, body) = switch (problem) {
      _Problem.accessOff => (
        'Camera access is off',
        'To take photos and record videos here, allow the camera for Kapy '
            'Notes in Settings.',
      ),
      _Problem.busy => (
        'The camera is busy',
        "Another app or a call is using it. Try again when it's free.",
      ),
      _Problem.noCamera => (null, 'No camera was found on this device.'),
    };
    final settings = problem == _Problem.accessOff;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const KapyIcon(
              KapyIcons.cameraOffOutlined,
              color: Colors.white70,
              size: 40,
            ),
            const SizedBox(height: 16),
            if (title != null) ...[
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: AppWeight.font(AppWeight.regular),
                  fontVariations: AppWeight.wght(AppWeight.regular),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 15,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              key: ValueKey(settings ? 'camera-settings' : 'camera-retry'),
              onPressed: settings
                  ? () => unawaited(widget.phone.openSettings())
                  : () => unawaited(_initializeCamera()),
              style: FilledButton.styleFrom(
                backgroundColor: _cream,
                foregroundColor: _ink,
                minimumSize: const Size(200, 48),
              ),
              child: Text(settings ? 'Open Settings' : 'Try again'),
            ),
            const SizedBox(height: 6),
            TextButton(
              key: const ValueKey('camera-choose-photos'),
              onPressed: _openingLibrary ? null : _openLibrary,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                minimumSize: const Size(200, 48),
              ),
              child: const Text('Choose from Photos'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReview(XFile file) {
    final note = _tooLarge
        ? 'This video ${describeVideoRejection(VideoRejection.tooLarge, attachmentMaxBytes: widget.attachmentMaxBytes)}.'
        : _reviewNote;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SizedBox(
              height: 48,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _RoundCameraButton(
                      key: const ValueKey('camera-close'),
                      label: 'Close camera',
                      icon: KapyIcons.closeRounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Text(
                    _capturedVideo ? 'Review video' : 'Review photo',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: AppWeight.font(AppWeight.regular),
                      fontVariations: AppWeight.wght(AppWeight.regular),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _capturedVideo
                ? _VideoReview(key: ValueKey(file.path), file: file)
                : _PhotoReview(file: file),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
              child: Row(
                key: const ValueKey('camera-review-note'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: KapyIcon(
                      KapyIcons.infoOutlined,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      note,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 22),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('camera-retake'),
                    onPressed: _retake,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      minimumSize: const Size(0, 52),
                    ),
                    icon: const KapyIcon(KapyIcons.refreshRounded),
                    label: const Text('Retake'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: FilledButton.icon(
                    key: ValueKey(
                      _capturedVideo ? 'camera-use-video' : 'camera-use-photo',
                    ),
                    onPressed: _tooLarge ? null : _keep,
                    style: FilledButton.styleFrom(
                      backgroundColor: _cream,
                      foregroundColor: _ink,
                      minimumSize: const Size(0, 52),
                    ),
                    icon: const KapyIcon(KapyIcons.checkRounded),
                    label: Text(_capturedVideo ? 'Use video' : 'Use photo'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoReview extends StatelessWidget {
  const _PhotoReview({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    // Decoded to fit the screen, which is the size it is shown at. The
    // capture itself is a twelve-megapixel JPEG that would otherwise decode to
    // some fifty megabytes of pixels for a review; the note gets the file,
    // not this decode, so nothing downstream is any smaller.
    final screen = View.of(context).physicalSize;
    return Image(
      image: ResizeImage(
        FileImage(File(file.path)),
        width: screen.width.ceil(),
        height: screen.height.ceil(),
        policy: ResizeImagePolicy.fit,
      ),
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const Center(
        child: KapyIcon(KapyIcons.brokenImageOutlined, color: Colors.white70),
      ),
    );
  }
}

/// The recording, ready to play before it is kept, with its time along a
/// bar that scrubs.
class _VideoReview extends StatefulWidget {
  const _VideoReview({super.key, required this.file});

  final XFile file;

  @override
  State<_VideoReview> createState() => _VideoReviewState();
}

class _VideoReviewState extends State<_VideoReview> {
  late final VideoPlayerController _player = VideoPlayerController.file(
    File(widget.file.path),
  );
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _player.addListener(_changed);
    unawaited(
      _player.initialize().catchError((Object _) {
        if (mounted) setState(() => _failed = true);
      }),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _player.removeListener(_changed);
    unawaited(_player.dispose());
    super.dispose();
  }

  void _togglePlay() {
    final value = _player.value;
    if (!value.isInitialized) return;
    if (value.isPlaying) {
      unawaited(_player.pause());
      return;
    }
    if (value.position >= value.duration) {
      unawaited(_player.seekTo(Duration.zero));
    }
    unawaited(_player.play());
  }

  @override
  Widget build(BuildContext context) {
    final value = _player.value;
    if (_failed || value.hasError) {
      return const Center(
        child: KapyIcon(KapyIcons.videoOutlined, color: Colors.white70),
      );
    }
    if (!value.isInitialized) return const SizedBox.expand();
    final length = value.duration;
    final position = value.position > length ? length : value.position;
    const time = TextStyle(color: Colors.white70, fontSize: 12);
    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: value.aspectRatio,
                  child: VideoPlayer(_player),
                ),
              ),
              Semantics(
                button: true,
                label: value.isPlaying ? 'Pause' : 'Play',
                child: GestureDetector(
                  key: const ValueKey('camera-review-play'),
                  onTap: _togglePlay,
                  child: Container(
                    width: 60,
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: KapyIcon(
                      value.isPlaying
                          ? KapyIcons.pauseRounded
                          : KapyIcons.playRounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
          child: Row(
            children: [
              Text(cameraClock(position), style: time),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey('camera-review-scrub'),
                    value: length.inMilliseconds == 0
                        ? 0
                        : position.inMilliseconds / length.inMilliseconds,
                    onChanged: (fraction) =>
                        unawaited(_player.seekTo(length * fraction)),
                  ),
                ),
              ),
              Text(cameraClock(length), style: time),
            ],
          ),
        ),
      ],
    );
  }
}

class _CameraScrims extends StatelessWidget {
  const _CameraScrims();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Column(
      children: [
        Container(
          height: 148,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xB3000000), Color(0x00000000)],
            ),
          ),
        ),
        const Spacer(),
        Container(
          height: 240,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
        ),
      ],
    ),
  );
}

/// "0:42 / 1:00" over the picture while recording, with "Paused" ahead of
/// it while paused.
class _RecordingTime extends StatelessWidget {
  const _RecordingTime({required this.elapsed, required this.paused});

  final Duration elapsed;
  final bool paused;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('camera-timer'),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (paused)
          const KapyIcon(KapyIcons.pauseRounded, color: Colors.white, size: 14)
        else
          const DecoratedBox(
            decoration: BoxDecoration(
              color: _recordRed,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(dimension: 8),
          ),
        const SizedBox(width: 8),
        Text.rich(
          TextSpan(
            children: [
              if (paused) const TextSpan(text: 'Paused '),
              TextSpan(
                text: cameraClock(elapsed),
                style: TextStyle(
                  fontWeight: AppWeight.font(AppWeight.regular),
                  fontVariations: AppWeight.wght(AppWeight.regular),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              TextSpan(
                text: ' / ${cameraClock(noteVideoMaxLength)}',
                style: const TextStyle(color: Colors.white60),
              ),
            ],
          ),
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    ),
  );
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.video, required this.onChanged});

  final bool video;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (choice, label) in const [(false, 'Photo'), (true, 'Video')])
          Semantics(
            button: true,
            selected: choice == video,
            child: GestureDetector(
              key: ValueKey('camera-mode-${label.toLowerCase()}'),
              onTap: () => onChanged(choice),
              child: Container(
                constraints: const BoxConstraints(minHeight: 34),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: choice == video ? Colors.white24 : null,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: choice == video ? Colors.white : Colors.white70,
                    fontSize: 14,
                    fontWeight: AppWeight.font(
                      choice == video ? AppWeight.regular : AppWeight.regular,
                    ),
                    fontVariations: AppWeight.wght(
                      choice == video ? AppWeight.regular : AppWeight.regular,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// White for a photo, red for a video. While recording, a red ring fills
/// around it towards the minute, and the red disc becomes a stop square.
class _Shutter extends StatelessWidget {
  const _Shutter({
    required this.video,
    required this.recording,
    required this.enabled,
    required this.busy,
    required this.progress,
  });

  final bool video;
  final bool recording;
  final bool enabled;
  final bool busy;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final fill = video ? _recordRed : Colors.white;
    return SizedBox.square(
      dimension: 76,
      child: CustomPaint(
        painter: _ShutterRing(progress: recording ? progress : null),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: recording ? 28 : 60,
            height: recording ? 28 : 60,
            decoration: BoxDecoration(
              color: enabled ? fill : fill.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(recording ? 6 : 30),
            ),
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(
                      color: _ink,
                      strokeWidth: 2,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _ShutterRing extends CustomPainter {
  const _ShutterRing({required this.progress});

  /// How much of the minute is used, or null when not recording.
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1.5);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = progress == null ? Colors.white : Colors.white30;
    canvas.drawOval(rect, ring);
    final used = progress;
    if (used == null || used <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * used.clamp(0.0, 1.0),
      false,
      ring
        ..color = _recordRed
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ShutterRing old) => old.progress != progress;
}

/// A round button with its name under it, beside the shutter.
class _SideButton extends StatelessWidget {
  const _SideButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.semanticsLabel,
  });

  final String label;
  final String? semanticsLabel;
  final Widget icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticsLabel ?? label,
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.38),
              ),
              child: icon,
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: AppTypeScale.small,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RoundCameraButton extends StatelessWidget {
  const _RoundCameraButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.lit = false,
  });

  final String label;
  final KapyIconData icon;
  final VoidCallback onPressed;

  /// Drawn light on dark while what it controls is on, as the light is.
  final bool lit;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: IconButton(
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: lit ? _cream : Colors.black.withValues(alpha: 0.38),
        foregroundColor: lit ? _ink : Colors.white,
      ),
      icon: KapyIcon(icon),
    ),
  );
}

/// A line over the picture about something the person can put right, with
/// the way to do it.
class _CameraNotice extends StatelessWidget {
  const _CameraNotice({
    super.key,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final KapyIconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KapyIcon(icon, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              if (action case final label?)
                GestureDetector(
                  key: const ValueKey('camera-notice-action'),
                  onTap: onAction,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        decoration: TextDecoration.underline,
                        decorationColor: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// "0:42": minutes and seconds, as the camera shows a video's time.
String cameraClock(Duration duration) {
  final seconds = duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

int _sizeOf(XFile file) {
  try {
    return File(file.path).lengthSync();
  } on FileSystemException {
    return 0;
  }
}

/// Stops a recording nobody kept before the controller goes, so its file
/// goes with it.
Future<void> _closeController(
  CameraController? controller, {
  required bool discardRecording,
}) async {
  if (controller == null) return;
  if (discardRecording) {
    try {
      _deleteCapture(await controller.stopVideoRecording());
    } catch (_) {
      // Already stopped, so there is nothing left to delete.
    }
  }
  await controller.dispose();
}

/// One unlink, done at once so a closing page leaves no file behind.
void _deleteCapture(XFile? file) {
  if (file == null || file.path.isEmpty) return;
  try {
    File(file.path).deleteSync();
  } on FileSystemException {
    // Already gone, or in a cache the system clears anyway.
  }
}
