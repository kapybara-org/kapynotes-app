import 'ast.dart';
import 'evaluator.dart';
import 'format.dart';
import 'lexer.dart';
import 'parser.dart';
import 'unit_registry.dart';
import 'value.dart';

/// The result attached to one line of a note.
class LineResult {
  final int line;
  final CalcValue value;

  /// Compact, grouped text for the gutter chip.
  final String text;

  /// Full-precision text for the clipboard.
  final String copyText;

  final DigitGrouping grouping;

  /// Number-system-aware words and scale context, prepared only if a visible
  /// chip needs them. Long notes should not spell every off-screen result on
  /// each keystroke.
  late final String tooltipText = ResultFormatter.tooltip(
    value,
    grouping: grouping,
  );

  LineResult({
    required this.line,
    required this.value,
    required this.text,
    required this.copyText,
    this.grouping = DigitGrouping.international,
  });

  ResultKind get kind => value.kind;
}

/// One pass over a note, including both its line-by-line results and the
/// running total that remains after the final line.
class DocumentEvaluation {
  final Map<int, LineResult> results;
  final CalcValue? total;
  final DigitGrouping grouping;

  const DocumentEvaluation({
    required this.results,
    required this.total,
    this.grouping = DigitGrouping.international,
  });

  /// Null when the note holds no calculations at all, so the footer can omit
  /// the readout rather than claim a total of zero.
  String? get totalText => total == null
      ? null
      : ResultFormatter.display(total!, grouping: grouping);
}

class _EvaluatedLine {
  final LineResult result;
  final bool isAggregateReadout;

  const _EvaluatedLine({
    required this.result,
    required this.isAggregateReadout,
  });
}

/// Evaluates a note, one line at a time, against a scope that carries
/// forward — so `subtotal = 42` on line 1 is usable on line 7.
///
/// An engine is immutable with respect to its unit table; when exchange rates
/// change a new engine is built rather than mutated, which keeps evaluation
/// free of half-updated currency state.
class CalcEngine {
  final UnitRegistry registry;

  /// Where separators fall in the results this engine renders. Changing it
  /// means building a new engine, exactly as a rate change does.
  final DigitGrouping grouping;

  CalcEngine({
    Map<String, double> ratesPerUsd = const {},
    this.grouping = DigitGrouping.international,
  }) : registry = UnitRegistry(ratesPerUsd: ratesPerUsd);

  bool get hasCurrencyRates => registry.hasCurrencies;

  /// Evaluates every line of [body], returning results keyed by line index.
  /// Lines that are prose, blank, or unparseable are simply absent.
  Map<int, LineResult> evaluateDocument(String body) =>
      evaluateDocumentWithSummary(body).results;

  /// Evaluates a note once and exposes the same running total used by the
  /// `sum` and `total` aggregate names.
  DocumentEvaluation evaluateDocumentWithSummary(String body) {
    final scope = CalcScope();
    final evaluator = Evaluator(registry: registry, scope: scope);
    final results = <int, LineResult>{};
    final lines = body.split('\n');

    for (var i = 0; i < lines.length; i++) {
      final evaluated = _evaluateLine(lines[i], i, evaluator, scope);
      if (evaluated != null) {
        results[i] = evaluated.result;
        // Aggregate readouts, including conversions such as `total to usd`,
        // report the total without becoming another entry in it.
        if (!evaluated.isAggregateReadout) {
          scope.record(evaluated.result.value);
        }
      }
    }
    return DocumentEvaluation(
      results: Map<int, LineResult>.unmodifiable(results),
      total: scope.runningSum,
      grouping: grouping,
    );
  }

  /// True when the parsed expression only reads an aggregate, optionally
  /// converting it to another unit or currency for display.
  static bool _isAggregateReadout(Node node) => switch (node) {
    IdentifierNode() => aggregateNames.contains(node.name.toLowerCase()),
    ConvertNode() => _isAggregateReadout(node.value),
    _ => false,
  };

  _EvaluatedLine? _evaluateLine(
    String rawLine,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    final source = _prepare(rawLine, scope);
    if (source == null) return null;

    return _evaluateExpression(source, index, evaluator, scope) ??
        _labelledAmount(source, index, evaluator, scope) ??
        _labelledArithmetic(source, index, evaluator, scope);
  }

  _EvaluatedLine? _evaluateExpression(
    String source,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    try {
      final node = Parser(
        source,
        registry: registry,
        boundNames: scope.variables.keys.toSet(),
      ).parseLine();
      final value = evaluator.evaluate(node);
      return _EvaluatedLine(
        result: LineResult(
          line: index,
          value: value,
          text: ResultFormatter.display(value, grouping: grouping),
          copyText: ResultFormatter.copy(value),
          grouping: grouping,
        ),
        isAggregateReadout: _isAggregateReadout(node),
      );
    } on CalcError {
      return null;
    } catch (_) {
      // A malformed line is a line the user is still typing, not an error.
      return null;
    }
  }

  /// Reads `Coffee $4.50` or `Run 5 km`: a label in plain words, then an
  /// amount that says what it is.
  ///
  /// Only tried once the line has failed to parse whole, and only a suffix
  /// carrying a currency or a unit is accepted. A bare trailing number is
  /// refused on purpose — `Room 12` and `Chapter 4` are the same shape as
  /// `Lunch 12`, and nothing in the text distinguishes them. The unit or
  /// currency is the user saying which one they meant.
  ///
  /// The other order — `12 mangoes`, where the number leads — needs no such
  /// marker and is read by [_quantityWithLabel].
  _EvaluatedLine? _labelledAmount(
    String source,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    final known = scope.variables.keys.toSet();
    final tokens = Lexer(source)
        .tokenize()
        .where((t) => t.isSignificant && t.type != TokenType.eof)
        .toList();
    if (tokens.length < 2) return null;

    for (var i = 0; i < tokens.length - 1; i++) {
      // Everything stepped over has to be an ordinary word. Stopping at the
      // first token that is not keeps a half-typed `2 + + 3 usd` from being
      // read as `3 usd`, and leaves any name the document has defined to go
      // on meaning what it says.
      final token = tokens[i];
      if (token.type != TokenType.identifier) return null;
      final name = token.text.toLowerCase();
      if (known.contains(token.text) ||
          aggregateNames.contains(name) ||
          mathConstants.contains(name)) {
        return null;
      }

      final evaluated = _evaluateExpression(
        source.substring(tokens[i + 1].start),
        index,
        evaluator,
        scope,
      );
      if (evaluated == null) continue;
      final kind = evaluated.result.value.kind;
      if (kind == ResultKind.currency || kind == ResultKind.unit) {
        return evaluated;
      }
    }
    return null;
  }

  /// Reads a line whose numbers carry words naming what they count:
  /// `12 mangoes`, `20 domains * 2`, `$2/mailbox`.
  ///
  /// The mirror of [_labelledAmount], and safe where that one needs a unit to
  /// be safe. Word order carries the meaning: a line that *opens* with a word
  /// is naming something — `Room 12`, `Chapter 4`, `iPhone 15` — while one
  /// that opens with an amount is stating a quantity. So the first word of the
  /// line has to be one the calculator already understands.
  ///
  /// After that the labels are simply taken out and what remains is evaluated
  /// as ordinary arithmetic. A label only counts as a label where it can only
  /// be one: directly after an amount, or after another label already dropped.
  /// That single rule is what separates `12 mangoes` from `10 min break` — in
  /// the first the word follows a bare number and is what the number counts,
  /// in the second it follows a unit that has already said what the amount is,
  /// and everything after that is prose. It is also what keeps `12 + mangoes`
  /// out: a word after an operator is an operand, and an operand nobody has
  /// defined is a line still being typed rather than a line about mangoes.
  ///
  /// `$2/mailbox` is the one shape that needs more than that. The label is the
  /// thing the rate is *per*, so the divide belongs to it and goes too, and
  /// what is left is the amount — which is what someone writing a price per
  /// mailbox means by it. A rate over something the calculator does know,
  /// `$120 / 3 months`, is untouched and stays a rate.
  _EvaluatedLine? _labelledArithmetic(
    String source,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    final tokens = Lexer(source)
        .tokenize()
        .where((t) => t.isSignificant && t.type != TokenType.eof)
        .toList();
    if (tokens.length < 2) return null;
    // Named, not counted.
    if (_isLabelWord(tokens.first, scope)) return null;

    final dropped = <int>{};
    for (var i = 1; i < tokens.length; i++) {
      if (!_isLabelWord(tokens[i], scope)) continue;
      // `2 x 3 widgets`: the parser reads that x as a multiplication sign, so
      // taking it out as a label here would leave two numbers side by side and
      // lose the line. See Parser's own rule for the shape.
      if (_isTimesLetter(
        tokens[i],
        i + 1 < tokens.length ? tokens[i + 1] : null,
      )) {
        continue;
      }
      if (_statesAnAmount(tokens[i - 1], dropped.contains(i - 1))) {
        dropped.add(i);
        continue;
      }
      // `$2/mailbox`, `$2 per mailbox`.
      final over = i - 1;
      if (over > 0 &&
          _isPerOperator(tokens[over]) &&
          _statesAnAmount(tokens[over - 1], dropped.contains(over - 1))) {
        dropped
          ..add(over)
          ..add(i);
      }
    }
    if (dropped.isEmpty) return null;

    final evaluated = _evaluateExpression(
      _withoutTokens(source, tokens, dropped),
      index,
      evaluator,
      scope,
    );
    if (evaluated == null) return null;
    // A comparison that happens to be followed by words is not a quantity.
    final kind = evaluated.result.value.kind;
    if (kind == ResultKind.boolean || kind == ResultKind.other) return null;
    return evaluated;
  }

  /// Whether [token] is the end of something with an amount in it, and so
  /// something a following word could be naming.
  static bool _statesAnAmount(Token token, bool wasDropped) =>
      wasDropped ||
      token.type == TokenType.number ||
      token.type == TokenType.percent ||
      token.type == TokenType.currencySymbol;

  static bool _isTimesLetter(Token token, Token? next) =>
      token.type == TokenType.identifier &&
      token.text.toLowerCase() == 'x' &&
      next != null &&
      (next.type == TokenType.number ||
          next.type == TokenType.currencySymbol ||
          next.type == TokenType.lparen);

  static bool _isPerOperator(Token token) =>
      (token.type == TokenType.operator &&
          (token.text == '/' || token.text == '÷')) ||
      (token.type == TokenType.identifier && token.text.toLowerCase() == 'per');

  /// [source] with the given tokens cut out, spacing preserved so the offsets
  /// of everything kept still read the same way.
  static String _withoutTokens(
    String source,
    List<Token> tokens,
    Set<int> dropped,
  ) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final i in dropped.toList()..sort()) {
      buffer.write(source.substring(cursor, tokens[i].start));
      cursor = tokens[i].end;
    }
    buffer.write(source.substring(cursor));
    return buffer.toString();
  }

  /// True for a word the calculator can make nothing of, and so can read as
  /// part of a label.
  bool _isLabelWord(Token token, CalcScope scope) {
    if (token.type != TokenType.identifier) return false;
    // A word with a digit in it is a code, a model or a run-together sum —
    // `2x3` lexes as `2` and `x3` — and none of those are what a number
    // counts. Reading them as labels answered `2x3` with 2, which is a wrong
    // answer where saying nothing was available.
    if (token.text.contains(RegExp(r'[0-9]'))) return false;
    final name = token.text.toLowerCase();
    return !scope.variables.containsKey(token.text) &&
        !calcKeywords.contains(name) &&
        !aggregateNames.contains(name) &&
        !mathConstants.contains(name) &&
        !booleanLiterals.contains(name) &&
        !functionNames.contains(name) &&
        !registry.isUnit(name);
  }

  /// Decides whether a line is worth evaluating, and rewrites the couple of
  /// shorthands that are easier to handle before parsing than during it.
  ///
  /// Returns null for lines that should stay plain text.
  String? _prepare(String rawLine, CalcScope scope) {
    var line = rawLine.trim();
    if (line.isEmpty) return null;
    // Full-line comments must be dismissed before the leading-operator
    // continuation below. Otherwise `// note` begins with `/` and can be
    // rewritten as `prev // note`, accidentally repeating the prior result.
    if (line.startsWith('//') || line.startsWith('#')) return null;

    // A leading `=` is how many people start a calculation out of habit.
    if (line.startsWith('=') && !line.startsWith('==')) {
      line = line.substring(1).trim();
    }
    // A trailing `=` is the same habit from the other end.
    if (line.endsWith('=') && !line.endsWith('==')) {
      line = line.substring(0, line.length - 1).trim();
    }
    if (line.isEmpty) return null;

    // A line starting with an operator continues the one above it, so a
    // column of `+ 12` reads as a running tally. `-` is excluded because
    // `-5` on its own is a perfectly good negative number.
    if (scope.prev != null && line.length > 1) {
      final first = line[0];
      if (const ['+', '*', '/', '^', '×', '÷'].contains(first)) {
        line = 'prev $line';
      }
    }

    return looksLikeMath(line, scope.variables.keys.toSet()) ? line : null;
  }

  /// Prose and calculations share the document, so the engine only attempts
  /// lines that carry some arithmetic signal: a digit, an operator, or a name
  /// the document has already defined.
  ///
  /// Also used by the highlighter, so colouring and evaluation agree on which
  /// lines are calculations.
  static bool looksLikeMath(String line, Set<String> knownNames) {
    final tokens = Lexer(
      line,
    ).tokenize().where((t) => t.isSignificant).toList();
    // Drop the trailing EOF.
    if (tokens.isNotEmpty) tokens.removeLast();
    if (tokens.isEmpty) return false;

    var hasNumber = false;
    var hasOperator = false;
    var hasKnownName = false;

    for (final token in tokens) {
      switch (token.type) {
        case TokenType.number:
          hasNumber = true;
        case TokenType.operator:
        case TokenType.percent:
        case TokenType.currencySymbol:
          hasOperator = true;
        case TokenType.identifier:
          final name = token.text;
          if (knownNames.contains(name) ||
              aggregateNames.contains(name.toLowerCase()) ||
              mathConstants.contains(name.toLowerCase())) {
            hasKnownName = true;
          }
        default:
          break;
      }
    }
    return hasNumber || hasOperator || hasKnownName;
  }
}
