import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show SuggestionSpan;
import 'package:material_ui/material_ui.dart';

import '../../calc/highlight.dart';
import '../../core/editor_font.dart';
import '../../core/note_link.dart';
import '../../core/theme.dart';
import '../../data/note_format.dart';
import 'editor_formatting.dart';
import 'markdown_syntax.dart';

/// One image, already sized and built, ready to be dropped into the span tree
/// at its placeholder.
///
/// The controller is handed finished widgets rather than the refs to build
/// them from, because sizing an image needs the layout width and the layout
/// width is only known inside the editor's [LayoutBuilder]. Keeping that
/// knowledge out here leaves the controller doing one thing: placing spans.
typedef NoteImageSpan = ({double width, double height, Widget child});

/// A [TextEditingController] that paints the note's own syntax.
///
/// Flutter can style a text field's content directly, so there is no need for
/// the layered "transparent textarea over a mirrored div" trick a web build
/// requires: this is one real, editable, syntax-coloured text field.
class HighlightingController extends TextEditingController {
  HighlightingController({
    required Highlighter highlighter,
    required CalcPalette palette,
    required WritingFont writingFont,
    List<NoteFormatRange> formats = const [],
    bool markdown = false,
    super.text,
  }) : _highlighter = highlighter,
       _palette = palette,
       _writingFont = writingFont,
       _formats = formats,
       _markdown = markdown;

  Highlighter _highlighter;
  CalcPalette _palette;
  WritingFont _writingFont;
  List<NoteFormatRange> _formats;
  bool _markdown;
  final MarkdownAnalyzer _markdownAnalyzer = MarkdownAnalyzer();
  Map<int, NoteImageSpan> _imageSpans = const {};

  /// Native spelling results currently painted by this rich text controller.
  ///
  /// Deliberately a silent field: the editor rebuilds after accepting an
  /// asynchronous result. Notifying controller listeners here would make a
  /// visual underline look like a document edit and reset idle interactions.
  List<SuggestionSpan> spellingSuggestions = const [];

  String? _cachedText;
  List<HighlightSpan> _cachedSpans = const [];
  List<NoteLink> _cachedLinks = const [];
  List<NoteLink> _cachedWebLinks = const [];

  /// Swapped in when exchange rates arrive and new currency codes become
  /// colourable.
  set highlighter(Highlighter value) {
    if (identical(_highlighter, value)) return;
    _highlighter = value;
    _invalidate();
    notifyListeners();
  }

  set palette(CalcPalette value) {
    if (_palette == value) return;
    _palette = value;
    notifyListeners();
  }

  set writingFont(WritingFont value) {
    if (_writingFont == value) return;
    _writingFont = value;
    notifyListeners();
  }

  List<NoteFormatRange> get formats => _formats;

  set formats(List<NoteFormatRange> value) {
    if (listEquals(_formats, value)) return;
    _formats = value;
    notifyListeners();
  }

  /// Whether the note is read as markdown: its syntax drawn, its markers
  /// kept quiet, and its lists and code kept away from the calculator.
  bool get markdown => _markdown;

  set markdown(bool value) {
    if (_markdown == value) return;
    _markdown = value;
    _invalidate();
    notifyListeners();
  }

  /// The note read as markdown.
  ///
  /// Never null. A table is drawn as a grid whether or not this device has
  /// markdown switched on, so with the setting off this holds the note's tables
  /// and nothing else — see [MarkdownAnalysis.tablesOnly]. Headings, lists,
  /// code, links and spelling therefore behave exactly as they did before.
  MarkdownAnalysis markdownFor(String source) {
    final analysis = _markdownAnalyzer.analyze(source);
    return _markdown ? analysis : analysis.tablesOnly;
  }

  /// When hidden markdown is shown as written: blocks while the note is being
  /// edited, inline markers only then and not while the writer is typing.
  /// See [MarkdownAnalysis.concealFor].
  ///
  /// Deliberately silent, like [spellingSuggestions]: the editor sets this as
  /// focus moves and typing starts and stops, and rebuilds itself — and with
  /// it the field — whenever it does.
  ({bool blocks, bool edges}) markdownReveal = (blocks: false, edges: false);

  MarkdownConcealment? _concealment;
  MarkdownAnalysis? _concealedFor;
  TextSelection? _concealedAt;
  ({bool blocks, bool edges})? _concealedWith;

  /// What of the note's markdown is hidden right now, given the caret.
  MarkdownConcealment markdownConcealment() {
    final analysis = markdownFor(text);
    final cached = _concealment;
    if (cached != null &&
        identical(_concealedFor, analysis) &&
        _concealedAt == selection &&
        _concealedWith == markdownReveal) {
      return cached;
    }
    final concealment = analysis.concealFor(
      selection,
      revealBlocks: markdownReveal.blocks,
      revealEdges: markdownReveal.edges,
    );
    _concealment = concealment;
    _concealedFor = analysis;
    _concealedAt = selection;
    _concealedWith = markdownReveal;
    return concealment;
  }

  /// What the calculator reads: [source] itself, or in markdown the same
  /// text with its code blanked and its list markers made into bullets. See
  /// [MarkdownAnalysis.calculatorText].
  String calculatorTextFor(String source) => markdownFor(source).calculatorText;

  Map<int, NoteImageSpan> get imageSpans => _imageSpans;

  /// Deliberately silent.
  ///
  /// This is set from inside the editor's build, once the layout width is
  /// known and immediately before the span is built. Notifying here would ask
  /// for a rebuild from inside a build, which is both an error and a loop.
  void setImageSpansDuringLayout(Map<int, NoteImageSpan> value) {
    _imageSpans = value;
  }

  /// The placeholder boxes [TextPainter] must be told about before it can lay
  /// out a span containing [WidgetSpan]s, in the order they appear.
  List<PlaceholderDimensions> placeholderDimensions() {
    final offsets = _imageSpans.keys.toList()..sort();
    return [
      for (final offset in offsets)
        PlaceholderDimensions(
          size: Size(_imageSpans[offset]!.width, _imageSpans[offset]!.height),
          alignment: PlaceholderAlignment.top,
        ),
    ];
  }

  void _invalidate() {
    _cachedText = null;
    _cachedSpans = const [];
    _cachedLinks = const [];
    _cachedWebLinks = const [];
  }

  List<HighlightSpan> spansFor(String source) {
    if (_cachedText == source) return _cachedSpans;
    final markdown = markdownFor(source);
    // In markdown the calculator reads its own view of the note, and so does
    // the highlighter: colouring and evaluation have to agree on which lines
    // are calculations, and a bullet or a line of code is not one.
    final view = markdown.calculatorText;
    _cachedWebLinks = findNoteLinks(view);
    _cachedLinks = markdown.linksWith(_cachedWebLinks);
    _cachedSpans = _highlighter.spans(view, links: _cachedWebLinks);
    _cachedText = source;
    return _cachedSpans;
  }

  /// Everything in [source] a click opens: web addresses, and in markdown the
  /// words of each link as well.
  List<NoteLink> linksFor(String source) {
    spansFor(source);
    return _cachedLinks;
  }

  /// Whether a spelling suggestion over [range] should be dropped: it is on a
  /// web address, or in markdown on code or on a link's destination.
  ///
  /// Not the same as [linksFor]. A markdown link's words are prose, and are
  /// checked like any other.
  bool isSpellingExempt(String source, TextRange range) {
    spansFor(source);
    for (final link in _cachedWebLinks) {
      if (range.start < link.end && range.end > link.start) return true;
    }
    return markdownFor(source).isLiteral(range.start, range.end);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final source = text;
    if (source.isEmpty) return TextSpan(style: base);

    final spans = spansFor(source);
    final links = linksFor(source);
    final checkedRanges = _checkedTextRanges(source);
    final analysis = markdownFor(source);
    final markdownSpans = analysis.spans;
    final concealment = markdownConcealment();
    final hidden = concealment.hidden;
    final transparent = concealment.transparent;
    final stretches = _listStretches(
      analysis,
      base,
      MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
    );
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : null;

    // Cut the text at every span edge and at the composing-region edges, then
    // emit one run per segment. Doing it via a boundary set keeps the two
    // kinds of styling from having to know about each other.
    final boundaries = <int>{0, source.length};
    for (final span in spans) {
      boundaries.add(span.start.clamp(0, source.length));
      boundaries.add(span.end.clamp(0, source.length));
    }
    for (final link in links) {
      boundaries.add(link.start);
      boundaries.add(link.end);
    }
    for (final format in _formats) {
      boundaries.add(format.start.clamp(0, source.length));
      boundaries.add(format.end.clamp(0, source.length));
    }
    for (final range in checkedRanges) {
      boundaries.add(range.start);
      boundaries.add(range.end);
    }
    for (final suggestion in spellingSuggestions) {
      boundaries.add(suggestion.range.start.clamp(0, source.length));
      boundaries.add(suggestion.range.end.clamp(0, source.length));
    }
    for (final offset in _imageSpans.keys) {
      if (offset < 0 || offset >= source.length) continue;
      boundaries.add(offset);
      boundaries.add(offset + 1);
    }
    for (final span in markdownSpans) {
      boundaries.add(span.start);
      boundaries.add(span.end);
    }
    for (final range in [...hidden, ...transparent]) {
      boundaries.add(range.start.clamp(0, source.length));
      boundaries.add(range.end.clamp(0, source.length));
    }
    for (final stretch in stretches) {
      boundaries.add(stretch.start);
      boundaries.add(stretch.end);
    }
    if (composing != null) {
      boundaries.add(composing.start.clamp(0, source.length));
      boundaries.add(composing.end.clamp(0, source.length));
    }

    final cuts = boundaries.toList()..sort();
    final children = <InlineSpan>[];
    var spanIndex = 0;
    var linkIndex = 0;
    final linkColor = Theme.of(context).colorScheme.primary;
    // Markdown spans nest, so the ones open over a segment are a set rather
    // than a single pointer: everything that has started, less everything
    // that has ended. Every span edge is a cut, so an open span always covers
    // the whole segment.
    var markdownIndex = 0;
    final openMarkdown = <MarkdownSpan>[];
    // Hidden and transparent ranges never overlap within their own list, so
    // one pointer each is enough.
    var hiddenIndex = 0;
    var transparentIndex = 0;
    var stretchIndex = 0;

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

      // A placeholder is exactly one character wide, and the image stands in
      // its place. Emitting the widget rather than the U+FFFC glyph is the
      // whole of how an image appears inside an otherwise ordinary text field.
      final image = end == start + 1 ? _imageSpans[start] : null;
      if (image != null) {
        children.add(
          WidgetSpan(alignment: PlaceholderAlignment.top, child: image.child),
        );
        continue;
      }

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
      final checked = checkedRanges.any(
        (range) => range.start <= start && range.end >= end,
      );
      final misspelled = spellingSuggestions.any(
        (suggestion) =>
            suggestion.range.start <= start && suggestion.range.end >= end,
      );

      // Code is literal, so the calculator's colours stay out of it.
      final literal =
          marked(MarkdownStyle.code) ||
          marked(MarkdownStyle.codeBlock) ||
          marked(MarkdownStyle.html);
      var segmentStyle = active == null || literal
          ? base
          : base.merge(_styleFor(active.kind));
      if (markdown != 0) {
        segmentStyle = _markdownBlockStyle(segmentStyle, base, marked);
      }
      final matchingFormats = _formats.where(
        (format) => format.start <= start && format.end >= end,
      );
      final activeFormats = [
        ...matchingFormats.where((format) => format.format.isParagraph),
        ...matchingFormats.where((format) => format.format.isInline),
      ];
      for (final format in activeFormats) {
        segmentStyle = switch (format.format) {
          NoteFormat.bold => segmentStyle.copyWith(fontWeight: FontWeight.w700),
          NoteFormat.italic => segmentStyle.copyWith(
            fontStyle: FontStyle.italic,
          ),
          NoteFormat.heading => paragraphTextStyle(
            segmentStyle,
            NoteParagraphStyle.heading,
            writingFont: _writingFont,
            primaryColor: base.color,
          ),
          NoteFormat.subtitle => paragraphTextStyle(
            segmentStyle,
            NoteParagraphStyle.subtitle,
            writingFont: _writingFont,
            secondaryColor: _palette.textSecondary,
          ),
        };
      }
      if (markdown != 0) {
        segmentStyle = _markdownInlineStyle(segmentStyle, marked, linkColor);
      }
      final done = checked || marked(MarkdownStyle.doneTask);
      // A spelling mark must not replace KapyNotes' syntax, rich formatting,
      // link, or attachment spans. It is just one quiet decoration layered on
      // top. Links are distinguished by colour and pointer behaviour, while
      // completed tasks keep their strike-through.
      if (misspelled && activeLink == null && !done) {
        segmentStyle = segmentStyle.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: Theme.of(context).colorScheme.error,
          decorationStyle:
              defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.macOS
              ? TextDecorationStyle.dotted
              : TextDecorationStyle.wavy,
        );
      }
      if (activeLink != null) {
        segmentStyle = segmentStyle.copyWith(
          color: linkColor,
          decoration: TextDecoration.none,
        );
      }
      if (done) {
        segmentStyle = segmentStyle.copyWith(
          color: _palette.comment,
          decoration: TextDecoration.lineThrough,
          decorationColor: _palette.comment,
        );
      }
      // Last of the colours: a marker stays quiet whatever it sits in, a
      // link's words and a ticked task included.
      if (marked(MarkdownStyle.syntax)) {
        segmentStyle = segmentStyle.copyWith(color: _palette.textTertiary);
      }
      if (composing != null &&
          start >= composing.start &&
          end <= composing.end) {
        segmentStyle = segmentStyle.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: segmentStyle.color,
        );
      }
      // Over everything else. Hidden markdown collapses to nothing: a size too
      // small to take room or be seen, which the forced strut keeps from
      // moving the line it sits on, and which the caret still steps through.
      // Transparent text keeps its room for what is drawn there instead.
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

  /// The room a list marker takes — a bullet, a box or a number, with the
  /// space after it — so that every item's words start in one column and
  /// each level of nesting is one more room in, the way GitHub and Craft lay
  /// a list out, rather than wherever its characters happen to end.
  ///
  /// Enough for a task's box and a gap, and for a one-digit number, its dot
  /// and a space, in the note's own face: a monospace one needs more.
  double markdownMarkerRoom(TextStyle base, TextScaler scaler) => math.max(
    scaler.scale(markdownMarkerMinRoom),
    _advance('8. ', base, scaler),
  );

  final Map<(String, TextStyle, TextScaler), double> _advances = {};

  /// How far [text] reaches in [style], trailing spaces and all.
  double _advance(String text, TextStyle style, TextScaler scaler) {
    if (text.isEmpty) return 0;
    final key = (text, style, scaler);
    final known = _advances[key];
    if (known != null) return known;
    if (_advances.length > 256) _advances.clear();
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    // The caret after the last character: a width would leave out a
    // trailing space.
    final width = painter
        .getOffsetForCaret(TextPosition(offset: text.length), Rect.zero)
        .dx;
    painter.dispose();
    return _advances[key] = width;
  }

  MarkdownAnalysis? _stretchedFor;
  TextStyle? _stretchedStyle;
  TextScaler? _stretchedScaler;
  List<_Stretch> _stretches = const [];

  /// The letter spacing that gives the markers of [analysis]'s list items
  /// their room. Sorted, never overlapping, and never over hidden text.
  List<_Stretch> _listStretches(
    MarkdownAnalysis analysis,
    TextStyle base,
    TextScaler scaler,
  ) {
    if (identical(analysis, _stretchedFor) &&
        _stretchedStyle == base &&
        _stretchedScaler == scaler) {
      return _stretches;
    }
    final text = analysis.text;
    // Measured against characters scaled as the field scales them.
    final room = markdownMarkerRoom(base, scaler);
    double advance(int start, int end) =>
        end <= start ? 0 : _advance(text.substring(start, end), base, scaler);

    final stretches = <_Stretch>[];
    // The text engine puts half a glyph's spacing in front of it as well as
    // after, and at the start of a line nothing before takes that half up:
    // there, a run of n letters grows by n and a half spacings, not n.
    void stretch(int start, int end, double width, {bool lineStart = false}) {
      if (end <= start) return;
      final letters = end - start + (lineStart ? 0.5 : 0);
      final spacing = (width - advance(start, end)) / letters;
      if (spacing.abs() >= 0.01) {
        stretches.add((start: start, end: end, spacing: spacing));
      }
    }

    for (final item in analysis.listItems) {
      // A quote's hidden markers share a quoted item's indentation, and
      // spacing them out would bring them back.
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
        // The bullet before a box is hidden; the box takes the room.
        stretch(box, box + 3, room - advance(box + 3, item.wordsStart));
      } else if (item.ordered) {
        // A number is read, so it keeps its shape, and the space after it
        // makes up the rest — unless the number is wider than the room.
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
    _stretchedFor = analysis;
    _stretchedStyle = base;
    _stretchedScaler = scaler;
    return _stretches = stretches;
  }

  static const _headingLevels = [
    MarkdownStyle.heading1,
    MarkdownStyle.heading2,
    MarkdownStyle.heading3,
    MarkdownStyle.heading4,
    MarkdownStyle.heading5,
    MarkdownStyle.heading6,
  ];

  /// What a markdown block makes of a run: its size as a heading, its colour
  /// in a quote, its face as code.
  ///
  /// Applied under the note's own rich formatting, the way a paragraph style
  /// is, so a range made bold before markdown was switched on still reads
  /// bold inside a markdown heading.
  TextStyle _markdownBlockStyle(
    TextStyle style,
    TextStyle base,
    bool Function(MarkdownStyle) marked,
  ) {
    var result = style;
    for (var level = 1; level <= _headingLevels.length; level++) {
      if (!marked(_headingLevels[level - 1])) continue;
      result = markdownHeadingStyle(
        result,
        level,
        writingFont: _writingFont,
        primaryColor: base.color,
        secondaryColor: _palette.textSecondary,
      );
      break;
    }
    if (marked(MarkdownStyle.quote)) {
      result = result.copyWith(color: _palette.textSecondary);
    }
    if (marked(MarkdownStyle.codeBlock) || marked(MarkdownStyle.code)) {
      // The panel under a code block and the pill under inline code are drawn
      // behind the field, where the selection highlight still shows over them.
      result = _codeStyle(result);
    }
    return result;
  }

  /// Small enough to take no room and show nothing. Not zero, which a text
  /// engine is entitled to read as "no size given".
  static const double _hiddenFontSize = 0.01;

  /// Code in the monospace face, at the size that face is set at in a note,
  /// keeping the row the line sits in.
  TextStyle _codeStyle(TextStyle style) {
    const mono = WritingFont.monospace;
    final size = style.fontSize;
    final height = style.height;
    final codeSize = size == null
        ? null
        : size * mono.editorSize / _writingFont.editorSize;
    return style.copyWith(
      fontFamily: mono.fontFamily,
      fontFamilyFallback: mono.fontFamilyFallback,
      // The handwritten face's axes mean nothing to a monospace one.
      fontVariations: const [],
      fontSize: codeSize,
      height: codeSize == null || size == null || height == null
          ? height
          : size * height / codeSize,
    );
  }

  /// How words under [styles] are drawn somewhere other than the field — in
  /// a table drawn as a grid — in the faces and colours they have in it.
  TextStyle markdownRunStyle(
    TextStyle base,
    Set<MarkdownStyle> styles,
    Color linkColor,
  ) {
    bool marked(MarkdownStyle style) => styles.contains(style);
    return _markdownInlineStyle(
      _markdownBlockStyle(base, base, marked),
      marked,
      linkColor,
    );
  }

  /// The markdown that changes a word rather than a block.
  TextStyle _markdownInlineStyle(
    TextStyle style,
    bool Function(MarkdownStyle) marked,
    Color linkColor,
  ) {
    var result = style;
    if (marked(MarkdownStyle.strong) || marked(MarkdownStyle.tableHeader)) {
      result = result.copyWith(fontWeight: FontWeight.w700);
    }
    if (marked(MarkdownStyle.emphasis)) {
      result = result.copyWith(fontStyle: FontStyle.italic);
    }
    if (marked(MarkdownStyle.strikethrough)) {
      result = result.copyWith(
        decoration: TextDecoration.lineThrough,
        decorationColor: result.color,
      );
    }
    if (marked(MarkdownStyle.link)) {
      result = result.copyWith(color: linkColor);
    }
    if (marked(MarkdownStyle.listMarker) || marked(MarkdownStyle.taskBox)) {
      result = result.copyWith(color: _palette.textSecondary);
    }
    if (marked(MarkdownStyle.html)) {
      result = result.copyWith(color: _palette.comment);
    }
    return result;
  }

  static List<TextRange> _checkedTextRanges(String source) {
    final ranges = <TextRange>[];
    var lineStart = 0;
    while (lineStart <= source.length) {
      final newline = source.indexOf('\n', lineStart);
      final lineEnd = newline < 0 ? source.length : newline;
      var contentStart = lineStart;
      while (contentStart < lineEnd &&
          (source[contentStart] == ' ' || source[contentStart] == '\t')) {
        contentStart++;
      }
      if (source.startsWith(checkedPrefix, contentStart) &&
          contentStart + checkedPrefix.length < lineEnd) {
        ranges.add(
          TextRange(start: contentStart + checkedPrefix.length, end: lineEnd),
        );
      }
      if (newline < 0) break;
      lineStart = newline + 1;
    }
    return ranges;
  }

  TextStyle _styleFor(HighlightKind kind) {
    switch (kind) {
      case HighlightKind.number:
      case HighlightKind.constant:
        return TextStyle(color: _palette.number);
      case HighlightKind.keyword:
      case HighlightKind.aggregate:
        // Colour only: a heavier weight could change glyph advances in a
        // fallback font and shift the measured line positions.
        return TextStyle(color: _palette.keyword);
      case HighlightKind.unit:
        return TextStyle(color: _palette.unit);
      case HighlightKind.currency:
        return TextStyle(color: _palette.currency);
      case HighlightKind.function:
        return TextStyle(color: _palette.function);
      case HighlightKind.variable:
        return TextStyle(color: _palette.variable);
      case HighlightKind.operator:
      case HighlightKind.punctuation:
        return TextStyle(color: _palette.operator);
      case HighlightKind.comment:
        return TextStyle(color: _palette.comment, fontStyle: FontStyle.italic);
      case HighlightKind.plain:
        return const TextStyle();
    }
  }
}

/// Letter spacing over [start, end): see
/// [HighlightingController._listStretches].
typedef _Stretch = ({int start, int end, double spacing});
