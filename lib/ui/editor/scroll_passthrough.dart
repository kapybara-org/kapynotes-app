import 'package:flutter/gestures.dart' show Drag;
import 'package:material_ui/material_ui.dart';

/// Makes a vertical drag anywhere inside it scroll somebody else's scrollable.
///
/// The results gutter is a sibling of the text field rather than part of it:
/// its chips are positioned from the field's scroll offset instead of being
/// laid out inside the field's scroll view. That is what keeps a long note
/// cheap — only the chips that can be seen are built — but it also leaves the
/// gutter with no scrollable of its own, so a drag that began over it had
/// nothing to move. On a phone the gutter is a third of the width, which made
/// a third of the screen a place where scrolling quietly did nothing.
///
/// Handing the drag to [ScrollPosition.drag], rather than nudging `offset` on
/// each update, is what buys the real thing: momentum after the finger
/// leaves, the platform's own overscroll, and a fling that stops where the
/// note does. It is the same call [Scrollable] makes for its own gestures.
class ScrollPassthrough extends StatefulWidget {
  const ScrollPassthrough({
    super.key,
    required this.controller,
    required this.child,
  });

  /// The scrollable to drive. Nothing happens while it has no clients, which
  /// is the first frame and any layout with no room to scroll.
  final ScrollController controller;
  final Widget child;

  @override
  State<ScrollPassthrough> createState() => _ScrollPassthroughState();
}

class _ScrollPassthroughState extends State<ScrollPassthrough> {
  Drag? _drag;

  void _start(DragStartDetails details) {
    _drag?.cancel();
    final controller = widget.controller;
    if (!controller.hasClients) return;
    _drag = controller.position.drag(details, () => _drag = null);
  }

  void _update(DragUpdateDetails details) => _drag?.update(details);

  void _end(DragEndDetails details) {
    _drag?.end(details);
    _drag = null;
  }

  void _cancel() {
    _drag?.cancel();
    _drag = null;
  }

  @override
  void dispose() {
    _drag?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    // Opaque so a drag starting on the gutter's empty background counts, not
    // only one that starts on a chip. Children still hit-test first, so a tap
    // on a chip is still the chip's.
    behavior: HitTestBehavior.opaque,
    onVerticalDragStart: _start,
    onVerticalDragUpdate: _update,
    onVerticalDragEnd: _end,
    onVerticalDragCancel: _cancel,
    child: widget.child,
  );
}
