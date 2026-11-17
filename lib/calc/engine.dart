import 'ast.dart';
import 'evaluator.dart';
import 'format.dart';
import 'lexer.dart';
import 'parser.dart';
import 'temporal.dart';
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

  /// Whether the line reads the note's running total, `total` or `sum`, or
  /// converts it, as `total in eur` does: the figure a list of amounts
  /// builds up to.
  final bool isTotal;

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
    this.isTotal = false,
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

  /// The same outcome on line [line].
  _EvaluatedLine at(int line) => _EvaluatedLine(
    result: LineResult(
      line: line,
      value: result.value,
      text: result.text,
      copyText: result.copyText,
      grouping: result.grouping,
      isTotal: result.isTotal,
    ),
    isAggregateReadout: isAggregateReadout,
  );
}

/// Evaluates a note, one line at a time, against a scope that carries
/// forward — so `subtotal = 42` on line 1 is usable on line 7.
///
/// An engine is immutable with respect to its unit table; when exchange rates
/// change a new engine is built rather than mutated, which keeps evaluation
/// free of half-updated currency state.
///
/// It remembers the lines it reads, each with what it read from the scope,
/// and reads a line again only when its text or one of those reads changes,
/// so a keystroke in a long note costs a line or two rather than the note.
class CalcEngine {
  final UnitRegistry registry;
  final DateTime Function() _now;
  final String? timeZoneId;
  late final TemporalExpressions _temporal = TemporalExpressions(
    now: _now,
    defaultTimeZoneId: timeZoneId,
  );

  /// Where separators fall in the results this engine renders. Changing it
  /// means building a new engine, exactly as a rate change does.
  final DigitGrouping grouping;

  final _LineMemo _memo = _LineMemo();

  CalcEngine({
    Map<String, double> ratesPerUsd = const {},
    this.grouping = DigitGrouping.international,
    DateTime Function()? now,
    this.timeZoneId,
  }) : registry = UnitRegistry(ratesPerUsd: ratesPerUsd),
       _now = now ?? DateTime.now;

  bool get hasCurrencyRates => registry.hasCurrencies;

  /// Evaluates every line of [body], returning results keyed by line index.
  /// Lines that are prose, blank, or unparseable are simply absent.
  Map<int, LineResult> evaluateDocument(String body) =>
      evaluateDocumentWithSummary(body).results;

  /// Evaluates a note once and exposes the same running total used by the
  /// `sum` and `total` aggregate names.
  DocumentEvaluation evaluateDocumentWithSummary(String body) {
    final scope = CalcScope();
    final evaluator = Evaluator(
      registry: registry,
      scope: scope,
      now: _now,
      timeZoneId: timeZoneId,
    );
    final results = <int, LineResult>{};
    final pass = _memo.begin(body);

    for (var i = 0; i < pass.lines.length; i++) {
      final evaluated = _evaluateLine(pass, i, evaluator, scope);
      if (evaluated != null) {
        results[i] = evaluated.result;
        // Aggregate readouts, including conversions such as `total to usd`,
        // report the total without becoming another entry in it.
        if (!evaluated.isAggregateReadout) {
          scope.record(evaluated.result.value);
        }
      }
    }
    _memo.end(pass);
    return DocumentEvaluation(
      results: Map<int, LineResult>.unmodifiable(results),
      total: scope.runningSum,
      grouping: grouping,
    );
  }

  /// True when the parsed expression only reads an aggregate, optionally
  /// converting it to another unit or currency for display.
  /// A variable the note named `sum` or `total` is its own value, not a
  /// readout, which is why [scope] is asked first.
  static bool _isAggregateReadout(Node node, CalcScope scope) => switch (node) {
    IdentifierNode() =>
      !scope.defines(node.name) &&
          aggregateNames.contains(node.name.toLowerCase()),
    ConvertNode() => _isAggregateReadout(node.value, scope),
    _ => false,
  };

  /// The readouts of the running total itself, as against `prev` or `avg`.
  static bool _isTotalReadout(Node node, CalcScope scope) => switch (node) {
    IdentifierNode() =>
      !scope.defines(node.name) &&
          const {'sum', 'total'}.contains(node.name.toLowerCase()),
    ConvertNode() => _isTotalReadout(node.value, scope),
    _ => false,
  };

  /// Line [index] of [pass]: an earlier reading of the same text where it
  /// holds in [scope], otherwise a fresh one, remembered for next time.
  _EvaluatedLine? _evaluateLine(
    _Pass pass,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    final reading = _memo.reuse(pass, index, scope);
    if (reading != null) return reading.at(index);
    scope.beginTrace();
    final evaluated = _readLine(pass.lines[index], index, evaluator, scope);
    _memo.remember(pass, index, scope.endTrace(), evaluated);
    return evaluated;
  }

  _EvaluatedLine? _readLine(
    String rawLine,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    final source = _prepare(rawLine, scope);
    if (source == null) return null;

    return _evaluateExpression(source, index, evaluator, scope) ??
        _labelledAssignment(source, index, evaluator, scope) ??
        _explicitLabel(source, index, evaluator, scope) ??
        _labelledArithmetic(source, index, evaluator, scope) ??
        _labelledAmount(source, index, evaluator, scope);
  }

  /// Reads `mailboxes = domains * 5 mail boxes` or `fee: $2/mailbox`: an
  /// assignment whose value carries the same words [_labelledArithmetic] and
  /// [_labelledAmount] already read on a line of their own.
  ///
  /// Those readings only ever saw whole lines, so a value that was fine alone
  /// failed as soon as it was given a name, and then so did every later line
  /// that used the name. Here the name stays put, the words are read out of
  /// the value alone, and the result is bound exactly as a plain assignment
  /// would be.
  _EvaluatedLine? _labelledAssignment(
    String source,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    final tokens = Lexer(source)
        .tokenize()
        .where((t) => t.isSignificant && t.type != TokenType.eof)
        .toList();
    if (tokens.length < 3) return null;
    final name = tokens[0];
    final assign = tokens[1];
    // The same heads the parser takes as an assignment.
    if (name.type != TokenType.identifier ||
        assign.type != TokenType.operator ||
        !isAssignableName(name.text, assign.text)) {
      return null;
    }

    // A colon also ends a label, `Milk: 2 bottles`, which shows its amount
    // and names nothing; making `Milk` a variable would stop it labelling
    // `Milk powder $8` further down. There only a value that works something
    // out is a definition, as `fee: $2/mailbox` is.
    if (assign.text == ':' && !_computes(tokens.sublist(2), scope)) {
      return null;
    }

    final head = source.substring(0, assign.end);
    final value = source.substring(assign.end);
    // Each reading evaluates `name = …`, which gives the name a value even
    // when the reading then refuses what it got: `n = Room 12` is a bare
    // number, not an amount. Unless one of them keeps its answer, the name
    // goes back to what it was.
    final before = scope[name.text];
    final read =
        _labelledArithmetic(value, index, evaluator, scope, head: head) ??
        _labelledAmount(value, index, evaluator, scope, head: head);
    if (read == null) {
      if (before == null) {
        scope.remove(name.text);
      } else {
        scope[name.text] = before;
      }
    }
    return read;
  }

  /// Whether [tokens], the value of an assignment, work something out rather
  /// than state one amount: an operator after the first token, the letter x
  /// between amounts, or a name the note has defined.
  bool _computes(List<Token> tokens, CalcScope scope) {
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      // A sign in front of the amount is part of it, and a colon between
      // numbers is a time or a ratio.
      if (token.type == TokenType.operator &&
          i > 0 &&
          const ['+', '-', '*', '/', '^', '×', '÷', '−'].contains(token.text)) {
        return true;
      }
      if (token.type == TokenType.identifier && scope.defines(token.text)) {
        return true;
      }
      if (_isTimesLetter(token, i + 1 < tokens.length ? tokens[i + 1] : null)) {
        return true;
      }
    }
    return false;
  }

  /// Reads the value to the right of an explicit label boundary.
  ///
  /// A colon is a promise from the writer that the left side is a name and
  /// the right side is the amount: `Solar system: 12000rs`. That is stronger
  /// evidence than the word-order heuristics used for unpunctuated lines, so
  /// model numbers and other digits in the label must never leak into the
  /// answer. Single-name labels such as `budget: 120` are parsed first as
  /// assignments and keep defining a reusable variable.
  ///
  /// The first equals sign makes the same promise once more than a name
  /// stands before it, so `looker connector = 29 usd` reads as
  /// `looker connector: 29 usd` does and names nothing. A single name before
  /// it is an assignment, read before this. Colons are tried first, so
  /// `Q1: revenue = 1000` still defines `revenue`.
  ///
  /// Work from the rightmost colon so nested descriptions such as
  /// `Quote 7: panels: 12000rs` still select the final value. A colon joining
  /// two adjacent numbers is time/ratio punctuation (`12:30`, `1:2`), not a
  /// label boundary.
  _EvaluatedLine? _explicitLabel(
    String source,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    final tokens = Lexer(source)
        .tokenize()
        .where((t) => t.isSignificant && t.type != TokenType.eof)
        .toList();
    final equals = tokens.indexWhere(
      (token) => token.type == TokenType.operator && token.text == '=',
    );
    final boundaries = [
      for (var i = tokens.length - 2; i > 0; i--)
        if (tokens[i].type == TokenType.operator && tokens[i].text == ':') i,
      if (equals > 1 && equals < tokens.length - 1) equals,
    ];
    for (final i in boundaries) {
      final boundary = tokens[i];
      final before = tokens[i - 1];
      final after = tokens[i + 1];
      final joinsNumbers =
          before.type == TokenType.number &&
          after.type == TokenType.number &&
          before.end == boundary.start &&
          boundary.end == after.start;
      if (joinsNumbers) continue;

      final hasLabel = tokens
          .take(i)
          .any((token) => _isExplicitLabelToken(token, scope));
      if (!hasLabel) continue;

      final right = source.substring(boundary.end).trim();
      if (right.isEmpty) continue;
      final evaluated =
          _evaluateExpression(right, index, evaluator, scope) ??
          _labelledArithmetic(right, index, evaluator, scope) ??
          _labelledAmount(right, index, evaluator, scope);
      if (evaluated != null) return evaluated;
    }
    return null;
  }

  /// Explicit labels may contain ordinary prose, product codes and model
  /// numbers. A recognised calculator name is deliberately not enough on its
  /// own: `2:3` and `subtotal:2` either have another meaning or were already
  /// handled by the complete-expression parser.
  bool _isExplicitLabelToken(Token token, CalcScope scope) {
    if (token.type == TokenType.unknown) return true;
    if (token.type != TokenType.identifier) return false;
    final name = token.text.toLowerCase();
    return !scope.defines(token.text) &&
        !calcKeywords.contains(name) &&
        !aggregateNames.contains(name) &&
        !mathConstants.contains(name) &&
        !temporalNames.contains(name) &&
        !booleanLiterals.contains(name) &&
        !functionNames.contains(name) &&
        !registry.isUnit(name);
  }

  _EvaluatedLine? _evaluateExpression(
    String source,
    int index,
    Evaluator evaluator,
    CalcScope scope,
  ) {
    try {
      final temporal = _temporal.evaluate(source);
      if (temporal != null) {
        scope.markUnrepeatable();
        return _EvaluatedLine(
          result: LineResult(
            line: index,
            value: temporal,
            text: ResultFormatter.display(temporal, grouping: grouping),
            copyText: ResultFormatter.copy(temporal),
            grouping: grouping,
          ),
          isAggregateReadout: false,
        );
      }
      final node = Parser(
        source,
        registry: registry,
        isBound: (name) =>
            !unitConfigurationNames.contains(name.toLowerCase()) &&
            scope.defines(name),
      ).parseLine();
      final value = evaluator.evaluate(node);
      // Shown in the device's zone, a date reads the zone as it is written.
      if (value is DateTimeValue && value.timeZoneId == null) {
        scope.markUnrepeatable();
      }
      return _EvaluatedLine(
        result: LineResult(
          line: index,
          value: value,
          text: ResultFormatter.display(value, grouping: grouping),
          copyText: ResultFormatter.copy(value),
          grouping: grouping,
          isTotal: _isTotalReadout(node, scope),
        ),
        isAggregateReadout: _isAggregateReadout(node, scope),
      );
    } on CalcError {
      return null;
    } catch (_) {
      // A malformed line is a line the user is still typing, not an error.
      return null;
    }
  }

  /// Reads `Coffee $4.50`, `Run 5 km`, or `Model 7 inverter 850 usd`: a
  /// human label followed by an amount that says what it is.
  ///
  /// Only tried once the line has failed to parse whole, and only a suffix
  /// carrying a currency or a unit is accepted. A bare trailing number is
  /// refused on purpose — `Room 12` and `Chapter 4` are the same shape as
  /// `Lunch 12`, and nothing in the text distinguishes them. The unit or
  /// currency is the user saying which one they meant.
  ///
  /// Digits and punctuation are allowed inside the label because product
  /// names and capacities routinely contain them. Operators are not: that
  /// keeps an invalid `2 + + 3 usd` from being rescued as `3 usd`. The other
  /// order, `12 mangoes`, is handled by [_labelledArithmetic].
  ///
  /// [head] is an assignment the amount is given to, `name =`, kept in front
  /// of whatever is evaluated.
  _EvaluatedLine? _labelledAmount(
    String source,
    int index,
    Evaluator evaluator,
    CalcScope scope, {
    String head = '',
  }) {
    final tokens = Lexer(source)
        .tokenize()
        .where((t) => t.isSignificant && t.type != TokenType.eof)
        .toList();
    if (tokens.length < 2) return null;

    for (var i = tokens.length - 1; i > 0; i--) {
      if (!_couldStartAmount(
        tokens[i],
        i + 1 < tokens.length ? tokens[i + 1] : null,
      )) {
        continue;
      }
      if (!_safeLabelPrefix(tokens.take(i), scope)) continue;
      final evaluated = _evaluateExpression(
        '$head${source.substring(tokens[i].start)}',
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

  static bool _couldStartAmount(Token token, Token? next) {
    if (token.type == TokenType.number || token.type == TokenType.lparen) {
      return true;
    }
    if (token.type == TokenType.currencySymbol) {
      return next != null &&
          (next.type == TokenType.number ||
              next.type == TokenType.lparen ||
              (next.type == TokenType.operator && next.text == '-'));
    }
    return token.type == TokenType.operator &&
        const ['-', '−'].contains(token.text) &&
        next != null &&
        (next.type == TokenType.number ||
            next.type == TokenType.currencySymbol ||
            next.type == TokenType.lparen);
  }

  bool _safeLabelPrefix(Iterable<Token> prefix, CalcScope scope) {
    var hasWord = false;
    for (final token in prefix) {
      switch (token.type) {
        case TokenType.identifier:
          final name = token.text.toLowerCase();
          if (scope.defines(token.text) ||
              aggregateNames.contains(name) ||
              mathConstants.contains(name) ||
              temporalNames.contains(name) ||
              booleanLiterals.contains(name) ||
              functionNames.contains(name) ||
              calcKeywords.contains(name)) {
            return false;
          }
          hasWord = true;
        case TokenType.operator:
          // Hyphens belong naturally in model names (`Model-7`). Every other
          // operator is evidence that the discarded prefix was arithmetic.
          if (!const ['-', '−'].contains(token.text)) return false;
        case TokenType.currencySymbol:
        case TokenType.percent:
          return false;
        case TokenType.number:
        case TokenType.lparen:
        case TokenType.rparen:
        case TokenType.comma:
        case TokenType.unknown:
          break;
        case TokenType.comment:
        case TokenType.whitespace:
        case TokenType.eof:
          break;
      }
    }
    return hasWord;
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
  ///
  /// [head] is as for [_labelledAmount].
  _EvaluatedLine? _labelledArithmetic(
    String source,
    int index,
    Evaluator evaluator,
    CalcScope scope, {
    String head = '',
  }) {
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
      '$head${_withoutTokens(source, tokens, dropped)}',
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
    return !scope.defines(token.text) &&
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
    // `-5` on its own is a perfectly good negative number. Only such a line
    // asks about the line above, so that no other line depends on it.
    if (line.length > 1 &&
        const ['+', '*', '/', '^', '×', '÷'].contains(line[0]) &&
        scope.prev != null) {
      line = 'prev $line';
    }

    return _looksLikeMath(line, scope.defines) ? line : null;
  }

  /// Prose and calculations share the document, so the engine only attempts
  /// lines that carry some arithmetic signal: a digit, an operator, or a name
  /// the document has already defined.
  ///
  /// Also used by the highlighter, so colouring and evaluation agree on which
  /// lines are calculations.
  static bool looksLikeMath(String line, Set<String> knownNames) =>
      _looksLikeMath(line, knownNames.contains);

  static bool _looksLikeMath(String line, bool Function(String name) isKnown) {
    final tokens = Lexer(
      line,
    ).tokenize().where((t) => t.isSignificant).toList();
    // Drop the trailing EOF.
    if (tokens.isNotEmpty) tokens.removeLast();
    if (tokens.isEmpty) return false;

    var hasNumber = false;
    var hasOperator = false;
    var hasKnownName = false;

    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      switch (token.type) {
        case TokenType.number:
          hasNumber = true;
        case TokenType.operator:
        case TokenType.percent:
        case TokenType.currencySymbol:
          hasOperator = true;
        case TokenType.identifier:
          final name = token.text;
          if (isKnown(name) ||
              aggregateNames.contains(name.toLowerCase()) ||
              mathConstants.contains(name.toLowerCase()) ||
              temporalNames.contains(name.toLowerCase()) ||
              (functionNames.contains(name.toLowerCase()) &&
                  i + 1 < tokens.length &&
                  tokens[i + 1].type == TokenType.lparen)) {
            hasKnownName = true;
          }
        default:
          break;
      }
    }
    return hasNumber || hasOperator || hasKnownName;
  }
}

/// One reading of a line's text in one scope: what the line read and wrote
/// there, and what it gave.
class _Reading {
  final ScopeTrace trace;
  _EvaluatedLine? outcome;

  /// The last pass that used this reading, which is what [_LineMemo] forgets
  /// by.
  int used;

  _Reading(this.trace, this.outcome, this.used);

  /// The outcome, as line [index] of the note.
  _EvaluatedLine? at(int index) {
    final outcome = this.outcome;
    if (outcome == null || outcome.result.line == index) return outcome;
    return this.outcome = outcome.at(index);
  }
}

/// One evaluation of a note: the text of each line, and the reading each
/// line used. Until a line is evaluated, its reading is the one the same line
/// used in the earlier pass this one was matched against, if any.
class _Pass {
  final int number;
  final List<String> lines;
  final List<_Reading?> readings;

  _Pass(this.number, this.lines, this.readings);
}

/// The lines an engine has read, so that a note is read again only where an
/// edit could have changed it.
///
/// A line's outcome depends on its text and on what it read from the scope,
/// so each text keeps a [_Reading] for each of the last few scopes it was
/// read in. Even so, looking every line of a long note up by its text costs
/// more than the rest of an incremental pass together, so the memo also
/// keeps the last few passes. A note is matched against the one it shares
/// most lines with, from its first line down and its last line up, and only
/// the lines in between are looked up by text.
class _LineMemo {
  /// Readings kept, past which all but the most recently used are forgotten,
  /// leaving fewer than half as many.
  static const _capacity = 10000;

  /// Readings kept for one text, past which the one used longest ago is
  /// forgotten. A `total` line under figures that keep changing is read in a
  /// new scope on every pass, and each reading kept is one more to compare.
  static const _readingsPerText = 4;

  /// Earlier passes kept to match new ones against.
  static const _passesKept = 4;

  final Map<String, List<_Reading>> _readings = {};
  final List<_Pass> _passes = [];
  int _size = 0;
  int _count = 0;

  /// Starts a pass over [body]. An earlier pass that shares most of its
  /// lines with it was an earlier version of the same note, which this pass
  /// replaces.
  _Pass begin(String body) {
    _Pass? earlier;
    var shared = (head: 0, tail: 0, from: 0, to: body.length);
    for (final pass in _passes) {
      final candidate = _shared(body, pass.lines);
      if (candidate.head + candidate.tail > shared.head + shared.tail) {
        earlier = pass;
        shared = candidate;
      }
    }
    final (:head, :tail, :from, :to) = shared;
    final kept = earlier?.lines.length ?? 0;
    if ((head + tail) * 2 > kept) _passes.remove(earlier);
    final changed = from > to
        ? const <String>[]
        : body.substring(from, to).split('\n');
    return _Pass(
      ++_count,
      [
        ...?earlier?.lines.sublist(0, head),
        ...changed,
        ...?earlier?.lines.sublist(kept - tail),
      ],
      [
        ...?earlier?.readings.sublist(0, head),
        for (final _ in changed) null,
        ...?earlier?.readings.sublist(kept - tail),
      ],
    );
  }

  /// How many of [earlier]'s lines [body] starts with and ends with, and the
  /// span of [body] between them.
  static ({int head, int tail, int from, int to}) _shared(
    String body,
    List<String> earlier,
  ) {
    var head = 0;
    var from = 0;
    while (head < earlier.length) {
      final line = earlier[head];
      final end = from + line.length;
      if (end > body.length ||
          !body.startsWith(line, from) ||
          (end < body.length && body.codeUnitAt(end) != 0x0A)) {
        break;
      }
      head++;
      from = end + 1;
    }
    var tail = 0;
    var to = body.length;
    while (tail < earlier.length - head) {
      final line = earlier[earlier.length - 1 - tail];
      final start = to - line.length;
      if (start < from ||
          !body.startsWith(line, start) ||
          (start > 0 && body.codeUnitAt(start - 1) != 0x0A)) {
        break;
      }
      tail++;
      to = start - 1;
    }
    return (head: head, tail: tail, from: from, to: to);
  }

  /// A reading of line [index] that holds in [scope], already redone there.
  _Reading? reuse(_Pass pass, int index, CalcScope scope) {
    final hint = pass.readings[index];
    if (hint != null && scope.reuse(hint.trace)) {
      return hint..used = pass.number;
    }
    pass.readings[index] = null;
    for (final reading in _readings[pass.lines[index]] ?? const <_Reading>[]) {
      if (!identical(reading, hint) && scope.reuse(reading.trace)) {
        pass.readings[index] = reading;
        return reading..used = pass.number;
      }
    }
    return null;
  }

  /// Keeps what line [index] read and gave, unless [trace] is null because
  /// the line can't be reused.
  void remember(
    _Pass pass,
    int index,
    ScopeTrace? trace,
    _EvaluatedLine? outcome,
  ) {
    if (trace == null) return;
    final reading = _Reading(trace, outcome, pass.number);
    final readings = _readings[pass.lines[index]] ??= [];
    if (readings.length < _readingsPerText) {
      _size++;
    } else {
      readings.remove(readings.reduce((a, b) => b.used < a.used ? b : a));
    }
    readings.add(reading);
    pass.readings[index] = reading;
  }

  /// Keeps [pass] to match later ones against, and once there are too many
  /// readings forgets those used longest ago.
  void end(_Pass pass) {
    _passes.insert(0, pass);
    if (_passes.length > _passesKept) _passes.removeLast();
    if (_size <= _capacity) return;
    final used = [
      for (final readings in _readings.values)
        for (final reading in readings) reading.used,
    ]..sort();
    final oldest = used[used.length - _capacity ~/ 2];
    _readings.removeWhere((_, readings) {
      readings.removeWhere((reading) => reading.used <= oldest);
      return readings.isEmpty;
    });
    _size = _readings.values.fold(
      0,
      (size, readings) => size + readings.length,
    );
  }
}
