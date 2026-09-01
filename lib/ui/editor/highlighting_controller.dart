import 'package:material_ui/material_ui.dart';

import '../../calc/highlight.dart';
import '../../core/theme.dart';

/// A [TextEditingController] that paints the note's own syntax.
///
/// Flutter can style a text field's content directly, so there is no need for
/// the layered "transparent textarea over a mirrored div" trick a web build
/// requires: this is one real, editable, syntax-coloured text field.
class HighlightingController extends TextEditingController {
  HighlightingController({
    required Highlighter highlighter,
    required CalcPalette palette,
    super.text,
  }) : _highlighter = highlighter,
       _palette = palette;

  Highlighter _highlighter;
  CalcPalette _palette;

  String? _cachedText;
  List<HighlightSpan> _cachedSpans = const [];

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

  void _invalidate() {
    _cachedText = null;
    _cachedSpans = const [];
  }

  List<HighlightSpan> spansFor(String source) {
    if (_cachedText == source) return _cachedSpans;
    _cachedSpans = _highlighter.spans(source);
    _cachedText = source;
    return _cachedSpans;
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
    if (composing != null) {
      boundaries.add(composing.start.clamp(0, source.length));
      boundaries.add(composing.end.clamp(0, source.length));
    }

    final cuts = boundaries.toList()..sort();
    final children = <TextSpan>[];
    var spanIndex = 0;

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

      var segmentStyle = active == null
          ? base
          : base.merge(_styleFor(active.kind));
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
