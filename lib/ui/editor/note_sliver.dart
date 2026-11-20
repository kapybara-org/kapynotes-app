import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle, LineMetrics;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import 'line_heights.dart';
import 'note_lines.dart';

/// What a line draws: its runs, and the size of each widget among them, in
/// the order they come. A [folded] line takes no room and draws nothing. A
/// line with a [row] is exactly that tall, in pixels at the note's own text
/// size, rather than as tall as the note's strut and its writing make it. A
/// line with an [inset] starts that far in from the column, and ends as far
/// short of it. A line that wraps starts its later rows under its character
/// at [hang], where its words begin after a list's marker or an indent.
typedef LineSpan = ({
  InlineSpan span,
  List<PlaceholderDimensions> placeholders,
  bool folded,
  double? row,
  double inset,
  int hang,
});

/// How the field draws its caret: [width] wide, [height] tall or a row of
/// the note's base style, with ends rounded by [radius], moved by [offset],
/// over the text or under it, and snapped to the pixels of a screen with
/// [pixelRatio] of them to a point.
typedef NoteCaret = ({
  double width,
  double? height,
  Radius? radius,
  Offset offset,
  bool aboveText,
  double pixelRatio,
});

/// What the lines draw besides their text: the selection, in
/// [selectionColor] while it shows, and the caret, in [caretColor] while it
/// shows. While [handles] are given, the lines holding the selection's ends
/// lead them, for the selection handles to follow.
typedef NoteMarks = ({
  TextSelection selection,
  Color? selectionColor,
  Color? caretColor,
  NoteCaret caret,
  ({LayerLink start, LayerLink end})? handles,
});

/// What a line shows past its writing, such as a calculation's result:
/// [child], centred on the line's last row, or on its first with [firstRow],
/// with its right edge at [right] in the line. When the writing on that row
/// runs too near, the child moves out past [right] after it, as far as the
/// line reaches, and covers the writing only once there's no room left.
/// [leader], when given, fills the space between the writing and the child.
/// Every row of the writing stops [room] short of the line's end, so that
/// the child never covers it; with none, the writing runs the full width.
typedef LineTrailing = ({
  Widget child,
  Widget? leader,
  double right,
  bool firstRow,
  double room,
});

/// The space a line keeps between its writing, the leader of what it shows
/// past the writing, and what it shows.
const double lineTrailingGap = 12;

/// Where a selection handle points in [paragraph], for the part of the
/// selection a line holds, [range], in the line's own offsets: under the
/// first or last box of it, or under the caret where it has none, as
/// [RenderEditable.getEndpointsForSelection] puts it, on a line [width] wide.
Offset handlePointIn(
  TextPainter paragraph,
  TextSelection range, {
  required bool start,
  required double width,
}) {
  if (!range.isCollapsed) {
    final boxes = paragraph.getBoxesForSelection(
      range,
      boxHeightStyle: BoxHeightStyle.strut,
    );
    if (boxes.isNotEmpty) {
      final box = start ? boxes.first : boxes.last;
      return Offset(
        clampDouble(start ? box.start : box.end, 0, math.max(width, 0)),
        box.bottom,
      );
    }
  }
  return paragraph.getOffsetForCaret(
        start ? range.base : range.extent,
        Rect.zero,
      ) +
      Offset(0, paragraph.preferredLineHeight);
}

/// Where the caret at [position] in [paragraph] is drawn, in the
/// paragraph's coordinates, as [RenderEditable.getLocalRectForCaret] puts
/// it, on a line [width] wide.
Rect caretRectIn(
  TextPainter paragraph,
  TextPosition position,
  NoteCaret caret,
  double width,
) {
  final height = caret.height ?? paragraph.preferredLineHeight;
  final apple = switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => true,
    _ => false,
  };
  final prototype = apple
      ? Rect.fromLTWH(0, 0, caret.width, height + 2)
      : Rect.fromLTWH(0, 2, caret.width, height - 4);
  var at = paragraph.getOffsetForCaret(position, prototype);
  // Past a run of hidden markdown at the end of a line, the engine puts the
  // caret before the last character shown. The character before the caret
  // says where it really is, when it sits on the caret's row.
  if (position.offset > 0) {
    final before = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: position.offset - 1,
        extentOffset: position.offset,
      ),
      boxHeightStyle: BoxHeightStyle.max,
    );
    if (before.isNotEmpty) {
      final box = before.last;
      final middle = at.dy + prototype.center.dy;
      if (middle >= box.top && middle <= box.bottom) {
        at = Offset(
          box.direction == TextDirection.ltr ? box.right : box.left,
          at.dy,
        );
      }
    }
  }
  final rect = prototype.shift(at + caret.offset);
  final left = clampDouble(rect.left, 0, math.max(width, 0));
  final full = paragraph.getFullHeightForCaret(position, prototype);
  return apple
      ? Rect.fromLTWH(
          left,
          rect.top + (full - rect.height) / 2,
          rect.width,
          rect.height,
        )
      : Rect.fromLTWH(
          left,
          rect.top - 2 + (full - height) / 2,
          rect.width,
          height,
        );
}

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
    this.caretRoom = 0,
  });

  final NoteLines lines;

  /// What a line draws.
  final LineSpan Function(int line) spanOf;

  /// The note's base style, which an empty line is laid out in.
  final TextStyle style;

  final StrutStyle strut;

  final TextScaler scaler;

  /// The room each row keeps at its end for the caret, when [columnWidth]
  /// is null.
  final double caretRoom;

  /// How wide the writing runs, when it's narrower than the lines: the room
  /// past it is for what lines show beside their writing. The lines' width
  /// less [caretRoom] when null.
  double? get columnWidth => _columnWidth;
  double? _columnWidth;
  set columnWidth(double? value) {
    if (value == _columnWidth) return;
    _columnWidth = value;
    _sliver?.markNeedsLayout();
  }

  /// What a line shows past its writing, built for the lines in view.
  LineTrailing? Function(int line)? trailingOf;

  /// Where the selection shows on a line that something other than its
  /// writing draws, such as a table's row: rects in the line's coordinates
  /// for the part of the selection it holds, [selected], in the line's own
  /// offsets. Null, or null for a line, to fill the writing's own boxes.
  List<Rect>? Function(int line, TextRange selected)? selectionOf;

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

  /// What the lines draw besides their text. Setting it repaints them.
  NoteMarks get marks => _marks;
  NoteMarks _marks = (
    selection: const TextSelection.collapsed(offset: -1),
    selectionColor: null,
    caretColor: null,
    caret: (
      width: 2,
      height: null,
      radius: null,
      offset: Offset.zero,
      aboveText: false,
      pixelRatio: 1,
    ),
    handles: null,
  );
  set marks(NoteMarks value) {
    if (value == _marks) return;
    _marks = value;
    _sliver?.markNeedsPaint();
  }

  /// How wide the writing runs, once the sliver has been laid out.
  double? get width => _width;

  /// A row of the note's base style.
  double get rowHeight => _row;

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
    final height = spanAt(line).folded ? 0.0 : paragraphOf(line).height;
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

  /// Scrolls [position] so that the note's last line ends at the bottom of
  /// the viewport, exactly, measuring the last screenful first. It scrolls
  /// as a jump does, so what follows the scroll offset follows this too.
  void jumpToEnd(ScrollPosition position) {
    final heights = _heights;
    final sliver = _sliver;
    if (heights == null || sliver == null) return;
    final constraints = sliver.constraints;
    final viewport = constraints.viewportMainAxisExtent;
    var covered = 0.0;
    for (var line = length - 1; line >= 0 && covered < viewport; line--) {
      covered += measure(line);
    }
    sliver._anchor = null;
    position.jumpTo(
      constraints.precedingScrollExtent + math.max(0, heights.total - viewport),
    );
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
    final width = math.max(0.0, _width! - (trailingOf?.call(line)?.room ?? 0));
    final key = _Drawn(
      drawn.span,
      drawn.placeholders,
      drawn.row,
      drawn.inset,
      drawn.hang,
      width,
    );
    final kept = _kept.remove(key);
    if (kept != null) return _kept[key] = kept;
    // In one paragraph of the whole note, an empty line takes its height
    // from its newline, in the base style. An empty paragraph would take the
    // paragraph style's instead.
    final text = lines[line].isEmpty
        ? TextSpan(text: ' ', style: style)
        : drawn.span;
    final strutStyle = drawn.row == null ? strut : _forced(drawn.row!);
    final painter =
        (drawn.inset == 0 && drawn.hang == 0
              ? TextPainter(
                  text: text,
                  textDirection: TextDirection.ltr,
                  strutStyle: strutStyle,
                  textScaler: scaler,
                )
              : InsetTextPainter(
                  // In pixels at the note's own size, so it grows with the
                  // editor's zoom as a forced row does, then with the text.
                  inset: scaler.scale(
                    drawn.inset *
                        strut.fontSize! *
                        strut.height! /
                        EditorMetrics.lineHeight,
                  ),
                  hang: drawn.hang,
                  text: text,
                  textDirection: TextDirection.ltr,
                  strutStyle: strutStyle,
                  textScaler: scaler,
                ))
          ..setPlaceholderDimensions(drawn.placeholders)
          ..layout(maxWidth: width);
    _kept[key] = painter;
    if (_kept.length > _keep) _kept.remove(_kept.keys.first);
    return painter;
  }

  /// The strut that makes a row exactly [row] tall, at the size the note's
  /// own strut gives a row of 28.
  StrutStyle _forced(double row) => StrutStyle(
    fontFamily: strut.fontFamily,
    fontFamilyFallback: strut.fontFamilyFallback,
    fontSize: strut.fontSize,
    height: row * strut.height! / EditorMetrics.lineHeight,
    forceStrutHeight: true,
    leading: 0,
  );

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
  const _Drawn(
    this.span,
    this.placeholders,
    this.row,
    this.inset,
    this.hang,
    this.width,
  );

  final InlineSpan span;
  final List<PlaceholderDimensions> placeholders;
  final double? row;
  final double inset;
  final int hang;
  final double width;

  @override
  bool operator ==(Object other) =>
      other is _Drawn &&
      other.span == span &&
      other.row == row &&
      other.inset == inset &&
      other.hang == hang &&
      other.width == width &&
      listEquals(other.placeholders, placeholders);

  @override
  int get hashCode =>
      Object.hash(span, row, inset, hang, width, Object.hashAll(placeholders));
}

/// A line's paragraph set [inset] in from both edges of its column: it wraps
/// [inset] short of each, and every place it is asked about or drawn is
/// [inset] right of where the paragraph under it puts it, so that the line
/// answers in its own, column coordinates, as a line with no inset does.
///
/// When the line wraps, its rows after the first also start under its
/// character at [hang], and wrap that much shorter, as a list item's do.
class InsetTextPainter extends TextPainter {
  InsetTextPainter({
    this.inset = 0,
    this.hang = 0,
    super.text,
    super.textDirection,
    super.strutStyle,
    super.textScaler,
  });

  final double inset;
  final int hang;

  /// How far right the rows after the first are moved, and where the first
  /// row ends, once laid out.
  double _hanging = 0;
  double _firstRowBottom = double.infinity;

  Offset get _in => Offset(inset, 0);

  double _shiftAt(double y) => inset + (y >= _firstRowBottom ? _hanging : 0);

  TextBox _shifted(TextBox box) {
    final dx = _shiftAt((box.top + box.bottom) / 2);
    return TextBox.fromLTRBD(
      box.left + dx,
      box.top,
      box.right + dx,
      box.bottom,
      box.direction,
    );
  }

  @override
  void layout({double minWidth = 0.0, double maxWidth = double.infinity}) {
    final min = math.max(0.0, minWidth - 2 * inset);
    final max = math.max(0.0, maxWidth - 2 * inset);
    _hanging = 0;
    _firstRowBottom = double.infinity;
    super.layout(minWidth: min, maxWidth: max);
    if (hang <= 0 || super.computeLineMetrics().length < 2) return;
    final hanging = super
        .getOffsetForCaret(TextPosition(offset: hang), Rect.zero)
        .dx;
    if (hanging <= 0 || hanging >= max / 2) return;
    super.layout(
      minWidth: math.max(0.0, min - hanging),
      maxWidth: max - hanging,
    );
    final first = super.computeLineMetrics().first;
    _hanging = hanging;
    _firstRowBottom = first.baseline + first.descent;
  }

  @override
  double get width => super.width + 2 * inset + _hanging;

  @override
  Size get size => Size(width, height);

  @override
  List<TextBox>? get inlinePlaceholderBoxes =>
      super.inlinePlaceholderBoxes?.map(_shifted).toList();

  @override
  void paint(Canvas canvas, Offset offset) {
    if (_hanging == 0) return super.paint(canvas, offset + _in);
    final split = offset.dy + _firstRowBottom;
    final far = Rect.largest;
    canvas
      ..save()
      ..clipRect(Rect.fromLTRB(far.left, far.top, far.right, split));
    super.paint(canvas, offset + _in);
    canvas
      ..restore()
      ..save()
      ..clipRect(Rect.fromLTRB(far.left, split, far.right, far.bottom));
    super.paint(canvas, offset + _in + Offset(_hanging, 0));
    canvas.restore();
  }

  @override
  TextPosition getPositionForOffset(Offset offset) =>
      super.getPositionForOffset(offset - Offset(_shiftAt(offset.dy), 0));

  @override
  Offset getOffsetForCaret(TextPosition position, Rect caretPrototype) {
    final at = super.getOffsetForCaret(position, caretPrototype);
    return at + Offset(_shiftAt(at.dy + caretPrototype.height / 2 + 1), 0);
  }

  @override
  List<TextBox> getBoxesForSelection(
    TextSelection selection, {
    BoxHeightStyle boxHeightStyle = BoxHeightStyle.tight,
    BoxWidthStyle boxWidthStyle = BoxWidthStyle.tight,
  }) => [
    for (final box in super.getBoxesForSelection(
      selection,
      boxHeightStyle: boxHeightStyle,
      boxWidthStyle: boxWidthStyle,
    ))
      _shifted(box),
  ];

  @override
  List<LineMetrics> computeLineMetrics() => [
    for (final line in super.computeLineMetrics())
      LineMetrics(
        hardBreak: line.hardBreak,
        ascent: line.ascent,
        descent: line.descent,
        unscaledAscent: line.unscaledAscent,
        height: line.height,
        width: line.width,
        left: line.left + inset + (line.lineNumber > 0 ? _hanging : 0),
        baseline: line.baseline,
        lineNumber: line.lineNumber,
      ),
  ];
}

/// The note's lines in a scroll view, each one a widget of its own, laid
/// out only where they show: in the viewport and its cache extent.
class NoteSliver extends SliverMultiBoxAdaptorWidget {
  NoteSliver({super.key, required this.layout})
    : super(
        delegate: SliverChildBuilderDelegate(
          (context, line) => _NoteLine(
            layout,
            line,
            layout.spanAt(line),
            layout.trailingOf?.call(line),
          ),
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
    final layout = _noteLayout
      .._setWidth(
        _noteLayout.columnWidth ??
            math.max(0.0, constraints.crossAxisExtent - _noteLayout.caretRoom),
      );
    final heights = layout._heights!;
    final count = heights.length;
    assert(count == layout.length, 'The note was edited without edited().');

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
  _NoteLine(this.layout, this.line, this.span, this.trailing)
    : super(
        children: [
          ...WidgetSpan.extractFromInlineSpan(span.span, layout.scaler),
          ?trailing?.leader,
          ?trailing?.child,
        ],
      );

  final NoteLayout layout;
  final int line;
  final LineSpan span;
  final LineTrailing? trailing;

  LineTrailingPlacement? get _placement => switch (trailing) {
    null => null,
    final trailing => (
      right: trailing.right,
      firstRow: trailing.firstRow,
      leader: trailing.leader != null,
    ),
  };

  @override
  RenderNoteLine createRenderObject(BuildContext context) =>
      RenderNoteLine(layout, line, span, _placement);

  @override
  void updateRenderObject(BuildContext context, RenderNoteLine renderObject) {
    renderObject
      ..noteLayout = layout
      ..line = line
      ..span = span
      ..trailing = _placement;
  }
}

/// Where a line puts what it shows past its writing; see [LineTrailing].
typedef LineTrailingPlacement = ({double right, bool firstRow, bool leader});

/// One line of the note: its paragraph, the widgets set in it, and what it
/// shows past its writing, which comes after them among its children.
class RenderNoteLine extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, TextParentData>,
        RenderInlineChildrenContainerDefaults {
  RenderNoteLine(this._noteLayout, this._line, this._span, this._trailing);

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
    _widgets = null;
    markNeedsLayout();
  }

  /// Where each widget set in the line sits among its characters, in the
  /// order they come.
  List<int> get _widgetOffsets => _widgets ??= () {
    if (_span.placeholders.isEmpty) return const <int>[];
    final offsets = <int>[];
    var at = 0;
    _span.span.visitChildren((span) {
      if (span is PlaceholderSpan) {
        offsets.add(at++);
      } else if (span is TextSpan) {
        at += span.text?.length ?? 0;
      }
      return true;
    });
    return offsets;
  }();
  List<int>? _widgets;

  LineTrailingPlacement? _trailing;
  set trailing(LineTrailingPlacement? value) {
    if (value == _trailing) return;
    _trailing = value;
    markNeedsLayout();
  }

  /// What the line shows past its writing, and the leader to it, and where
  /// each is, once laid out.
  RenderBox? get _trailingChild => _trailing == null ? null : lastChild;
  RenderBox? get _leaderChild =>
      _trailing?.leader ?? false ? childBefore(lastChild!) : null;
  Offset? _trailingAt;
  Offset? _leaderAt;

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
    // As a paragraph lays its inline widgets out: as wide as the line at
    // most, and as tall as they like.
    final inline = BoxConstraints(maxWidth: _noteLayout.width!);
    var child = firstChild;
    for (var i = 0; i < _span.placeholders.length && child != null; i++) {
      child.layout(inline);
      child = childAfter(child);
    }
    positionInlineChildren(paragraph.inlinePlaceholderBoxes ?? const []);
    _layOutTrailing(paragraph);
  }

  void _layOutTrailing(TextPainter paragraph) {
    final trailing = _trailing;
    final child = _trailingChild;
    if (trailing == null || child == null) return;
    child.layout(BoxConstraints(maxWidth: size.width), parentUsesSize: true);
    final row = _row(paragraph, first: trailing.firstRow);
    final start = row.right + lineTrailingGap;
    final width = child.size.width;
    var left = trailing.right - width;
    if (left < start) left = math.min(start, size.width - width);
    left = math.max(0.0, left);
    _trailingAt = Offset(left, row.top + (row.height - child.size.height) / 2);
    final leader = _leaderChild;
    if (leader == null) return;
    leader.layout(
      BoxConstraints.tight(
        Size(math.max(0.0, left - lineTrailingGap - start), row.height),
      ),
    );
    _leaderAt = Offset(start, row.top);
  }

  /// The line's first or last row: as tall as the row, and as wide as the
  /// writing on it.
  Rect _row(TextPainter paragraph, {required bool first}) {
    final length = _noteLayout.lines[_line].length;
    final boxes = length == 0
        ? const <TextBox>[]
        : paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: length),
            boxHeightStyle: BoxHeightStyle.max,
          );
    if (boxes.isEmpty) {
      return Rect.fromLTWH(0, 0, 0, paragraph.preferredLineHeight);
    }
    final top = boxes.map((box) => box.top).reduce(first ? math.min : math.max);
    final row = boxes.where((box) => (box.top - top).abs() < 0.5);
    return Rect.fromLTRB(
      row.map((box) => box.left).reduce(math.min),
      top,
      row.map((box) => box.right).reduce(math.max),
      row.map((box) => box.bottom).reduce(math.max),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_span.folded) return;
    final layout = _noteLayout;
    final marks = layout.marks;
    final paragraph = _paragraph!;
    final start = layout.lines.startOf(_line);
    final end = start + layout.lines[_line].length;
    final selection = marks.selection;
    final selectionColor = marks.selectionColor;
    final fill =
        selectionColor != null &&
            selection.isValid &&
            selection.start <= end &&
            selection.end > start
        ? (Paint()..color = selectionColor)
        : null;
    final selectedWidgets = fill == null
        ? const <({int widget, Rect? row})>[]
        : _paintSelection(
            context.canvas,
            offset,
            math.max(selection.start, start) - start,
            math.min(selection.end, end) - start,
            fill,
          );
    final caretColor = marks.caretColor;
    final extent = selection.extentOffset;
    final caret =
        caretColor != null &&
            selection.isValid &&
            selection.isCollapsed &&
            extent >= start &&
            extent <= end
        ? caretRectIn(
            paragraph,
            TextPosition(offset: extent - start, affinity: selection.affinity),
            marks.caret,
            layout.width!,
          )
        : null;
    if (caret != null && !marks.caret.aboveText) {
      _paintCaret(context.canvas, caret, offset, marks.caret, caretColor!);
    }
    paragraph.paint(context.canvas, offset);
    paintInlineChildren(context, offset);
    // A widget draws over whatever is under it, so the selection over one
    // is drawn after it, as far as the widget reaches: no taller than its
    // row when it shares the line with writing.
    var child = firstChild;
    var index = 0;
    for (final (:widget, :row) in selectedWidgets) {
      for (; index < widget; index++) {
        child = childAfter(child!);
      }
      final at = (child!.parentData! as TextParentData).offset;
      if (at == null) continue;
      final drawn = at & child.size;
      context.canvas.drawRect(
        (row == null
                ? drawn
                : Rect.fromLTRB(
                    math.min(row.left, drawn.left),
                    row.top,
                    math.max(row.right, drawn.right),
                    row.bottom,
                  ))
            .shift(offset),
        fill!,
      );
    }
    if (caret != null && marks.caret.aboveText) {
      _paintCaret(context.canvas, caret, offset, marks.caret, caretColor!);
    }
    if (_leaderChild case final leader?) {
      context.paintChild(leader, offset + _leaderAt!);
    }
    if (_trailingChild case final child?) {
      context.paintChild(child, offset + _trailingAt!);
    }
    final handles = marks.handles;
    if (handles == null || !selection.isValid) return;
    void lead(LayerLink link, {required bool first}) {
      final range = TextSelection(
        baseOffset: math.max(selection.start, start) - start,
        extentOffset: math.min(selection.end, end) - start,
        affinity: selection.affinity,
      );
      context.pushLayer(
        LeaderLayer(
          link: link,
          offset:
              offset +
              handlePointIn(
                paragraph,
                range,
                start: first,
                width: layout.width!,
              ),
        ),
        (context, offset) {},
        Offset.zero,
      );
    }

    if (selection.start >= start && selection.start <= end) {
      lead(handles.start, first: true);
    }
    if (selection.end >= start && selection.end <= end) {
      lead(handles.end, first: false);
    }
  }

  /// Fills the selection under the line's writing, from [from] to [to] in
  /// the line's own offsets, and answers which of the widgets set in the line
  /// it holds, by their place among them, and the row each stands on where
  /// the line holds writing as well.
  List<({int widget, Rect? row})> _paintSelection(
    Canvas canvas,
    Offset offset,
    int from,
    int to,
    Paint fill,
  ) {
    final layout = _noteLayout;
    final paragraph = _paragraph!;
    final length = layout.lines[_line].length;
    if (from == to) {
      // A blank line shows its line break selected as a selected space,
      // which is how its paragraph is laid out.
      if (length == 0 && _line < layout.length - 1) {
        for (final box in paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
          boxHeightStyle: BoxHeightStyle.strut,
        )) {
          canvas.drawRect(box.toRect().shift(offset), fill);
        }
      }
      return const [];
    }
    final drawn = layout.selectionOf?.call(
      _line,
      TextRange(start: from, end: to),
    );
    if (drawn != null) {
      for (final rect in drawn) {
        canvas.drawRect(rect.shift(offset), fill);
      }
      return const [];
    }
    final widgets = _widgetOffsets;
    final held = <({int widget, Rect? row})>[];
    final alone = widgets.length == length;
    var shown = false;
    var at = from;
    void fillWriting(int until) {
      if (at >= until) return;
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: at, extentOffset: until),
        boxHeightStyle: BoxHeightStyle.strut,
      )) {
        final rect = box.toRect();
        shown |= rect.width >= 1;
        canvas.drawRect(rect.shift(offset), fill);
      }
    }

    for (var i = 0; i < widgets.length && widgets[i] < to; i++) {
      if (widgets[i] < from) continue;
      fillWriting(widgets[i]);
      final boxes = alone
          ? const <TextBox>[]
          : paragraph.getBoxesForSelection(
              TextSelection(
                baseOffset: widgets[i],
                extentOffset: widgets[i] + 1,
              ),
              boxHeightStyle: BoxHeightStyle.strut,
            );
      held.add((
        widget: i,
        row: boxes.isEmpty
            ? null
            : boxes
                  .map((box) => box.toRect())
                  .reduce((a, b) => a.expandToInclude(b)),
      ));
      at = widgets[i] + 1;
    }
    fillWriting(to);
    // A line whose writing is all hidden, such as a rule drawn in its place,
    // shows selected across the column once the whole of it is.
    if (!shown && held.isEmpty && from == 0 && to == length) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, layout.width!, size.height).shift(offset),
        fill,
      );
    }
    return held;
  }

  /// Draws the caret at [rect], snapped to the screen's pixels as
  /// [RenderEditable] snaps it.
  void _paintCaret(
    Canvas canvas,
    Rect rect,
    Offset offset,
    NoteCaret caret,
    Color color,
  ) {
    final global = localToGlobal(rect.topLeft);
    final pixel = 1 / caret.pixelRatio;
    final snapped = rect.shift(
      offset +
          Offset(
            (global.dx / pixel).round() * pixel - global.dx,
            (global.dy / pixel).round() * pixel - global.dy,
          ),
    );
    final fill = Paint()..color = color;
    final radius = caret.radius;
    if (radius == null) {
      canvas.drawRect(snapped, fill);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(snapped, radius), fill);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final trailing = _trailingChild;
    final at = _trailingAt;
    if (trailing != null &&
        at != null &&
        result.addWithPaintOffset(
          offset: at,
          position: position,
          hitTest: (result, position) =>
              trailing.hitTest(result, position: position),
        )) {
      return true;
    }
    return hitTestInlineChildren(result, position);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final at = identical(child, _trailingChild)
        ? _trailingAt
        : identical(child, _leaderChild)
        ? _leaderAt
        : null;
    if (at == null) return defaultApplyPaintTransform(child, transform);
    transform.translateByDouble(at.dx, at.dy, 0, 1);
  }
}
