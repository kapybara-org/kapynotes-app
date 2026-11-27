import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';

/// Which way a step goes: back to what came before, or forward again.
enum BackForwardStep { back, forward }

/// The steps an area has taken, for a [BackForwardSlide] to follow. Areas
/// that mean the same thing, such as Tasks' filter list and its page, share
/// one, so either slides the page.
class BackForwardSteps extends ChangeNotifier {
  BackForwardStep? _last;

  /// The step taken last, null until one is.
  BackForwardStep? get last => _last;

  /// Tells what follows these steps that one was taken, for a step an area
  /// took on behalf of another: Back over the list stepping the page up out
  /// of a folder.
  void took(BackForwardStep step) {
    _last = step;
    notifyListeners();
  }
}

/// A place a two-finger sideways swipe and the mouse's Back and Forward
/// buttons step through, the same way in every place. Fingers moving right,
/// or Back, step back; fingers moving left, or Forward, step forward.
///
/// The area under the pointer takes the step, the innermost where areas
/// nest, so the list beside the page and the note on it each keep their own
/// meaning. One swipe takes one step however far it goes. Something under
/// the pointer that scrolls sideways (a wide table, a long field) keeps the
/// swipe while it can still move that way.
///
/// Desktop only: a phone has its own swipes.
class BackForwardArea extends StatefulWidget {
  const BackForwardArea({
    super.key,
    required this.onStep,
    this.steps,
    required this.child,
  });

  /// Takes one step and says whether it moved what the area shows. Null
  /// keeps the swipes that start over the area for what is in it, while the
  /// mouse's buttons go to the place around it: a drawing canvas pans under
  /// the same two fingers.
  final bool Function(BackForwardStep step)? onStep;

  /// Where the steps it takes are told, when another area shares them.
  final BackForwardSteps? steps;

  final Widget child;

  /// How far sideways a swipe goes before it steps.
  ///
  /// High enough that the sideways drift of an ordinary vertical scroll
  /// never reaches it, low enough that a deliberate swipe does at once.
  static const double threshold = 90;

  @override
  State<BackForwardArea> createState() => _BackForwardAreaState();
}

class _BackForwardAreaState extends State<BackForwardArea> {
  BackForwardSteps? _ownSteps;

  BackForwardSteps get _steps =>
      widget.steps ?? (_ownSteps ??= BackForwardSteps());

  @override
  void initState() {
    super.initState();
    _router.attach();
  }

  @override
  void dispose() {
    _router.detach();
    _ownSteps?.dispose();
    super.dispose();
  }

  void _step(BackForwardStep step) {
    if (!mounted) return;
    if (widget.onStep?.call(step) ?? false) _steps.took(step);
  }

  @override
  Widget build(BuildContext context) {
    if (!AppPlatform.isDesktop) return widget.child;
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        _router.scrolled(notification);
        return false;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: widget.onStep == null
            ? null
            : (_) => _router.claim(this),
        onPointerSignal: (_) => _router.claim(this),
        onPointerPanZoomStart: (_) => _router.claim(this),
        child: _BackForwardScope(steps: _steps, child: widget.child),
      ),
    );
  }
}

/// Slides what it holds in from the side a step came from, a short way, as
/// the area around it steps: from the right going forward, from the left
/// going back. Still where the system asks for less motion.
class BackForwardSlide extends StatefulWidget {
  const BackForwardSlide({super.key, required this.child});

  final Widget child;

  @override
  State<BackForwardSlide> createState() => _BackForwardSlideState();
}

class _BackForwardSlideState extends State<BackForwardSlide>
    with SingleTickerProviderStateMixin {
  static const _distance = 24.0;

  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  final GlobalKey _child = GlobalKey();
  BackForwardSteps? _steps;
  double _from = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final steps = context
        .dependOnInheritedWidgetOfExactType<_BackForwardScope>()
        ?.steps;
    if (identical(steps, _steps)) return;
    _steps?.removeListener(_start);
    _steps = steps?..addListener(_start);
  }

  @override
  void dispose() {
    _steps?.removeListener(_start);
    _slide.dispose();
    super.dispose();
  }

  void _start() {
    if (MediaQuery.disableAnimationsOf(context)) return;
    _from = _steps?.last == BackForwardStep.forward ? 1 : -1;
    _slide.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _child, child: widget.child);
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, _) {
        // At rest it is the child alone, so a place that never steps draws
        // exactly as it would without a slide around it.
        if (_slide.isCompleted) return child;
        final shown = Curves.easeOutCubic.transform(_slide.value);
        return Transform.translate(
          offset: Offset(_from * _distance * (1 - shown), 0),
          child: Opacity(opacity: 0.4 + 0.6 * shown, child: child),
        );
      },
    );
  }
}

class _BackForwardScope extends InheritedWidget {
  const _BackForwardScope({required this.steps, required super.child});

  final BackForwardSteps steps;

  @override
  bool updateShouldNotify(_BackForwardScope oldWidget) =>
      !identical(steps, oldWidget.steps);
}

/// One swipe: the area it began over, how far the fingers have gone, and
/// whether it has been spent, on a step or on scrolling something.
class _Swipe {
  _Swipe(this.area);

  final _BackForwardAreaState? area;
  Offset _travel = Offset.zero;
  bool spent = false;

  /// Adds [fingers], the way the fingers moved, and steps once the swipe is
  /// far enough, and more sideways than up or down.
  void add(Offset fingers) {
    if (spent) return;
    _travel += fingers;
    final sideways = _travel.dx.abs();
    if (sideways < BackForwardArea.threshold || sideways <= _travel.dy.abs()) {
      return;
    }
    spent = true;
    area?._step(
      _travel.dx > 0 ? BackForwardStep.back : BackForwardStep.forward,
    );
  }
}

final _router = _BackForwardRouter();

/// Reads every swipe and mouse press once, after the widgets under the
/// pointer have seen it, and hands it to the innermost area there.
///
/// A trackpad sends a swipe as a pan, which carries its own start and end;
/// a sideways wheel, or a trackpad on some systems, sends scroll signals,
/// which do not, so a short pause ends one of those.
class _BackForwardRouter {
  static const _wheelPause = Duration(milliseconds: 160);

  int _areas = 0;

  /// The innermost area under the event being delivered, if any.
  _BackForwardAreaState? _claim;

  final Map<int, _Swipe> _pans = {};
  _Swipe? _wheel;
  Timer? _wheelRest;

  /// Whether the last sideways scroll signal went to something else under
  /// the pointer, which scrolled with it.
  bool _wheelAwaited = false;

  void attach() {
    if (_areas++ == 0) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
    }
  }

  void detach() {
    if (--_areas > 0) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
    _claim = null;
    _pans.clear();
    _restWheel();
  }

  /// Areas see an event innermost first, so the first to claim it is the
  /// one it lands in.
  void claim(_BackForwardAreaState area) => _claim ??= area;

  /// Something sideways scrolled under a swipe's fingers, so the swipe was
  /// for it. A bounce past either end is not scrolling.
  void scrolled(ScrollUpdateNotification notification) {
    if (_pans.isEmpty || notification.dragDetails == null) return;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.horizontal) return;
    final after = metrics.pixels;
    final before = after - (notification.scrollDelta ?? 0);
    bool within(double pixels) =>
        pixels > metrics.minScrollExtent && pixels < metrics.maxScrollExtent;
    if (!within(before) && !within(after)) return;
    for (final swipe in _pans.values) {
      swipe.spent = true;
    }
  }

  void _restWheel() {
    _wheelRest?.cancel();
    _wheelRest = null;
    _wheel = null;
    _wheelAwaited = false;
  }

  void _route(PointerEvent event) {
    final area = _claim;
    _claim = null;
    switch (event) {
      case PointerDownEvent(buttons: kBackMouseButton):
        area?._step(BackForwardStep.back);
      case PointerDownEvent(buttons: kForwardMouseButton):
        area?._step(BackForwardStep.forward);
      case PointerPanZoomStartEvent():
        _pans[event.pointer] = _Swipe(area);
      case PointerPanZoomUpdateEvent():
        _pans[event.pointer]?.add(event.panDelta);
      case PointerPanZoomEndEvent() || PointerCancelEvent():
        _pans.remove(event.pointer);
      case PointerScrollEvent(:final scrollDelta):
        _wheelRest?.cancel();
        _wheelRest = Timer(_wheelPause, _restWheel);
        final wheel = _wheel ??= _Swipe(area);
        if (_wheelAwaited) wheel.spent = true;
        _wheelAwaited = false;
        if (wheel.spent || wheel.area?.widget.onStep == null) return;
        // A scroll moves content the way the fingers go, so the fingers
        // went the other way from the scroll.
        if (scrollDelta.dx.abs() <= scrollDelta.dy.abs()) {
          wheel.add(Offset(0, -scrollDelta.dy));
          return;
        }
        // Asked last, so whatever under the pointer would scroll with it
        // takes it first; one at either end does not ask.
        _wheelAwaited = true;
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          _wheelAwaited = false;
          wheel.add(-scrollDelta);
        });
      default:
    }
  }
}
