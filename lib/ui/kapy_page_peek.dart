import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Kapy at the page's bottom-right edge, out of sight until the window has
/// been left alone for a while.
///
/// After [idleBeforePeek] with no pointer or key input it slides in from the
/// edge, stays [stay], and slides out again, then comes back at random
/// intervals between [minInterval] and [maxInterval] while nothing is touched.
/// Any input sends it away at once, on the same motion, and starts the wait
/// again. It holds back while a pointer is down, while a dialog or menu route
/// is over the page, and while [held] says so. With Reduce Motion on it fades
/// where it would slide.
class KapyPagePeek extends StatefulWidget {
  const KapyPagePeek({super.key, this.held, this.random});

  static const assetPath = 'assets/mascot/kapy_cursor_peek.webp';
  static const imageKey = ValueKey('page-kapy');
  static const width = 60.0;
  static const height = 113.0;

  /// How long the window must be left alone before the first peek.
  static const idleBeforePeek = Duration(seconds: 60);

  /// How long Kapy stays out once it has slid in.
  static const stay = Duration(seconds: 3);

  /// The slide in, and the slide out.
  static const slide = Duration(milliseconds: 700);

  /// The wait between peeks while the window stays idle.
  static const minInterval = Duration(minutes: 2);
  static const maxInterval = Duration(minutes: 5);

  /// How long to wait before asking again when a peek was held back.
  static const retryWhenHeld = Duration(seconds: 10);

  /// Whether something other than input rules a peek out right now, such as
  /// Kapy AI answering.
  final bool Function()? held;

  /// Chooses the wait between peeks; a test passes a seeded one.
  final math.Random? random;

  @override
  State<KapyPagePeek> createState() => _KapyPagePeekState();
}

class _KapyPagePeekState extends State<KapyPagePeek>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: KapyPagePeek.slide,
  );
  late final Animation<double> _slide = CurvedAnimation(
    parent: _motion,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  late final math.Random _random = widget.random ?? math.Random();
  Timer? _timer;
  int _pointersDown = 0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _timer = Timer(KapyPagePeek.idleBeforePeek, _peek);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _timer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    _input();
    return false;
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _pointersDown++;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointersDown = math.max(0, _pointersDown - 1);
    }
    _input();
  }

  void _input() {
    _timer?.cancel();
    if (!_motion.isDismissed) _motion.reverse();
    _timer = Timer(KapyPagePeek.idleBeforePeek, _peek);
  }

  void _peek() {
    if (!mounted) return;
    if (_pointersDown > 0 ||
        (ModalRoute.of(context)?.isCurrent ?? true) == false ||
        (widget.held?.call() ?? false)) {
      _timer = Timer(KapyPagePeek.retryWhenHeld, _peek);
      return;
    }
    _motion.forward();
    _timer = Timer(KapyPagePeek.slide + KapyPagePeek.stay, _leave);
  }

  void _leave() {
    _motion.reverse();
    final range =
        KapyPagePeek.maxInterval.inMilliseconds -
        KapyPagePeek.minInterval.inMilliseconds;
    _timer = Timer(
      KapyPagePeek.slide +
          KapyPagePeek.minInterval +
          Duration(milliseconds: _random.nextInt(range + 1)),
      _peek,
    );
  }

  @override
  Widget build(BuildContext context) {
    final fades = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, _) {
        final shown = _slide.value;
        if (shown == 0) return const SizedBox.shrink();
        return IgnorePointer(
          child: Transform.translate(
            offset: Offset(fades ? 0 : (1 - shown) * KapyPagePeek.width, 0),
            child: Opacity(
              opacity: fades ? shown : 1,
              child: Image.asset(
                KapyPagePeek.assetPath,
                key: KapyPagePeek.imageKey,
                width: KapyPagePeek.width,
                height: KapyPagePeek.height,
                excludeFromSemantics: true,
              ),
            ),
          ),
        );
      },
    );
  }
}
