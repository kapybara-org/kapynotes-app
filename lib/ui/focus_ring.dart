import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';

/// The one mark of keyboard focus on the desktop: a ring in the theme's
/// accent around whatever a key last moved focus to, drawn over the whole
/// window. A press anywhere puts it away until a key moves focus again, so a
/// click never leaves one behind.
class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.child});

  final Widget child;

  /// How far the ring stands off the edge of what it marks.
  static const double gap = 2;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  final bool _desktop = AppPlatform.isDesktop;
  final ValueNotifier<FocusNode?> _target = ValueNotifier(null);
  bool _keyed = false;

  @override
  void initState() {
    super.initState();
    if (!_desktop) return;
    HardwareKeyboard.instance.addHandler(_onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    FocusManager.instance.addListener(_onFocus);
  }

  @override
  void dispose() {
    if (_desktop) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      FocusManager.instance.removeListener(_onFocus);
    }
    _target.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _keyed = true;
    return false;
  }

  void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    _keyed = false;
    _target.value = null;
  }

  void _onFocus() {
    final node = FocusManager.instance.primaryFocus;
    _target.value =
        _keyed && node != null && node is! FocusScopeNode && !node.skipTraversal
        ? node
        : null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_desktop) return widget.child;
    final palette = context.palette;
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.topLeft,
      children: [
        widget.child,
        _Ring(
          key: const ValueKey('focus-ring'),
          target: _target,
          color: palette.accent,
          width: palette.increasedContrast ? 3 : 2,
        ),
      ],
    );
  }
}

class _Ring extends LeafRenderObjectWidget {
  const _Ring({
    super.key,
    required this.target,
    required this.color,
    required this.width,
  });

  final ValueListenable<FocusNode?> target;
  final Color color;
  final double width;

  @override
  _RenderRing createRenderObject(BuildContext context) =>
      _RenderRing(target: target, color: color, width: width);

  @override
  void updateRenderObject(BuildContext context, _RenderRing ring) {
    ring
      ..target = target
      ..color = color
      ..width = width;
  }
}

class _RenderRing extends RenderBox {
  _RenderRing({
    required ValueListenable<FocusNode?> target,
    required Color color,
    required double width,
  }) : _target = target,
       _color = color,
       _width = width;

  ValueListenable<FocusNode?> _target;
  set target(ValueListenable<FocusNode?> value) {
    if (value == _target) return;
    if (attached) {
      _target.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _target = value;
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double _width;
  set width(double value) {
    if (value == _width) return;
    _width = value;
    markNeedsPaint();
  }

  /// The ring as last painted. A frame can move what it marks, a scroll or a
  /// panel sliding, without repainting the ring, so each frame after one with
  /// a ring checks whether it still fits and paints it again if not.
  RRect? _painted;
  bool _watching = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _target.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _target.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => false;

  RRect? _ring() {
    final context = _target.value?.context;
    if (context == null || !context.mounted) return null;
    // A text field is marked whole, its box and border, not just the line
    // of text that holds the focus.
    final field = context.findAncestorStateOfType<State<TextField>>();
    final box = (field?.context ?? context).findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    if (_root(box) != _root(this)) return null;
    final toRing = getTransformTo(null);
    if (toRing.invert() == 0) return null;
    final bounds = MatrixUtils.transformRect(
      toRing..multiply(box.getTransformTo(null)),
      Offset.zero & box.size,
    );
    final rect = bounds
        .inflate(FocusRing.gap + _width / 2)
        .intersect((Offset.zero & size).deflate(_width / 2));
    if (rect.width <= 0 || rect.height <= 0) return null;
    return RRect.fromRectAndRadius(
      rect,
      const Radius.circular(AppRadii.control + FocusRing.gap),
    );
  }

  static RenderObject _root(RenderObject node) {
    var root = node;
    for (var up = node.parent; up != null; up = up.parent) {
      root = up;
    }
    return root;
  }

  void _watch() {
    if (_watching) return;
    _watching = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _watching = false;
      if (!attached || _painted == null) return;
      if (_ring() != _painted) {
        markNeedsPaint();
      } else {
        _watch();
      }
    }, debugLabel: 'FocusRing.watch');
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final ring = _painted = _ring();
    if (ring == null) return;
    _watch();
    context.canvas.drawRRect(
      ring.shift(offset),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _width
        ..color = _color,
    );
  }
}
