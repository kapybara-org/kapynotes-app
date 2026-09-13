import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../crdt/text_diff.dart';
import '../../core/theme.dart';
import '../../sync/presence.dart';
import '../collaborator_colors.dart';

/// Other people's carets and selections, drawn over the note as they move.
///
/// Painted rather than built. A caret follows every keystroke and every
/// scroll, and widgets placed after layout would rebuild a dozen times a
/// second and still trail the words they mark by a frame. This layer reads
/// the field's own layout while it paints, so a caret moves in the same frame
/// as the text around it.
///
/// A name rides on a flag while its owner types or moves, then folds down to
/// a small tab — enough to mark a quiet collaborator's place without shouting
/// over the note. Pointing at a caret raises its flag again.
class RemoteCaretLayer extends StatefulWidget {
  const RemoteCaretLayer({
    super.key,
    required this.noteId,
    required this.source,
    required this.controller,
    required this.scroll,
    required this.editable,
    required this.hover,
  });

  final String noteId;
  final RemoteCaretSource source;

  /// The field's text. Offsets are mapped onto it before they are drawn.
  final TextEditingController controller;
  final ScrollController scroll;

  /// The field's render object, looked up when it is needed rather than held:
  /// the field rebuilds it whenever it likes.
  final RenderEditable? Function() editable;

  /// The pointer, in global coordinates, or null when it is not over the note.
  final ValueListenable<Offset?> hover;

  /// How long a flag stays up after its caret last moved or typed.
  static const flagDuration = Duration(seconds: 3);

  @override
  State<RemoteCaretLayer> createState() => _RemoteCaretLayerState();
}

class _RemoteCaretLayerState extends State<RemoteCaretLayer> {
  RemoteCarets _carets = RemoteCarets.empty;

  /// Carets whose name flag is up: their owner is typing, or moved within
  /// [RemoteCaretLayer.flagDuration].
  Set<String> _raised = const {};
  Timer? _foldTimer;

  @override
  void initState() {
    super.initState();
    widget.source.caretChanges.addListener(_refresh);
    _resolve();
  }

  @override
  void didUpdateWidget(RemoteCaretLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      oldWidget.source.caretChanges.removeListener(_refresh);
      widget.source.caretChanges.addListener(_refresh);
    }
    // A rebuild of the editor usually means the note's text moved — somebody
    // else's words landed, or ours were absorbed — so the anchors are read
    // against the document again.
    _resolve();
  }

  @override
  void dispose() {
    widget.source.caretChanges.removeListener(_refresh);
    _foldTimer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(_resolve);
  }

  void _resolve() {
    _carets = widget.source.caretsFor(widget.noteId);
    final now = DateTime.now();
    final raised = <String>{};
    final folding = <String, Duration>{};
    for (final caret in _carets.carets) {
      if (caret.leaving) continue;
      if (caret.typing) {
        raised.add(caret.id);
        continue;
      }
      final left =
          RemoteCaretLayer.flagDuration - now.difference(caret.movedAt);
      if (left > Duration.zero) {
        raised.add(caret.id);
        folding[caret.id] = left;
      }
    }
    _raised = raised;
    _scheduleFold(folding);
  }

  /// Folds each flag when its time is up, so a caret that stops moving folds
  /// on time rather than whenever something else happens to repaint. The
  /// timer decides, not the clock at paint time: a frame painted a moment
  /// early must not keep a flag up that has already been told to go.
  void _scheduleFold(Map<String, Duration> folding) {
    _foldTimer?.cancel();
    _foldTimer = null;
    if (folding.isEmpty) return;
    final first = folding.values.reduce((a, b) => a < b ? a : b);
    _foldTimer = Timer(first, () {
      if (!mounted) return;
      final raised = {..._raised};
      final rest = <String, Duration>{};
      folding.forEach((id, left) {
        final remaining = left - first;
        // Flags due within a frame of each other fold together.
        if (remaining < const Duration(milliseconds: 20)) {
          raised.remove(id);
        } else {
          rest[id] = remaining;
        }
      });
      setState(() => _raised = raised);
      _scheduleFold(rest);
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: _RemoteCaretPaint(
        carets: _carets,
        raised: _raised,
        controller: widget.controller,
        scroll: widget.scroll,
        hover: widget.hover,
        editable: widget.editable,
        brightness: Theme.of(context).brightness,
        labelStyle: DefaultTextStyle.of(context).style.merge(
          TextStyle(
            fontSize: AppTypeScale.caption,
            fontWeight: FontWeight.w400,
            color: const Color(0xFFFFFFFF),
            height: 1.25,
            letterSpacing: 0.1,
            decoration: TextDecoration.none,
          ),
        ),
        textDirection: Directionality.of(context),
      ),
    );
  }
}

class _RemoteCaretPaint extends LeafRenderObjectWidget {
  const _RemoteCaretPaint({
    required this.carets,
    required this.raised,
    required this.controller,
    required this.scroll,
    required this.hover,
    required this.editable,
    required this.brightness,
    required this.labelStyle,
    required this.textDirection,
  });

  final RemoteCarets carets;
  final Set<String> raised;
  final TextEditingController controller;
  final ScrollController scroll;
  final ValueListenable<Offset?> hover;
  final RenderEditable? Function() editable;
  final Brightness brightness;
  final TextStyle labelStyle;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderRemoteCarets(
    carets: carets,
    raised: raised,
    controller: controller,
    scroll: scroll,
    hover: hover,
    editable: editable,
    brightness: brightness,
    labelStyle: labelStyle,
    textDirection: textDirection,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderRemoteCarets renderObject,
  ) {
    renderObject
      ..carets = carets
      ..raised = raised
      ..controller = controller
      ..scroll = scroll
      ..hover = hover
      ..editable = editable
      ..brightness = brightness
      ..labelStyle = labelStyle
      ..textDirection = textDirection;
  }
}

class _RenderRemoteCarets extends RenderBox {
  _RenderRemoteCarets({
    required RemoteCarets carets,
    required Set<String> raised,
    required TextEditingController controller,
    required ScrollController scroll,
    required ValueListenable<Offset?> hover,
    required this.editable,
    required Brightness brightness,
    required TextStyle labelStyle,
    required TextDirection textDirection,
  }) : _carets = carets,
       _raised = raised,
       _controller = controller,
       _scroll = scroll,
       _hover = hover,
       _brightness = brightness,
       _labelStyle = labelStyle,
       _textDirection = textDirection;

  RenderEditable? Function() editable;

  RemoteCarets _carets;
  set carets(RemoteCarets value) {
    if (identical(value, _carets)) return;
    _carets = value;
    markNeedsPaint();
  }

  Set<String> _raised;
  set raised(Set<String> value) {
    if (setEquals(value, _raised)) return;
    _raised = value;
    markNeedsPaint();
  }

  TextEditingController _controller;
  set controller(TextEditingController value) {
    if (identical(value, _controller)) return;
    if (attached) _controller.removeListener(markNeedsPaint);
    _controller = value;
    if (attached) _controller.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  ScrollController _scroll;
  set scroll(ScrollController value) {
    if (identical(value, _scroll)) return;
    if (attached) _scroll.removeListener(markNeedsPaint);
    _scroll = value;
    if (attached) _scroll.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  ValueListenable<Offset?> _hover;
  set hover(ValueListenable<Offset?> value) {
    if (identical(value, _hover)) return;
    if (attached) _hover.removeListener(markNeedsPaint);
    _hover = value;
    if (attached) _hover.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Brightness _brightness;
  set brightness(Brightness value) {
    if (value == _brightness) return;
    _brightness = value;
    markNeedsPaint();
  }

  TextStyle _labelStyle;
  set labelStyle(TextStyle value) {
    if (value == _labelStyle) return;
    _labelStyle = value;
    _clearLabels();
    markNeedsPaint();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    _clearLabels();
    markNeedsPaint();
  }

  /// Laid-out names, so a flag that follows a typist is not re-shaped on
  /// every keystroke.
  final Map<String, TextPainter> _labels = {};

  void _clearLabels() {
    for (final label in _labels.values) {
      label.dispose();
    }
    _labels.clear();
  }

  TextPainter _label(String name) => _labels.putIfAbsent(
    name,
    () => TextPainter(
      text: TextSpan(text: name, style: _labelStyle),
      textDirection: _textDirection,
      maxLines: 1,
      ellipsis: '…',
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: 160),
  );

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  /// Carets move far more often than the text does; this keeps each of those
  /// repaints to this layer instead of the field underneath.
  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(markNeedsPaint);
    _scroll.addListener(markNeedsPaint);
    _hover.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _controller.removeListener(markNeedsPaint);
    _scroll.removeListener(markNeedsPaint);
    _hover.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _clearLabels();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final carets = _carets.carets;
    if (carets.isEmpty) return;
    final field = editable();
    if (field == null || !field.attached || !field.hasSize) return;

    final text = _controller.text;
    final edit = _carets.text == text ? null : diffTexts(_carets.text, text);
    int place(int at) =>
        (edit == null ? at : mapOffsetAcross(edit, at)).clamp(0, text.length);

    // Everything below is in this layer's coordinates. The field's own rects
    // already account for its scroll offset.
    final origin = globalToLocal(field.localToGlobal(Offset.zero));
    final visible = origin & field.size;
    final pointedAt = _hover.value;
    final pointer = pointedAt == null ? null : globalToLocal(pointedAt);

    final canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy);

    // Selections first, so no highlight is ever drawn over a caret or a flag.
    canvas
      ..save()
      ..clipRect(visible);
    for (final caret in carets) {
      final start = place(caret.base);
      final end = place(caret.extent);
      if (start == end) continue;
      final fill = Paint()
        ..color = collaboratorColor(
          caret.userId,
          on: _brightness,
        ).withValues(alpha: caret.leaving ? 0.1 : 0.22);
      for (final box in field.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      )) {
        canvas.drawRect(box.toRect().shift(origin), fill);
      }
    }
    canvas.restore();

    for (final caret in carets) {
      final rect = field
          .getLocalRectForCaret(TextPosition(offset: place(caret.extent)))
          .shift(origin);
      if (rect.bottom <= visible.top || rect.top >= visible.bottom) continue;
      final color = collaboratorColor(
        caret.userId,
        on: _brightness,
      ).withValues(alpha: caret.leaving ? 0.45 : 1);
      final ink = Paint()..color = color;
      canvas.drawRect(
        Rect.fromLTWH(
          rect.left - 1,
          rect.top,
          2,
          rect.height,
        ).intersect(visible),
        ink,
      );

      final pointed = pointer != null && rect.inflate(6).contains(pointer);
      if (!caret.leaving && (_raised.contains(caret.id) || pointed)) {
        _paintFlag(canvas, caret.name, rect, ink);
      } else if (rect.top >= visible.top) {
        // The folded flag: a tab on top of the caret, like a pin in a map.
        canvas.drawRect(
          Rect.fromLTWH(rect.left - 2.5, rect.top - 1.5, 5, 4),
          ink,
        );
      }
    }
    canvas.restore();
  }

  /// A name tag whose corner sits on the caret: above it where there is room,
  /// below it on the first line, and kept inside the note's edges.
  void _paintFlag(Canvas canvas, String name, Rect caret, Paint ink) {
    final label = _label(name);
    const padX = 5.0;
    const padY = 1.5;
    final width = label.width + padX * 2;
    final height = label.height + padY * 2;
    final left = math.max(0.0, math.min(caret.left - 1, size.width - width));
    final above = caret.top - height >= 0;
    final top = above ? caret.top - height : caret.bottom;
    const round = Radius.circular(4);
    final flag = RRect.fromRectAndCorners(
      Rect.fromLTWH(left, top, width, height),
      topLeft: above ? round : Radius.zero,
      topRight: round,
      bottomRight: round,
      bottomLeft: above ? Radius.zero : round,
    );
    canvas.drawRRect(flag, ink);
    label.paint(canvas, Offset(left + padX, top + padY));
  }
}
