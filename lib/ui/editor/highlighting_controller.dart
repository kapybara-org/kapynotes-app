import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show SuggestionSpan;
import 'package:material_ui/material_ui.dart';

import '../../calc/highlight.dart';
import '../../core/editor_font.dart';
import '../../core/note_link.dart';
import '../../core/theme.dart';
import '../../data/note_format.dart';
import 'code_highlighting.dart';
import 'editor_formatting.dart';
import 'markdown_syntax.dart';
import 'note_math.dart';
import 'note_sliver.dart';

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
  final NoteLinkFinder _linkFinder = NoteLinkFinder();
  Map<int, NoteImageSpan> _imageSpans = const {};
  final NoteMath _math = NoteMath();
  final CodeHighlighter _codeHighlighter = CodeHighlighter();
  double _mathWidth = 0;
  List<(int, PlaceholderDimensions)> _formulaPlaceholders = const [];

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
  Set<(int, int)> _cachedWebSpans = const {};

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
      drawable: (math) => _math.draws(math.tex),
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

  /// Deliberately silent, for the same reason as [setImageSpansDuringLayout].
  ///
  /// How tall each table row is, by where its line starts, in pixels at the
  /// note's own text size. The page lays a table's lines out at these exactly.
  void setTableRowsDuringLayout(Map<int, double> value) {
    _tableRows = value;
  }

  Map<int, double> _tableRows = const {};

  /// Deliberately silent, for the same reason as [setImageSpansDuringLayout].
  ///
  /// The width of the writing column a formula is drawn in: display math is
  /// centred across it, and any formula wider than it is drawn smaller.
  void setMathWidthDuringLayout(double value) {
    _mathWidth = value;
  }

  /// The placeholder boxes [TextPainter] must be told about before it can lay
  /// out a span containing [WidgetSpan]s, in the order they appear: pictures,
  /// table rows, and the formulas the last [buildTextSpan] drew.
  List<PlaceholderDimensions> placeholderDimensions() =>
      _placeholdersIn(0, text.length, _formulaPlaceholders);

  /// The pictures in `[start, end)` and [formulas], in the order they come.
  List<PlaceholderDimensions> _placeholdersIn(
    int start,
    int end,
    List<(int, PlaceholderDimensions)> formulas,
  ) {
    final placeholders = [
      for (final MapEntry(key: offset, value: image) in _imageSpans.entries)
        if (offset >= start && offset < end)
          (
            offset,
            PlaceholderDimensions(
              size: Size(image.width, image.height),
              alignment: PlaceholderAlignment.top,
            ),
          ),
      ...formulas,
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, dimensions) in placeholders) dimensions];
  }

  void _invalidate() {
    _cachedText = null;
    _cachedSpans = const [];
    _cachedLinks = const [];
    _cachedWebLinks = const [];
    _cachedWebSpans = const {};
    _styled = null;
  }

  List<HighlightSpan> spansFor(String source) {
    if (_cachedText == source) return _cachedSpans;
    final markdown = markdownFor(source);
    // In markdown the calculator reads its own view of the note, and so does
    // the highlighter: colouring and evaluation have to agree on which lines
    // are calculations, and a bullet or a line of code is not one.
    final view = markdown.calculatorText;
    _cachedWebLinks = _linkFinder.find(view);
    _cachedWebSpans = {
      for (final link in _cachedWebLinks) (link.start, link.end),
    };
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
    if (text.isEmpty) return TextSpan(style: base);
    final styling = _stylingFor(
      context,
      base,
      withComposing && value.isComposingRangeValid ? value.composing : null,
    );
    final (children, placeholders) = _spansIn(styling, 0, text.length);
    _formulaPlaceholders = placeholders;
    return _NoteSpan(style: base, children: children);
  }

  /// What any stretch of the note draws, by [buildTextSpan]'s rules, from
  /// styling worked out once for the note as it is now: the stretch's runs,
  /// and the size of each picture and formula among them, in order.
  LineSpan Function(int start, int end) spansIn(
    BuildContext context,
    TextStyle style, {
    TextRange? composing,
  }) {
    final styling = _stylingFor(context, style, composing);
    return (start, end) {
      final (children, formulas) = _spansIn(styling, start, end);
      final forced = styling.rows
          .overlapping(start, math.max(end, start + 1))
          .firstOrNull;
      return (
        span: TextSpan(style: style, children: children),
        placeholders: _placeholdersIn(start, end, formulas),
        // A line inside a formula drawn as itself, which the formula's own
        // line draws, as one paragraph of the whole note draws it in one row.
        folded: styling.formulas
            .overlapping(start, math.max(end, start + 1))
            .any((formula) => formula.start < start && formula.end >= end),
        row: forced?.row,
        inset: forced?.inset ?? 0,
      );
    };
  }

  /// The last styling worked out, and what it was worked out from: the title
  /// and the field both ask for it in one frame.
  _Styling? _styled;
  Object? _styledFor;

  /// What the note's text is styled by, worked out for the whole note so that
  /// [_spansIn] can build any stretch of it.
  _Styling _stylingFor(
    BuildContext context,
    TextStyle base,
    TextRange? composing,
  ) {
    final source = text;
    final links = linksFor(source);
    final analysis = markdownFor(source);
    final concealment = markdownConcealment();
    final scaler =
        MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    final colors = Theme.of(context).colorScheme;
    final key = (
      source,
      analysis,
      concealment,
      base,
      composing,
      scaler,
      _palette,
      _writingFont,
      _imageSpans,
      colors.primary,
      colors.error,
    );
    final styled = _styled;
    if (styled != null && key == _styledFor) return styled;
    _styledFor = key;
    final boxes = plainCheckboxes(source);
    final stretches = [
      ..._listStretches(analysis, base, scaler),
      ..._pageStretches(source, boxes, links, base, scaler),
      ..._codeChipStretches(source, analysis, scaler),
    ]..sort((a, b) => a.start.compareTo(b.start));
    // A pill straight after a list's number reaches into room it has.
    for (var i = stretches.length - 1; i > 0; i--) {
      if (stretches[i].start < stretches[i - 1].end) stretches.removeAt(i);
    }
    final copies = <String, int>{};
    return _styled = (
      base: base,
      scaler: scaler,
      titleEnd: _lineEndAt(source, 0),
      // Paper's sage on the page, a step lighter than the accent in the dark.
      linkColor: _palette.accentText,
      errorColor: colors.error,
      composing: composing,
      checked: _checkedTextRanges(source),
      boxGlyphs: {for (final box in boxes) box.start},
      spans: _Sorted(spansFor(source), (span) => (span.start, span.end)),
      links: _Sorted(links, (link) => (link.start, link.end)),
      markdown: _Sorted(analysis.spans, (span) => (span.start, span.end)),
      hidden: _Sorted(
        [...concealment.hidden, ..._chipSchemes(source)]
          ..sort((a, b) => a.start.compareTo(b.start)),
        (range) => (range.start, range.end),
      ),
      transparent: _Sorted(
        concealment.transparent,
        (range) => (range.start, range.end),
      ),
      stretches: _Sorted(stretches, (stretch) => (stretch.start, stretch.end)),
      formulas: _Sorted(
        concealment.formulas,
        (formula) => (formula.start, formula.end),
      ),
      code: _Sorted(_codeTokens(analysis), (token) => (token.start, token.end)),
      rows: _Sorted(
        _forcedRows(analysis, concealment),
        (rows) => (rows.start, rows.end),
      ),
      copies: {
        for (final formula in concealment.formulas)
          formula.start: copies.update(
            formula.tex,
            (copy) => copy + 1,
            ifAbsent: () => 0,
          ),
      },
    );
  }

  /// The rows a code block and a table set by their own measure, which
  /// the note's strut would otherwise round up to a row of writing: a code
  /// block's lines, its fences while they are hidden, and a table's
  /// delimiter line, which has nothing to show. A code block's lines also
  /// start [EditorMetrics.codeInset] in from the panel.
  List<({int start, int end, double row, double inset})> _forcedRows(
    MarkdownAnalysis analysis,
    MarkdownConcealment concealment,
  ) {
    final rows = <({int start, int end, double row, double inset})>[];
    for (final block in analysis.blocks) {
      if (block.kind != MarkdownBlockKind.code) continue;
      final fences = analysis.fencesOf(block);
      final open = fences?.open;
      final close = fences?.close;
      final openHidden =
          open != null && concealment.hides(open.start, open.end);
      final closeHidden =
          close != null && concealment.hides(close.start, close.end);
      if (openHidden) {
        rows.add((
          start: open.start,
          end: open.end,
          row: EditorMetrics.codeOpenRow,
          inset: 0,
        ));
      }
      rows.add((
        start: openHidden ? open.end + 1 : block.start,
        end: closeHidden ? close.start : block.end,
        row: EditorMetrics.codeRow,
        inset: EditorMetrics.codeInset,
      ));
      if (closeHidden) {
        rows.add((
          start: close.start,
          end: close.end,
          row: EditorMetrics.codeCloseRow,
          inset: 0,
        ));
      }
    }
    for (final table in analysis.tables) {
      for (final row in table.rows) {
        if (_tableRows[row.start] case final height?) {
          rows.add((start: row.start, end: row.end, row: height, inset: 0));
        }
      }
      // Hidden, the delimiter line has nothing to show and no row of its own.
      // Not zero, which a strut is entitled to read as no height given.
      if (concealment.hides(table.delimiterStart, table.delimiterEnd)) {
        rows.add((
          start: table.delimiterStart,
          end: table.delimiterEnd,
          row: 0.01,
          inset: 0,
        ));
      }
    }
    return rows..sort((a, b) => a.start.compareTo(b.start));
  }

  /// The runs that draw `[from, to)` of the note, with the boxes of the
  /// formulas among them.
  (List<InlineSpan>, List<(int, PlaceholderDimensions)>) _spansIn(
    _Styling styling,
    int from,
    int to,
  ) {
    final source = text;
    final base = styling.base;
    final scaler = styling.scaler;
    final titleEnd = styling.titleEnd;
    final linkColor = styling.linkColor;
    final composing = styling.composing;
    final spans = styling.spans.overlapping(from, to);
    final links = styling.links.overlapping(from, to);
    final markdownSpans = styling.markdown.overlapping(from, to);
    final hidden = styling.hidden.overlapping(from, to);
    final transparent = styling.transparent.overlapping(from, to);
    final stretches = styling.stretches.overlapping(from, to);
    final formulas = styling.formulas.overlapping(from, to);
    final code = styling.code.overlapping(from, to);
    bool overlaps(int start, int end) => start < to && end > from;
    final checkedRanges = [
      for (final range in styling.checked)
        if (overlaps(range.start, range.end)) range,
    ];
    final formats = [
      for (final format in _formats)
        if (overlaps(format.start, format.end)) format,
    ];
    final misspellings = [
      for (final suggestion in spellingSuggestions)
        if (overlaps(suggestion.range.start, suggestion.range.end)) suggestion,
    ];
    final boxGlyphs = styling.boxGlyphs;

    // Cut the text at every span edge and at the composing-region edges, then
    // emit one run per segment. Doing it via a boundary set keeps the two
    // kinds of styling from having to know about each other.
    final boundaries = <int>{from, to};
    void cut(int at) {
      if (at > from && at < to) boundaries.add(at);
    }

    cut(titleEnd);
    for (final span in spans) {
      cut(span.start);
      cut(span.end);
    }
    for (final link in links) {
      cut(link.start);
      cut(link.end);
    }
    for (final format in formats) {
      cut(format.start);
      cut(format.end);
    }
    for (final range in checkedRanges) {
      cut(range.start);
      cut(range.end);
    }
    for (final suggestion in misspellings) {
      cut(suggestion.range.start);
      cut(suggestion.range.end);
    }
    for (final offset in _imageSpans.keys) {
      if (offset < from || offset >= to) continue;
      cut(offset);
      cut(offset + 1);
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
    for (final formula in formulas) {
      cut(formula.start + 1);
    }
    for (final token in code) {
      cut(token.start);
      cut(token.end);
    }
    if (composing != null) {
      cut(composing.start);
      cut(composing.end);
    }

    final cuts = boundaries.toList()..sort();
    final children = <InlineSpan>[];
    var spanIndex = 0;
    var linkIndex = 0;
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
    var formulaIndex = 0;
    var codeIndex = 0;
    final placeholders = <(int, PlaceholderDimensions)>[];

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
          (transparentIndex < transparent.length &&
              transparent[transparentIndex].start <= start) ||
          boxGlyphs.contains(start);
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
          source.codeUnitAt(start) != PlaceholderSpan.placeholderCodeUnit
              ? _StandInSpan(text: source[start], child: image.child)
              : WidgetSpan(
                  alignment: PlaceholderAlignment.top,
                  child: image.child,
                ),
        );
        continue;
      }

      // A formula drawn as itself stands in the place of its first character,
      // the way a picture does, with the rest of its TeX hidden after it.
      while (formulaIndex < formulas.length &&
          formulas[formulaIndex].end <= start) {
        formulaIndex++;
      }
      final formula =
          formulaIndex < formulas.length &&
              formulas[formulaIndex].start <= start
          ? formulas[formulaIndex]
          : null;
      if (formula != null && start == formula.start) {
        final (span, placeholder) = _formulaSpan(
          formula,
          copy: styling.copies[formula.start]!,
          words: _markdownBlockStyle(
            base,
            base,
            (style) => style != MarkdownStyle.math && marked(style),
          ),
          base: base,
          scaler: scaler,
          indent: formula.display
              ? _indent(
                  formula.start,
                  styling.hidden.items,
                  styling.stretches.items,
                  base,
                  scaler,
                )
              : 0,
        );
        children.add(span);
        placeholders.add((formula.start, placeholder));
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
      final misspelled = misspellings.any(
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
      // A comment is muted as a whole, so a link written in one keeps the
      // comment's colour rather than lighting up in the middle of it. It is
      // still a link: it opens, and spelling leaves it alone.
      final segmentLinkColor = active?.kind == HighlightKind.comment
          ? _palette.comment
          : linkColor;
      if (markdown != 0) {
        segmentStyle = _markdownBlockStyle(segmentStyle, base, marked);
      }
      while (codeIndex < code.length && code[codeIndex].end <= start) {
        codeIndex++;
      }
      if (codeIndex < code.length && code[codeIndex].start <= start) {
        segmentStyle = segmentStyle.merge(
          _codeTokenStyle(code[codeIndex].kind),
        );
      }
      final matchingFormats = formats.where(
        (format) => format.start <= start && format.end >= end,
      );
      final activeFormats = [
        ...matchingFormats.where((format) => format.format.isParagraph),
        ...matchingFormats.where((format) => format.format.isInline),
      ];
      for (final format in activeFormats) {
        // The title is set as one whatever paragraph style its line had.
        if (start < titleEnd && format.format.isParagraph) continue;
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
      if (start < titleEnd) {
        segmentStyle = noteTitleStyle(segmentStyle, writingFont: _writingFont);
      }
      final done = checked || marked(MarkdownStyle.doneTask);
      // A spelling mark must not replace KapyNotes' syntax, rich formatting,
      // link, or attachment spans. It is just one quiet decoration layered on
      // top. Links are distinguished by colour and pointer behaviour, while
      // completed tasks keep their strike-through.
      if (misspelled && activeLink == null && !done) {
        segmentStyle = segmentStyle.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: styling.errorColor,
          decorationStyle:
              defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.macOS
              ? TextDecorationStyle.dotted
              : TextDecorationStyle.wavy,
        );
      }
      if (activeLink != null) {
        segmentStyle = _chipLink(activeLink) && start >= titleEnd
            ? _linkChipStyle(segmentStyle)
            : segmentStyle.copyWith(
                color: segmentLinkColor,
                decoration: TextDecoration.underline,
                decorationColor: segmentLinkColor,
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
          letterSpacing: stretch?.spacing,
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

      // A line break inside a formula drawn as itself would still break the
      // line, hidden or not, and leave an empty line under the formula for
      // each one; the span the field draws is not the note's text, so here it
      // is a space.
      final words = source.substring(start, end);
      children.add(
        TextSpan(
          text: formula == null ? words : words.replaceAll(_lineEnd, ' '),
          style: segmentStyle,
        ),
      );
    }

    return (children, placeholders);
  }

  static final _lineEnd = RegExp('[\r\n]');

  /// Where the line [from] is on ends: its line break, or the end of [source].
  static int _lineEndAt(String source, int from) {
    final end = source.indexOf('\n', from);
    return end < 0 ? source.length : end;
  }

  /// Whether [link] is a web address written out, which the page sets as a
  /// chip. A markdown link's words stay words.
  bool _chipLink(NoteLink link) =>
      _cachedWebSpans.contains((link.start, link.end));

  /// A web address on the page: Paper's link chip, Geist Mono at 12.5 in the
  /// muted ink, keeping the row it sits in. The chip under it is drawn by the
  /// backdrop.
  TextStyle _linkChipStyle(TextStyle style) {
    final size = style.fontSize == null ? null : style.fontSize! * 12.5 / 16;
    final row = style.fontSize == null || style.height == null
        ? null
        : style.fontSize! * style.height!;
    return style.copyWith(
      fontFamily: AppFonts.mono,
      fontFamilyFallback: AppFonts.monoFallback,
      fontVariations: const [],
      fontWeight: FontWeight.w400,
      fontSize: size,
      height: row == null || size == null ? null : row / size,
      color: _palette.textMuted,
      decoration: TextDecoration.none,
    );
  }

  static final _scheme = RegExp('^https?://');

  /// The \`https://\` of each chip the caret is not in: Paper's pill shows the
  /// address without it, and it comes back for whoever is editing the link.
  List<TextRange> _chipSchemes(String source) {
    final titleEnd = _lineEndAt(source, 0);
    return [
      for (final link in linksFor(source))
        if (link.start >= titleEnd &&
            _chipLink(link) &&
            (selection.end < link.start || selection.start > link.end))
          if (_scheme.firstMatch(source.substring(link.start, link.end))
              case final scheme?)
            TextRange(start: link.start, end: link.start + scheme.end),
    ];
  }

  /// The web addresses in [source] the page sets as chips: all but those in
  /// the title, which stay in the title's face.
  List<TextRange> linkChips(String source) {
    final titleEnd = _lineEndAt(source, 0);
    return [
      for (final link in linksFor(source))
        if (link.start >= titleEnd && _chipLink(link))
          TextRange(start: link.start, end: link.end),
    ];
  }

  String? _boxesFor;
  List<MarkdownOrnament> _boxes = const [];

  /// The app's own checkboxes in [source], the ☐ and ☑ at the start of a
  /// line's words, as the ornaments the page draws them as.
  List<MarkdownOrnament> plainCheckboxes(String source) {
    if (_boxesFor == source) return _boxes;
    final boxes = <MarkdownOrnament>[];
    var lineStart = 0;
    while (lineStart < source.length) {
      final lineEnd = _lineEndAt(source, lineStart);
      var at = lineStart;
      while (at < lineEnd && source[at] == ' ') {
        at++;
      }
      final checked = source.startsWith(checkedPrefix, at);
      if (checked || source.startsWith(uncheckedPrefix, at)) {
        boxes.add(
          MarkdownOrnament(
            MarkdownOrnamentKind.checkbox,
            at,
            at + 1,
            checked: checked,
          ),
        );
      }
      lineStart = lineEnd + 1;
    }
    _boxesFor = source;
    return _boxes = boxes;
  }

  /// The page's room: a checkbox's glyph spaced out so that it and the space
  /// after it take a box and its gap, unpainted for the box drawn there, and
  /// the space before a link chip widened by the chip's reach.
  List<_Stretch> _pageStretches(
    String source,
    List<MarkdownOrnament> boxes,
    List<NoteLink> links,
    TextStyle base,
    TextScaler scaler,
  ) {
    final room = markdownMarkerRoom(base, scaler);
    final reach = scaler.scale(EditorMetrics.linkChipLead);
    double advance(int start, int end) =>
        _advance(source.substring(start, end), base, scaler);
    return [
      for (final box in boxes)
        (
          start: box.start,
          end: box.end,
          spacing:
              (room - advance(box.start, box.end + 1)) /
              (box.start == 0 || source[box.start - 1] == '\n' ? 1.5 : 1),
        ),
      for (final link in links)
        if (_chipLink(link) && link.start > 0 && source[link.start - 1] == ' ')
          (start: link.start - 1, end: link.start, spacing: reach),
    ];
  }

  /// Room for the pill under inline code, which reaches
  /// [EditorMetrics.codeChipReach] past its words: after the character
  /// before its hidden backtick, and after its last character, which the
  /// pill then covers.
  List<_Stretch> _codeChipStretches(
    String source,
    MarkdownAnalysis analysis,
    TextScaler scaler,
  ) {
    final reach = scaler.scale(EditorMetrics.codeChipReach);
    return [
      for (final chip in analysis.ornaments)
        if (chip.kind == MarkdownOrnamentKind.codeSpan &&
            chip.end > chip.start) ...[
          if (chip.start >= 2 && source[chip.start - 2] != '\n')
            (start: chip.start - 2, end: chip.start - 1, spacing: reach),
          (start: chip.end - 1, end: chip.end, spacing: reach),
        ],
    ];
  }

  /// How much bigger a formula is set than the words around it. KaTeX's own
  /// face runs small beside a sans serif at the same size.
  static const double _mathScale = 1.1;

  /// [formula] as a placeholder, and the box [placeholderDimensions] reports
  /// for it.
  ///
  /// Among words a formula sits on their baseline. Set apart, it is centred
  /// across what is left of the writing column after [indent], in the middle
  /// of a line of its own. Both are drawn in the size and colour of the words
  /// they stand among, in [words].
  ///
  /// A placeholder's widget is scaled with the text by the field, so it is
  /// built at the size the text is before scaling, and the box is reported
  /// at the size it comes out at. [copy] is which of the formulas drawn with
  /// the same TeX this one is: see [NoteMath.formula].
  (WidgetSpan, PlaceholderDimensions) _formulaSpan(
    MarkdownMath formula, {
    required int copy,
    required TextStyle words,
    required TextStyle base,
    required TextScaler scaler,
    required double indent,
  }) {
    final size = base.fontSize ?? kDefaultFontSize;
    final scale = scaler.scale(size) / size;
    final room = math.max(0.0, _mathWidth - indent) / scale;
    final drawn = _math.formula(
      formula.tex,
      display: formula.display,
      fontSize: (words.fontSize ?? size) * _mathScale,
      color: words.color ?? _palette.textPrimary,
      maxWidth: room,
      copy: copy,
    );
    if (!formula.display) {
      return (
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: drawn.child,
        ),
        PlaceholderDimensions(
          size: Size(drawn.width * scale, drawn.height * scale),
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          baselineOffset: drawn.baseline * scale,
        ),
      );
    }
    final width = math.max(room, drawn.width);
    return (
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: SizedBox(
          width: width,
          height: drawn.height,
          child: Center(child: drawn.child),
        ),
      ),
      PlaceholderDimensions(
        size: Size(width * scale, drawn.height * scale),
        alignment: PlaceholderAlignment.middle,
      ),
    );
  }

  /// How far into its line [offset] is drawn: the advance of what is shown
  /// before it, with the room any list marker there is spaced out to.
  double _indent(
    int offset,
    List<TextRange> hidden,
    List<_Stretch> stretches,
    TextStyle base,
    TextScaler scaler,
  ) {
    final source = text;
    final lineStart = offset == 0
        ? 0
        : source.lastIndexOf('\n', offset - 1) + 1;
    if (lineStart >= offset) return 0;
    final painter = TextPainter(
      text: TextSpan(
        style: base,
        children: [
          for (var i = lineStart; i < offset; i++)
            if (!hidden.any((range) => range.start <= i && i < range.end))
              TextSpan(
                text: source[i],
                style: TextStyle(
                  letterSpacing: stretches
                      .where((stretch) => stretch.start <= i && i < stretch.end)
                      .firstOrNull
                      ?.spacing,
                ),
              ),
        ],
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter
        .getOffsetForCaret(
          TextPosition(offset: painter.plainText.length),
          Rect.zero,
        )
        .dx;
    painter.dispose();
    return width;
  }

  MarkdownAnalysis? _colouredFor;
  List<CodeToken> _colouredCode = const [];

  /// The colours of [analysis]'s fenced code, worked out once per analysis.
  List<CodeToken> _codeTokens(MarkdownAnalysis analysis) {
    if (identical(analysis, _colouredFor)) return _colouredCode;
    _colouredFor = analysis;
    return _colouredCode = analysis.fencedCode.isEmpty
        ? const []
        : _codeHighlighter.tokensIn(analysis.text, analysis.fencedCode);
  }

  /// Code coloured from the note's own palette, so that it sits in the note
  /// in light and in dark alike rather than in some editor's theme: Paper's
  /// clay, sage, ochre and teal, with a function's name in the ink, bold.
  TextStyle _codeTokenStyle(CodeTokenKind kind) => switch (kind) {
    CodeTokenKind.keyword => TextStyle(color: _palette.codeKeyword),
    CodeTokenKind.builtIn => TextStyle(color: _palette.codeBuiltIn),
    CodeTokenKind.string => TextStyle(color: _palette.codeString),
    CodeTokenKind.number => TextStyle(color: _palette.codeNumber),
    CodeTokenKind.comment => TextStyle(
      color: _palette.textTertiary,
      fontStyle: FontStyle.italic,
    ),
    CodeTokenKind.title => TextStyle(
      color: _palette.textPrimary,
      fontWeight: FontWeight.w600,
    ),
    CodeTokenKind.type ||
    CodeTokenKind.attribute => TextStyle(color: _palette.codeBuiltIn),
    CodeTokenKind.variable => TextStyle(color: _palette.textSubheading),
    CodeTokenKind.punctuation => TextStyle(color: _palette.textTertiary),
  };

  @override
  void dispose() {
    _math.dispose();
    super.dispose();
  }

  /// The room a list marker takes — a bullet, a box or a number, with the
  /// space after it — so that every item's words start in one column and
  /// each level of nesting is one more room in, the way GitHub and Craft lay
  /// a list out, rather than wherever its characters happen to end.
  ///
  /// Enough for a task's box and a gap, and for a one-digit number, its dot
  /// and a space, in the note's own face: a monospace one needs more.
  double markdownMarkerRoom(TextStyle base, TextScaler scaler) => math.max(
    scaler.scale(markdownMarkerPageRoom),
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

    // On the page a quote's words start where Paper's do, past its bar: the
    // hidden `>` of each line takes that room.
    {
      var barredLine = -1;
      for (final marker in analysis.containerMarkers) {
        if (text[marker.start] != '>') continue;
        final lineStart = marker.start == 0
            ? 0
            : text.lastIndexOf('\n', marker.start - 1) + 1;
        if (lineStart == barredLine) continue;
        barredLine = lineStart;
        final end =
            marker.end +
            (marker.end < text.length && text[marker.end] == ' ' ? 1 : 0);
        final letters =
            end - marker.start + (marker.start == lineStart ? 0.5 : 0);
        stretches.add((
          start: marker.start,
          end: end,
          spacing: EditorMetrics.quoteIndent / letters,
        ));
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
    if (marked(MarkdownStyle.codeBlock) ||
        marked(MarkdownStyle.code) ||
        marked(MarkdownStyle.math)) {
      // The panel under a code block and the pill under inline code are drawn
      // behind the field, where the selection highlight still shows over them.
      // A formula's TeX, shown as written, is code too, in a step softer ink.
      result = _codeStyle(result).copyWith(color: _palette.textSubheading);
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

  /// How [words] under [styles] are drawn somewhere other than the field —
  /// in a table drawn as a grid — in the faces and colours they have in it.
  TextStyle markdownRunStyle(
    TextStyle base,
    Set<MarkdownStyle> styles,
    Color linkColor, {
    String words = '',
  }) {
    bool marked(MarkdownStyle style) => styles.contains(style);
    return _markdownInlineStyle(
      _markdownBlockStyle(base, base, marked),
      marked,
      linkColor,
      words,
    );
  }

  /// The markdown that changes a word rather than a block. [script] is all
  /// of the superscript or subscript the words are part of, if they are.
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
    if (marked(MarkdownStyle.listMarker)) {
      result = result.copyWith(
        color: _palette.textSecondary,
        fontWeight: FontWeight.w600,
      );
    }
    if (marked(MarkdownStyle.taskBox)) {
      result = result.copyWith(color: _palette.textSecondary);
    }
    if (marked(MarkdownStyle.html)) {
      result = result.copyWith(color: _palette.comment);
    }
    return result;
  }

  /// Superscript or subscript: the face's own raised or lowered glyphs where
  /// it has one for every character of [script], and otherwise the same words
  /// smaller. A text engine cannot move words off their baseline, and the
  /// line keeps its height either way.
  ///
  /// Which characters a face has these for is known for the faces a note is
  /// written in: Shantell Sans for digits, the system face on Apple's
  /// platforms for digits, small letters and `+=()`. Anywhere else the words
  /// are drawn smaller.
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
      fontSize: size * _scriptScale,
      height: height == null ? null : height / _scriptScale,
    );
  }

  static const double _scriptScale = 0.75;
  static final _digits = '0123456789'.runes.toSet();
  static final _appleScriptCharacters =
      '0123456789abcdefghijklmnopqrstuvwxyz+=()'.runes.toSet();

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

/// What [HighlightingController._spansIn] styles the note's text by: see
/// [HighlightingController._stylingFor].
typedef _Styling = ({
  TextStyle base,
  TextScaler scaler,
  int titleEnd,
  Color linkColor,
  Color errorColor,
  TextRange? composing,
  List<TextRange> checked,
  Set<int> boxGlyphs,
  _Sorted<HighlightSpan> spans,
  _Sorted<NoteLink> links,
  _Sorted<MarkdownSpan> markdown,
  _Sorted<TextRange> hidden,
  _Sorted<TextRange> transparent,
  _Sorted<_Stretch> stretches,
  _Sorted<MarkdownMath> formulas,
  _Sorted<CodeToken> code,
  _Sorted<({int start, int end, double row, double inset})> rows,
  Map<int, int> copies,
});

/// Ranges in the order they start, with those that overlap a stretch of the
/// note found by a binary search rather than a walk from the top.
class _Sorted<T> {
  _Sorted(this.items, this._extent) {
    var reach = 0;
    _reach = [
      for (final item in items) reach = math.max(reach, _extent(item).$2),
    ];
  }

  final List<T> items;
  final (int, int) Function(T) _extent;

  /// The furthest any of the first i + 1 items reaches.
  late final List<int> _reach;

  /// Those of [items] that overlap `[from, to)`, in order.
  List<T> overlapping(int from, int to) {
    final first = _search(_reach.length, (i) => _reach[i] > from);
    final last = _search(items.length, (i) => _extent(items[i]).$1 >= to);
    return [
      for (var i = first; i < last; i++)
        if (_extent(items[i]).$2 > from) items[i],
    ];
  }

  /// The first of 0 to [count] at which [test] holds, given that once it
  /// holds it holds for every one after; [count] when it never does.
  static int _search(int count, bool Function(int) test) {
    var low = 0;
    var high = count;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (test(middle)) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low;
  }
}

/// A placeholder standing in for a character of the note, such as the
/// title's letter that carries the room under the title, which reads to a
/// screen reader and copies as that character rather than as an object.
class _StandInSpan extends WidgetSpan {
  const _StandInSpan({required this.text, required super.child})
    : super(alignment: PlaceholderAlignment.top);

  final String text;

  @override
  void computeToPlainText(
    StringBuffer buffer, {
    bool includeSemanticsLabels = true,
    bool includePlaceholders = true,
  }) => buffer.write(text);

  @override
  void computeSemanticsInformation(
    List<InlineSpanSemanticsInformation> collector,
  ) => collector.add(InlineSpanSemanticsInformation(text));

  @override
  bool operator ==(Object other) =>
      other is _StandInSpan && other.text == text && super == other;

  @override
  int get hashCode => Object.hash(super.hashCode, text);
}

/// The text the field draws, which works out its semantics information once
/// and keeps it.
///
/// The field works that information out afresh, over every run in the note,
/// each time its semantics are marked dirty, and taking in a widget marks
/// them. So without this, opening a note with hundreds of formulas walked the
/// whole note that many times over whenever the semantics tree was on, and on
/// macOS it always is, for dictation: see `AccessibilityTree.swift`.
class _NoteSpan extends TextSpan {
  _NoteSpan({super.style, super.children});

  late final List<InlineSpanSemanticsInformation> _semantics =
      List.unmodifiable(super.getSemanticsInformation());

  @override
  List<InlineSpanSemanticsInformation> getSemanticsInformation() => _semantics;
}
