import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme.dart';
import '../../data/blob_store.dart';
import '../../data/note_attachment.dart';
import '../../images/note_image_provider.dart';
import 'note_image_layout.dart';

/// A quiet first frame in the note. Playback opens edge-to-edge so a moving
/// surface never competes with the text somebody is editing around it.
class NoteVideoView extends StatefulWidget {
  const NoteVideoView({
    super.key,
    required this.ref,
    required this.box,
    required this.store,
    this.fetch,
    this.uploadProgress,
    this.onOpen,
    this.onRemove,
  });

  final NoteVideoRef ref;
  final NoteImageBox box;
  final BlobStore store;
  final NoteImageFetcher? fetch;
  final ValueListenable<double?>? uploadProgress;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  State<NoteVideoView> createState() => _NoteVideoViewState();
}

class _NoteVideoViewState extends State<NoteVideoView> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(NoteVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ref.hash != widget.ref.hash ||
        !identical(oldWidget.store, widget.store)) {
      unawaited(_controller?.dispose());
      _controller = null;
      _failed = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final ref = widget.ref;
    final store = widget.store;
    final file = await _videoFile(ref, store, widget.fetch);
    if (!mounted || widget.ref.hash != ref.hash || widget.store != store) {
      return;
    }
    if (file == null) {
      setState(() => _failed = true);
      return;
    }
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
      await controller.seekTo(Duration.zero);
      await controller.pause();
      if (!mounted || widget.ref.hash != ref.hash || widget.store != store) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      debugPrint('KapyNotes: video preview could not open: $error');
      await controller.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final progress = widget.uploadProgress;
    final media = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: palette.separator, width: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_controller case final controller?)
              FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: controller.value.size.width,
                  height: controller.value.size.height,
                  child: VideoPlayer(controller),
                ),
              )
            else
              _VideoUnavailable(palette: palette, failed: _failed),
            ColoredBox(color: Colors.black.withValues(alpha: 0.12)),
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  shape: BoxShape.circle,
                ),
                child: const Padding(
                  padding: EdgeInsets.all(13),
                  child: KapyIcon(
                    KapyIcons.playRounded,
                    size: 25,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 10,
              bottom: 8,
              child: Text(
                _durationLabel(widget.ref.duration),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppTypeScale.caption,
                  fontWeight: FontWeight.w500,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                ),
              ),
            ),
            if (!widget.ref.isUploaded && progress != null)
              Positioned.fill(
                child: ValueListenableBuilder<double?>(
                  valueListenable: progress,
                  builder: (context, value, _) => _VideoUploadCover(value),
                ),
              ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: noteImageGap / 2),
      child: MouseRegion(
        cursor: widget.onOpen == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onOpen,
          child: SizedBox(
            width: widget.box.width,
            height: widget.box.height,
            child: Stack(
              children: [
                Positioned.fill(child: media),
                if (widget.onRemove != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IconButton(
                      key: ValueKey(
                        'remove-video-${widget.ref.hash}-${widget.ref.offset}',
                      ),
                      tooltip: 'Remove video',
                      onPressed: widget.onRemove,
                      icon: const KapyIcon(KapyIcons.closeRounded, size: 17),
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.58),
                        minimumSize: const Size.square(30),
                        maximumSize: const Size.square(30),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoUploadCover extends StatelessWidget {
  const _VideoUploadCover(this.progress);

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final value = progress?.clamp(0.0, 1.0);
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.42),
      child: Center(
        child: value == null
            ? const SizedBox.square(
                dimension: 25,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                '${(value * 100).round()}%',
                key: const ValueKey('video-upload-percentage'),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppTypeScale.control,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

class _VideoUnavailable extends StatelessWidget {
  const _VideoUnavailable({required this.palette, required this.failed});

  final CalcPalette palette;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            KapyIcon(
              KapyIcons.videoOutlined,
              size: 26,
              color: palette.textTertiary,
            ),
            const SizedBox(height: 7),
            Text(
              failed ? 'Video unavailable' : 'Loading video…',
              style: TextStyle(
                color: palette.textTertiary,
                fontSize: AppTypeScale.caption,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NoteVideoViewer extends StatefulWidget {
  const NoteVideoViewer({
    super.key,
    required this.ref,
    required this.store,
    this.fetch,
  });

  final NoteVideoRef ref;
  final BlobStore store;
  final NoteImageFetcher? fetch;

  static Future<void> open(
    BuildContext context, {
    required NoteVideoRef ref,
    required BlobStore store,
    NoteImageFetcher? fetch,
  }) => Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (context, animation, secondary) => FadeTransition(
        opacity: animation,
        child: NoteVideoViewer(ref: ref, store: store, fetch: fetch),
      ),
      transitionDuration: const Duration(milliseconds: 160),
    ),
  );

  @override
  State<NoteVideoViewer> createState() => _NoteVideoViewerState();
}

class _NoteVideoViewerState extends State<NoteVideoViewer> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _controlsVisible = true;
  bool _lastIsPlaying = false;
  bool _lastIsCompleted = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final file = await _videoFile(widget.ref, widget.store, widget.fetch);
    if (!mounted) return;
    if (file == null) {
      setState(() => _failed = true);
      return;
    }
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
      _lastIsPlaying = controller.value.isPlaying;
      _lastIsCompleted = controller.value.isCompleted;
      controller.addListener(_playerChanged);
      await controller.play();
      if (!mounted) {
        controller.removeListener(_playerChanged);
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      _scheduleHide();
    } catch (error) {
      debugPrint('KapyNotes: video could not open: $error');
      await controller.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  void _playerChanged() {
    final value = _controller?.value;
    if (value == null ||
        (value.isPlaying == _lastIsPlaying &&
            value.isCompleted == _lastIsCompleted)) {
      return;
    }
    _lastIsPlaying = value.isPlaying;
    _lastIsCompleted = value.isCompleted;
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_controller?.value.isPlaying != true) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (controller.value.isCompleted) await controller.seekTo(Duration.zero);
      await controller.play();
    }
    if (mounted) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_playerChanged);
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) => Navigator.of(context).maybePop(),
            ),
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => _togglePlayback(),
            ),
          },
          child: Focus(
            autofocus: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _controlsVisible = !_controlsVisible);
                if (_controlsVisible) _scheduleHide();
              },
              onDoubleTap: _togglePlayback,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller != null && controller.value.isInitialized)
                    Center(
                      child: AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                    )
                  else
                    Center(
                      child: _failed
                          ? const Text(
                              'This video could not be played.',
                              style: TextStyle(color: Colors.white70),
                            )
                          : const CircularProgressIndicator(
                              color: Colors.white,
                            ),
                    ),
                  if (_controlsVisible && controller != null)
                    Center(
                      child: IconButton(
                        key: const ValueKey('video-play-pause'),
                        onPressed: _togglePlayback,
                        icon: KapyIcon(
                          controller.value.isPlaying
                              ? KapyIcons.pauseRounded
                              : KapyIcons.playRounded,
                          size: 34,
                        ),
                        color: Colors.white,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black.withValues(alpha: 0.48),
                          minimumSize: const Size.square(62),
                        ),
                      ),
                    ),
                  if (_controlsVisible && controller != null)
                    Positioned(
                      left: 18,
                      right: 18,
                      bottom: MediaQuery.paddingOf(context).bottom + 16,
                      child: VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.white,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 8,
                    right: 8,
                    child: IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const KapyIcon(KapyIcons.closeRounded),
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<File?> _videoFile(
  NoteVideoRef ref,
  BlobStore store,
  NoteImageFetcher? fetch,
) async {
  var file = await store.fileFor(ref.hash);
  if (file != null) return file;
  final bytes = await fetch?.call(ref.hash);
  if (bytes == null || BlobStore.hashOf(bytes) != ref.hash) return null;
  await store.put(bytes, extension: ref.extension);
  file = await store.fileFor(ref.hash);
  return file;
}

String _durationLabel(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:$minutes:$seconds'
      : '${duration.inMinutes}:$seconds';
}
