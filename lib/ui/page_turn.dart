import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// A phone's sideways page turn that follows the finger: the page on screen
/// moves with the drag, and the one it turns to slides in beside it. Let go
/// past [PageTurn.distance] of the width, or with a flick of
/// [PageTurn.speed] that way, and it settles on that page; anything less
/// springs back, as does a drag back the way it came. Where there is no page
/// further on, the drag meets resistance and springs back.
///
/// A turn starts only from a drag that is plainly sideways: [PageTurn.start]
/// across before it has gone [PageTurn.slop] up or down, at no steeper than
/// [PageTurn.steepest]. So a scroll, a tap, a long press or a wobble never
/// moves the page, and a row's own swipe or a sideways scroller under the
/// finger, which take a drag sooner, keep theirs. On Android a drag from
/// inside the system's back gesture edges never starts one, though on a
/// page with [PageTurn.onBack] the left edge goes back, as the system's own
/// gesture there does.
///
/// [before] and [after] are built only while they show, except [before] with
/// [keepBefore], which stays built out of sight, as a list does under the
/// page it turned to. Each page is told apart by its key, so once a turn
/// settles and [onTurn] has made the page turned to [child], it keeps its
/// state, as does a page kept out of sight. A page with no page before it
/// may still go back, with [onBack], from a drag right.
///
/// A page may keep a part of itself still above the turn, its [top], such
/// as a header, which shows the page turned to as soon as a turn is let go.
///
/// Under reduce motion nothing moves with the finger: a turn past the same
/// marks crossfades to its page instead.
class PageTurn extends StatefulWidget {
  const PageTurn({
    super.key,
    required this.child,
    this.before,
    this.after,
    this.keepBefore = false,
    this.onTurn,
    this.onBack,
    this.canStart,
    this.top,
    this.onlyFromTop = false,
  });

  final Widget child;

  /// Build the page a drag to the right turns back to, and the page a drag
  /// to the left turns on to, when they first show, once for each build of
  /// the turn. Null where there is none.
  final WidgetBuilder? before;
  final WidgetBuilder? after;

  /// Whether [before] stays built while it is out of sight.
  final bool keepBefore;

  /// Called once a turn has settled, true for [after] and false for
  /// [before], to make that page [child].
  final ValueChanged<bool>? onTurn;

  /// Called from a drag right, past the same marks as a turn, where there is
  /// no page before, to go back as the page's Back does.
  final VoidCallback? onBack;

  /// Whether a drag that lands at this global position may turn the page.
  final bool Function(Offset position)? canStart;

  /// The part above the pages that stays put while they turn, built with
  /// the way a turn let go is settling, true for [after] and false for
  /// [before], or null while none is, so it shows the page turned to from
  /// then on.
  final Widget Function(BuildContext context, bool? turning)? top;

  /// Whether a turn starts only from a drag on [top].
  final bool onlyFromTop;

  /// How far a drag goes across before it is a turn, and how far up or down
  /// it may go before that, at no steeper than [steepest] (rise over run).
  static const double start = 2 * kTouchSlop;
  static const double slop = kTouchSlop;
  static const double steepest = 0.4;

  /// How far across, as a share of the width, or how fast, a drag has to go
  /// to turn the page.
  static const double distance = 0.25;
  static const double speed = 700;

  /// The settle: one motion for every turn, the same as the week's and the
  /// tabs' slides, shortened by however far the drag already took it.
  static const Duration motion = Duration(milliseconds: 250);
  static const Curve curve = Curves.easeOutCubic;

  /// The crossfade under reduce motion.
  static const Duration fade = Duration(milliseconds: 150);

  /// How far in from the left iOS's own back swipe starts, which a turn
  /// leaves to it on a page that can go back, and how far in a drag on
  /// Android goes back ahead of a row's own swipe, from the phone's own
  /// touch slop across, at most [slop], as soon as the row's would take it.
  static const double backEdge = 20;

  /// How far a drag with no page beyond can pull the page, as a share of
  /// the width.
  static const double give = 0.08;

  @override
  State<PageTurn> createState() => _PageTurnState();
}

class _PageTurnState extends State<PageTurn> with TickerProviderStateMixin {
  /// Where the page on screen stands, as a share of the width: negative as
  /// it moves left, towards [PageTurn.after].
  late final AnimationController _shift = AnimationController.unbounded(
    vsync: this,
  );

  /// The crossfade under reduce motion, to the page after when true.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: PageTurn.fade,
  );
  bool? _fadingTo;

  /// The way a turn let go is settling, until it has and [PageTurn.onTurn]
  /// has built the page turned to.
  bool? _settlingTo;

  final _top = GlobalKey();

  double _width = 1;
  double _pulled = 0;
  bool _dragging = false;

  bool get _still => MediaQuery.disableAnimationsOf(context);

  /// [PageTurn.before] and [PageTurn.after] as built, until the turn is
  /// built again.
  Widget? _before;
  Widget? _after;

  @override
  void didUpdateWidget(PageTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    _before = _after = null;
    if (!_shift.isAnimating && !_fade.isAnimating) _settlingTo = null;
  }

  @override
  void dispose() {
    _shift.dispose();
    _fade.dispose();
    super.dispose();
  }

  /// Whether a drag from [event] may start, on the page or, with [edge],
  /// on Android's left edge strip, which goes back as the system's own back
  /// gesture there does.
  bool _allowed(PointerDownEvent event, {bool edge = false}) {
    if (_fadingTo != null) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    if (!box.size.contains(box.globalToLocal(event.position))) return false;
    if (widget.onlyFromTop) {
      final top = _top.currentContext?.findRenderObject();
      if (top is! RenderBox ||
          !top.hasSize ||
          !top.size.contains(top.globalToLocal(event.position))) {
        return false;
      }
    }
    final media = MediaQuery.of(context);
    final edges = media.systemGestureInsets;
    final x = event.position.dx;
    switch (Theme.of(context).platform) {
      case TargetPlatform.android
          when !edge && (x < edges.left || x > media.size.width - edges.right):
        return false;
      case TargetPlatform.iOS
          when x < PageTurn.backEdge &&
              (ModalRoute.of(context)?.isFirst == false):
        return false;
      case _:
    }
    return widget.canStart?.call(event.position) ?? true;
  }

  void _begin(DragStartDetails details) {
    _shift.stop();
    _dragging = true;
    _pulled = _shift.value;
  }

  void _drag(DragUpdateDetails details) {
    if (!_dragging) return;
    _pulled = (_pulled + (details.primaryDelta ?? 0) / _width).clamp(-1, 1);
    if (_still) return;
    final beyond = _pulled < 0 ? widget.after : widget.before;
    _shift.value = beyond != null ? _pulled : _give(_pulled);
  }

  /// A pull with no page beyond: firm at once, then ever firmer, up to
  /// [PageTurn.give].
  static double _give(double pulled) {
    const give = PageTurn.give;
    return pulled.sign * give * (1 - 1 / (pulled.abs() * 2.2 / give + 1));
  }

  void _end(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final velocity = details.primaryVelocity ?? 0;
    final forward = _pulled < 0;
    // A flick decides on its own, so a flick back calls the turn off; else
    // it is how far the page has been pulled.
    final turns = velocity.abs() >= PageTurn.speed
        ? (velocity < 0) == forward && _pulled != 0
        : _pulled.abs() >= PageTurn.distance;
    if (turns && !forward && widget.before == null) {
      _settleBack();
      return widget.onBack?.call();
    }
    if (!turns || (forward ? widget.after : widget.before) == null) {
      return _settleBack();
    }
    if (_still) {
      _crossfade(forward);
      return;
    }
    _settle(forward, velocity.abs());
  }

  void _cancel() {
    if (!_dragging) return;
    _dragging = false;
    _settleBack();
  }

  void _settleBack() {
    _pulled = 0;
    final from = _shift.value.abs();
    if (from == 0) return;
    _shift.animateTo(0, duration: _left(from, 0), curve: PageTurn.curve);
  }

  void _settle(bool forward, double speed) {
    final to = forward ? -1.0 : 1.0;
    final left = (to - _shift.value).abs();
    if (widget.top != null) setState(() => _settlingTo = forward);
    _shift
        .animateTo(to, duration: _left(left, speed), curve: PageTurn.curve)
        .whenCompleteOrCancel(() {
          if (!mounted) return;
          if (_shift.value == to) return _turned(forward);
          if (_settlingTo != null) setState(() => _settlingTo = null);
        });
  }

  /// The settle's time for [share] of the width still to go: the full
  /// motion for the whole width, never under a third of it, and quicker
  /// for a flick that would get there sooner.
  Duration _left(double share, double speed) {
    final full = PageTurn.motion.inMicroseconds.toDouble();
    var micros = (full * share).clamp(full / 3, full);
    if (speed > 0) {
      final flick = share * _width / speed * 2e6;
      micros = math.min(micros, math.max(flick, full / 3));
    }
    return Duration(microseconds: micros.round());
  }

  Future<void> _crossfade(bool forward) async {
    _pulled = 0;
    setState(() {
      _fadingTo = forward;
      if (widget.top != null) _settlingTo = forward;
    });
    try {
      await _fade.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    }
    if (mounted) _turned(forward);
  }

  void _turned(bool forward) {
    setState(() {
      _fadingTo = null;
      _fade.value = 0;
      _shift.value = 0;
      _pulled = 0;
    });
    widget.onTurn?.call(forward);
  }

  Widget _slot(Widget page, {required double at, double opacity = 1}) {
    final shown = at.abs() < 1;
    return Positioned.fill(
      key: ValueKey<Key?>(page.key),
      child: Offstage(
        offstage: !shown,
        child: TickerMode(
          enabled: shown,
          child: Transform.translate(
            offset: Offset(at * _width, 0),
            child: Opacity(
              opacity: opacity,
              child: RepaintBoundary(child: page),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final on =
        widget.before != null || widget.after != null || widget.onBack != null;
    Map<Type, GestureRecognizerFactory> turn({bool edge = false}) => {
      if (on)
        _SidewaysDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_SidewaysDragRecognizer>(
              () => _SidewaysDragRecognizer(debugOwner: this),
              (drag) => drag
                ..edge = edge
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                ..allowed = ((event) => _allowed(event, edge: edge))
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = _begin
                ..onUpdate = _drag
                ..onEnd = _end
                ..onCancel = _cancel,
            ),
    };
    final pages = LayoutBuilder(
      builder: (context, constraints) {
        _width = math.max(constraints.maxWidth, 1);
        return AnimatedBuilder(
          animation: Listenable.merge([_shift, _fade]),
          builder: (context, _) {
            final shift = _shift.value;
            final fading = _fadingTo;
            final showsBefore = shift > 0 || fading == false;
            final showsAfter = shift < 0 || fading == true;
            final before = showsBefore || widget.keepBefore
                ? _before ??= widget.before?.call(context)
                : null;
            final after = showsAfter
                ? _after ??= widget.after?.call(context)
                : null;
            assert(
              (before == null && after == null) ||
                  (widget.child.key != null &&
                      (before == null || before.key != null) &&
                      (after == null || after.key != null)),
              'A page that turns is told apart by its key.',
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                _slot(widget.child, at: shift),
                if (before != null)
                  _slot(
                    before,
                    at: fading == false ? 0 : (showsBefore ? shift - 1 : -1),
                    opacity: fading == false ? _fade.value : 1,
                  ),
                if (after != null)
                  _slot(
                    after,
                    at: fading == true ? 0 : shift + 1,
                    opacity: fading == true ? _fade.value : 1,
                  ),
              ],
            );
          },
        );
      },
    );
    final top = widget.top;
    final page = RawGestureDetector(
      gestures: turn(),
      child: top == null
          ? pages
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Listener(
                  key: _top,
                  behavior: HitTestBehavior.opaque,
                  child: top(context, _settlingTo ?? _fadingTo),
                ),
                Expanded(child: pages),
              ],
            ),
    );
    // Android's pages have no back swipe of their own, so there the left
    // edge goes back ahead of a row's swipe, outside the system's own back
    // gesture edges.
    if (widget.onBack == null ||
        Theme.of(context).platform == TargetPlatform.iOS) {
      return page;
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        page,
        PositionedDirectional(
          start: 0,
          top: 0,
          bottom: 0,
          width: PageTurn.backEdge,
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: turn(edge: true),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

/// A horizontal drag that wins only once it is plainly sideways:
/// [PageTurn.start] across before [PageTurn.slop] up or down, at no steeper
/// than [PageTurn.steepest]. A drag that goes up or down first is let go, so
/// the scroll under it keeps it.
class _SidewaysDragRecognizer extends HorizontalDragGestureRecognizer {
  _SidewaysDragRecognizer({super.debugOwner}) {
    // Won by default, as where nothing else wants the drag, it still waits
    // until the drag is plainly sideways.
    onlyAcceptDragOnThreshold = true;
  }

  /// Whether this is Android's left edge strip, whose drag goes back from
  /// the phone's own touch slop across, so ahead of a row's swipe.
  bool edge = false;

  bool Function(PointerDownEvent event) allowed = _always;
  static bool _always(PointerDownEvent _) => true;

  final Map<int, Offset> _downs = {};
  Offset _moved = Offset.zero;
  bool _sideways = false;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (event is! PointerDownEvent || allowed(event)) &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_downs.isEmpty) {
      _moved = Offset.zero;
      _sideways = false;
    }
    _downs[event.pointer] = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _downs[event.pointer];
    if (down != null && event is PointerMoveEvent && !_sideways) {
      _moved = event.position - down;
      if (_moved.dy.abs() > PageTurn.slop) {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
        return;
      }
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    final start = edge
        ? math.min(PageTurn.slop, deviceTouchSlop ?? PageTurn.slop)
        : PageTurn.start;
    return _sideways =
        _sideways ||
        (_moved.dx.abs() >= start &&
            _moved.dy.abs() <= _moved.dx.abs() * PageTurn.steepest);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _downs.clear();
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  String get debugDescription => 'sideways page turn';
}
