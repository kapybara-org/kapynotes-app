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
/// again. [activity] counts as input too, for text that arrives without a key
/// or pointer event, such as dictation or the character viewer. It holds back
/// while a pointer is down, while a dialog or menu route is over the page, and
/// while [held] says so, and it keeps no timer while the app is hidden or
/// paused. With Reduce Motion on it fades where it would slide.
class KapyPagePeek extends StatefulWidget {
  const KapyPagePeek({super.key, this.held, this.activity, this.random});

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

  /// Changes to this, the note's text and selection, are input.
  final Listenable? activity;

  /// Chooses the wait between peeks; a test passes a seeded one.
  final math.Random? random;

  @override
  State<KapyPagePeek> createState() => _KapyPagePeekState();
}

class _KapyPagePeekState extends State<KapyPagePeek>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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
  final Set<int> _pointersDown = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    widget.activity?.addListener(_input);
    _timer = Timer(KapyPagePeek.idleBeforePeek, _peek);
  }

  @override
  void didUpdateWidget(KapyPagePeek oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity == widget.activity) return;
    oldWidget.activity?.removeListener(_input);
    widget.activity?.addListener(_input);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _timer?.cancel();
        _timer = null;
        if (!_motion.isDismissed) _motion.reverse();
      case AppLifecycleState.resumed:
        _input();
      case AppLifecycleState.inactive:
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(precacheImage(const AssetImage(KapyPagePeek.assetPath), context));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.activity?.removeListener(_input);
    HardwareKeyboard.instance.removeHandler(_onKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _timer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    _pointersDown.clear();
    _input();
    return false;
  }

  /// A pointer whose release was lost would hold Kapy back for good, so any
  /// event from another pointer, a hover, or a key says it is no longer down.
  void _onPointer(PointerEvent event) {
    if (event is PointerHoverEvent) {
      _pointersDown.clear();
    } else {
      _pointersDown.removeWhere((pointer) => pointer != event.pointer);
    }
    if (event is PointerDownEvent) _pointersDown.add(event.pointer);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointersDown.remove(event.pointer);
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
    if (_pointersDown.isNotEmpty ||
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
        if (shown == 0 && _motion.status != AnimationStatus.forward) {
          return const SizedBox.shrink();
        }
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
