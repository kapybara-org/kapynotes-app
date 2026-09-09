import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

typedef CameraListLoader = Future<List<CameraDescription>> Function();
typedef ImageLibraryPicker = Future<List<XFile>> Function();

/// Opens the mobile capture surface and returns either one new photograph or
/// the pictures selected through its library shortcut.
Future<List<XFile>> showNoteCamera(
  BuildContext context, {
  required ImageLibraryPicker chooseFromLibrary,
  CameraListLoader loadCameras = availableCameras,
}) async {
  final files = await Navigator.of(context, rootNavigator: true)
      .push<List<XFile>>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CameraCapturePage(
            chooseFromLibrary: chooseFromLibrary,
            loadCameras: loadCameras,
          ),
        ),
      );
  return files ?? const [];
}

/// A focused still-camera experience for a note.
///
/// It deliberately does not expose video, filters or a second editing step.
/// The full screen is the viewfinder, the three useful camera controls stay at
/// the edges, and the library remains one tap away. A captured photo is not
/// returned until the user explicitly chooses **Use photo**.
class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({
    super.key,
    required this.chooseFromLibrary,
    this.loadCameras = availableCameras,
  });

  final ImageLibraryPicker chooseFromLibrary;
  final CameraListLoader loadCameras;

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  CameraDescription? _activeCamera;
  XFile? _captured;
  String? _cameraError;
  bool _loading = true;
  bool _takingPicture = false;
  bool _openingLibrary = false;
  bool _flashAuto = false;
  bool _keptCapture = false;
  int _cameraGeneration = 0;

  bool get _ready => _controller?.value.isInitialized ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_captured != null) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _releaseCamera(markLoading: true);
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      unawaited(_initializeCamera(preferred: _activeCamera));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraGeneration++;
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose());
    if (!_keptCapture) unawaited(_deleteCapture(_captured));
    super.dispose();
  }

  Future<void> _initializeCamera({CameraDescription? preferred}) async {
    final generation = ++_cameraGeneration;
    final previous = _controller;
    _controller = null;
    if (mounted) {
      setState(() {
        _loading = true;
        _cameraError = null;
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
          _cameraError = 'No camera was found on this device.';
        });
        return;
      }

      final selected = preferred != null && cameras.contains(preferred)
          ? preferred
          : cameras.firstWhere(
              (camera) => camera.lensDirection == CameraLensDirection.back,
              orElse: () => cameras.first,
            );
      final controller = await _openController(selected);
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
        _loading = false;
      });
    } on CameraException catch (error) {
      if (!mounted || generation != _cameraGeneration) return;
      setState(() {
        _loading = false;
        _cameraError = _describeCameraError(error);
      });
    } catch (error) {
      if (!mounted || generation != _cameraGeneration) return;
      setState(() {
        _loading = false;
        _cameraError = 'The camera is unavailable right now.';
      });
    }
  }

  Future<CameraController> _openController(
    CameraDescription description,
  ) async {
    final controller = CameraController(
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

  void _releaseCamera({required bool markLoading}) {
    _cameraGeneration++;
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose());
    if (mounted && markLoading && !_loading) {
      setState(() => _loading = true);
    }
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture ||
        _takingPicture) {
      return;
    }
    setState(() => _takingPicture = true);
    try {
      final file = await controller.takePicture();
      if (!mounted) {
        await _deleteCapture(file);
        return;
      }
      try {
        await controller.pausePreview();
      } catch (_) {
        // A frozen preview is polish, not a prerequisite for review.
      }
      setState(() => _captured = file);
    } on CameraException {
      if (mounted) _showMessage('Could not take that photo. Try again.');
    } finally {
      if (mounted) setState(() => _takingPicture = false);
    }
  }

  Future<void> _retake() async {
    final old = _captured;
    setState(() => _captured = null);
    await _deleteCapture(old);
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

  void _usePhoto() {
    final captured = _captured;
    if (captured == null) return;
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

  Widget _buildCamera() => Stack(
    fit: StackFit.expand,
    children: [
      _buildViewfinder(),
      const _CameraScrims(),
      SafeArea(
        child: Column(
          children: [
            _CameraTopBar(
              title: 'Camera',
              onClose: () => Navigator.of(context).pop(),
              onFlash: _ready ? _toggleFlash : null,
              flashAuto: _flashAuto,
              onSwitch: _ready && _cameras.length > 1 ? _switchCamera : null,
            ),
            const Spacer(),
            _CameraBottomBar(
              openingLibrary: _openingLibrary,
              takingPicture: _takingPicture,
              canCapture: _ready && !_loading,
              onLibrary: _openLibrary,
              onCapture: _takePicture,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _buildViewfinder() {
    final controller = _controller;
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFF5F2E9)),
      );
    }
    if (_cameraError case final message?) {
      return _CameraUnavailable(message: message, onRetry: _initializeCamera);
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

  Widget _buildReview(XFile file) => Stack(
    fit: StackFit.expand,
    children: [
      Image.file(
        File(file.path),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.white70),
        ),
      ),
      const _CameraScrims(),
      SafeArea(
        child: Column(
          children: [
            _CameraTopBar(
              title: 'Review photo',
              onClose: () => Navigator.of(context).pop(),
            ),
            const Spacer(),
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
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retake'),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('camera-use-photo'),
                      onPressed: _usePhoto,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFF5F2E9),
                        foregroundColor: const Color(0xFF15171A),
                        minimumSize: const Size(0, 52),
                      ),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Use photo'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );
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
          height: 184,
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

class _CameraTopBar extends StatelessWidget {
  const _CameraTopBar({
    required this.title,
    required this.onClose,
    this.onFlash,
    this.flashAuto = false,
    this.onSwitch,
  });

  final String title;
  final VoidCallback onClose;
  final VoidCallback? onFlash;
  final bool flashAuto;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) => Padding(
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
              icon: Icons.close_rounded,
              onPressed: onClose,
            ),
          ),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onFlash != null)
                  _RoundCameraButton(
                    key: const ValueKey('camera-flash'),
                    label: flashAuto ? 'Turn flash off' : 'Set flash to auto',
                    icon: flashAuto
                        ? Icons.flash_auto_rounded
                        : Icons.flash_off,
                    onPressed: onFlash!,
                  ),
                if (onFlash != null && onSwitch != null)
                  const SizedBox(width: 4),
                if (onSwitch != null)
                  _RoundCameraButton(
                    key: const ValueKey('camera-switch'),
                    label: 'Switch camera',
                    icon: Icons.cameraswitch_rounded,
                    onPressed: onSwitch!,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _CameraBottomBar extends StatelessWidget {
  const _CameraBottomBar({
    required this.openingLibrary,
    required this.takingPicture,
    required this.canCapture,
    required this.onLibrary,
    required this.onCapture,
  });

  final bool openingLibrary;
  final bool takingPicture;
  final bool canCapture;
  final VoidCallback onLibrary;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
    child: SizedBox(
      height: 86,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              label: 'Choose existing photos',
              child: InkWell(
                key: const ValueKey('camera-library'),
                onTap: openingLibrary ? null : onLibrary,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (openingLibrary)
                        const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      else
                        const Icon(
                          Icons.photo_library_outlined,
                          color: Colors.white,
                          size: 26,
                        ),
                      const SizedBox(height: 4),
                      const Text(
                        'Photos',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Semantics(
            button: true,
            enabled: canCapture && !takingPicture,
            label: 'Take photo',
            child: GestureDetector(
              key: const ValueKey('camera-shutter'),
              onTap: canCapture && !takingPicture ? onCapture : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 76,
                height: 76,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: canCapture
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.35),
                  ),
                  child: takingPicture
                      ? const Padding(
                          padding: EdgeInsets.all(17),
                          child: CircularProgressIndicator(
                            color: Color(0xFF15171A),
                            strokeWidth: 2,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
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
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: IconButton(
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.38),
        foregroundColor: Colors.white,
      ),
      icon: Icon(icon),
    ),
  );
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 44),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.no_photography_outlined,
            color: Colors.white70,
            size: 42,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            key: const ValueKey('camera-retry'),
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}

String _describeCameraError(CameraException error) => switch (error.code) {
  'CameraAccessDenied' || 'CameraAccessDeniedWithoutPrompt' =>
    'Allow camera access in Settings to take a photo. You can still choose one from Photos.',
  'CameraAccessRestricted' =>
    'Camera access is restricted on this device. You can still choose one from Photos.',
  _ => 'The camera is unavailable right now. You can still choose from Photos.',
};

Future<void> _deleteCapture(XFile? file) async {
  if (file == null || file.path.isEmpty) return;
  try {
    final temporary = File(file.path);
    if (await temporary.exists()) await temporary.delete();
  } catch (_) {
    // Camera files live in cache. A failed best-effort cleanup is harmless.
  }
}
