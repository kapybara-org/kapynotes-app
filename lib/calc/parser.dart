import 'ast.dart';
import 'lexer.dart';
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
  'minus',
  'times',
  'over',
  'into',
  'percent',
  'pct',
};

/// Names that resolve against the running document rather than the scope.
const Set<String> aggregateNames = {'prev', 'sum', 'total', 'avg'};

const Set<String> mathConstants = {'pi', 'e', 'tau', 'phi', 'inf', 'infinity'};

const Set<String> booleanLiterals = {'true', 'false'};

const Set<String> functionNames = {
  'sqrt',
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
  'acos',
  'atan',
  'atan2',
  'sinh',
  'cosh',
  'tanh',
  'hypot',
  'gcd',
  'lcm',
  'fact',
  'random',
};

/// Recursive-descent parser for one line of note text.
///
/// Precedence, loosest first:
///   assignment  →  comparison  →  conversion  →  additive
///   →  "of/off/on"  →  multiplicative  →  unary  →  power  →  postfix
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
        return AssignNode(name, _parseComparison());
      }
    }
    return _parseComparison();
  }

  Node _parseComparison() {
    var left = _parseConversion();
    while (_current.type == TokenType.operator &&
        const ['==', '!=', '<', '>', '<=', '>='].contains(_current.text)) {
      final op = _current.text;
      _advance();
      left = BinaryNode(op, left, _parseConversion());
    }
    while (_isWord('and') || _isWord('or') || _isWord('xor')) {
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
      if (_isConversionKeyword()) {
        _advance();
        final unit = _parseUnitSpec();
        if (unit == null) throw const CalcError('expected a unit after "to"');
        node = ConvertNode(node, unit);
        continue;
      }
      break;
    }
    return node;
  }

  /// Matches the tail `as [a|an] % of <expr>` following an already-parsed
  /// left-hand side.
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
    if (!_isWord('of', offset + 1)) return null;

    for (var i = 0; i < offset + 2; i++) {
      _advance();
    }
    return AsPercentOfNode(left, _parseAdditive());
  }

  /// `to` and `->` always convert. `in` and `as` only convert when a unit
  /// actually follows, so `10 in` stays ten inches.
  bool _isConversionKeyword() {
    if (_current.type == TokenType.operator && _current.text == '->') {
      return true;
    }
    if (_current.type != TokenType.identifier) return false;
    final word = _current.text.toLowerCase();
    if (word == 'to' || word == 'into') return true;
    if (word == 'in' || word == 'as') return _startsUnitSpec(1);
    return false;
  }

  bool _startsUnitSpec(int offset) {
    final t = _peek(offset);
    if (t.type == TokenType.currencySymbol) return true;
    if (t.type != TokenType.identifier) return false;
    final word = t.text.toLowerCase();
    if (calcKeywords.contains(word)) return false;
    if (_boundNames.contains(t.text)) return false;
    return _registry.isUnit(word);
  }

  /// Parses `km`, `km/h`, `m^2`, `USD/hour` after a conversion keyword.
  ///
  /// [allowIn] lets the leading factor be `in` (inches) at call sites that
  /// have already ruled out the conversion-keyword reading.
  Unit? _parseUnitSpec({bool allowIn = false}) {
    var unit = _parseUnitFactor(allowIn: allowIn);
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

  Unit? _parseUnitFactor({bool allowIn = false}) {
    UnitDef? def;
    if (_current.type == TokenType.currencySymbol) {
      final code = currencySymbolCodes[_current.text];
      def = code == null ? null : _registry.lookup(code);
      if (def == null) return null;
      _advance();
    } else if (_current.type == TokenType.identifier) {
      final word = _current.text.toLowerCase();
      if (calcKeywords.contains(word) && !(allowIn && word == 'in')) {
        return null;
      }
      def = _registry.lookup(word);
      if (def == null) return null;
      _advance();
    } else {
      return null;
    }

    var unit = Unit.single(def);
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

  Node _parseAdditive() {
    var left = _parseOf();
    while (true) {
      if (_current.type == TokenType.operator &&
          const ['+', '-', '−', '–', '—'].contains(_current.text)) {
        final op = _current.text == '+' ? '+' : '-';
        _advance();
        left = BinaryNode(op, left, _parseOf());
      } else if (_isWord('plus')) {
        _advance();
        left = BinaryNode('+', left, _parseOf());
      } else if (_isWord('minus')) {
        _advance();
        left = BinaryNode('-', left, _parseOf());
      } else {
        break;
      }
    }
    return left;
  }

  Node _parseOf() {
    var left = _parseMultiplicative();
    while (_isWord('of') || _isWord('off') || _isWord('on')) {
      final op = _current.text.toLowerCase();
      _advance();
      left = BinaryNode(op, left, _parseMultiplicative());
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
      } else if (_isWord('times')) {
        _advance();
        left = BinaryNode('*', left, _parseUnary());
      } else if (_isWord('over') || _isWord('per')) {
        _advance();
        left = BinaryNode('/', left, _parseUnary());
      } else if (_isWord('mod')) {
        _advance();
        left = BinaryNode('mod', left, _parseUnary());
      } else {
        break;
      }
    }
    return left;
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
    return _parsePower();
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
      // The spelled-out form, so "20 percent of 80" reads the same as
      // "20% of 80". The `as a percent of` phrase is matched earlier, at the
      // conversion level, and never reaches here.
      if (_current.type == TokenType.identifier &&
          const ['percent', 'pct'].contains(_current.text.toLowerCase())) {
        _advance();
        node = PercentNode(node);
        continue;
      }
      final unit = _tryUnitSuffix();
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
  Unit? _tryUnitSuffix() {
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
      if (_startsUnitSpec(1)) return null;
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
