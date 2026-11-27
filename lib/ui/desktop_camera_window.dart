import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../images/camera_capture.dart';
import '../images/desktop_camera.dart';
import '../images/image_picker.dart';
import '../video/video_ingest.dart';
import '../video/video_picker.dart';
import 'tonal_button.dart';

/// Photos and videos in one file dialog, for when the camera can't be used.
Future<List<XFile>> chooseCameraFiles() async {
  try {
    return await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'Photos and videos',
          extensions: [
            ...?imageTypeGroup.extensions,
            ...?videoTypeGroup.extensions,
          ],
          uniformTypeIdentifiers: const ['public.image', 'public.movie'],
          mimeTypes: [
            ...?imageTypeGroup.mimeTypes,
            ...?videoTypeGroup.mimeTypes,
          ],
        ),
      ],
    );
  } catch (error) {
    debugPrint('KapyNotes: camera file chooser failed: $error');
    return const [];
  }
}

/// Opens the camera window over the note, and returns the photo or video kept
/// there, or the files chosen instead.
Future<List<XFile>> showDesktopCamera(
  BuildContext context, {
  required DesktopCamera camera,
  required int attachmentMaxBytes,
  required Future<List<XFile>> Function() chooseFiles,
  bool startInVideo = false,
  ValueChanged<bool>? onVideoChosen,
  String? cameraId,
  ValueChanged<String>? onCameraChosen,
  Future<Directory> Function() captureDirectory = getTemporaryDirectory,
}) async {
  final files = await showDialog<List<XFile>>(
    context: context,
    builder: (_) => DesktopCameraWindow(
      camera: camera,
      attachmentMaxBytes: attachmentMaxBytes,
      chooseFiles: chooseFiles,
      startInVideo: startInVideo,
      onVideoChosen: onVideoChosen,
      cameraId: cameraId,
      onCameraChosen: onCameraChosen,
      captureDirectory: captureDirectory,
    ),
  );
  return files ?? const [];
}

/// The camera on a Mac or PC: a window over the note with the picture, the
/// camera to use, the shutter and a Photo / Video switch. Space takes the
/// photo or starts and stops the video, and Esc closes it. Review happens in
/// the same window, and nothing is returned until Use photo or Use video.
class DesktopCameraWindow extends StatefulWidget {
  const DesktopCameraWindow({
    super.key,
    required this.camera,
    required this.attachmentMaxBytes,
    required this.chooseFiles,
    this.startInVideo = false,
    this.onVideoChosen,
    this.cameraId,
    this.onCameraChosen,
    this.captureDirectory = getTemporaryDirectory,
  });

  final DesktopCamera camera;

  /// The largest attachment the note's plan allows, which bounds a video.
  final int attachmentMaxBytes;
  final Future<List<XFile>> Function() chooseFiles;
  final bool startInVideo;

  /// Told each time the switch changes mode, so the next window opens in it.
  final ValueChanged<bool>? onVideoChosen;

  /// The camera chosen last time, used again while it is there.
  final String? cameraId;
  final ValueChanged<String>? onCameraChosen;
  final Future<Directory> Function() captureDirectory;

  @override
  State<DesktopCameraWindow> createState() => _DesktopCameraWindowState();
}

enum _Problem { accessOff, busy, noCamera }

const _recordRed = Color(0xFFF2675C);
const _picture = Color(0xFF0E0D0B);
const _tick = Duration(milliseconds: 100);

/// Ticks between two looks at how big the recording has grown.
const _ticksPerCheck = 5;

class _DesktopCameraWindowState extends State<DesktopCameraWindow>
    with WidgetsBindingObserver {
  final _focus = FocusNode(debugLabel: 'Camera window');
  List<DesktopCameraDevice> _cameras = const [];
  DesktopCameraDevice? _activeCamera;
  DesktopCameraSession? _session;
  _Problem? _problem;
  bool _loading = true;
  bool _busy = false;
  bool _keptCapture = false;
  int _generation = 0;

  late bool _video = widget.startInVideo;
  bool _micOff = false;

  String? _recordingPath;
  bool _stopping = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  int _ticks = 0;

  XFile? _captured;
  bool _capturedVideo = false;
  Duration _capturedLength = Duration.zero;
  String? _reviewNote;
  bool _tooLarge = false;

  bool get _recording => _recordingPath != null;
  int get _largestVideo => maxVideoSourceBytesFor(widget.attachmentMaxBytes);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_openCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system's settings, perhaps with the camera or microphone
    // now allowed.
    if (state != AppLifecycleState.resumed ||
        _captured != null ||
        _recording ||
        (_problem != _Problem.accessOff && !_micOff)) {
      return;
    }
    _micOff = false;
    unawaited(_openCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _generation++;
    unawaited(_session?.close());
    _session = null;
    if (!_keptCapture) _delete(_captured?.path);
    _focus.dispose();
    super.dispose();
  }

  Future<void> _openCamera() async {
    final generation = ++_generation;
    final previous = _session;
    _session = null;
    setState(() {
      _loading = true;
      _problem = null;
    });
    await previous?.close();
    try {
      final cameras = await widget.camera.cameras();
      if (!mounted || generation != _generation) return;
      if (cameras.isEmpty) {
        setState(() {
          _cameras = const [];
          _loading = false;
          _problem = _Problem.noCamera;
        });
        return;
      }
      final wanted = _activeCamera?.id ?? widget.cameraId;
      final selected = cameras.firstWhere(
        (camera) => camera.id == wanted,
        orElse: () => cameras.first,
      );
      final video = _video;
      DesktopCameraSession session;
      try {
        session = await widget.camera.open(
          selected,
          video: video,
          sound: video && !_micOff,
        );
      } on DesktopCameraException {
        // A refused microphone fails the opening with sound; the picture may
        // still come without it.
        if (!video || _micOff) rethrow;
        session = await widget.camera.open(selected, video: true, sound: false);
        _micOff = true;
      }
      if (!mounted || generation != _generation) {
        await session.close();
        return;
      }
      setState(() {
        _cameras = cameras;
        _activeCamera = selected;
        _session = session;
        _loading = false;
      });
    } on DesktopCameraException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _problem = switch (error.trouble) {
          DesktopCameraTrouble.accessOff => _Problem.accessOff,
          DesktopCameraTrouble.busy => _Problem.busy,
        };
      });
    }
  }

  Future<void> _chooseMode(bool video) async {
    if (video == _video || _recording || _busy || _captured != null) return;
    setState(() => _video = video);
    widget.onVideoChosen?.call(video);
    await _openCamera();
  }

  Future<void> _chooseCamera(DesktopCameraDevice camera) async {
    if (camera == _activeCamera || _recording || _busy) return;
    _activeCamera = camera;
    widget.onCameraChosen?.call(camera.id);
    await _openCamera();
  }

  void _onShutter() {
    if (_session == null || _captured != null) return;
    if (!_video) {
      unawaited(_takePhoto());
    } else if (_recording) {
      unawaited(_stopRecording());
    } else {
      unawaited(_startRecording());
    }
  }

  Future<String> _capturePath(String extension) async {
    final base = await widget.captureDirectory();
    final folder = Directory('${base.path}/camera');
    folder.createSync(recursive: true);
    return '${folder.path}/${DateTime.now().microsecondsSinceEpoch}.$extension';
  }

  Future<void> _takePhoto() async {
    final session = _session;
    if (session == null || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await session.takePhoto(await _capturePath('jpg'));
      if (!mounted) {
        _delete(file.path);
        return;
      }
      setState(() {
        _captured = file;
        _capturedVideo = false;
      });
    } catch (_) {
      if (mounted) _say('Could not take that photo. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startRecording() async {
    final session = _session;
    if (session == null || _busy) return;
    setState(() => _busy = true);
    try {
      final path = await _capturePath('mp4');
      await session.startRecording(path);
      if (!mounted) return;
      _ticks = 0;
      _ticker = Timer.periodic(_tick, _onTick);
      setState(() {
        _recordingPath = path;
        _elapsed = Duration.zero;
      });
    } catch (_) {
      if (mounted) _say('Could not start recording. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onTick(Timer timer) {
    if (!_recording || _stopping) return;
    setState(() => _elapsed += _tick);
    if (_elapsed >= noteVideoMaxLength) {
      unawaited(_stopRecording());
    } else if (++_ticks % _ticksPerCheck == 0) {
      _checkSize();
    }
  }

  /// Stops a recording before it outgrows the plan. Where the file isn't
  /// written as it grows, the minute and the check in review still hold.
  void _checkSize() {
    final path = _recordingPath;
    if (path == null) return;
    if (_sizeOf(path) < _largestVideo - noteVideoSizeMargin) return;
    unawaited(
      _stopRecording(note: recordingStoppedAtSize(widget.attachmentMaxBytes)),
    );
  }

  Future<void> _stopRecording({String? note}) async {
    final session = _session;
    if (session == null || !_recording || _stopping) return;
    _stopping = true;
    _ticker?.cancel();
    try {
      final file = await session.stopRecording();
      if (!mounted) {
        _delete(file.path);
        return;
      }
      setState(() {
        _recordingPath = null;
        _captured = file;
        _capturedVideo = true;
        _capturedLength = _elapsed;
        _reviewNote = note;
        _tooLarge = _sizeOf(file.path) > _largestVideo;
      });
    } catch (_) {
      if (!mounted) return;
      _delete(_recordingPath);
      setState(() => _recordingPath = null);
      _say('Could not save that video. Try again.');
    } finally {
      _stopping = false;
    }
  }

  void _retake() {
    _delete(_captured?.path);
    setState(() {
      _captured = null;
      _reviewNote = null;
      _tooLarge = false;
    });
    _focus.requestFocus();
  }

  void _keep() {
    final captured = _captured;
    if (captured == null || _tooLarge) return;
    _keptCapture = true;
    Navigator.of(context).pop(<XFile>[captured]);
  }

  Future<void> _chooseFiles() async {
    final files = await widget.chooseFiles();
    if (!mounted || files.isEmpty) return;
    Navigator.of(context).pop(files);
  }

  void _say(String message) =>
      Toast.show(context, message, icon: KapyIcons.errorOutlined);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space && _captured == null) {
      _onShutter();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final captured = _captured;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(880.0, size.width - 96);
    return Dialog(
      backgroundColor: palette.surfaceBackground,
      insetPadding: const EdgeInsets.all(24),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 22, 26, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  title: captured == null
                      ? 'Camera'
                      : _capturedVideo
                      ? 'Review video'
                      : 'Review photo',
                  onClose: () => Navigator.of(context).pop(),
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: captured == null
                        ? _buildCamera()
                        : _buildReview(captured),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildCamera() {
    final problem = _problem;
    if (problem != null) {
      return [_Picture(child: _buildProblem(problem))];
    }
    final session = _session;
    return [
      _Picture(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (session != null && !_loading)
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: 1280,
                  height: 1280 / session.aspectRatio,
                  child: session.preview(),
                ),
              ),
            if (_recording)
              Positioned(
                left: 16,
                top: 16,
                child: _RecordingTime(elapsed: _elapsed),
              )
            else if (_video && _micOff)
              Positioned(
                left: 16,
                right: 16,
                top: 16,
                child: _MicrophoneOff(
                  onOpenSettings: () => unawaited(
                    widget.camera.openPrivacySettings(microphone: true),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      SizedBox(
        height: 84,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _CameraList(
                cameras: _cameras,
                active: _activeCamera,
                enabled: !_recording && !_busy,
                onChosen: (camera) => unawaited(_chooseCamera(camera)),
              ),
            ),
            _Shutter(
              video: _video,
              recording: _recording,
              progress:
                  _elapsed.inMilliseconds / noteVideoMaxLength.inMilliseconds,
              onPressed: session == null || _loading ? null : _onShutter,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _ModeSwitch(
                video: _video,
                enabled: !_recording && !_busy,
                onChanged: (video) => unawaited(_chooseMode(video)),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildProblem(_Problem problem) {
    final mac = AppPlatform.isMacOS;
    final (title, body, action, onAction) = switch (problem) {
      _Problem.noCamera => (
        'No camera found',
        'Connect a camera, or add a photo or video from your files.',
        null,
        null,
      ),
      _Problem.accessOff => (
        'Camera access is off',
        mac
            ? 'Allow Kapy Notes in System Settings, under Privacy & '
                  'Security, then Camera.'
            : 'In Settings, go to Privacy & security, then Camera, and turn '
                  'on Let desktop apps access your camera.',
        mac ? 'Open System Settings' : 'Open Settings',
        () => unawaited(widget.camera.openPrivacySettings(microphone: false)),
      ),
      _Problem.busy => (
        'The camera is busy',
        'Another app is using it. Close that app, then try again.',
        'Try again',
        () => unawaited(_openCamera()),
      ),
    };
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: ValueKey('camera-problem-${problem.name}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            KapyIcon(
              KapyIcons.cameraOffOutlined,
              size: 30,
              color: palette.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 17,
                fontWeight: AppWeight.font(AppWeight.page),
                fontVariations: AppWeight.wght(AppWeight.page),
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: AppTypeScale.body,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                if (action case final label?)
                  TonalButton(label: label, onPressed: onAction),
                TonalButton(
                  label: 'Choose files',
                  neutral: action != null,
                  onPressed: () => unawaited(_chooseFiles()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildReview(XFile captured) {
    final palette = context.palette;
    final note = _tooLarge
        ? 'This video ${describeVideoRejection(VideoRejection.tooLarge, attachmentMaxBytes: widget.attachmentMaxBytes)}.'
        : _reviewNote;
    return [
      _Picture(
        child: _capturedVideo
            ? _VideoReview(key: ValueKey(captured.path), file: captured)
            : Image.file(
                File(captured.path),
                key: const ValueKey('camera-review-photo'),
                fit: BoxFit.contain,
                cacheWidth: 1760,
                errorBuilder: (_, _, _) => const Center(
                  child: KapyIcon(
                    KapyIcons.brokenImageOutlined,
                    color: Colors.white70,
                  ),
                ),
              ),
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          KapyIcon(
            _capturedVideo ? KapyIcons.videoOutlined : KapyIcons.imageOutlined,
            size: 17,
            color: palette.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _capturedVideo
                      ? 'Video · ${cameraClock(_capturedLength)}'
                      : 'Photo',
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: AppTypeScale.body,
                  ),
                ),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, right: 16),
                    child: Text(
                      note,
                      key: const ValueKey('camera-review-note'),
                      style: TextStyle(
                        color: palette.textTertiary,
                        fontSize: AppTypeScale.caption,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          TonalButton(
            key: const ValueKey('camera-retake'),
            icon: KapyIcons.refreshRounded,
            label: 'Retake',
            neutral: true,
            onPressed: _retake,
          ),
          const SizedBox(width: 10),
          TonalButton(
            key: const ValueKey('camera-use'),
            icon: KapyIcons.checkRounded,
            label: _capturedVideo ? 'Use video' : 'Use photo',
            onPressed: _tooLarge ? null : _keep,
          ),
        ],
      ),
    ];
  }
}

int _sizeOf(String path) {
  try {
    return File(path).lengthSync();
  } on FileSystemException {
    return 0;
  }
}

void _delete(String? path) {
  if (path == null || path.isEmpty) return;
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone, or in a folder the system clears anyway.
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 17,
              height: 22 / 17,
              fontWeight: AppWeight.font(AppWeight.page),
              fontVariations: AppWeight.wght(AppWeight.page),
              color: palette.textPrimary,
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('camera-close'),
          icon: const KapyIcon(KapyIcons.closeRounded, size: 18),
          tooltip: 'Close',
          color: palette.textSecondary,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onClose,
        ),
      ],
    );
  }
}

/// The 16:9 area the picture, a review or a problem fills.
class _Picture extends StatelessWidget {
  const _Picture({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 16 / 9,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.surface),
      child: ColoredBox(
        color: context.palette.brightness == Brightness.dark
            ? _picture
            : context.palette.controlBackground,
        child: child,
      ),
    ),
  );
}

/// "● 0:12 / 1:00" over the picture while recording.
class _RecordingTime extends StatelessWidget {
  const _RecordingTime({required this.elapsed});

  final Duration elapsed;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('camera-timer'),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(AppRadii.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(color: _recordRed, shape: BoxShape.circle),
          child: SizedBox.square(dimension: 8),
        ),
        const SizedBox(width: 8),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: cameraClock(elapsed),
                style: TextStyle(
                  fontWeight: AppWeight.font(AppWeight.button),
                  fontVariations: AppWeight.wght(AppWeight.button),
                ),
              ),
              TextSpan(
                text: ' / ${cameraClock(noteVideoMaxLength)}',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

/// What Video says when the microphone isn't allowed: the video still
/// records, without sound.
class _MicrophoneOff extends StatelessWidget {
  const _MicrophoneOff({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final mac = AppPlatform.isMacOS;
    return Align(
      alignment: Alignment.topLeft,
      child: Container(
        key: const ValueKey('camera-microphone-off'),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              mac
                  ? 'Your video will have no sound. To record sound, allow '
                        'Kapy Notes in System Settings, under Privacy & '
                        'Security, then Microphone.'
                  : 'Your video will have no sound. To record sound, go to '
                        'Settings, then Privacy & security, then Microphone, '
                        'and turn on Let desktop apps access your microphone.',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: const ValueKey('camera-microphone-settings'),
                onTap: onOpenSettings,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    mac ? 'Open System Settings' : 'Open Settings',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The camera to use, bottom left: its name, and the others in a menu.
class _CameraList extends StatelessWidget {
  const _CameraList({
    required this.cameras,
    required this.active,
    required this.enabled,
    required this.onChosen,
  });

  final List<DesktopCameraDevice> cameras;
  final DesktopCameraDevice? active;
  final bool enabled;
  final ValueChanged<DesktopCameraDevice> onChosen;

  @override
  Widget build(BuildContext context) {
    final active = this.active;
    if (active == null) return const SizedBox.shrink();
    final palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 272),
      child: PopupMenuButton<DesktopCameraDevice>(
        key: const ValueKey('camera-list'),
        enabled: enabled,
        tooltip: 'Camera',
        initialValue: active,
        position: PopupMenuPosition.over,
        onSelected: onChosen,
        itemBuilder: (_) => [
          for (final camera in cameras)
            PopupMenuItem(
              key: ValueKey('camera-choice-${camera.id}'),
              value: camera,
              child: Text(camera.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: palette.controlBackground,
            border: Border.all(color: palette.controlBorder),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              KapyIcon(
                KapyIcons.cameraOutlined,
                size: 16,
                color: palette.textSecondary,
              ),
              Flexible(
                child: Text(
                  active.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: AppTypeScale.body,
                  ),
                ),
              ),
              KapyIcon(
                KapyIcons.chevronDownRounded,
                size: 14,
                color: palette.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Photo, a plain round shutter; Video, a red one that turns to a stop
/// square while recording, with the minute filling round it.
class _Shutter extends StatelessWidget {
  const _Shutter({
    required this.video,
    required this.recording,
    required this.progress,
    required this.onPressed,
  });

  final bool video;
  final bool recording;
  final double progress;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      label: !video
          ? 'Take photo'
          : recording
          ? 'Stop recording'
          : 'Start recording',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('camera-shutter'),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 72,
            child: CustomPaint(
              painter: _ShutterRing(
                track: palette.textPrimary.withValues(alpha: 0.85),
                progress: recording ? progress.clamp(0, 1) : null,
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: recording ? 26 : 56,
                  height: recording ? 26 : 56,
                  decoration: BoxDecoration(
                    color: video ? _recordRed : palette.textPrimary,
                    borderRadius: BorderRadius.circular(recording ? 6 : 28),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShutterRing extends CustomPainter {
  const _ShutterRing({required this.track, required this.progress});

  final Color track;
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final progress = this.progress;
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = progress == null ? track : track.withValues(alpha: 0.25),
    );
    if (progress == null || progress == 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = _recordRed,
    );
  }

  @override
  bool shouldRepaint(_ShutterRing old) =>
      old.progress != progress || old.track != track;
}

/// Photo / Video, bottom right.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.video,
    required this.enabled,
    required this.onChanged,
  });

  final bool video;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget segment(String label, bool value) {
      final selected = value == video;
      final weight = selected ? AppWeight.button : AppWeight.body;
      return Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            key: ValueKey('camera-mode-${label.toLowerCase()}'),
            onTap: enabled ? () => onChanged(value) : null,
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? palette.surfaceBackground : null,
                borderRadius: BorderRadius.circular(AppRadii.compact),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? palette.textPrimary : palette.textSecondary,
                  fontSize: AppTypeScale.body,
                  fontWeight: AppWeight.font(weight),
                  fontVariations: AppWeight.wght(weight),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        border: Border.all(color: palette.controlBorder),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [segment('Photo', false), segment('Video', true)],
      ),
    );
  }
}

/// The recording, ready to play before it is kept, with its time along a
/// bar over the bottom of the picture.
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
    const time = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Stack(
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
          excludeSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey('camera-review-play'),
              onTap: _togglePlay,
              child: Container(
                width: 48,
                height: 48,
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
                  size: 22,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0x99000000), Color(0x00000000)],
              ),
            ),
            child: Row(
              children: [
                Text(cameraClock(position), style: time),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white38,
                      thumbColor: Colors.white,
                      overlayShape: SliderComponentShape.noOverlay,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
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
        ),
      ],
    );
  }
}
