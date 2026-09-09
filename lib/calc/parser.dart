import 'ast.dart';
import 'lexer.dart';
import 'notation.dart';
import 'unit.dart';
import 'unit_registry.dart';
import 'value.dart';

/// Words that act as operators rather than identifiers.
const Set<String> calcKeywords = {
  'to',
  'of',
  'off',
  'on',
  'as',
  'in',
  'per',
  'mod',
  'and',
  'or',
  'xor',
  'not',
  'a',
  'an',
  'plus',
  'with',
  'minus',
  'subtract',
  'without',
  'times',
  'multiply',
  'multiplied',
  'mul',
  'divide',
  'divided',
  'by',
  'over',
  'into',
  'percent',
  'pct',
  'binary',
  'bin',
  'octal',
  'oct',
  'hexadecimal',
  'hex',
  'decimal',
  'dec',
  'scientific',
  'sci',
  'thousand',
  'thousands',
  'million',
  'millions',
  'billion',
  'billions',
  'trillion',
  'trillions',
  'lakh',
  'lakhs',
  'lac',
  'lacs',
  'crore',
  'crores',
};

/// Names that resolve against the running document rather than the scope.
const Set<String> aggregateNames = {'prev', 'sum', 'total', 'avg', 'average'};

const Set<String> mathConstants = {'pi', 'e', 'tau', 'phi', 'inf', 'infinity'};

const Set<String> booleanLiterals = {'true', 'false'};

const Set<String> temporalNames = {
  'now',
  'time',
  'today',
  'tomorrow',
  'yesterday',
};

/// Document variables that configure a unit while leaving that unit usable as
/// a suffix on following lines (`em = 20px`, then `1.2 em in px`).
const Set<String> unitConfigurationNames = {'ppi', 'em'};

const Map<String, NumericNotation> numericNotationNames = {
  'binary': NumericNotation.binary,
  'bin': NumericNotation.binary,
  'octal': NumericNotation.octal,
  'oct': NumericNotation.octal,
  'hexadecimal': NumericNotation.hexadecimal,
  'hex': NumericNotation.hexadecimal,
  'decimal': NumericNotation.decimal,
  'dec': NumericNotation.decimal,
  'scientific': NumericNotation.scientific,
  'sci': NumericNotation.scientific,
};

const Map<String, double> numberScaleNames = {
  'thousand': 1e3,
  'thousands': 1e3,
  'million': 1e6,
  'millions': 1e6,
  'billion': 1e9,
  'billions': 1e9,
  'trillion': 1e12,
  'trillions': 1e12,
  'lakh': 1e5,
  'lakhs': 1e5,
  'lac': 1e5,
  'lacs': 1e5,
  'crore': 1e7,
  'crores': 1e7,
};

const Set<String> functionNames = {
  'sqrt',
  'root',
  'cbrt',
  'abs',
  'round',
  'floor',
  'ceil',
  'trunc',
  'sign',
  'min',
  'max',
  'sum',
  'avg',
  'mean',
  'median',
  'log',
  'log10',
  'log2',
  'ln',
  'exp',
  'pow',
  'mod',
  'sin',
  'cos',
  'tan',
  'asin',
  'arcsin',
  'acos',
  'arccos',
  'atan',
  'arctan',
  'atan2',
  'sinh',
  'cosh',
  'tanh',
  'hypot',
  'gcd',
  'lcm',
  'fact',
  'random',
  'fromunix',
};

/// Functions whose single argument may follow as natural calculator text:
/// `sqrt 16`, `sin 90 deg`, `fact 5`. Multi-argument calls keep brackets so
/// their endpoint is never guessed.
const Set<String> prefixFunctionNames = {
  'sqrt',
  'cbrt',
  'abs',
  'round',
  'floor',
  'ceil',
  'trunc',
  'sign',
  'log10',
  'log2',
  'ln',
  'exp',
  'sin',
  'cos',
  'tan',
  'asin',
  'arcsin',
  'acos',
  'arccos',
  'atan',
  'arctan',
  'sinh',
  'cosh',
  'tanh',
  'fact',
  'fromunix',
};

/// Recursive-descent parser for one line of note text.
///
/// Precedence, loosest first:
///   assignment → logical or/and → comparison → conversion → additive
///   →  mixed-unit sequence → "of/off/on" → multiplicative
///   →  unary → power → postfix
///
/// `of` binds tighter than `+` so `20% of 80 + 5` is 21, and looser than `*`
/// so `10% of 50 * 2` is 10.
class Parser {
  final List<Token> _tokens;
  final UnitRegistry _registry;

  /// Names currently bound in the document scope. Consulted so a user's own
  /// variable always wins over a same-named unit (`h = 5` then `h * 2`).
  final Set<String> _boundNames;

  int _index = 0;

  Parser(
    String source, {
    required UnitRegistry registry,
    Set<String> boundNames = const {},
  }) : _tokens = Lexer(
         source,
       ).tokenize().where((t) => t.isSignificant).toList(),
       _registry = registry,
       _boundNames = boundNames;

  Token get _current => _tokens[_index];

  Token _peek([int offset = 1]) {
    final i = _index + offset;
    return i < _tokens.length ? _tokens[i] : _tokens.last;
  }

  bool get _atEnd => _current.type == TokenType.eof;

  void _advance() {
    if (!_atEnd) _index++;
  }

  bool _isWord(String word, [int offset = 0]) {
    final t = _peek(offset);
    return t.type == TokenType.identifier && t.text.toLowerCase() == word;
  }

  /// Parses a complete line, requiring that every token is consumed. Trailing
  /// garbage is a parse failure, which is what stops prose like
  /// "10 min break" from producing a bogus result.
  Node parseLine() {
    if (_atEnd) throw const CalcError('empty');
    final node = _parseAssignment();
    if (!_atEnd) {
      throw CalcError('unexpected "${_current.text}"');
    }
    return node;
  }

  Node _parseAssignment() {
    // `subtotal = 42` and the Soulver-style `Groceries: 42`.
    if (_current.type == TokenType.identifier &&
        !calcKeywords.contains(_current.text.toLowerCase()) &&
        !functionNames.contains(_current.text.toLowerCase())) {
      final next = _peek();
      final isAssign =
          next.type == TokenType.operator &&
          (next.text == '=' || next.text == ':');
      if (isAssign) {
        final name = _current.text;
        _advance();
        _advance();
        if (_atEnd) throw const CalcError('assignment has no value');
        return AssignNode(name, _parseLogicalOr());
      }
    }
    return _parseLogicalOr();
  }

  Node _parseLogicalOr() {
    var left = _parseLogicalAnd();
    while (_isWord('or')) {
      _advance();
      left = BinaryNode('or', left, _parseLogicalAnd());
    }
    return left;
  }

  Node _parseLogicalAnd() {
    var left = _parseComparison();
    while (_isWord('and')) {
      _advance();
      left = BinaryNode('and', left, _parseComparison());
    }
    return left;
  }

  Node _parseComparison() {
    var left = _parseBitwise();
    while (_current.type == TokenType.operator &&
        const ['=', '==', '!=', '<', '>', '<=', '>='].contains(_current.text)) {
      final op = _current.text == '=' ? '==' : _current.text;
      _advance();
      left = BinaryNode(op, left, _parseBitwise());
    }
    return left;
  }

  /// Integer bitwise operations. They sit below conversion and arithmetic,
  /// matching ordinary calculator precedence while keeping comparisons such
  /// as `flags & 4 == 4` intuitive.
  Node _parseBitwise() {
    var left = _parseConversion();
    while ((_current.type == TokenType.operator &&
            const ['&', '|', '<<', '>>'].contains(_current.text)) ||
        _isWord('xor')) {
      final op = _current.text.toLowerCase();
      _advance();
      left = BinaryNode(op, left, _parseConversion());
    }
    return left;
  }

  Node _parseConversion() {
    var node = _parseAdditive();

    while (true) {
      // `25 as a % of 200` is checked before the generic `as` conversion,
      // since both start with the same word.
      final asPercent = _tryAsPercentOfTail(node);
      if (asPercent != null) {
        node = asPercent;
        continue;
      }
      final notation = _conversionNotation();
      if (notation != null) {
        _advance();
        _advance();
        node = FormatNode(node, notation);
        continue;
      }
      if (_isConversionKeyword(node)) {
        _advance();
        final unit = _parseUnitSpec(expectedDimension: _nodeDimension(node));
        if (unit == null) throw const CalcError('expected a unit after "to"');
        node = ConvertNode(node, unit);
        continue;
      }
      break;
    }
    return node;
  }

  NumericNotation? _conversionNotation() {
    final isLead =
        (_current.type == TokenType.operator && _current.text == '->') ||
        (_current.type == TokenType.identifier &&
            const [
              'to',
              'into',
              'in',
              'as',
            ].contains(_current.text.toLowerCase()));
    if (!isLead) return null;
    final next = _peek();
    if (next.type != TokenType.identifier) return null;
    return numericNotationNames[next.text.toLowerCase()];
  }

  /// Matches `as [a|an] % of|on|off <expr>` after an already-parsed value.
  Node? _tryAsPercentOfTail(Node left) {
    if (!_isWord('as')) return null;
    var offset = 1;
    if (_isWord('a', offset) || _isWord('an', offset)) offset++;
    final pct = _peek(offset);
    final isPercentWord =
        pct.type == TokenType.percent ||
        (pct.type == TokenType.identifier &&
            const ['percent', 'pct'].contains(pct.text.toLowerCase()));
    if (!isPercentWord) return null;
    final relationship = _peek(offset + 1).text.toLowerCase();
    if (!const {'of', 'on', 'off'}.contains(relationship)) return null;

    for (var i = 0; i < offset + 2; i++) {
      _advance();
    }
    return AsPercentOfNode(left, _parseAdditive(), relationship);
  }

  /// `to` and `->` always convert. `in` and `as` only convert when a unit
  /// actually follows, so `10 in` stays ten inches.
  bool _isConversionKeyword(Node value) {
    if (_current.type == TokenType.operator && _current.text == '->') {
      return true;
    }
    if (_current.type != TokenType.identifier) return false;
    final word = _current.text.toLowerCase();
    if (word == 'to' || word == 'into') return true;
    if (word == 'in' || word == 'as') {
      return _startsUnitSpec(1, expectedDimension: _nodeDimension(value));
    }
    return false;
  }

  bool _startsUnitSpec(int offset, {Dimension? expectedDimension}) {
    return _writtenUnitAt(offset, expectedDimension: expectedDimension) != null;
  }

  /// Parses `km`, `km/h`, `m^2`, `USD/hour` after a conversion keyword.
  ///
  /// [allowIn] lets the leading factor be `in` (inches) at call sites that
  /// have already ruled out the conversion-keyword reading.
  Unit? _parseUnitSpec({bool allowIn = false, Dimension? expectedDimension}) {
    var unit = _parseUnitFactor(
      allowIn: allowIn,
      expectedDimension: expectedDimension,
    );
    if (unit == null) return null;
    while (true) {
      if (_current.type == TokenType.operator &&
          (_current.text == '/' || _current.text == '*')) {
        final isDivide = _current.text == '/';
        final save = _index;
        _advance();
        final next = _parseUnitFactor();
        if (next == null) {
          _index = save;
          break;
        }
        unit = isDivide ? unit! / next : unit! * next;
        continue;
      }
      if (_isWord('per')) {
        final save = _index;
        _advance();
        final next = _parseUnitFactor();
        if (next == null) {
          _index = save;
          break;
        }
        unit = unit! / next;
        continue;
      }
      break;
    }
    return unit;
  }

  Unit? _parseUnitFactor({bool allowIn = false, Dimension? expectedDimension}) {
    final written = _writtenUnitAt(
      0,
      allowIn: allowIn,
      expectedDimension: expectedDimension,
    );
    if (written == null) return null;
    for (var i = 0; i < written.tokens; i++) {
      _advance();
    }

    var unit = Unit.single(written.def).pow(written.exponent);
    if (_current.type == TokenType.operator && _current.text == '^') {
      final exp = _peek();
      if (exp.type == TokenType.number &&
          exp.number != null &&
          exp.number == exp.number!.roundToDouble()) {
        _advance();
        _advance();
        unit = unit.pow(exp.number!.toInt());
      }
    }
    return unit;
  }

  /// Resolves the longest written unit starting at [offset]. Spaces inside
  /// names are optional, so `nautical mile`, `fluid ounce` and their compact
  /// aliases share one registry entry. `square`/`sq` and `cubic`/`cu` are
  /// grammatical prefixes rather than hundreds of duplicated unit records.
  ({UnitDef def, int tokens, int exponent})? _writtenUnitAt(
    int offset, {
    bool allowIn = false,
    Dimension? expectedDimension,
  }) {
    final first = _peek(offset);
    if (first.type == TokenType.currencySymbol) {
      final code = currencySymbolCodes[first.text];
      final def = code == null
          ? null
          : _registry.lookup(code, dimension: expectedDimension);
      return def == null ? null : (def: def, tokens: 1, exponent: 1);
    }
    if (first.type != TokenType.identifier) return null;

    var exponent = 1;
    var prefixTokens = 0;
    final prefix = first.text.toLowerCase();
    if (prefix == 'sq' || prefix == 'square') {
      exponent = 2;
      prefixTokens = 1;
    } else if (prefix == 'cu' || prefix == 'cubic' || prefix == 'cb') {
      exponent = 3;
      prefixTokens = 1;
    }

    final unitOffset = offset + prefixTokens;
    final unitFirst = _peek(unitOffset);
    if (unitFirst.type != TokenType.identifier) return null;
    final unitWord = unitFirst.text.toLowerCase();
    if (calcKeywords.contains(unitWord) && !(allowIn && unitWord == 'in')) {
      return null;
    }
    if (_boundNames.contains(unitFirst.text)) return null;

    var available = 0;
    while (available < 3) {
      final token = _peek(unitOffset + available);
      if (token.type != TokenType.identifier ||
          _boundNames.contains(token.text)) {
        break;
      }
      available++;
    }
    for (var count = available; count >= 1; count--) {
      final phrase = List.generate(
        count,
        (i) => _peek(unitOffset + i).text,
      ).join();
      final lookupDimension = exponent == 1 ? expectedDimension : null;
      final def = _registry.lookup(phrase, dimension: lookupDimension);
      if (def != null) {
        return (def: def, tokens: prefixTokens + count, exponent: exponent);
      }
    }
    return null;
  }

  Node _parseAdditive() {
    var left = _parseUnitSequence();
    while (true) {
      if (_current.type == TokenType.operator &&
          const ['+', '-', '−', '–', '—'].contains(_current.text)) {
        final op = _current.text == '+' ? '+' : '-';
        _advance();
        left = BinaryNode(op, left, _parseUnitSequence());
      } else if (_isWord('plus')) {
        _advance();
        left = BinaryNode('+', left, _parseUnitSequence());
      } else if (_isWord('with')) {
        _advance();
        left = BinaryNode('+', left, _parseUnitSequence());
      } else if (_isWord('minus') ||
          _isWord('subtract') ||
          _isWord('without')) {
        _advance();
        left = BinaryNode('-', left, _parseUnitSequence());
      } else {
        break;
      }
    }
    return left;
  }

  /// Adds adjacent amounts of the same dimension: `1 meter 20 cm`,
  /// `5 ft 6 in`, `1 h 30 min`. Two bare numbers are never joined, and an
  /// incompatible unit restores the cursor so ordinary prose still fails as
  /// a complete expression instead of yielding a plausible wrong answer.
  Node _parseUnitSequence() {
    var left = _parseOf();
    var dimension = _directQuantityDimension(left);

    while (dimension != null && _startsSequenceAmount()) {
      final save = _index;
      final right = _parseOf();
      final rightDimension = _directQuantityDimension(right);
      if (rightDimension == null || rightDimension != dimension) {
        _index = save;
        break;
      }
      left = BinaryNode('+', left, right);
    }
    return left;
  }

  bool _startsSequenceAmount() =>
      _current.type == TokenType.number ||
      _current.type == TokenType.currencySymbol;

  static Dimension? _directQuantityDimension(Node node) =>
      node is QuantityNode ? node.unit.dimension : null;

  Node _parseOf() {
    var left = _parseMultiplicative();
    while (_isWord('of') || _isWord('off') || _isWord('on')) {
      final op = _current.text.toLowerCase();
      _advance();
      if (_isWord('what') && _isWord('is', 1)) {
        _advance();
        _advance();
        left = SolvePercentNode(op, left, _parseMultiplicative());
      } else {
        left = BinaryNode(op, left, _parseMultiplicative());
      }
    }
    return left;
  }

  Node _parseMultiplicative() {
    var left = _parseUnary();
    while (true) {
      if (_current.type == TokenType.operator &&
          const ['*', '/', '×', '÷'].contains(_current.text)) {
        final op = const ['*', '×'].contains(_current.text) ? '*' : '/';
        _advance();
        left = BinaryNode(op, left, _parseUnary());
      } else if (_isWord('times') || _isTimesLetter()) {
        _advance();
        left = BinaryNode('*', left, _parseUnary());
      } else if (_isWord('multiply') || _isWord('multiplied')) {
        _advance();
        if (_isWord('by')) _advance();
        left = BinaryNode('*', left, _parseUnary());
      } else if (_isWord('mul')) {
        _advance();
        left = BinaryNode('*', left, _parseUnary());
      } else if (_isWord('over') || _isWord('per')) {
        _advance();
        left = BinaryNode('/', left, _parseUnary());
      } else if (_isWord('divide') || _isWord('divided')) {
        _advance();
        if (_isWord('by')) _advance();
        left = BinaryNode('/', left, _parseUnary());
      } else if (_isWord('mod')) {
        _advance();
        left = BinaryNode('mod', left, _parseUnary());
      } else if (_current.type == TokenType.lparen) {
        // Numi's compact multiplication: `6 (3)`, `2(3 + 4)` and
        // `(2 + 1)(4 + 2)`. Restricting adjacency to a parenthesised right
        // operand avoids turning ordinary neighbouring numbers into maths.
        left = BinaryNode('*', left, _parseUnary());
      } else {
        break;
      }
    }
    return left;
  }

  /// `3 x 4`, and `1920 x 1080`.
  ///
  /// Only where an amount already sits on the left and another begins on the
  /// right, because `x` is also the first name anybody gives a variable and
  /// `x = 5` has to go on meaning that. A document that has defined `x` keeps
  /// it as a name here too, whatever surrounds it: the note said what it is.
  bool _isTimesLetter() {
    if (_current.type != TokenType.identifier) return false;
    if (_current.text.toLowerCase() != 'x') return false;
    if (_boundNames.contains(_current.text)) return false;
    final next = _peek();
    return next.type == TokenType.number ||
        next.type == TokenType.currencySymbol ||
        next.type == TokenType.lparen;
  }

  Node _parseUnary() {
    if (_current.type == TokenType.operator &&
        const ['-', '−', '–', '—'].contains(_current.text)) {
      _advance();
      return UnaryNode('-', _parseUnary());
    }
    if (_current.type == TokenType.operator && _current.text == '+') {
      _advance();
      return _parseUnary();
    }
    if (_isWord('not')) {
      _advance();
      return UnaryNode('not', _parseUnary());
    }
    final basedCall = _tryWrittenBaseFunction();
    if (basedCall != null) return basedCall;
    if (_current.type == TokenType.identifier &&
        prefixFunctionNames.contains(_current.text.toLowerCase()) &&
        _peek().type != TokenType.lparen) {
      final name = _current.text.toLowerCase();
      _advance();
      return CallNode(name, [_parseUnary()]);
    }
    return _parsePower();
  }

  /// `root 3 (27)` and `log 2 (8)`: the first value states the degree/base,
  /// while the parenthesised value is the operand. Requiring the brackets on
  /// the second value keeps `log 2 + 8` from being guessed at.
  Node? _tryWrittenBaseFunction() {
    final isRoot = _isWord('root');
    final isLog = _isWord('log');
    if (!isRoot && !isLog) return null;

    final save = _index;
    _advance();
    final degreeOrBase = _parsePower();
    if (_current.type != TokenType.lparen) {
      _index = save;
      return null;
    }
    final operand = _parsePrimary();
    return isRoot
        ? CallNode('root', [degreeOrBase, operand])
        : CallNode('log', [operand, degreeOrBase]);
  }

  Node _parsePower() {
    final base = _parsePostfix();
    if (_current.type == TokenType.operator &&
        (_current.text == '^' || _current.text == '**')) {
      _advance();
      return BinaryNode('^', base, _parseUnary());
    }
    return base;
  }

  /// Applies postfix `%` and any unit suffix to a primary value.
  Node _parsePostfix() {
    var node = _parsePrimary();

    while (true) {
      if (_current.type == TokenType.percent) {
        _advance();
        node = PercentNode(node);
        continue;
      }
      if (_current.type == TokenType.operator && _current.text == '!') {
        _advance();
        node = CallNode('fact', [node]);
        continue;
      }
      // The spelled-out form, so "20 percent of 80" reads the same as
      // "20% of 80". The `as a percent of` phrase is matched earlier, at the
      // conversion level, and never reaches here.
      if (_current.type == TokenType.identifier &&
          const ['percent', 'pct'].contains(_current.text.toLowerCase())) {
        _advance();
        node = PercentNode(node);
        continue;
      }
      if (_current.type == TokenType.identifier) {
        final scale = numberScaleNames[_current.text.toLowerCase()];
        if (scale != null) {
          _advance();
          node = BinaryNode('*', node, NumberNode(scale));
          continue;
        }
      }
      final unit = _tryUnitSuffix(node);
      if (unit != null) {
        node = QuantityNode(node, unit);
        continue;
      }
      break;
    }
    return node;
  }

  /// A unit written directly after a value (`100 usd`, `10 km`, `5 $`).
  ///
  /// `in` is the awkward case: it is both "inch" and a conversion keyword.
  /// It is only taken as inches when no unit follows it.
  Unit? _tryUnitSuffix(Node value) {
    if (_current.type == TokenType.currencySymbol) {
      final code = currencySymbolCodes[_current.text];
      final def = code == null ? null : _registry.lookup(code);
      if (def == null) return null;
      _advance();
      return Unit.single(def);
    }
    if (_current.type != TokenType.identifier) return null;

    final word = _current.text.toLowerCase();
    if (_boundNames.contains(_current.text)) return null;
    final isInch = word == 'in';
    if (isInch) {
      // `10 in cm` converts; `10 in` and `10 in + 2 in` are inches.
      final next = _peek();
      if (_startsUnitSpec(1, expectedDimension: _nodeDimension(value)) ||
          (next.type == TokenType.identifier &&
              numericNotationNames.containsKey(next.text.toLowerCase()))) {
        return null;
      }
    } else if (calcKeywords.contains(word)) {
      return null;
    }
    // An identifier immediately followed by "(" is a call, never a unit.
    if (_peek().type == TokenType.lparen) return null;

    final save = _index;
    final unit = _parseUnitSpec(allowIn: isInch);
    if (unit == null) {
      _index = save;
      return null;
    }
    return unit;
  }

  static Dimension? _nodeDimension(Node node) => switch (node) {
    QuantityNode() => node.unit.dimension,
    ConvertNode() => node.target.dimension,
    BinaryNode(op: '+' || '-') =>
      _nodeDimension(node.left) == _nodeDimension(node.right)
          ? _nodeDimension(node.left)
          : null,
    _ => null,
  };

  Node _parsePrimary() {
    final token = _current;

    if (token.type == TokenType.number) {
      _advance();
      if (token.number == null) throw const CalcError('bad number');
      return NumberNode(token.number!);
    }

    // `$100` — symbol before the amount.
    if (token.type == TokenType.currencySymbol) {
      final code = currencySymbolCodes[token.text];
      final def = code == null ? null : _registry.lookup(code);
      if (def == null) throw CalcError('unknown currency ${token.text}');
      _advance();
      if (_current.type == TokenType.number ||
          _current.type == TokenType.lparen ||
          (_current.type == TokenType.operator && _current.text == '-')) {
        return QuantityNode(_parseUnary(), Unit.single(def));
      }
      return QuantityNode(const NumberNode(1), Unit.single(def));
    }

    if (token.type == TokenType.lparen) {
      _advance();
      final inner = _parseAssignment();
      if (_current.type != TokenType.rparen) {
        throw const CalcError('missing ")"');
      }
      _advance();
      return inner;
    }

    if (token.type == TokenType.identifier) {
      final word = token.text.toLowerCase();
      if (calcKeywords.contains(word)) {
        throw CalcError('unexpected "${token.text}"');
      }
      if (_peek().type == TokenType.lparen) {
        _advance();
        _advance();
        final args = <Node>[];
        if (_current.type != TokenType.rparen) {
          args.add(_parseAssignment());
          while (_current.type == TokenType.comma) {
            _advance();
            args.add(_parseAssignment());
          }
        }
        if (_current.type != TokenType.rparen) {
          throw const CalcError('missing ")"');
        }
        _advance();
        return CallNode(word, args);
      }
      _advance();
      return IdentifierNode(token.text);
    }

    throw CalcError('unexpected "${token.text}"');
  }
}
