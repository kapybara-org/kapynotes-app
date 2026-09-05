import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Kapy briefly looks around the editor caret, then slips behind it again.
///
/// The approved hero-peek pose already holds a straight vertical edge. This
/// widget treats the caret as that edge and clips Kapy against its left side,
/// so the motion reads as a real peek instead of an image fading over text.
/// It uses Flutter's own compositor and one small WebP, which keeps it
/// identical across every platform the app supports.
class KapyCursorPeek extends StatefulWidget {
  const KapyCursorPeek({
    super.key,
    this.size = 44,
    this.duration = const Duration(milliseconds: 1150),
    this.animation,
    this.caretColor,
  });

  static const assetPath = 'assets/mascot/kapy_cursor_peek.webp';
  static const mascotKey = ValueKey('kapy-cursor-peek-mascot');
  static const caretKey = ValueKey('kapy-cursor-peek-caret');

  // The image crop is 136 x 256. Pinning this here avoids decoding it merely
  // to discover layout, which keeps the first animation frame predictable.
  static const double _mascotAspectRatio = 136 / 256;
  static const double _caretXFactor = 0.76;
  static const double _caretTopFactor = 0.22;
  static const double _caretHeightFactor = 0.56;

  /// The point that should sit on the editor caret's top center.
  static Offset caretAnchor(double size) =>
      Offset(size * _caretXFactor, size * _caretTopFactor);

  final double size;
  final Duration duration;

  /// Optional shared timeline, expressed from 0 to 1.
  ///
  /// Without one, the peek plays once as soon as it is mounted. Passing an
  /// animation lets an overlay synchronize Kapy with an existing effect.
  final Animation<double>? animation;
  final Color? caretColor;

  @override
  State<KapyCursorPeek> createState() => _KapyCursorPeekState();
}

class _KapyCursorPeekState extends State<KapyCursorPeek>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  bool _started = false;
  bool _animationsDisabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFallbackAnimation();
  }

  @override
  void didUpdateWidget(KapyCursorPeek oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.animation != widget.animation) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
      _syncFallbackAnimation();
    }
  }

  void _syncFallbackAnimation() {
    final disabled = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _animationsDisabled = disabled;
    if (widget.animation != null) return;

    if (disabled) {
      _controller.stop();
      _controller.value = 1;
      _started = false;
    } else if (!_started) {
      _started = true;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_animationsDisabled) return SizedBox.square(dimension: widget.size);

    final animation = widget.animation ?? _controller;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) => _frame(context, animation.value),
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, double rawProgress) {
    final progress = rawProgress.clamp(0.0, 1.0);
    final reveal = _revealAt(progress);
    final size = widget.size;
    final caretX = size * KapyCursorPeek._caretXFactor;
    final caretHeight = size * KapyCursorPeek._caretHeightFactor;
    final caretWidth = (size * 0.042).clamp(1.5, 2.2);
    final mascotHeight = size * 0.96;
    final mascotWidth = mascotHeight * KapyCursorPeek._mascotAspectRatio;
    final hiddenDistance = mascotWidth + caretWidth;
    final holdProgress = ((progress - 0.36) / 0.34).clamp(0.0, 1.0);
    final bob = progress >= 0.36 && progress <= 0.70
        ? -math.sin(holdProgress * math.pi) * size * 0.018
        : 0.0;
    final curiousTilt = progress >= 0.36 && progress <= 0.70
        ? math.sin(holdProgress * math.pi) * -0.025
        : 0.0;
    final caretColor =
        widget.caretColor ??
        Theme.of(context).textSelectionTheme.cursorColor ??
        Theme.of(context).colorScheme.primary;

    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            width: caretX,
            height: size,
            child: ClipRect(
              child: Align(
                alignment: Alignment.centerRight,
                child: Transform.translate(
                  key: KapyCursorPeek.mascotKey,
                  offset: Offset(hiddenDistance * (1 - reveal), bob),
                  child: Transform.rotate(
                    angle: curiousTilt,
                    alignment: Alignment.bottomRight,
                    child: Image.asset(
                      KapyCursorPeek.assetPath,
                      width: mascotWidth,
                      height: mascotHeight,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      isAntiAlias: true,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: caretX - caretWidth / 2,
            top: size * KapyCursorPeek._caretTopFactor,
            width: caretWidth,
            height: caretHeight,
            child: Opacity(
              key: KapyCursorPeek.caretKey,
              opacity: _caretOpacityAt(progress),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: caretColor,
                  borderRadius: BorderRadius.circular(caretWidth),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static double _revealAt(double progress) {
    if (progress < 0.10) return 0;
    if (progress < 0.36) {
      return Curves.easeOutBack.transform((progress - 0.10) / 0.26);
    }
    if (progress < 0.70) return 1;
    if (progress < 0.94) {
      return 1 - Curves.easeInCubic.transform((progress - 0.70) / 0.24);
    }
    return 0;
  }

  static double _caretOpacityAt(double progress) {
    if (progress < 0.06) return progress / 0.06;
    if (progress <= 0.92) return 1;
    return ((1 - progress) / 0.08).clamp(0.0, 1.0);
  }
}
