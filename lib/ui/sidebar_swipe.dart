import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Opens and closes the notes list with a sideways trackpad swipe.
///
/// Horizontal scrolling is otherwise unused in the editor — the note scrolls
/// vertically and never sideways — so it is free to mean this. Pointer
/// signals rather than a drag recogniser: a horizontal *drag* inside a text
/// field is how you select text, and taking it would cost more than the
/// gesture is worth. A two-finger swipe conflicts with nothing.
///
/// Desktop keeps this observer above both responsive layouts, so the same
/// two-finger gesture works in wide and narrow windows. Touchscreen compact
/// layouts use their separate full-page swipe handling.
class SidebarSwipe extends StatefulWidget {
  const SidebarSwipe({
    super.key,
    required this.child,
    required this.sidebarVisible,
    required this.onToggle,
  });

  final Widget child;
  final bool sidebarVisible;
  final VoidCallback onToggle;

  /// How far sideways counts as meaning it.
  ///
  /// High enough that the sideways component of an ordinary vertical scroll
  /// never reaches it, low enough that a deliberate swipe does so at once.
  static const double threshold = 90;

  @override
  State<SidebarSwipe> createState() => _SidebarSwipeState();
}

class _SidebarSwipeState extends State<SidebarSwipe> {
  static const _scrollGestureIdle = Duration(milliseconds: 160);

  final _SidebarSwipeExclusions _exclusions = _SidebarSwipeExclusions();

  double _travel = 0;

  /// A trackpad pan that began over a [SidebarSwipeExclusion], which owns
  /// the whole of it, wherever it goes next.
  bool _panExcluded = false;

  /// Swallows the rest of a gesture once it has been acted on, so one long
  /// swipe toggles once instead of flapping the sidebar open and shut.
  bool _spent = false;
  Timer? _scrollRestTimer;

  @override
  void dispose() {
    _scrollRestTimer?.cancel();
    super.dispose();
  }

  void _accumulate(double dx, double dy) {
    // A scroll that is mostly vertical is a scroll, whatever its drift.
    if (dx.abs() < dy.abs()) return;
    _travel += dx;

    if (_spent) return;
    // Natural scrolling reports a swipe to the right as a negative delta,
    // the same direction the content moves.
    final wantsOpen = _travel <= -SidebarSwipe.threshold;
    final wantsClose = _travel >= SidebarSwipe.threshold;
    if (!wantsOpen && !wantsClose) return;

    _spent = true;
    // Only when it would change something: swiping further right with the
    // list already open should do nothing rather than close it.
    if (wantsOpen != widget.sidebarVisible) widget.onToggle();
  }

  void _rest() {
    _travel = 0;
    _spent = false;
  }

  void _scheduleScrollRest() {
    _scrollRestTimer?.cancel();
    _scrollRestTimer = Timer(_scrollGestureIdle, _rest);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        if (_exclusions.cover(event.position)) return;
        _accumulate(event.scrollDelta.dx, event.scrollDelta.dy);
        // Scroll signals do not carry an end event. Treat a short idle period
        // as the boundary so a later two-finger gesture can act again.
        _scheduleScrollRest();
      },
      // A trackpad gesture arrives as a pan rather than as scroll signals on
      // some platforms, and reports its own beginning and end.
      onPointerPanZoomStart: (event) {
        _scrollRestTimer?.cancel();
        _rest();
        _panExcluded = _exclusions.cover(event.position);
      },
      onPointerPanZoomUpdate: (event) {
        if (_panExcluded) return;
        _accumulate(event.panDelta.dx, event.panDelta.dy);
      },
      onPointerPanZoomEnd: (_) {
        _panExcluded = false;
        _rest();
      },
      child: _SidebarSwipeScope(exclusions: _exclusions, child: widget.child),
    );
  }
}

/// Exempts a subtree from [SidebarSwipe].
///
/// A sideways two-finger gesture that starts inside one of these is left to
/// it. A drawing canvas is the reason it exists: panning the canvas sideways
/// is exactly the gesture that otherwise opened and shut the notes list, and
/// resized the canvas under the pan.
///
/// Inert where there is no [SidebarSwipe] above it, which is every phone.
class SidebarSwipeExclusion extends StatefulWidget {
  const SidebarSwipeExclusion({super.key, required this.child});

  final Widget child;

  @override
  State<SidebarSwipeExclusion> createState() => _SidebarSwipeExclusionState();
}

class _SidebarSwipeExclusionState extends State<SidebarSwipeExclusion> {
  _SidebarSwipeExclusions? _exclusions;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final found = _SidebarSwipeScope.of(context);
    if (identical(found, _exclusions)) return;
    _exclusions?.remove(context);
    _exclusions = found;
    _exclusions?.add(context);
  }

  @override
  void dispose() {
    _exclusions?.remove(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The regions a sidebar swipe must not begin in, read where the gesture
/// lands rather than cached, since the canvas resizes with the window.
class _SidebarSwipeExclusions {
  final Set<BuildContext> _contexts = {};

  void add(BuildContext context) => _contexts.add(context);

  void remove(BuildContext context) => _contexts.remove(context);

  bool cover(Offset globalPosition) {
    for (final context in _contexts) {
      if (!context.mounted) continue;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (box.size.contains(box.globalToLocal(globalPosition))) return true;
    }
    return false;
  }
}

class _SidebarSwipeScope extends InheritedWidget {
  const _SidebarSwipeScope({required this.exclusions, required super.child});

  final _SidebarSwipeExclusions exclusions;

  static _SidebarSwipeExclusions? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_SidebarSwipeScope>()
      ?.exclusions;

  @override
  bool updateShouldNotify(_SidebarSwipeScope oldWidget) =>
      !identical(exclusions, oldWidget.exclusions);
}
