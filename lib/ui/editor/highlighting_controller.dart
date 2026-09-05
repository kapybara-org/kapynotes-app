import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../calc/highlight.dart';
import '../../core/editor_font.dart';
import '../../core/note_link.dart';
import '../../core/theme.dart';
import '../../data/note_format.dart';
import 'editor_formatting.dart';

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
    super.text,
  }) : _highlighter = highlighter,
       _palette = palette,
       _writingFont = writingFont,
       _formats = formats;

  Highlighter _highlighter;
  CalcPalette _palette;
  WritingFont _writingFont;
  List<NoteFormatRange> _formats;

  String? _cachedText;
  List<HighlightSpan> _cachedSpans = const [];
  List<NoteLink> _cachedLinks = const [];

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

  void _invalidate() {
    _cachedText = null;
    _cachedSpans = const [];
    _cachedLinks = const [];
  }

  List<HighlightSpan> spansFor(String source) {
    if (_cachedText == source) return _cachedSpans;
    _cachedLinks = findNoteLinks(source);
    _cachedSpans = _highlighter.spans(source, links: _cachedLinks);
    _cachedText = source;
    return _cachedSpans;
  }

  List<NoteLink> linksFor(String source) {
    spansFor(source);
    return _cachedLinks;
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
    if (composing != null) {
      boundaries.add(composing.start.clamp(0, source.length));
      boundaries.add(composing.end.clamp(0, source.length));
    }

    final cuts = boundaries.toList()..sort();
    final children = <TextSpan>[];
    var spanIndex = 0;
    var linkIndex = 0;
    final linkColor = Theme.of(context).colorScheme.primary;

    for (var i = 0; i < cuts.length - 1; i++) {
      final start = cuts[i];
      final end = cuts[i + 1];
      if (end <= start) continue;

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

      var segmentStyle = active == null
          ? base
          : base.merge(_styleFor(active.kind));
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
      if (activeLink != null) {
        segmentStyle = segmentStyle.copyWith(
          color: linkColor,
          decoration: TextDecoration.underline,
          decorationColor: linkColor.withValues(alpha: 0.82),
          decorationThickness: 1,
        );
      }
      final checked = checkedRanges.any(
        (range) => range.start <= start && range.end >= end,
      );
      if (checked) {
        segmentStyle = segmentStyle.copyWith(
          color: _palette.comment,
          decoration: activeLink == null
              ? TextDecoration.lineThrough
              : TextDecoration.combine(const [
                  TextDecoration.underline,
                  TextDecoration.lineThrough,
                ]),
          decorationColor: _palette.comment,
        );
      }
      if (composing != null &&
          start >= composing.start &&
          end <= composing.end) {
        segmentStyle = segmentStyle.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: segmentStyle.color,
        );
      }

      children.add(
        TextSpan(text: source.substring(start, end), style: segmentStyle),
      );
    }

    return TextSpan(style: base, children: children);
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
