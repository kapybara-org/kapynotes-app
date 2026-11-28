import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../data/blob_store.dart';
import '../../data/note_attachment.dart';
import '../../images/note_image_provider.dart';
import '../settings_rows.dart';
import 'note_image_layout.dart';
import 'placeholder_scale.dart';

/// A video in the note, sized and rounded like a photo: its first frame, a
/// play button and its length. Play starts it right here, with sound, and
/// pause, the time, sound and full screen run along its foot. It never starts
/// by itself, and it stops when it is scrolled out of sight. Linux has no
/// player in the app, so there it opens in the person's own.
class NoteVideoView extends StatefulWidget {
  const NoteVideoView({
    super.key,
    required this.ref,
    required this.box,
    required this.store,
    this.fetch,
    this.uploadProgress,
    this.onRemove,
  });

  final NoteVideoRef ref;
  final NoteImageBox box;
  final BlobStore store;
  final NoteImageFetcher? fetch;
  final ValueListenable<double?>? uploadProgress;
  final VoidCallback? onRemove;

  @override
  State<NoteVideoView> createState() => _NoteVideoViewState();
}

class _NoteVideoViewState extends State<NoteVideoView> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _ready = false;

  /// Play has been pressed here, so the bar along the foot stays.
  bool _started = false;
  bool _playing = false;
  bool _hovering = false;
  List<ScrollPosition> _scrolls = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Every scrolling ancestor: the field's own may never move while the page
    // around it does, and either can carry the video out of sight.
    final scrolls = <ScrollPosition>[];
    for (
      var scrollable = Scrollable.maybeOf(context);
      scrollable != null;
      scrollable = Scrollable.maybeOf(scrollable.context)
    ) {
      scrolls.add(scrollable.position);
    }
    for (final scroll in _scrolls) {
      scroll.removeListener(_pauseOutOfSight);
    }
    _scrolls = scrolls;
    for (final scroll in _scrolls) {
      scroll.addListener(_pauseOutOfSight);
    }
  }

  @override
  void didUpdateWidget(NoteVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ref.hash != widget.ref.hash ||
        !identical(oldWidget.store, widget.store)) {
      _controller?.removeListener(_playerChanged);
      unawaited(_controller?.dispose());
      _controller = null;
      _failed = false;
      _ready = false;
      _started = false;
      _playing = false;
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
    if (AppPlatform.isLinux) {
      setState(() => _ready = true);
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
      controller.addListener(_playerChanged);
      setState(() => _controller = controller);
    } catch (error) {
      debugPrint('KapyNotes: video preview could not open: $error');
      await controller.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  void _playerChanged() {
    final playing = _controller?.value.isPlaying ?? false;
    if (playing == _playing || !mounted) return;
    setState(() => _playing = playing);
  }

  void _pauseOutOfSight() {
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    for (final scroll in _scrolls) {
      final viewport = scroll.context.notificationContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) continue;
      final view = viewport.localToGlobal(Offset.zero) & viewport.size;
      if (!rect.overlaps(view)) {
        unawaited(controller.pause());
        return;
      }
    }
  }

  Future<void> _togglePlayback() async {
    if (AppPlatform.isLinux) {
      if (!_ready) return;
      await NoteVideoViewer.open(
        context,
        ref: widget.ref,
        store: widget.store,
        fetch: widget.fetch,
      );
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
      return;
    }
    if (controller.value.isCompleted) await controller.seekTo(Duration.zero);
    setState(() => _started = true);
    await controller.play();
  }

  Future<void> _toggleSound() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.setVolume(controller.value.volume > 0 ? 0 : 1);
  }

  Future<void> _openFullScreen() async {
    final controller = _controller;
    if (controller == null) return;
    final playing = controller.value.isPlaying;
    await controller.pause();
    if (!mounted) return;
    final stoppedAt = await NoteVideoViewer.open(
      context,
      ref: widget.ref,
      store: widget.store,
      fetch: widget.fetch,
      start: controller.value.position,
      play: playing,
    );
    if (stoppedAt != null && identical(controller, _controller)) {
      await controller.seekTo(stoppedAt);
    }
  }

  @override
  void dispose() {
    for (final scroll in _scrolls) {
      scroll.removeListener(_pauseOutOfSight);
    }
    _controller?.removeListener(_playerChanged);
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final radius = BorderRadius.circular(widget.box.cropped ? 8 : 10);
    final playback = controller != null && _started;
    final media = ClipRRect(
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(
            color: context.palette.separator,
            width: AppHairline.of(context),
          ),
          borderRadius: radius,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null) ...[
              FittedBox(
                fit: widget.box.cropped ? BoxFit.cover : BoxFit.contain,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: controller.value.size.width,
                  height: controller.value.size.height,
                  child: VideoPlayer(controller),
                ),
              ),
              if (!_started) ...[
                ColoredBox(color: Colors.black.withValues(alpha: 0.12)),
                const Center(child: _PlayButton()),
              ],
            ] else
              _VideoPlaceholder(
                label: _failed
                    ? 'Video unavailable'
                    : _ready
                    ? 'Opens in your video player'
                    : 'Loading video…',
                playable: _ready,
              ),
            if (!playback)
              Positioned(
                left: 8,
                bottom: 8,
                child: _LengthPill(
                  length: widget.ref.duration,
                  progress: widget.ref.isUploaded
                      ? null
                      : widget.uploadProgress,
                ),
              )
            else ...[
              // A computer shows the bar under the pointer, or while paused;
              // a phone has no pointer to wait for.
              if (AppPlatform.isMobile || _hovering || !_playing)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _PlaybackBar(
                    controller: controller,
                    length: widget.ref.duration,
                    onPlayPause: _togglePlayback,
                    onSound: _toggleSound,
                    onFullScreen: _openFullScreen,
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _PlayedLine(controller),
              ),
            ],
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: noteImageGap / 2),
      child: MouseRegion(
        cursor: controller == null && !_ready
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: _togglePlayback,
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
                    child: PlaceholderTooltip(
                      message: 'Remove video',
                      child: IconButton(
                        key: ValueKey(
                          'remove-video-${widget.ref.hash}-${widget.ref.offset}',
                        ),
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
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('video-play'),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.62),
      shape: BoxShape.circle,
    ),
    child: const Padding(
      padding: EdgeInsets.all(13),
      child: KapyIcon(KapyIcons.playRounded, size: 25, color: Colors.white),
    ),
  );
}

/// White words over the picture, in figures that keep their width while the
/// time runs.
TextStyle _overPicture({bool quiet = false}) => TextStyle(
  color: quiet ? Colors.white70 : Colors.white,
  fontSize: AppTypeScale.caption,
  fontWeight: AppWeight.font(AppWeight.regular),
  fontVariations: AppWeight.wght(AppWeight.regular),
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// The length, in a pill on the first frame. While the video uploads, the
/// 14 px clock face beside it fills.
class _LengthPill extends StatelessWidget {
  const _LengthPill({required this.length, required this.progress});

  final Duration length;
  final ValueListenable<double?>? progress;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress != null) ...[
              ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (context, value, _) => SettingsPie(
                  key: const ValueKey('video-upload-pie'),
                  fraction: value,
                  fill: Colors.white,
                  track: Colors.white70,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(_clockLabel(length), style: _overPicture()),
          ],
        ),
      ),
    );
  }
}

/// Pause, the time, sound and full screen, along the foot of a video playing
/// in the note.
class _PlaybackBar extends StatelessWidget {
  const _PlaybackBar({
    required this.controller,
    required this.length,
    required this.onPlayPause,
    required this.onSound,
    required this.onFullScreen,
  });

  final VideoPlayerController controller;
  final Duration length;
  final VoidCallback onPlayPause;
  final VoidCallback onSound;
  final VoidCallback onFullScreen;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 5),
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final sound = value.volume > 0;
          return Row(
            children: [
              _BarButton(
                key: const ValueKey('note-video-play-pause'),
                icon: value.isPlaying
                    ? KapyIcons.pauseRounded
                    : KapyIcons.playRounded,
                label: value.isPlaying ? 'Pause' : 'Play',
                onPressed: onPlayPause,
              ),
              const SizedBox(width: 2),
              Flexible(
                child: Text.rich(
                  key: const ValueKey('video-time'),
                  TextSpan(
                    children: [
                      TextSpan(text: _clockLabel(value.position)),
                      TextSpan(
                        text:
                            ' / ${_clockLabel(value.duration > Duration.zero ? value.duration : length)}',
                        style: _overPicture(quiet: true),
                      ),
                    ],
                  ),
                  style: _overPicture(),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
              ),
              const Spacer(),
              _BarButton(
                key: const ValueKey('video-sound'),
                icon: sound
                    ? KapyIcons.volumeHighRounded
                    : KapyIcons.volumeOffRounded,
                label: sound ? 'Turn sound off' : 'Turn sound on',
                onPressed: onSound,
              ),
              _BarButton(
                key: const ValueKey('video-full-screen'),
                icon: KapyIcons.fullScreenRounded,
                label: 'Full screen',
                onPressed: onFullScreen,
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => PlaceholderTooltip(
    message: label,
    child: IconButton(
      onPressed: onPressed,
      icon: KapyIcon(icon, size: 18, semanticLabel: label),
      color: Colors.white,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(32),
        maximumSize: const Size.square(32),
        padding: EdgeInsets.zero,
      ),
    ),
  );
}

/// How far it has played, as a line along the very foot of the card.
class _PlayedLine extends StatelessWidget {
  const _PlayedLine(this.controller);

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final total = value.duration.inMilliseconds;
          return SizedBox(
            height: 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.white24),
                FractionallySizedBox(
                  key: const ValueKey('video-played'),
                  alignment: Alignment.centerLeft,
                  widthFactor: total <= 0
                      ? 0
                      : (value.position.inMilliseconds / total).clamp(0.0, 1.0),
                  child: const ColoredBox(color: Colors.white),
                ),
              ],
            ),
          );
        },
      );
}

/// What stands in a video's place until its first frame can be shown: what
/// is happening, in words under a mark, the video's or, where the video opens
/// in the video player, the play glyph. Nothing is drawn over the words.
/// The card is black in either appearance, so the mark and the words keep
/// the dark appearance's quiet ink, the way the time and the × keep white.
/// Increase contrast strengthens it, as it does every quiet text.
class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.label, required this.playable});

  final String label;
  final bool playable;

  @override
  Widget build(BuildContext context) {
    final dark = KapyTheme.darkPalette;
    final ink =
        (context.palette.increasedContrast
                ? dark.withIncreasedContrast()
                : dark)
            .textTertiary;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            KapyIcon(
              playable ? KapyIcons.playRounded : KapyIcons.videoOutlined,
              size: 26,
              color: ink,
            ),
            const SizedBox(height: 7),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(color: ink, fontSize: AppTypeScale.caption),
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
    this.start = Duration.zero,
    this.play = true,
  });

  final NoteVideoRef ref;
  final BlobStore store;
  final NoteImageFetcher? fetch;

  /// Where it opens, and whether it carries on playing from there: the card
  /// in the note hands over the moment it was at.
  final Duration start;
  final bool play;

  /// Opens [ref] full screen, and answers where it was when it closed. Linux
  /// opens it in the person's own player instead, and answers null.
  static Future<Duration?> open(
    BuildContext context, {
    required NoteVideoRef ref,
    required BlobStore store,
    NoteImageFetcher? fetch,
    Duration start = Duration.zero,
    bool play = true,
  }) async {
    if (AppPlatform.isLinux) {
      await _openInVideoPlayer(context, ref: ref, store: store, fetch: fetch);
      return null;
    }
    return Navigator.of(context).push(
      PageRouteBuilder<Duration>(
        opaque: true,
        pageBuilder: (context, animation, secondary) => FadeTransition(
          opacity: animation,
          child: NoteVideoViewer(
            ref: ref,
            store: store,
            fetch: fetch,
            start: start,
            play: play,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 160),
      ),
    );
  }

  /// Linux has no player in the app, so a video plays in the person's own.
  static Future<void> _openInVideoPlayer(
    BuildContext context, {
    required NoteVideoRef ref,
    required BlobStore store,
    NoteImageFetcher? fetch,
  }) async {
    final file = await _videoFile(ref, store, fetch);
    var opened = false;
    if (file != null) {
      try {
        opened = await launchUrl(Uri.file(file.path));
      } catch (_) {
        opened = false;
      }
    }
    if (opened || !context.mounted) return;
    Toast.show(
      context,
      'Could not open the video',
      icon: KapyIcons.errorOutlined,
      isError: true,
    );
  }

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
      if (widget.start > Duration.zero) await controller.seekTo(widget.start);
      if (widget.play) await controller.play();
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

  void _close() => Navigator.of(context).pop(_controller?.value.position);

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
    return PopScope<Duration>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) => _close(),
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
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.48,
                            ),
                            minimumSize: const Size.square(62),
                            maximumSize: const Size.square(62),
                          ),
                        ),
                      ),
                    if (_controlsVisible && controller != null)
                      Positioned(
                        left: 18,
                        right: 18,
                        bottom: MediaQuery.paddingOf(context).bottom + 16,
                        child: ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: controller,
                          builder: (context, value, bar) => Row(
                            children: [
                              Text(
                                _clockLabel(value.position),
                                key: const ValueKey('video-viewer-elapsed'),
                                style: _overPicture(quiet: true),
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: bar!),
                              const SizedBox(width: 12),
                              Text(
                                _clockLabel(value.duration),
                                key: const ValueKey('video-viewer-length'),
                                style: _overPicture(quiet: true),
                              ),
                            ],
                          ),
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
                      ),
                    Positioned(
                      top: MediaQuery.paddingOf(context).top + 8,
                      right: 8,
                      child: IconButton(
                        tooltip: 'Close',
                        onPressed: _close,
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

String _clockLabel(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:$minutes:$seconds'
      : '${duration.inMinutes}:$seconds';
}
