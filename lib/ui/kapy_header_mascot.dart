import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'app_logo.dart';

/// The five small transitions the header mascot understands.
enum KapyHeaderAnimation { emerge, think, sleep, wake, hide }

enum KapyHeaderRestingPose { logo, standing, sleeping }

class _KapyHeaderCommand {
  const _KapyHeaderCommand(
    this.animation,
    this.serial, {
    this.hideAfter = false,
  });

  final KapyHeaderAnimation animation;
  final int serial;
  final bool hideAfter;
}

/// Sends semantic animation requests without owning a ticker or a widget.
///
/// The mark decides how to reach each request from its current pose. Asking it
/// to think while asleep therefore wakes Kapy first, while asking it to sleep
/// from the logo makes Kapy emerge before lying down.
class KapyHeaderController extends ChangeNotifier {
  _KapyHeaderCommand? _command;
  int _serial = 0;
  KapyHeaderRestingPose _restingPose = KapyHeaderRestingPose.logo;

  KapyHeaderAnimation? get lastAnimation => _command?.animation;
  KapyHeaderRestingPose get restingPose => _restingPose;
  bool get needsWake =>
      _restingPose == KapyHeaderRestingPose.sleeping ||
      _command?.animation == KapyHeaderAnimation.sleep;

  void emerge() => _send(KapyHeaderAnimation.emerge);
  void think() => _send(KapyHeaderAnimation.think);
  void sleep() => _send(KapyHeaderAnimation.sleep);
  void wake({bool hideAfter = false}) =>
      _send(KapyHeaderAnimation.wake, hideAfter: hideAfter);
  void hide() => _send(KapyHeaderAnimation.hide);

  void _send(KapyHeaderAnimation animation, {bool hideAfter = false}) {
    _command = _KapyHeaderCommand(animation, ++_serial, hideAfter: hideAfter);
    notifyListeners();
  }

  void _settledAt(KapyHeaderRestingPose pose) => _restingPose = pose;
}

/// The fixed-size logo mark that can briefly become Kapy.
///
/// The layout footprint always remains [markSize] square. Kapy paints into a
/// small overflow area on the leading side, so the product name and the
/// centered toolbar never move when an animation starts.
class KapyHeaderMascot extends StatefulWidget {
  const KapyHeaderMascot({
    super.key,
    required this.controller,
    this.markSize = 19,
  });

  static const logoKey = ValueKey('kapy-header-logo');
  static const characterKey = ValueKey('kapy-header-character');
  static const sleepingKey = ValueKey('kapy-header-sleeping-image');
  static const standingAssetPath = 'assets/mascot/kapy_standing.webp';
  static const sleepingAssetPath = 'assets/mascot/kapy_sleeping.webp';
  static const emergeAtlasAssetPath =
      'assets/mascot/kapy_header_emerge_30fps.webp';
  static const thinkAtlasAssetPath =
      'assets/mascot/kapy_header_think_30fps.webp';
  static const sleepAtlasAssetPath =
      'assets/mascot/kapy_header_sleep_30fps.webp';
  static const sleepLoopAtlasAssetPath =
      'assets/mascot/kapy_header_sleep_loop_30fps.webp';

  static const framesPerSecond = 30;
  static const emergeFrameCount = 30;
  static const thinkFrameCount = 180;
  static const sleepFrameCount = 48;
  static const sleepLoopFrameCount = 96;
  static const runtimeAssetPaths = [
    standingAssetPath,
    sleepingAssetPath,
    emergeAtlasAssetPath,
    thinkAtlasAssetPath,
    sleepAtlasAssetPath,
    sleepLoopAtlasAssetPath,
  ];

  static const emergeDuration = Duration(milliseconds: 1000);
  static const thinkDuration = Duration(milliseconds: 6000);
  static const sleepDuration = Duration(milliseconds: 1600);
  static const wakeDuration = Duration(milliseconds: 1600);
  static const hideDuration = Duration(milliseconds: 1000);
  static const sleepLoopDuration = Duration(milliseconds: 3200);

  final KapyHeaderController controller;
  final double markSize;

  @override
  State<KapyHeaderMascot> createState() => KapyHeaderMascotState();
}

class KapyHeaderMascotState extends State<KapyHeaderMascot>
    with TickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: KapyHeaderMascot.emergeDuration,
  );
  late final AnimationController _breathing = AnimationController(
    vsync: this,
    duration: KapyHeaderMascot.sleepLoopDuration,
  );

  late KapyHeaderRestingPose _restingPose = widget.controller.restingPose;
  KapyHeaderAnimation? _segment;
  KapyHeaderAnimation? _sequence;
  int _generation = 0;
  int _handledSerial = 0;
  bool _animationsDisabled = false;
  final Set<String> _warmedAssets = {};

  KapyHeaderAnimation? get activeAnimation => _segment;
  KapyHeaderRestingPose get restingPose => _restingPose;
  int? get currentFrameIndex => _currentPlayback?.frameIndex;
  String? get currentAtlasAssetPath => _currentPlayback?.spec.assetPath;

  _KapyAtlasPlayback? get _currentPlayback => _KapyAtlasPlayback.resolve(
    segment: _segment,
    restingPose: _restingPose,
    motionProgress: _motion.value,
    breathingProgress: _breathing.value,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleCommand);
    if (_restingPose == KapyHeaderRestingPose.sleeping) {
      _breathing.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disabled == _animationsDisabled) return;
    _animationsDisabled = disabled;
    if (disabled) {
      _generation++;
      _motion.stop();
      _breathing.stop();
      _segment = null;
      _sequence = null;
      _restingPose = KapyHeaderRestingPose.logo;
      widget.controller._settledAt(_restingPose);
    }
  }

  @override
  void didUpdateWidget(KapyHeaderMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleCommand);
    widget.controller.addListener(_handleCommand);
    _restingPose = widget.controller.restingPose;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleCommand);
    _motion.dispose();
    _breathing.dispose();
    super.dispose();
  }

  void _handleCommand() {
    final command = widget.controller._command;
    if (command == null || command.serial == _handledSerial) return;
    _handledSerial = command.serial;
    if (_animationsDisabled || !_accepts(command.animation)) return;

    _warmAssetsFor(command);
    final interruptedFrame = _currentFrame;
    final generation = ++_generation;
    _motion.stop();
    _breathing.stop();
    unawaited(_run(command, generation, interruptedFrame));
  }

  void _warmAssetsFor(_KapyHeaderCommand command) {
    final paths = switch (command.animation) {
      KapyHeaderAnimation.emerge => const [
        KapyHeaderMascot.emergeAtlasAssetPath,
      ],
      KapyHeaderAnimation.think => const [
        KapyHeaderMascot.emergeAtlasAssetPath,
        KapyHeaderMascot.thinkAtlasAssetPath,
      ],
      KapyHeaderAnimation.sleep => const [
        KapyHeaderMascot.emergeAtlasAssetPath,
        KapyHeaderMascot.sleepAtlasAssetPath,
        KapyHeaderMascot.sleepLoopAtlasAssetPath,
      ],
      KapyHeaderAnimation.wake => [
        KapyHeaderMascot.sleepAtlasAssetPath,
        if (command.hideAfter) KapyHeaderMascot.emergeAtlasAssetPath,
      ],
      KapyHeaderAnimation.hide => const [KapyHeaderMascot.emergeAtlasAssetPath],
    };
    for (final path in paths) {
      if (!_warmedAssets.add(path)) continue;
      unawaited(precacheImage(AssetImage(path), context));
    }
  }

  bool _accepts(KapyHeaderAnimation animation) {
    if (animation == KapyHeaderAnimation.think &&
        _sequence == KapyHeaderAnimation.think) {
      return false;
    }
    if (animation == KapyHeaderAnimation.sleep &&
        (_restingPose == KapyHeaderRestingPose.sleeping ||
            _sequence == KapyHeaderAnimation.sleep)) {
      return false;
    }
    if (animation == KapyHeaderAnimation.wake) {
      return _restingPose == KapyHeaderRestingPose.sleeping ||
          _sequence == KapyHeaderAnimation.sleep;
    }
    if (animation == KapyHeaderAnimation.hide) {
      return _restingPose != KapyHeaderRestingPose.logo || _segment != null;
    }
    if (animation == KapyHeaderAnimation.emerge &&
        _restingPose == KapyHeaderRestingPose.standing &&
        _segment == null) {
      return false;
    }
    return true;
  }

  Future<void> _run(
    _KapyHeaderCommand command,
    int generation,
    _KapyHeaderFrame interrupted,
  ) async {
    final animation = command.animation;
    _sequence = animation;
    switch (animation) {
      case KapyHeaderAnimation.emerge:
        if (!await _reachStanding(generation, interrupted)) return;
        break;
      case KapyHeaderAnimation.think:
        if (!await _reachStanding(generation, interrupted)) return;
        if (!await _play(
          KapyHeaderAnimation.think,
          KapyHeaderMascot.thinkDuration,
          generation,
        )) {
          return;
        }
        _settle(KapyHeaderRestingPose.standing);
        if (!await _play(
          KapyHeaderAnimation.hide,
          KapyHeaderMascot.hideDuration,
          generation,
        )) {
          return;
        }
        _settle(KapyHeaderRestingPose.logo);
        break;
      case KapyHeaderAnimation.sleep:
        if (!await _reachStanding(generation, interrupted)) return;
        if (!await _play(
          KapyHeaderAnimation.sleep,
          KapyHeaderMascot.sleepDuration,
          generation,
        )) {
          return;
        }
        _settle(KapyHeaderRestingPose.sleeping);
        if (mounted && generation == _generation) _breathing.repeat();
        break;
      case KapyHeaderAnimation.wake:
        if (interrupted.sleep > 0) {
          _restingPose = KapyHeaderRestingPose.sleeping;
          final from = (1 - interrupted.sleep).clamp(0.0, 1.0);
          if (!await _play(
            KapyHeaderAnimation.wake,
            KapyHeaderMascot.wakeDuration,
            generation,
            from: from,
          )) {
            return;
          }
          _settle(KapyHeaderRestingPose.standing);
        } else if (interrupted.visibility < 0.5) {
          _settle(KapyHeaderRestingPose.logo);
          break;
        } else {
          _settle(KapyHeaderRestingPose.standing);
        }
        if (!command.hideAfter) break;
        if (!await _play(
          KapyHeaderAnimation.hide,
          KapyHeaderMascot.hideDuration,
          generation,
          from: (1 - interrupted.visibility).clamp(0.0, 1.0),
        )) {
          return;
        }
        _settle(KapyHeaderRestingPose.logo);
        break;
      case KapyHeaderAnimation.hide:
        if (interrupted.sleep > 0) {
          _restingPose = KapyHeaderRestingPose.sleeping;
          if (!await _play(
            KapyHeaderAnimation.wake,
            KapyHeaderMascot.wakeDuration,
            generation,
            from: (1 - interrupted.sleep).clamp(0.0, 1.0),
          )) {
            return;
          }
          _settle(KapyHeaderRestingPose.standing);
        }
        if (!await _play(
          KapyHeaderAnimation.hide,
          KapyHeaderMascot.hideDuration,
          generation,
          from: (1 - interrupted.visibility).clamp(0.0, 1.0),
        )) {
          return;
        }
        _settle(KapyHeaderRestingPose.logo);
        break;
    }
    if (mounted && generation == _generation) {
      setState(() => _sequence = null);
    }
  }

  Future<bool> _reachStanding(
    int generation,
    _KapyHeaderFrame interrupted,
  ) async {
    if (interrupted.sleep > 0) {
      _restingPose = KapyHeaderRestingPose.sleeping;
      if (!await _play(
        KapyHeaderAnimation.wake,
        KapyHeaderMascot.wakeDuration,
        generation,
        from: (1 - interrupted.sleep).clamp(0.0, 1.0),
      )) {
        return false;
      }
      _settle(KapyHeaderRestingPose.standing);
      return true;
    }
    if (interrupted.visibility >= 0.99) {
      _settle(KapyHeaderRestingPose.standing);
      return true;
    }
    _restingPose = KapyHeaderRestingPose.logo;
    if (!await _play(
      KapyHeaderAnimation.emerge,
      KapyHeaderMascot.emergeDuration,
      generation,
      from: interrupted.visibility.clamp(0.0, 1.0),
    )) {
      return false;
    }
    _settle(KapyHeaderRestingPose.standing);
    return true;
  }

  Future<bool> _play(
    KapyHeaderAnimation segment,
    Duration duration,
    int generation, {
    double from = 0,
  }) async {
    if (!mounted || generation != _generation) return false;
    setState(() => _segment = segment);
    _motion.duration = duration;
    try {
      await _motion.forward(from: from).orCancel;
    } on TickerCanceled {
      return false;
    }
    return mounted && generation == _generation;
  }

  void _settle(KapyHeaderRestingPose pose) {
    if (!mounted) return;
    setState(() {
      _restingPose = pose;
      _segment = null;
    });
    widget.controller._settledAt(pose);
  }

  _KapyHeaderFrame get _currentFrame {
    final progress = _motion.value.clamp(0.0, 1.0);
    final breathing = _breathing.value;
    final segment = _segment;
    if (segment == null) {
      return switch (_restingPose) {
        KapyHeaderRestingPose.logo => const _KapyHeaderFrame(),
        KapyHeaderRestingPose.standing => const _KapyHeaderFrame(visibility: 1),
        KapyHeaderRestingPose.sleeping => _KapyHeaderFrame(
          visibility: 1,
          sleep: 1,
          zzz: 1,
          zzzPhase: breathing,
        ),
      };
    }

    return switch (segment) {
      KapyHeaderAnimation.emerge => _KapyHeaderFrame(visibility: progress),
      KapyHeaderAnimation.hide => _KapyHeaderFrame(visibility: 1 - progress),
      KapyHeaderAnimation.think => const _KapyHeaderFrame(visibility: 1),
      KapyHeaderAnimation.sleep => _KapyHeaderFrame(
        visibility: 1,
        sleep: progress,
        zzz: _interval(progress, 0.72, 1),
        zzzPhase: progress,
      ),
      KapyHeaderAnimation.wake => _KapyHeaderFrame(
        visibility: 1,
        sleep: 1 - progress,
        zzz: 1 - _interval(progress, 0, 0.24),
        zzzPhase: progress,
      ),
    };
  }

  static double _interval(double value, double begin, double end) => Curves
      .easeInOut
      .transform(((value - begin) / (end - begin)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    if (_animationsDisabled ||
        (_segment == null && _restingPose == KapyHeaderRestingPose.logo)) {
      return AppLogo(
        key: KapyHeaderMascot.logoKey,
        size: widget.markSize,
        excludeFromSemantics: true,
      );
    }

    return AnimatedBuilder(
      animation: Listenable.merge([_motion, _breathing]),
      builder: (context, _) {
        final frame = _currentFrame;
        // Keep Kapy visually close to the ordinary mark while preserving the
        // original 19px layout footprint, so the wordmark never shifts.
        final actorHeight = math.max(23.0, widget.markSize * 1.18);
        final actorWidth = math.max(32.0, widget.markSize * 1.68);
        final playback = _currentPlayback;
        return SizedBox.square(
          dimension: widget.markSize,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                right: 0,
                top: (widget.markSize - actorHeight) / 2,
                width: actorWidth,
                height: actorHeight,
                child: IgnorePointer(
                  child: _KapyHeaderActor(
                    frame: frame,
                    playback: playback,
                    height: actorHeight,
                    markSize: widget.markSize,
                    restingPose: _restingPose,
                    accent: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Paints one pre-rendered animation frame from a compact WebP atlas.
class _KapyHeaderActor extends StatelessWidget {
  const _KapyHeaderActor({
    required this.frame,
    required this.playback,
    required this.height,
    required this.markSize,
    required this.restingPose,
    required this.accent,
  });

  final _KapyHeaderFrame frame;
  final _KapyAtlasPlayback? playback;
  final double height;
  final double markSize;
  final KapyHeaderRestingPose restingPose;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final atlas = playback;
    return RepaintBoundary(
      child: SizedBox.expand(
        key: KapyHeaderMascot.characterKey,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (atlas == null)
              Positioned(
                right: 0,
                width: height,
                height: height,
                child: const _KapyPoseImage(
                  assetPath: KapyHeaderMascot.standingAssetPath,
                ),
              )
            else
              Positioned.fill(
                key: restingPose == KapyHeaderRestingPose.sleeping
                    ? KapyHeaderMascot.sleepingKey
                    : null,
                child: _KapySpriteAtlas(
                  key: ValueKey(atlas.spec.assetPath),
                  spec: atlas.spec,
                  frameIndex: atlas.frameIndex,
                  placeholder: _placeholderFor(atlas),
                ),
              ),
            if (frame.zzz > 0)
              Positioned.fill(
                child: CustomPaint(
                  painter: _KapySleepEffectsPainter(
                    opacity: frame.zzz,
                    phase: frame.zzzPhase,
                    color: accent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholderFor(_KapyAtlasPlayback atlas) {
    if (atlas.spec == _KapyAtlasSpec.emerge && atlas.frameIndex < 15) {
      return Align(
        alignment: Alignment.centerRight,
        child: AppLogo(size: markSize, excludeFromSemantics: true),
      );
    }
    if ((atlas.spec == _KapyAtlasSpec.sleep && atlas.frameIndex >= 25) ||
        atlas.spec == _KapyAtlasSpec.sleepLoop) {
      return const _KapyPoseImage(
        assetPath: KapyHeaderMascot.sleepingAssetPath,
        alignment: Alignment.bottomRight,
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox.square(
        dimension: height,
        child: const _KapyPoseImage(
          assetPath: KapyHeaderMascot.standingAssetPath,
        ),
      ),
    );
  }
}

class _KapyAtlasSpec {
  const _KapyAtlasSpec({
    required this.assetPath,
    required this.frameCount,
    required this.columns,
    required this.rows,
  });

  static const emerge = _KapyAtlasSpec(
    assetPath: KapyHeaderMascot.emergeAtlasAssetPath,
    frameCount: KapyHeaderMascot.emergeFrameCount,
    columns: 10,
    rows: 3,
  );
  static const think = _KapyAtlasSpec(
    assetPath: KapyHeaderMascot.thinkAtlasAssetPath,
    frameCount: KapyHeaderMascot.thinkFrameCount,
    columns: 15,
    rows: 12,
  );
  static const sleep = _KapyAtlasSpec(
    assetPath: KapyHeaderMascot.sleepAtlasAssetPath,
    frameCount: KapyHeaderMascot.sleepFrameCount,
    columns: 8,
    rows: 6,
  );
  static const sleepLoop = _KapyAtlasSpec(
    assetPath: KapyHeaderMascot.sleepLoopAtlasAssetPath,
    frameCount: KapyHeaderMascot.sleepLoopFrameCount,
    columns: 12,
    rows: 8,
  );

  final String assetPath;
  final int frameCount;
  final int columns;
  final int rows;

  static const framePixelWidth = 64.0;
  static const framePixelHeight = 46.0;
  static const frameGutter = 2.0;
}

class _KapyAtlasPlayback {
  const _KapyAtlasPlayback(this.spec, this.progress);

  final _KapyAtlasSpec spec;
  final double progress;

  int get frameIndex => math.min(
    spec.frameCount - 1,
    (progress.clamp(0.0, 1.0) * spec.frameCount).floor(),
  );

  static _KapyAtlasPlayback? resolve({
    required KapyHeaderAnimation? segment,
    required KapyHeaderRestingPose restingPose,
    required double motionProgress,
    required double breathingProgress,
  }) {
    if (segment == null) {
      return restingPose == KapyHeaderRestingPose.sleeping
          ? _KapyAtlasPlayback(_KapyAtlasSpec.sleepLoop, breathingProgress)
          : null;
    }
    return switch (segment) {
      KapyHeaderAnimation.emerge => _KapyAtlasPlayback(
        _KapyAtlasSpec.emerge,
        motionProgress,
      ),
      KapyHeaderAnimation.hide => _KapyAtlasPlayback(
        _KapyAtlasSpec.emerge,
        1 - motionProgress,
      ),
      KapyHeaderAnimation.think => _KapyAtlasPlayback(
        _KapyAtlasSpec.think,
        motionProgress,
      ),
      KapyHeaderAnimation.sleep => _KapyAtlasPlayback(
        _KapyAtlasSpec.sleep,
        motionProgress,
      ),
      KapyHeaderAnimation.wake => _KapyAtlasPlayback(
        _KapyAtlasSpec.sleep,
        1 - motionProgress,
      ),
    };
  }
}

class _KapySpriteAtlas extends StatefulWidget {
  const _KapySpriteAtlas({
    super.key,
    required this.spec,
    required this.frameIndex,
    required this.placeholder,
  });

  final _KapyAtlasSpec spec;
  final int frameIndex;
  final Widget placeholder;

  @override
  State<_KapySpriteAtlas> createState() => _KapySpriteAtlasState();
}

class _KapySpriteAtlasState extends State<_KapySpriteAtlas> {
  ImageStream? _stream;
  ImageInfo? _imageInfo;
  late final ImageStreamListener _listener = ImageStreamListener(_handleImage);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(_KapySpriteAtlas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spec.assetPath != widget.spec.assetPath) _resolveImage();
  }

  void _resolveImage() {
    final stream = AssetImage(
      widget.spec.assetPath,
    ).resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _handleImage(ImageInfo image, bool synchronousCall) {
    if (!mounted) return;
    final copy = image.clone();
    setState(() {
      _imageInfo?.dispose();
      _imageInfo = copy;
    });
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _imageInfo?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _imageInfo?.image;
    if (image == null) return widget.placeholder;
    return CustomPaint(
      painter: _KapyAtlasPainter(
        image: image,
        spec: widget.spec,
        frameIndex: widget.frameIndex,
      ),
    );
  }
}

class _KapyAtlasPainter extends CustomPainter {
  const _KapyAtlasPainter({
    required this.image,
    required this.spec,
    required this.frameIndex,
  });

  final ui.Image image;
  final _KapyAtlasSpec spec;
  final int frameIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final cellWidth = image.width / spec.columns;
    final cellHeight = image.height / spec.rows;
    final column = frameIndex % spec.columns;
    final row = frameIndex ~/ spec.columns;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        column * cellWidth + _KapyAtlasSpec.frameGutter,
        row * cellHeight + _KapyAtlasSpec.frameGutter,
        _KapyAtlasSpec.framePixelWidth,
        _KapyAtlasSpec.framePixelHeight,
      ),
      Offset.zero & size,
      Paint()
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_KapyAtlasPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.frameIndex != frameIndex ||
      oldDelegate.spec != spec;
}

class _KapyPoseImage extends StatelessWidget {
  const _KapyPoseImage({
    required this.assetPath,
    this.alignment = Alignment.bottomCenter,
  });

  final String assetPath;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => Image.asset(
    assetPath,
    fit: BoxFit.contain,
    alignment: alignment,
    filterQuality: FilterQuality.medium,
    isAntiAlias: true,
    gaplessPlayback: true,
    excludeFromSemantics: true,
  );
}

class _KapyHeaderFrame {
  const _KapyHeaderFrame({
    this.visibility = 0,
    this.sleep = 0,
    this.zzz = 0,
    this.zzzPhase = 0,
  });

  final double visibility;
  final double sleep;
  final double zzz;
  final double zzzPhase;
}

class _KapySleepEffectsPainter extends CustomPainter {
  const _KapySleepEffectsPainter({
    required this.opacity,
    required this.phase,
    required this.color,
  });

  final double opacity;
  final double phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final origins = [
      Offset(size.width * 0.80, size.height * 0.34),
      Offset(size.width * 0.87, size.height * 0.18),
      Offset(size.width * 0.92, size.height * 0.02),
    ];
    for (var index = 0; index < origins.length; index++) {
      final localPhase = (phase + index * 0.22) % 1;
      final alpha = opacity.clamp(0.0, 1.0) * (0.48 + localPhase * 0.52);
      final origin = origins[index] - Offset(0, localPhase * 1.5);
      final width = 2.8 + index * 0.65;
      final height = 2.9 + index * 0.75;
      final path = Path()
        ..moveTo(origin.dx, origin.dy)
        ..lineTo(origin.dx + width, origin.dy)
        ..lineTo(origin.dx, origin.dy + height)
        ..lineTo(origin.dx + width, origin.dy + height);
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.75 + index * 0.1
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(_KapySleepEffectsPainter oldDelegate) =>
      oldDelegate.opacity != opacity ||
      oldDelegate.phase != phase ||
      oldDelegate.color != color;
}
