import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';

/// Keeps what a key moves focus to in sight. Tab scrolls a list forward and
/// Shift+Tab scrolls it back, but neither scrolls when it comes round past the
/// end of the list, which left focus on a control out of sight. When a key
/// puts focus on a control that is wholly out of sight, its lists scroll it
/// in; one already partly in sight stays where it is, and so does a list
/// scrolled away from the focus. On a phone or tablet only Tab and Shift+Tab
/// count as keys here, and a press or a touch moving focus scrolls nothing.
class FocusReveal extends StatefulWidget {
  const FocusReveal({super.key, required this.child});

  final Widget child;

  @override
  State<FocusReveal> createState() => _FocusRevealState();
}

class _FocusRevealState extends State<FocusReveal> {
  bool _keyed = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    FocusManager.instance.addListener(_onFocus);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    FocusManager.instance.removeListener(_onFocus);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      _keyed =
          AppPlatform.isDesktop || event.logicalKey == LogicalKeyboardKey.tab;
    }
    return false;
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _keyed = false;
  }

  void _onFocus() {
    final node = FocusManager.instance.primaryFocus;
    if (!_keyed || node == null) return;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        final context = node.context;
        if (!node.hasPrimaryFocus || context == null || !context.mounted) {
          return;
        }
        if (!_outOfSight(context)) return;
        for (final policy in [
          ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ]) {
          Scrollable.ensureVisible(context, alignmentPolicy: policy);
        }
      }, debugLabel: 'FocusReveal.reveal')
      ..ensureVisualUpdate();
  }

  /// Whether nothing of the control at [context] shows inside the lists it
  /// sits in.
  static bool _outOfSight(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    var shown = Rect.largest;
    for (
      var scrollable = Scrollable.maybeOf(context);
      scrollable != null;
      scrollable = Scrollable.maybeOf(scrollable.context)
    ) {
      final view = scrollable.context.findRenderObject();
      if (view is! RenderBox || !view.hasSize) return false;
      shown = shown.intersect(
        MatrixUtils.transformRect(
          view.getTransformTo(null),
          Offset.zero & view.size,
        ),
      );
    }
    final bounds = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    return !bounds.overlaps(shown);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
