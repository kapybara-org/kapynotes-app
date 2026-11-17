import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'line_heights.dart';
import 'note_lines.dart';

/// What a line draws: its runs, and the size of each widget among them, in
/// the order they come.
typedef LineSpan = ({
  InlineSpan span,
  List<PlaceholderDimensions> placeholders,
});

/// The note laid out a line at a time for [NoteSliver]: each line's
/// paragraph, made when the line is first shown and kept by what it draws,
/// and every line's height.
///
/// After an edit to [lines], call [edited] with what the edit did, and after
/// a change to what lines draw that came without one, call [restyled]. Either
/// way, build the [NoteSliver] again in the same frame.
class NoteLayout {
  NoteLayout({
    required this.lines,
    required this.spanOf,
    required this.style,
    required this.strut,
    this.scaler = TextScaler.noScaling,
  });

  final NoteLines lines;

  /// What a line draws.
  final LineSpan Function(int line) spanOf;

  /// The note's base style, which an empty line is laid out in.
  final TextStyle style;

  final StrutStyle strut;

  final TextScaler scaler;

  /// Paragraphs of lines shown before, by what they draw, so that a line
  /// scrolled back into view, or moved by an edit above it, isn't laid out
  /// again. The least recently used go first.
  final LinkedHashMap<_Drawn, TextPainter> _kept = LinkedHashMap();
  static const _keep = 2048;

  /// Each line's span and paragraph, until the next edit or restyle.
  final Map<int, LineSpan> _spans = {};
  final Map<int, TextPainter> _paragraphs = {};

  double? _width;
  LineHeights? _heights;
  RenderNoteSliver? _sliver;
  bool _toEnd = false;

  int get length => lines.length;

  /// Every line's height: measured for the lines laid out so far, and
  /// estimated for the rest. Null until the sliver's first layout gives the
  /// column its width.
  LineHeights? get heights => _heights;

  /// What [line] draws, built once until the next edit or restyle.
  LineSpan spanAt(int line) => _spans[line] ??= spanOf(line);

  /// [line]'s paragraph, laid out across the column.
  TextPainter paragraphOf(int line) =>
      _paragraphs[line] ??= _paragraphFor(line);

  /// Lays [line] out, unless it is already, and records its height.
  double measure(int line) {
    final height = paragraphOf(line).height;
    _heights!.measure(line, height);
    return height;
  }

  void edited(LineEdit edit) {
    _spans.clear();
    _paragraphs.clear();
    _heights?.apply(edit, _estimate);
    _sliver?._edited(edit);
  }

  void restyled() {
    _spans.clear();
    _paragraphs.clear();
    _sliver?.markNeedsLayout();
  }

  /// Scrolls so that the note's last line ends at the bottom of the viewport,
  /// exactly, measuring the last screenful first.
  void jumpToEnd() {
    _toEnd = true;
    _sliver?.markNeedsLayout();
  }

  void _setWidth(double width) {
    if (width == _width) return;
    _width = width;
    _kept.clear();
    _paragraphs.clear();
    final heights = _heights;
    if (heights == null) {
      _heights = LineHeights([
        for (var line = 0; line < length; line++) _estimate(line),
      ]);
    } else {
      heights.forget();
    }
  }

  TextPainter _paragraphFor(int line) {
    final drawn = spanAt(line);
    final key = _Drawn(drawn.span, drawn.placeholders);
    final kept = _kept.remove(key);
    if (kept != null) return _kept[key] = kept;
    final painter =
        TextPainter(
            // In one paragraph of the whole note, an empty line takes its
            // height from its newline, in the base style. An empty paragraph
            // would take the paragraph style's instead.
            text: lines[line].isEmpty
                ? TextSpan(text: ' ', style: style)
                : drawn.span,
            textDirection: TextDirection.ltr,
            strutStyle: strut,
            textScaler: scaler,
          )
          ..setPlaceholderDimensions(drawn.placeholders)
          ..layout(maxWidth: _width!);
    _kept[key] = painter;
    if (_kept.length > _keep) _kept.remove(_kept.keys.first);
    return painter;
  }

  /// A guess at [line]'s height before it is laid out: as many rows as its
  /// characters fill at an average advance.
  double _estimate(int line) {
    final rows = (lines[line].length * _advance / math.max(_width!, 1)).ceil();
    return math.max(1, rows) * _row;
  }

  late final double _row = _measured(' ').height;

  late final double _advance = () {
    const sample =
        'Plain prose for a note, with a total of 4 + 5 in it. The quick '
        'brown fox jumps over the lazy dog.';
    return _measured(sample).width / sample.length;
  }();

  Size _measured(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      strutStyle: strut,
      textScaler: scaler,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }
}

/// What a line draws, as the key its paragraph is kept under.
@immutable
class _Drawn {
  const _Drawn(this.span, this.placeholders);

  final InlineSpan span;
  final List<PlaceholderDimensions> placeholders;

  @override
  bool operator ==(Object other) =>
      other is _Drawn &&
      other.span == span &&
      listEquals(other.placeholders, placeholders);

  @override
  int get hashCode => Object.hash(span, Object.hashAll(placeholders));
}

/// The note's lines in a scroll view, each one a widget of its own, laid
/// out only where they show: in the viewport and its cache extent.
class NoteSliver extends SliverMultiBoxAdaptorWidget {
  NoteSliver({super.key, required this.layout})
    : super(
        delegate: SliverChildBuilderDelegate(
          (context, line) => _NoteLine(layout, line, layout.spanAt(line)),
          childCount: layout.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          addSemanticIndexes: false,
        ),
      );

  final NoteLayout layout;

  @override
  RenderNoteSliver createRenderObject(BuildContext context) => RenderNoteSliver(
    childManager: context as SliverMultiBoxAdaptorElement,
    noteLayout: layout,
  );

  @override
  void updateRenderObject(BuildContext context, RenderNoteSliver renderObject) {
    renderObject.noteLayout = layout;
  }
}

/// Lays out the lines in the viewport and its cache extent, placing each at
/// its top in the note's [LineHeights].
///
/// When lines above the first one in view turn out taller or shorter than
/// their estimates, or an edit changes them, the scroll offset moves by the
/// same amount, so the first line in view stays where it is on screen.
class RenderNoteSliver extends RenderSliverMultiBoxAdaptor {
  RenderNoteSliver({
    required super.childManager,
    required NoteLayout noteLayout,
  }) : _noteLayout = noteLayout;

  NoteLayout _noteLayout;
  NoteLayout get noteLayout => _noteLayout;
  set noteLayout(NoteLayout value) {
    if (identical(value, _noteLayout)) return;
    if (identical(_noteLayout._sliver, this)) _noteLayout._sliver = null;
    _noteLayout = value;
    _anchor = null;
    if (attached) value._sliver = this;
    markNeedsLayout();
  }

  /// The first line in view at the last layout, and its top then.
  ({int line, double top})? _anchor;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _noteLayout._sliver = this;
  }

  @override
  void detach() {
    if (identical(_noteLayout._sliver, this)) _noteLayout._sliver = null;
    super.detach();
  }

  void _edited(LineEdit edit) {
    final anchor = _anchor;
    if (anchor != null && anchor.line > edit.line) {
      _anchor = (
        line: anchor.line < edit.line + edit.removed
            ? edit.line
            : anchor.line - edit.removed + edit.inserted,
        top: anchor.top,
      );
    }
    markNeedsLayout();
  }

  BoxConstraints _constraintsFor(int line) {
    final height = _noteLayout._heights!.heightOf(line);
    return constraints.asBoxConstraints(minExtent: height, maxExtent: height);
  }

  void _place(RenderBox child, int line) {
    (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset =
        _noteLayout._heights!.topOf(line);
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    childManager
      ..didStartLayout()
      ..setDidUnderflow(false);
    final layout = _noteLayout.._setWidth(constraints.crossAxisExtent);
    final heights = layout._heights!;
    final count = heights.length;
    assert(count == layout.length, 'The note was edited without edited().');

    if (layout._toEnd) {
      layout._toEnd = false;
      final needed =
          constraints.viewportMainAxisExtent +
          constraints.remainingCacheExtent -
          constraints.remainingPaintExtent;
      var covered = 0.0;
      for (var line = count - 1; line >= 0 && covered < needed; line--) {
        covered += layout.measure(line);
      }
      _anchor = null;
      final by =
          math.max(0, heights.total - constraints.viewportMainAxisExtent) -
          constraints.scrollOffset;
      if (by.abs() > precisionErrorTolerance) {
        geometry = SliverGeometry(scrollOffsetCorrection: by);
        return;
      }
    }

    final anchor = _anchor;
    if (anchor != null && anchor.line < count) {
      final moved = heights.topOf(anchor.line) - anchor.top;
      if (moved.abs() > precisionErrorTolerance) {
        _anchor = (line: anchor.line, top: anchor.top + moved);
        geometry = SliverGeometry(scrollOffsetCorrection: moved);
        return;
      }
    }

    final scrollOffset = constraints.scrollOffset;
    final first = heights.lineAt(scrollOffset);
    final firstTop = heights.topOf(first);
    final cacheStart = scrollOffset + constraints.cacheOrigin;
    final cacheEnd = cacheStart + constraints.remainingCacheExtent;
    for (
      var line = first, top = firstTop;
      line < count && top < cacheEnd;
      line++
    ) {
      top += layout.measure(line);
    }
    for (
      var line = first - 1;
      line >= 0 && heights.topOf(line + 1) > cacheStart;
      line--
    ) {
      layout.measure(line);
    }
    final moved = heights.topOf(first) - firstTop;
    if (moved.abs() > precisionErrorTolerance) {
      _anchor = (line: first, top: firstTop + moved);
      geometry = SliverGeometry(scrollOffsetCorrection: moved);
      return;
    }

    final firstIndex = heights.lineAt(math.max(0, cacheStart));
    final lastIndex = math.max(firstIndex, heights.lineAt(cacheEnd));
    var leading = 0;
    for (
      var child = firstChild;
      child != null && indexOf(child) < firstIndex;
      child = childAfter(child)
    ) {
      leading++;
    }
    var trailing = 0;
    for (
      var child = lastChild;
      child != null && indexOf(child) > lastIndex;
      child = childBefore(child)
    ) {
      trailing++;
    }
    collectGarbage(leading, trailing);

    if (firstChild == null &&
        !addInitialChild(
          index: firstIndex,
          layoutOffset: heights.topOf(firstIndex),
        )) {
      geometry = SliverGeometry(
        scrollExtent: heights.total,
        maxPaintExtent: heights.total,
      );
      childManager.didFinishLayout();
      return;
    }

    RenderBox? previous;
    for (var line = indexOf(firstChild!) - 1; line >= firstIndex; line--) {
      layout.measure(line);
      final child = insertAndLayoutLeadingChild(_constraintsFor(line))!;
      _place(child, line);
      previous ??= child;
    }
    if (previous == null) {
      final line = indexOf(firstChild!);
      layout.measure(line);
      firstChild!.layout(_constraintsFor(line));
      _place(firstChild!, line);
      previous = firstChild;
    }
    for (var line = indexOf(previous!) + 1; line <= lastIndex; line++) {
      layout.measure(line);
      var child = childAfter(previous!);
      if (child == null || indexOf(child) != line) {
        child = insertAndLayoutChild(_constraintsFor(line), after: previous);
        if (child == null) break;
      } else {
        child.layout(_constraintsFor(line));
      }
      _place(child, line);
      previous = child;
    }

    final from = heights.topOf(indexOf(firstChild!));
    final to = heights.topOf(indexOf(lastChild!) + 1);
    final total = heights.total;
    geometry = SliverGeometry(
      scrollExtent: total,
      paintExtent: calculatePaintOffset(constraints, from: from, to: to),
      cacheExtent: calculateCacheOffset(constraints, from: from, to: to),
      maxPaintExtent: total,
      hasVisualOverflow: true,
    );
    _anchor = (line: first, top: firstTop);
    childManager.didFinishLayout();
  }
}

class _NoteLine extends MultiChildRenderObjectWidget {
  _NoteLine(this.layout, this.line, this.span)
    : super(
        children: WidgetSpan.extractFromInlineSpan(span.span, layout.scaler),
      );

  final NoteLayout layout;
  final int line;
  final LineSpan span;

  @override
  RenderNoteLine createRenderObject(BuildContext context) =>
      RenderNoteLine(layout, line, span);

  @override
  void updateRenderObject(BuildContext context, RenderNoteLine renderObject) {
    renderObject
      ..noteLayout = layout
      ..line = line
      ..span = span;
  }
}

/// One line of the note: its paragraph, and the widgets set in it.
class RenderNoteLine extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, TextParentData>,
        RenderInlineChildrenContainerDefaults {
  RenderNoteLine(this._noteLayout, this._line, this._span);

  NoteLayout _noteLayout;
  set noteLayout(NoteLayout value) {
    if (identical(value, _noteLayout)) return;
    _noteLayout = value;
    markNeedsLayout();
  }

  int _line;
  int get line => _line;
  set line(int value) {
    if (value == _line) return;
    _line = value;
    markNeedsLayout();
  }

  LineSpan _span;
  set span(LineSpan value) {
    if (identical(value, _span)) return;
    _span = value;
    markNeedsLayout();
  }

  TextPainter? _paragraph;

  /// The paragraph the line was last laid out with.
  TextPainter get paragraph => _paragraph!;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final paragraph = _paragraph = _noteLayout.paragraphOf(_line);
    var child = firstChild;
    for (final placeholder in _span.placeholders) {
      if (child == null) break;
      child.layout(BoxConstraints.tight(placeholder.size));
      child = childAfter(child);
    }
    positionInlineChildren(paragraph.inlinePlaceholderBoxes ?? const []);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paragraph!.paint(context.canvas, offset);
    paintInlineChildren(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      hitTestInlineChildren(result, position);

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      defaultApplyPaintTransform(child, transform);
}
