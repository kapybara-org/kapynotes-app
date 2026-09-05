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
/// The compact layout uses [Scaffold]'s own drawer drag instead, which knows
/// to start only near the edge and so leaves selection alone on a touchscreen.
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
  double _travel = 0;

  /// Swallows the rest of a gesture once it has been acted on, so one long
  /// swipe toggles once instead of flapping the sidebar open and shut.
  bool _spent = false;

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

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        _accumulate(event.scrollDelta.dx, event.scrollDelta.dy);
      },
      // A trackpad gesture arrives as a pan rather than as scroll signals on
      // some platforms, and reports its own beginning and end.
      onPointerPanZoomStart: (_) => _rest(),
      onPointerPanZoomUpdate: (event) =>
          _accumulate(event.panDelta.dx, event.panDelta.dy),
      onPointerPanZoomEnd: (_) => _rest(),
      child: widget.child,
    );
  }
}
