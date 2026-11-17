// HIS-14 spike B: a note sliver that lays out only the lines in view.
//
// A throwaway prototype for the per-line editor's viewport. It is measured by
// benchmark/spike_b_viewport.dart and tested in test/spike_b/; the findings
// are in the KAPY-5 handoff, spike-b-viewport.md.
//
// * Every visible line is a widget of its own whose render object paints one
//   cached paragraph. The paragraph cache is keyed by the line's text and its
//   place in a code fence or display formula, and cleared when the width
//   changes; the style is fixed per cache.
// * The sliver finds lines from scroll offsets, and the reverse, through a
//   Fenwick tree over line heights. A line nobody has laid out yet has an
//   estimated height, from its length and the column width.
// * When a line above the first visible one is measured and its height is not
//   the estimate, the sliver corrects the scroll offset by the difference, so
//   the first visible line stays where it is on screen.
// * A jump to the end measures the last screenful of lines first, then lands
//   the scroll offset so that the last line ends exactly at the bottom.
//
// Each line's spans come from the editor's own rules, run on that line alone:
// the real MarkdownAnalyzer, Highlighter and CodeHighlighter, and a port of
// HighlightingController.buildTextSpan's segment loop. A code fence or a
// display formula gives its lines their context through one cheap pass over
// the note. Formulas are drawn as their TeX in code's face, the way the editor
// shows a formula the caret is on.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/rendering.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/note_link.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/code_highlighting.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';
import 'package:kapy_notes/ui/editor/markdown_syntax.dart';
import 'package:material_ui/material_ui.dart';

/// Line heights in a Fenwick tree: a line's top from its index, and the line
/// at a scroll offset, each in O(log n).
class HeightIndex {
  HeightIndex(List<double> heights)
    : _heights = Float64List.fromList(heights),
      _tree = Float64List(heights.length + 1),
      _measured = Uint8List(heights.length) {
    final n = heights.length;
    for (var i = 1; i <= n; i++) {
      _tree[i] += heights[i - 1];
      final parent = i + (i & -i);
      if (parent <= n) _tree[parent] += _tree[i];
    }
    var step = 1;
    while (step * 2 <= n) {
      step *= 2;
    }
    _topStep = step;
  }

  final Float64List _heights;
  final Float64List _tree;
  final Uint8List _measured;
  late final int _topStep;
  int _measuredCount = 0;

  int get length => _heights.length;
  int get measuredCount => _measuredCount;
  double heightOf(int line) => _heights[line];
  bool isMeasured(int line) => _measured[line] != 0;

  /// The sum of the heights of the lines before [line], which may be
  /// [length].
  double topOf(int line) {
    var sum = 0.0;
    for (var i = line; i > 0; i -= i & -i) {
      sum += _tree[i];
    }
    return sum;
  }

  double get total => topOf(length);

  /// The line [offset] falls in: the last line whose top is at or above it,
  /// clamped to the note.
  int lineAt(double offset) {
    final n = length;
    if (n == 0) return 0;
    var position = 0;
    var remaining = offset;
    for (var step = _topStep; step > 0; step >>= 1) {
      final next = position + step;
      if (next <= n && _tree[next] <= remaining) {
        position = next;
        remaining -= _tree[next];
      }
    }
    return math.min(position, n - 1);
  }

  /// Sets [line]'s height; [measured] says it is a real height rather than an
  /// estimate.
  void setHeight(int line, double height, {bool measured = true}) {
    if (measured && _measured[line] == 0) {
      _measured[line] = 1;
      _measuredCount++;
    }
    final delta = height - _heights[line];
    if (delta == 0) return;
    _heights[line] = height;
    for (var i = line + 1; i <= length; i += i & -i) {
      _tree[i] += delta;
    }
  }
}

/// Where a line sits in the blocks that span lines: the line that opens a
/// code fence or a display formula, a line inside one, the line that closes
/// it, or none of these.
enum LineRole { plain, open, body, close }

/// A line's role, and the line that opened its block.
typedef LineKind = ({LineRole role, String opener});

const LineKind plainLine = (role: LineRole.plain, opener: '');

const _fence = '```';

/// One pass over the note that finds its code fences and display formulas,
/// which is all the context a line's own analysis needs from the others.
List<LineKind> classifyLines(List<String> lines) {
  final kinds = List<LineKind>.filled(lines.length, plainLine);
  String? opener;
  var fence = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    final indent = line.length - trimmed.length;
    if (opener == null) {
      if (indent <= 3 && trimmed.startsWith(_fence)) {
        opener = line;
        fence = true;
        kinds[i] = (role: LineRole.open, opener: line);
      } else if (trimmed.trimRight() == r'$$') {
        opener = r'$$';
        fence = false;
        kinds[i] = (role: LineRole.open, opener: r'$$');
      }
      continue;
    }
    final closes = fence
        ? indent <= 3 &&
              trimmed.startsWith(_fence) &&
              trimmed.substring(3).trim().isEmpty
        : trimmed.trimRight() == r'$$';
    kinds[i] = (role: closes ? LineRole.close : LineRole.body, opener: opener);
    if (closes) opener = null;
  }
  return kinds;
}

/// Builds one line's spans with the editor's own rules, and estimates the
/// height of a line nobody has laid out yet.
class LineStyler {
  LineStyler({
    required this.base,
    required this.strut,
    required this.palette,
    required this.linkColor,
    required this.highlighter,
    this.writingFont = WritingFont.handwritten,
    this.scaler = TextScaler.noScaling,
  });

  /// The editor's style as it is about to ship: KAPY-12's weight 500, the
  /// handwritten face, and the strut a note with formulas gets.
  factory LineStyler.of(BuildContext context, Highlighter highlighter) {
    final palette = context.palette;
    return LineStyler(
      base: EditorMetrics.textStyle(
        palette.textPrimary,
        WritingFont.handwritten,
      ).copyWith(fontWeight: FontWeight.w500),
      strut: EditorMetrics.strut(WritingFont.handwritten, allowTallRows: true),
      palette: palette,
      linkColor: Theme.of(context).colorScheme.primary,
      highlighter: highlighter,
      scaler: MediaQuery.textScalerOf(context),
    );
  }

  final TextStyle base;
  final StrutStyle strut;
  final CalcPalette palette;
  final Color linkColor;
  final Highlighter highlighter;
  final WritingFont writingFont;
  final TextScaler scaler;

  final MarkdownAnalyzer _analyzer = MarkdownAnalyzer();
  final CodeHighlighter _codeHighlighter = CodeHighlighter();

  double get rowHeight => scaler.scale(EditorMetrics.lineHeight);

  late final double _textAdvance = _averageAdvance(base);
  late final double _codeAdvance = _averageAdvance(_codeStyle(base));

  double _averageAdvance(TextStyle style) {
    const sample =
        'Plain prose for section 15, line 100, with a total of 4 + 5 in it. '
        'The quick brown fox jumps over the lazy dog.';
    final painter = TextPainter(
      text: TextSpan(text: sample, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width / sample.length;
  }

  /// A guess at [line]'s height in a column [width] wide: as many rows as its
  /// characters fill at an average advance.
  double estimate(String line, LineKind kind, double width) {
    if (line.isEmpty) return rowHeight;
    final code = kind.role != LineRole.plain;
    var advance = code ? _codeAdvance : _textAdvance;
    if (!code && line.startsWith('#')) advance *= 1.18;
    final rows = (line.length * advance / width).ceil();
    return math.max(1, rows) * rowHeight;
  }

  /// The text [line] is analysed in: the line itself, or the line inside the
  /// block that holds it, and where the line starts in that text.
  static ({String text, int from}) _window(String line, LineKind kind) {
    final closer = kind.opener == r'$$' ? r'$$' : _fence;
    switch (kind.role) {
      case LineRole.plain:
        return (text: line, from: 0);
      case LineRole.open:
        return (text: '$line\nx\n$closer', from: 0);
      case LineRole.body:
        final head = '${kind.opener}\n';
        return (text: '$head$line\n$closer', from: head.length);
      case LineRole.close:
        final head = '${kind.opener}\nx\n';
        return (text: '$head$line', from: head.length);
    }
  }

  /// [line] as the editor draws it with the caret elsewhere: markers hidden,
  /// formulas as their TeX.
  TextSpan spanFor(String line, LineKind kind) {
    if (line.isEmpty) return TextSpan(style: base, text: '');
    final window = _window(line, kind);
    final source = window.text;
    final from = window.from;
    final to = from + line.length;

    final analysis = _analyzer.analyze(source);
    final view = analysis.calculatorText;
    final webLinks = findNoteLinks(view);
    final links = analysis.linksWith(webLinks);
    final spans = highlighter.spans(view, links: webLinks);
    final markdownSpans = analysis.spans;
    final concealment = analysis.concealFor(
      null,
      revealBlocks: false,
      revealEdges: false,
      drawable: (_) => false,
    );
    final hidden = concealment.hidden;
    final transparent = concealment.transparent;
    final stretches = _listStretches(analysis);
    final code = analysis.fencedCode.isEmpty
        ? const <CodeToken>[]
        : _codeHighlighter.tokensIn(analysis.text, analysis.fencedCode);

    final boundaries = <int>{from, to};
    void cut(int at) {
      if (at > from && at < to) boundaries.add(at);
    }

    for (final span in spans) {
      cut(span.start);
      cut(span.end);
    }
    for (final link in links) {
      cut(link.start);
      cut(link.end);
    }
    for (final span in markdownSpans) {
      cut(span.start);
      cut(span.end);
    }
    for (final range in [...hidden, ...transparent]) {
      cut(range.start);
      cut(range.end);
    }
    for (final stretch in stretches) {
      cut(stretch.start);
      cut(stretch.end);
    }
    for (final token in code) {
      cut(token.start);
      cut(token.end);
    }

    final cuts = boundaries.toList()..sort();
    final children = <InlineSpan>[];
    var spanIndex = 0;
    var linkIndex = 0;
    var markdownIndex = 0;
    final openMarkdown = <MarkdownSpan>[];
    var hiddenIndex = 0;
    var transparentIndex = 0;
    var stretchIndex = 0;
    var codeIndex = 0;

    for (var i = 0; i < cuts.length - 1; i++) {
      final start = cuts[i];
      final end = cuts[i + 1];
      if (end <= start) continue;

      while (hiddenIndex < hidden.length && hidden[hiddenIndex].end <= start) {
        hiddenIndex++;
      }
      final concealed =
          hiddenIndex < hidden.length && hidden[hiddenIndex].start <= start;
      while (transparentIndex < transparent.length &&
          transparent[transparentIndex].end <= start) {
        transparentIndex++;
      }
      final unpainted =
          transparentIndex < transparent.length &&
          transparent[transparentIndex].start <= start;
      while (stretchIndex < stretches.length &&
          stretches[stretchIndex].end <= start) {
        stretchIndex++;
      }
      final stretch =
          stretchIndex < stretches.length &&
              stretches[stretchIndex].start <= start
          ? stretches[stretchIndex]
          : null;

      while (markdownIndex < markdownSpans.length &&
          markdownSpans[markdownIndex].start <= start) {
        openMarkdown.add(markdownSpans[markdownIndex++]);
      }
      openMarkdown.removeWhere((span) => span.end <= start);
      var markdown = 0;
      for (final span in openMarkdown) {
        markdown |= 1 << span.style.index;
      }
      bool marked(MarkdownStyle style) => markdown & (1 << style.index) != 0;

      while (spanIndex < spans.length && spans[spanIndex].end <= start) {
        spanIndex++;
      }
      final active =
          spanIndex < spans.length &&
              spans[spanIndex].start <= start &&
              spans[spanIndex].end >= end
          ? spans[spanIndex]
          : null;
      while (linkIndex < links.length && links[linkIndex].end <= start) {
        linkIndex++;
      }
      final activeLink =
          linkIndex < links.length &&
              links[linkIndex].start <= start &&
              links[linkIndex].end >= end
          ? links[linkIndex]
          : null;

      final literal =
          marked(MarkdownStyle.code) ||
          marked(MarkdownStyle.codeBlock) ||
          marked(MarkdownStyle.html);
      var segmentStyle = active == null || literal
          ? base
          : base.merge(_styleFor(active.kind));
      final segmentLinkColor = active?.kind == HighlightKind.comment
          ? palette.comment
          : linkColor;
      if (markdown != 0) {
        segmentStyle = _markdownBlockStyle(segmentStyle, marked);
      }
      while (codeIndex < code.length && code[codeIndex].end <= start) {
        codeIndex++;
      }
      if (codeIndex < code.length && code[codeIndex].start <= start) {
        segmentStyle = segmentStyle.merge(
          _codeTokenStyle(code[codeIndex].kind),
        );
      }
      if (markdown != 0) {
        final script = openMarkdown
            .where(
              (span) =>
                  span.style == MarkdownStyle.superscript ||
                  span.style == MarkdownStyle.subscript,
            )
            .lastOrNull;
        segmentStyle = _markdownInlineStyle(
          segmentStyle,
          marked,
          segmentLinkColor,
          script == null ? '' : source.substring(script.start, script.end),
        );
      }
      final done = marked(MarkdownStyle.doneTask);
      if (activeLink != null) {
        segmentStyle = segmentStyle.copyWith(
          color: segmentLinkColor,
          decoration: TextDecoration.none,
        );
      }
      if (done) {
        segmentStyle = segmentStyle.copyWith(
          color: palette.comment,
          decoration: TextDecoration.lineThrough,
          decorationColor: palette.comment,
        );
      }
      if (marked(MarkdownStyle.syntax)) {
        segmentStyle = segmentStyle.copyWith(color: palette.textTertiary);
      }
      if (concealed) {
        segmentStyle = segmentStyle.copyWith(
          fontSize: _hiddenFontSize,
          color: const Color(0x00000000),
          decoration: TextDecoration.none,
        );
      } else {
        if (unpainted) {
          segmentStyle = segmentStyle.copyWith(
            color: const Color(0x00000000),
            decorationColor: const Color(0x00000000),
          );
        }
        if (stretch != null) {
          segmentStyle = segmentStyle.copyWith(letterSpacing: stretch.spacing);
        }
      }
      children.add(
        TextSpan(text: source.substring(start, end), style: segmentStyle),
      );
    }
    return TextSpan(style: base, children: children);
  }

  static const double _hiddenFontSize = 0.01;

  static const _headingLevels = [
    MarkdownStyle.heading1,
    MarkdownStyle.heading2,
    MarkdownStyle.heading3,
    MarkdownStyle.heading4,
    MarkdownStyle.heading5,
    MarkdownStyle.heading6,
  ];

  TextStyle _markdownBlockStyle(
    TextStyle style,
    bool Function(MarkdownStyle) marked,
  ) {
    var result = style;
    for (var level = 1; level <= _headingLevels.length; level++) {
      if (!marked(_headingLevels[level - 1])) continue;
      result = markdownHeadingStyle(
        result,
        level,
        writingFont: writingFont,
        primaryColor: base.color,
        secondaryColor: palette.textSecondary,
      );
      break;
    }
    if (marked(MarkdownStyle.quote)) {
      result = result.copyWith(color: palette.textSecondary);
    }
    if (marked(MarkdownStyle.codeBlock) ||
        marked(MarkdownStyle.code) ||
        marked(MarkdownStyle.math)) {
      result = _codeStyle(result);
    }
    return result;
  }

  TextStyle _codeStyle(TextStyle style) {
    const mono = WritingFont.monospace;
    final size = style.fontSize;
    final height = style.height;
    final codeSize = size == null
        ? null
        : size * mono.editorSize / writingFont.editorSize;
    return style.copyWith(
      fontFamily: mono.fontFamily,
      fontFamilyFallback: mono.fontFamilyFallback,
      fontVariations: const [],
      fontSize: codeSize,
      height: codeSize == null || size == null || height == null
          ? height
          : size * height / codeSize,
    );
  }

  TextStyle _markdownInlineStyle(
    TextStyle style,
    bool Function(MarkdownStyle) marked,
    Color linkColor,
    String script,
  ) {
    var result = style;
    if (marked(MarkdownStyle.strong) || marked(MarkdownStyle.tableHeader)) {
      result = result.copyWith(fontWeight: FontWeight.w700);
    }
    if (marked(MarkdownStyle.emphasis)) {
      result = result.copyWith(fontStyle: FontStyle.italic);
    }
    final lines = [
      if (marked(MarkdownStyle.underline)) TextDecoration.underline,
      if (marked(MarkdownStyle.strikethrough)) TextDecoration.lineThrough,
    ];
    if (lines.isNotEmpty) {
      result = result.copyWith(
        decoration: TextDecoration.combine(lines),
        decorationColor: result.color,
      );
    }
    if (marked(MarkdownStyle.superscript) || marked(MarkdownStyle.subscript)) {
      result = _scripted(
        result,
        script,
        superscript: marked(MarkdownStyle.superscript),
      );
    }
    if (marked(MarkdownStyle.link)) {
      result = result.copyWith(color: linkColor);
    }
    if (marked(MarkdownStyle.listMarker) || marked(MarkdownStyle.taskBox)) {
      result = result.copyWith(color: palette.textSecondary);
    }
    if (marked(MarkdownStyle.html)) {
      result = result.copyWith(color: palette.comment);
    }
    return result;
  }

  TextStyle _scripted(
    TextStyle style,
    String script, {
    required bool superscript,
  }) {
    final (feature, drawn) = switch (style.fontFamily) {
      'Shantell Sans' => (superscript ? 'sups' : 'sinf', _digits),
      '.AppleSystemUIFont' => (
        superscript ? 'sups' : 'subs',
        _appleScriptCharacters,
      ),
      _ => (null, const <int>{}),
    };
    if (feature != null &&
        script.trim().isNotEmpty &&
        script.runes.every((rune) => rune == 0x20 || drawn.contains(rune))) {
      return style.copyWith(
        fontFeatures: [...?style.fontFeatures, FontFeature.enable(feature)],
      );
    }
    final size = style.fontSize;
    final height = style.height;
    if (size == null) return style;
    return style.copyWith(
      fontSize: size * 0.75,
      height: height == null ? null : height / 0.75,
    );
  }

  static final _digits = '0123456789'.runes.toSet();
  static final _appleScriptCharacters =
      '0123456789abcdefghijklmnopqrstuvwxyz+=()'.runes.toSet();

  TextStyle _codeTokenStyle(CodeTokenKind kind) => switch (kind) {
    CodeTokenKind.keyword => TextStyle(color: palette.keyword),
    CodeTokenKind.string => TextStyle(color: palette.chipCurrency),
    CodeTokenKind.number => TextStyle(color: palette.number),
    CodeTokenKind.comment => TextStyle(
      color: palette.comment,
      fontStyle: FontStyle.italic,
    ),
    CodeTokenKind.title => TextStyle(color: palette.function),
    CodeTokenKind.type ||
    CodeTokenKind.attribute => TextStyle(color: palette.unit),
    CodeTokenKind.variable => TextStyle(color: palette.variable),
    CodeTokenKind.punctuation => TextStyle(color: palette.operator),
  };

  TextStyle _styleFor(HighlightKind kind) => switch (kind) {
    HighlightKind.number ||
    HighlightKind.constant => TextStyle(color: palette.number),
    HighlightKind.keyword ||
    HighlightKind.aggregate => TextStyle(color: palette.keyword),
    HighlightKind.unit => TextStyle(color: palette.unit),
    HighlightKind.currency => TextStyle(color: palette.currency),
    HighlightKind.function => TextStyle(color: palette.function),
    HighlightKind.variable => TextStyle(color: palette.variable),
    HighlightKind.operator ||
    HighlightKind.punctuation => TextStyle(color: palette.operator),
    HighlightKind.comment => TextStyle(
      color: palette.comment,
      fontStyle: FontStyle.italic,
    ),
    HighlightKind.plain => const TextStyle(),
  };

  final Map<String, double> _advances = {};

  double _advance(String text) {
    if (text.isEmpty) return 0;
    final known = _advances[text];
    if (known != null) return known;
    if (_advances.length > 256) _advances.clear();
    final painter = TextPainter(
      text: TextSpan(text: text, style: base),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter
        .getOffsetForCaret(TextPosition(offset: text.length), Rect.zero)
        .dx;
    painter.dispose();
    return _advances[text] = width;
  }

  late final double _markerRoom = math.max(
    scaler.scale(markdownMarkerMinRoom),
    _advance('8. '),
  );

  List<({int start, int end, double spacing})> _listStretches(
    MarkdownAnalysis analysis,
  ) {
    if (analysis.listItems.isEmpty) return const [];
    final text = analysis.text;
    final room = _markerRoom;
    double advance(int start, int end) =>
        end <= start ? 0 : _advance(text.substring(start, end));
    final stretches = <({int start, int end, double spacing})>[];
    void stretch(int start, int end, double width, {bool lineStart = false}) {
      if (end <= start) return;
      final letters = end - start + (lineStart ? 0.5 : 0);
      final spacing = (width - advance(start, end)) / letters;
      if (spacing.abs() >= 0.01) {
        stretches.add((start: start, end: end, spacing: spacing));
      }
    }

    for (final item in analysis.listItems) {
      if (!item.quoted && item.markerStart > item.lineStart) {
        stretch(
          item.lineStart,
          item.markerStart,
          room * item.depth,
          lineStart: true,
        );
      }
      final box = item.box;
      if (box != null) {
        stretch(box, box + 3, room - advance(box + 3, item.wordsStart));
      } else if (item.ordered) {
        final number = advance(item.markerStart, item.markerEnd);
        final natural = advance(item.markerEnd, item.wordsStart);
        if (number + natural < room) {
          stretch(item.markerEnd, item.wordsStart, room - number);
        }
      } else {
        stretch(
          item.markerStart,
          item.markerEnd,
          room - advance(item.markerEnd, item.wordsStart),
          lineStart: item.markerStart == item.lineStart,
        );
      }
    }
    return stretches;
  }
}

/// One laid-out paragraph per line, least recently used dropped first.
///
/// Keyed by the line's text and kind; the width is checked on every lookup
/// and clears the cache when it changes, and the style is fixed per cache.
/// A dropped paragraph is left to the garbage collector rather than disposed,
/// because a line's render object may still hold it.
class LineLayoutCache {
  LineLayoutCache(this.styler, {this.capacity = 2048});

  final LineStyler styler;
  final int capacity;

  final LinkedHashMap<(String, LineKind), TextPainter> _entries =
      LinkedHashMap();
  double _width = -1;
  final Stopwatch _clock = Stopwatch()..start();

  int hits = 0;
  int misses = 0;

  /// Time spent building spans and laying them out, for the benchmark.
  int spanMicros = 0;
  int layoutMicros = 0;

  TextPainter painterFor(String text, LineKind kind, double width) {
    if (width != _width) {
      _entries.clear();
      _width = width;
    }
    final key = (text, kind);
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      hits++;
      return cached;
    }
    misses++;
    final t0 = _clock.elapsedMicroseconds;
    // An empty line in one paragraph of the whole note takes its height from
    // the newline's run; an empty paragraph would take it from the paragraph
    // style, which comes out 7px taller when the strut isn't forced. A space
    // in the base style has the newline's metrics.
    final span = text.isEmpty
        ? TextSpan(text: ' ', style: styler.base)
        : styler.spanFor(text, kind);
    final t1 = _clock.elapsedMicroseconds;
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      strutStyle: styler.strut,
      textScaler: styler.scaler,
    )..layout(maxWidth: width);
    final t2 = _clock.elapsedMicroseconds;
    spanMicros += t1 - t0;
    layoutMicros += t2 - t1;
    _entries[key] = painter;
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
    return painter;
  }
}

/// What the sliver did, for the benchmark and the tests.
class SliverStats {
  int layouts = 0;
  int measured = 0;
  int estimateMisses = 0;
  double estimateError = 0;
  int corrections = 0;
  double correctionTotal = 0;
  double correctionMax = 0;

  /// After every correction, how far the anchored line ended up from where
  /// it was on screen: zero when anchoring works.
  double anchorDriftMax = 0;

  void _corrected(double by) {
    corrections++;
    correctionTotal += by.abs();
    correctionMax = math.max(correctionMax, by.abs());
  }
}

/// The note as lines: their kinds, the height index and the paragraph cache.
class NoteLayout {
  NoteLayout({
    required String body,
    required this.styler,
    this.columnWidth = 680,
    double Function(String line, LineKind kind, double width)? estimate,
  }) : lines = body.split('\n') {
    final clock = Stopwatch()..start();
    kinds = classifyLines(lines);
    final guess = estimate ?? styler.estimate;
    index = HeightIndex([
      for (var i = 0; i < lines.length; i++)
        guess(lines[i], kinds[i], columnWidth),
    ]);
    estimatedTotal = index.total;
    cache = LineLayoutCache(styler);
    setupMicros = clock.elapsedMicroseconds;
  }

  final List<String> lines;
  late final List<LineKind> kinds;
  final LineStyler styler;
  final double columnWidth;
  late final HeightIndex index;
  late final LineLayoutCache cache;
  late final double estimatedTotal;
  late final int setupMicros;
  final SliverStats stats = SliverStats();

  RenderNoteSliver? _render;
  bool _endRequested = false;

  int get length => lines.length;
  RenderNoteSliver? get renderSliver => _render;

  TextPainter painterFor(int line) =>
      cache.painterFor(lines[line], kinds[line], columnWidth);

  /// [line]'s real height, laying it out the first time.
  double measure(int line) {
    if (index.isMeasured(line)) return index.heightOf(line);
    final height = painterFor(line).height;
    final estimate = index.heightOf(line);
    stats.measured++;
    if (height != estimate) {
      stats.estimateMisses++;
      stats.estimateError += height - estimate;
    }
    index.setHeight(line, height);
    return height;
  }

  /// Measures the lines in [from, to) outside layout, the way idle-time
  /// slices would, and asks for a layout to take them in.
  void refine(int from, int to) {
    for (var line = from; line < to; line++) {
      measure(line);
    }
    _render?.markNeedsLayout();
  }

  /// Lands the next layout exactly on the end of the note.
  void jumpToEnd() {
    _endRequested = true;
    _render?.markNeedsLayout();
  }

  bool _takeEndRequest() {
    final requested = _endRequested;
    _endRequested = false;
    return requested;
  }
}

/// The note, one widget per visible line.
class NoteSliver extends SliverMultiBoxAdaptorWidget {
  NoteSliver({super.key, required this.layout})
    : super(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _NoteLine(
            painter: layout.painterFor(index),
            columnWidth: layout.columnWidth,
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
    layout: layout,
  );

  @override
  void updateRenderObject(BuildContext context, RenderNoteSliver renderObject) {
    renderObject.noteLayout = layout;
  }
}

class _NoteLine extends LeafRenderObjectWidget {
  const _NoteLine({required this.painter, required this.columnWidth});

  final TextPainter painter;
  final double columnWidth;

  @override
  RenderNoteLine createRenderObject(BuildContext context) =>
      RenderNoteLine(painter, columnWidth);

  @override
  void updateRenderObject(BuildContext context, RenderNoteLine renderObject) {
    renderObject
      ..painter = painter
      ..columnWidth = columnWidth;
  }
}

/// One line: its cached paragraph, painted in the middle of the row.
class RenderNoteLine extends RenderBox {
  RenderNoteLine(this._painter, this._columnWidth);

  TextPainter _painter;
  TextPainter get painter => _painter;
  set painter(TextPainter value) {
    if (identical(value, _painter)) return;
    _painter = value;
    markNeedsLayout();
  }

  double _columnWidth;
  set columnWidth(double value) {
    if (value == _columnWidth) return;
    _columnWidth = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    size = constraints.constrain(Size(constraints.maxWidth, _painter.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final left = math.max(0.0, (size.width - _columnWidth) / 2);
    _painter.paint(context.canvas, offset + Offset(left, 0));
  }
}

/// Lays out only the lines in the viewport and its cache extent, placing
/// each from the height index.
class RenderNoteSliver extends RenderSliverMultiBoxAdaptor {
  RenderNoteSliver({required super.childManager, required NoteLayout layout})
    : _layout = layout;

  NoteLayout _layout;
  NoteLayout get noteLayout => _layout;
  set noteLayout(NoteLayout value) {
    if (identical(value, _layout)) return;
    if (identical(_layout._render, this)) _layout._render = null;
    _layout = value;
    _anchorLine = null;
    if (attached) value._render = this;
    markNeedsLayout();
  }

  /// The first visible line after the last layout, and its top then. If its
  /// top has moved since, lines above it were measured outside layout.
  int? _anchorLine;
  double _anchorTop = 0;

  /// After a correction: the line that was anchored and where it was on
  /// screen, to check where the next layout puts it.
  ({int line, double screenTop})? _corrected;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _layout._render = this;
  }

  @override
  void detach() {
    if (identical(_layout._render, this)) _layout._render = null;
    super.detach();
  }

  /// Where [line]'s top is in the viewport, if the line has a child now.
  double? screenTopOf(int line) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (indexOf(child) == line) return childMainAxisPosition(child);
    }
    return null;
  }

  /// The first line whose child shows in the viewport.
  int? get firstVisibleLine {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final top = childMainAxisPosition(child);
      if (top + paintExtentOf(child) > 0) return indexOf(child);
    }
    return null;
  }

  void _correct(double by, {required int anchor, required double screenTop}) {
    _layout.stats._corrected(by);
    _corrected = (line: anchor, screenTop: screenTop);
    geometry = SliverGeometry(scrollOffsetCorrection: by);
  }

  BoxConstraints _childConstraints(int line) {
    final height = _layout.index.heightOf(line);
    return constraints.asBoxConstraints(minExtent: height, maxExtent: height);
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    childManager.didStartLayout();
    childManager.setDidUnderflow(false);
    final layout = _layout;
    final index = layout.index;
    final count = index.length;
    layout.stats.layouts++;

    if (layout._takeEndRequest()) {
      final needed =
          constraints.viewportMainAxisExtent +
          constraints.remainingCacheExtent -
          constraints.remainingPaintExtent;
      var covered = 0.0;
      for (var line = count - 1; line >= 0 && covered < needed; line--) {
        covered += layout.measure(line);
      }
      _anchorLine = null;
      _corrected = null;
      final target = math.max(
        0.0,
        index.total - constraints.viewportMainAxisExtent,
      );
      final by = target - constraints.scrollOffset;
      if (by.abs() > precisionErrorTolerance) {
        geometry = SliverGeometry(scrollOffsetCorrection: by);
        return;
      }
    }

    final scrollOffset = constraints.scrollOffset;

    // Lines measured since the last layout, outside it, may have moved the
    // line that was first on screen.
    final previous = _anchorLine;
    if (previous != null && previous < count) {
      final moved = index.topOf(previous) - _anchorTop;
      if (moved.abs() > precisionErrorTolerance) {
        _anchorTop += moved;
        _correct(
          moved,
          anchor: previous,
          screenTop: _anchorTop - moved - scrollOffset,
        );
        return;
      }
    }

    final first = index.lineAt(scrollOffset);
    final firstTop = index.topOf(first);
    final cacheStart = scrollOffset + constraints.cacheOrigin;
    final cacheEnd = cacheStart + constraints.remainingCacheExtent;
    var line = first;
    var top = firstTop;
    while (line < count && top < cacheEnd) {
      top += layout.measure(line);
      line++;
    }
    for (var above = first - 1; above >= 0; above--) {
      if (index.topOf(above + 1) <= cacheStart) break;
      layout.measure(above);
    }
    final moved = index.topOf(first) - firstTop;
    if (moved.abs() > precisionErrorTolerance) {
      _anchorLine = first;
      _anchorTop = index.topOf(first);
      _correct(moved, anchor: first, screenTop: firstTop - scrollOffset);
      return;
    }

    final corrected = _corrected;
    if (corrected != null) {
      final drift =
          index.topOf(corrected.line) - scrollOffset - corrected.screenTop;
      layout.stats.anchorDriftMax = math.max(
        layout.stats.anchorDriftMax,
        drift.abs(),
      );
      _corrected = null;
    }

    final firstIndex = index.lineAt(math.max(0.0, cacheStart));
    final lastIndex = math.max(firstIndex, index.lineAt(cacheEnd));

    if (firstChild != null) {
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
    } else {
      collectGarbage(0, 0);
    }

    if (firstChild == null &&
        !addInitialChild(
          index: firstIndex,
          layoutOffset: index.topOf(firstIndex),
        )) {
      geometry = SliverGeometry(
        scrollExtent: index.total,
        maxPaintExtent: index.total,
      );
      childManager.didFinishLayout();
      return;
    }

    RenderBox? trailingChild;
    for (var i = indexOf(firstChild!) - 1; i >= firstIndex; i--) {
      layout.measure(i);
      final child = insertAndLayoutLeadingChild(_childConstraints(i))!;
      (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset =
          index.topOf(i);
      trailingChild ??= child;
    }
    if (trailingChild == null) {
      final i = indexOf(firstChild!);
      layout.measure(i);
      firstChild!.layout(_childConstraints(i));
      (firstChild!.parentData! as SliverMultiBoxAdaptorParentData)
              .layoutOffset =
          index.topOf(i);
      trailingChild = firstChild;
    }
    for (var i = indexOf(trailingChild!) + 1; i <= lastIndex; i++) {
      layout.measure(i);
      var child = childAfter(trailingChild!);
      if (child == null || indexOf(child) != i) {
        child = insertAndLayoutChild(_childConstraints(i), after: trailingChild);
        if (child == null) break;
      } else {
        child.layout(_childConstraints(i));
      }
      trailingChild = child;
      (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset =
          index.topOf(i);
    }

    final leadingOffset = index.topOf(indexOf(firstChild!));
    final trailingOffset = index.topOf(indexOf(lastChild!) + 1);
    final total = index.total;
    geometry = SliverGeometry(
      scrollExtent: total,
      paintExtent: calculatePaintOffset(
        constraints,
        from: leadingOffset,
        to: trailingOffset,
      ),
      cacheExtent: calculateCacheOffset(
        constraints,
        from: leadingOffset,
        to: trailingOffset,
      ),
      maxPaintExtent: total,
      hasVisualOverflow: true,
    );
    _anchorLine = first;
    _anchorTop = index.topOf(first);
    childManager.didFinishLayout();
  }
}

/// A note in the editor's column, scrolled by the platform's own physics.
class SpikeNoteView extends StatefulWidget {
  const SpikeNoteView({
    super.key,
    required this.body,
    required this.highlighter,
    this.onReady,
    this.estimate,
  });

  final String body;
  final Highlighter highlighter;
  final void Function(NoteLayout layout, ScrollController scroll)? onReady;
  final double Function(String line, LineKind kind, double width)? estimate;

  @override
  State<SpikeNoteView> createState() => _SpikeNoteViewState();
}

class _SpikeNoteViewState extends State<SpikeNoteView> {
  final ScrollController _scroll = ScrollController();
  NoteLayout? _layout;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_layout != null) return;
    _layout = NoteLayout(
      body: widget.body,
      styler: LineStyler.of(context, widget.highlighter),
      estimate: widget.estimate,
    );
    widget.onReady?.call(_layout!, _scroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.palette.editorBackground,
    child: CustomScrollView(
      controller: _scroll,
      slivers: [NoteSliver(layout: _layout!)],
    ),
  );
}

const _python = [
  'import math',
  'from dataclasses import dataclass',
  '',
  '@dataclass',
  'class Point:',
  '    x: float',
  '    y: float',
  '',
  '    def norm(self) -> float:',
  '        # Euclidean length of the vector',
  '        return math.sqrt(self.x ** 2 + self.y ** 2)',
  '',
  'def mean(values: list[float]) -> float:',
  '    """The arithmetic mean, or zero for nothing."""',
  '    if not values:',
  '        return 0.0',
  '    return sum(values) / len(values)',
  '',
  'for i in range(10):',
  '    print(f"step {i}: {mean([i, i * 2, 3.5])}")',
];

const _typescript = [
  "import { readFile } from 'node:fs/promises';",
  '',
  'interface Invoice {',
  '  id: string;',
  '  total: number;',
  '  paid?: boolean;',
  '}',
  '',
  'export async function load(path: string): Promise<Invoice[]> {',
  "  const raw = await readFile(path, 'utf8');",
  '  // One invoice per line, as JSON.',
  '  return raw.split("\\n").filter(Boolean).map((line) => JSON.parse(line));',
  '}',
  '',
  'const unpaid = (all: Invoice[]) => all.filter((i) => !i.paid);',
  'let sum = 0;',
  'for (const invoice of unpaid([])) {',
  '  sum += invoice.total * 1.2;',
  '}',
  r'console.log(`owed: ${sum.toFixed(2)}`);',
];

const _sql = [
  '-- Monthly revenue by customer',
  'SELECT c.name,',
  "       date_trunc('month', o.created_at) AS month,",
  '       SUM(o.total) AS revenue,',
  '       COUNT(*) AS orders',
  'FROM customers c',
  'JOIN orders o ON o.customer_id = c.id',
  "WHERE o.status = 'paid'",
  '  AND o.created_at >= NOW() - INTERVAL 1 YEAR',
  'GROUP BY c.name, month',
  'HAVING SUM(o.total) > 1000',
  'ORDER BY revenue DESC',
  'LIMIT 50;',
  '',
  'UPDATE orders SET status = NULL WHERE id IN (1, 2, 3);',
  'CREATE INDEX orders_customer ON orders (customer_id);',
  "INSERT INTO audit (event, at) VALUES ('refresh', NOW());",
  'DELETE FROM sessions WHERE expires_at < NOW();',
  "SELECT * FROM customers WHERE email LIKE '%@example.com';",
  'DROP TABLE IF EXISTS scratch;',
];

/// The long note of benchmark/markdown_rendering.dart, with its pattern of
/// 166-line sections repeated until the note has [count] lines. At 5,000
/// lines it is that note exactly; a test holds it to that.
String repeatedNote(int count, {bool formulas = true}) {
  final lines = <String>[];
  const languages = ['python', 'typescript', 'sql'];
  const bodies = [_python, _typescript, _sql];
  final sections = count ~/ 166;
  for (var section = 0; section < sections; section++) {
    final start = lines.length;
    lines
      ..add('## Section $section')
      ..add('');
    for (var i = 0; i < 5; i++) {
      lines.add(
        formulas
            ? 'Line $i of $section says \$x_{$i}^{2} + \\frac{a}{b}\$ grows '
                  'faster than \$\\sqrt{n}\$ here.'
            : 'Line $i of $section says x to the $i squared plus a over b '
                  'grows faster than root n here.',
      );
    }
    lines.add('');
    final displays = section < 20 ? 2 : 1;
    for (var d = 0; d < displays; d++) {
      lines
        ..add(formulas ? '\$\$' : 'Set apart:')
        ..add(
          formulas
              ? '\\sum_{k=1}^{$section} k^$d = \\int_0^1 f(t)\\,dt'
              : 'the sum of k to the $d for k up to $section is an integral',
        )
        ..add(formulas ? '\$\$' : 'of f over 0 to 1.')
        ..add('');
    }
    lines
      ..add('price = ${section + 3} usd')
      ..add('price * 3')
      ..add('')
      ..add('$_fence${languages[section % 3]}');
    final body = bodies[section % 3];
    lines
      ..addAll(body)
      ..addAll(body)
      ..add(_fence)
      ..add('');
    while (lines.length - start < 166) {
      lines.add(
        'Plain prose for section $section, line ${lines.length - start}, '
        'with a total of 4 + 5 in it.',
      );
    }
  }
  while (lines.length < count) {
    lines.add('closing line ${lines.length}');
  }
  return lines.take(count).join('\n');
}
