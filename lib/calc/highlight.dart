import '../core/note_link.dart';
import 'engine.dart';
import 'lexer.dart';
import 'parser.dart';
import 'unit_registry.dart';

/// Semantic categories the editor paints. Kept separate from colours so the
/// theme owns the palette.
enum HighlightKind {
  plain,
  number,
  constant,
  keyword,
  aggregate,
  unit,
  currency,
  function,
  variable,
  operator,
  punctuation,
  comment,
}

class HighlightSpan {
  final int start;
  final int end;
  final HighlightKind kind;

  const HighlightSpan(this.start, this.end, this.kind);
}

/// Classifies note text for display.
///
/// It runs the same [Lexer] the parser uses after masking web links, which are
/// prose rather than calculator syntax. Lines that are not calculations are
/// left uncoloured, so ordinary writing stays quiet.
class Highlighter {
  final UnitRegistry registry;

  const Highlighter(this.registry);

  /// Returns spans over the whole document, in order, covering only the
  /// characters that need colour. Gaps render in the default text colour.
  List<HighlightSpan> spans(String body, {List<NoteLink>? links}) {
    final knownNames = _assignedNames(body);
    final noteLinks = links ?? findNoteLinks(body);
    final out = <HighlightSpan>[];
    var offset = 0;

    for (final line in body.split('\n')) {
      final commentStart = _commentStart(line, offset, noteLinks);
      final content = commentStart < 0 ? line : line.substring(0, commentStart);
      final highlightableContent = _maskLinks(content, offset, noteLinks);
      final valueStart = _explicitDescriptionValueStart(
        highlightableContent,
        knownNames,
      );
      final calculatorContent = valueStart == null
          ? highlightableContent
          : highlightableContent.substring(valueStart);
      final calculatorOffset = offset + (valueStart ?? 0);
      if (calculatorContent.trim().isNotEmpty &&
          CalcEngine.looksLikeMath(calculatorContent, knownNames)) {
        _spansForLine(calculatorContent, calculatorOffset, knownNames, out);
      }
      if (commentStart >= 0) {
        // Inline comments are valid after prose as well as calculations. Keep
        // everything before the delimiter in its normal style and mute only
        // the comment itself.
        out.add(
          HighlightSpan(
            offset + commentStart,
            offset + line.length,
            HighlightKind.comment,
          ),
        );
      }
      offset += line.length + 1;
    }
    return out;
  }

  /// A descriptive label containing several words or its own number is prose
  /// even though a value follows it. Paint only the right side, matching the
  /// engine's rightmost-colon rule and making it visually clear that `7` in
  /// `7KvA Solar System: 12000rs` did not enter the calculation.
  static int? _explicitDescriptionValueStart(
    String line,
    Set<String> knownNames,
  ) {
    final tokens = Lexer(line)
        .tokenize()
        .where((token) => token.isSignificant && token.type != TokenType.eof)
        .toList();
    for (var i = tokens.length - 2; i > 0; i--) {
      final colon = tokens[i];
      if (colon.type != TokenType.operator || colon.text != ':') continue;
      final before = tokens[i - 1];
      final after = tokens[i + 1];
      if (before.type == TokenType.number &&
          after.type == TokenType.number &&
          before.end == colon.start &&
          colon.end == after.start) {
        continue;
      }

      final prefix = tokens.take(i).toList();
      final identifiers = prefix
          .where((token) => token.type == TokenType.identifier)
          .length;
      final isDescription =
          identifiers > 1 ||
          prefix.any(
            (token) =>
                token.type == TokenType.number ||
                token.type == TokenType.unknown,
          );
      if (!isDescription) continue;

      var start = colon.end;
      while (start < line.length && line[start].trim().isEmpty) {
        start++;
      }
      if (start < line.length &&
          CalcEngine.looksLikeMath(line.substring(start), knownNames)) {
        return start;
      }
    }
    return null;
  }

  /// Finds the first real comment delimiter, skipping slashes that belong to
  /// a detected web address. Without this, `https://` would mute the rest of
  /// an otherwise ordinary note line as though it were a calculator comment.
  static int _commentStart(String line, int lineOffset, List<NoteLink> links) {
    var searchFrom = 0;
    while (searchFrom < line.length) {
      final index = line.indexOf('//', searchFrom);
      if (index < 0) return -1;
      final globalIndex = lineOffset + index;
      NoteLink? containingLink;
      for (final link in links) {
        if (link.start > globalIndex) break;
        if (link.start <= globalIndex && link.end > globalIndex + 1) {
          containingLink = link;
          break;
        }
      }
      if (containingLink == null) return index;
      searchFrom = (containingLink.end - lineOffset).clamp(
        index + 2,
        line.length,
      );
    }
    return -1;
  }

  /// Keeps source offsets stable while making URL punctuation invisible to
  /// the calculator lexer. In particular, its own `//` token must not repaint
  /// a URL and everything after it as a comment.
  static String _maskLinks(
    String content,
    int lineOffset,
    List<NoteLink> links,
  ) {
    List<int>? codeUnits;
    final lineEnd = lineOffset + content.length;
    for (final link in links) {
      if (link.end <= lineOffset) continue;
      if (link.start >= lineEnd) break;
      final start = (link.start - lineOffset).clamp(0, content.length);
      final end = (link.end - lineOffset).clamp(0, content.length);
      if (end <= start) continue;
      codeUnits ??= List<int>.of(content.codeUnits);
      codeUnits.fillRange(start, end, 0x20);
    }
    return codeUnits == null ? content : String.fromCharCodes(codeUnits);
  }

  void _spansForLine(
    String line,
    int offset,
    Set<String> knownNames,
    List<HighlightSpan> out,
  ) {
    final tokens = Lexer(line).tokenize();

    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final kind = _classify(token, tokens, i, knownNames);
      if (kind == HighlightKind.plain) continue;
      out.add(HighlightSpan(offset + token.start, offset + token.end, kind));
    }
  }

  HighlightKind _classify(
    Token token,
    List<Token> tokens,
    int index,
    Set<String> knownNames,
  ) {
    switch (token.type) {
      case TokenType.number:
        return HighlightKind.number;
      case TokenType.comment:
        return HighlightKind.comment;
      case TokenType.currencySymbol:
        return HighlightKind.currency;
      case TokenType.percent:
      case TokenType.operator:
        return HighlightKind.operator;
      case TokenType.lparen:
      case TokenType.rparen:
      case TokenType.comma:
        return HighlightKind.punctuation;
      case TokenType.identifier:
        return _classifyIdentifier(token, tokens, index, knownNames);
      default:
        return HighlightKind.plain;
    }
  }

  HighlightKind _classifyIdentifier(
    Token token,
    List<Token> tokens,
    int index,
    Set<String> knownNames,
  ) {
    final word = token.text.toLowerCase();

    // A name followed by "(" is a call, whatever else it might mean.
    final next = _nextSignificant(tokens, index);
    if (next?.type == TokenType.lparen && functionNames.contains(word)) {
      return HighlightKind.function;
    }

    // The user's own names win over units, matching evaluation order.
    if (knownNames.contains(token.text)) return HighlightKind.variable;

    if (aggregateNames.contains(word)) return HighlightKind.aggregate;
    if (mathConstants.contains(word) || booleanLiterals.contains(word)) {
      return HighlightKind.constant;
    }
    if (temporalNames.contains(word)) return HighlightKind.constant;
    if (functionNames.contains(word)) return HighlightKind.function;
    if (calcKeywords.contains(word)) return HighlightKind.keyword;

    final unit = registry.lookup(word);
    if (unit != null) {
      return unit.isCurrency ? HighlightKind.currency : HighlightKind.unit;
    }
    return HighlightKind.plain;
  }

  Token? _nextSignificant(List<Token> tokens, int index) {
    for (var i = index + 1; i < tokens.length; i++) {
      if (tokens[i].isSignificant) return tokens[i];
    }
    return null;
  }

  /// Collects every name the document assigns to, so a variable is coloured
  /// consistently on the lines above its definition too.
  static Set<String> _assignedNames(String body) {
    final names = <String>{};
    for (final line in body.split('\n')) {
      final tokens = Lexer(
        line,
      ).tokenize().where((t) => t.isSignificant).toList();
      if (tokens.length < 3) continue;
      final first = tokens[0];
      final second = tokens[1];
      if (first.type == TokenType.identifier &&
          second.type == TokenType.operator &&
          (second.text == '=' || second.text == ':') &&
          !calcKeywords.contains(first.text.toLowerCase()) &&
          !unitConfigurationNames.contains(first.text.toLowerCase())) {
        names.add(first.text);
      }
    }
    return names;
  }
}
