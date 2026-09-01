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
/// It runs the same [Lexer] the parser uses, so highlighting can never drift
/// from evaluation. Lines that are not calculations are left uncoloured,
/// which keeps prose from lighting up because it happens to contain "to".
class Highlighter {
  final UnitRegistry registry;

  const Highlighter(this.registry);

  /// Returns spans over the whole document, in order, covering only the
  /// characters that need colour. Gaps render in the default text colour.
  List<HighlightSpan> spans(String body) {
    final knownNames = _assignedNames(body);
    final out = <HighlightSpan>[];
    var offset = 0;

    for (final line in body.split('\n')) {
      if (line.trimLeft().startsWith('//')) {
        // A standalone comment is prose by definition, so it never reaches
        // the math-only token highlighting below. Dim the complete line,
        // including indentation, to make its role immediately clear.
        out.add(
          HighlightSpan(offset, offset + line.length, HighlightKind.comment),
        );
      } else if (line.trim().isNotEmpty &&
          CalcEngine.looksLikeMath(line, knownNames)) {
        _spansForLine(line, offset, knownNames, out);
      }
      offset += line.length + 1;
    }
    return out;
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
          !calcKeywords.contains(first.text.toLowerCase())) {
        names.add(first.text);
      }
    }
    return names;
  }
}
