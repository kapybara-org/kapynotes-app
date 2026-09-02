/// Token categories produced by [Lexer].
///
/// The same token stream drives both evaluation and syntax highlighting, so
/// what you see coloured is exactly what the parser saw.
enum TokenType {
  number,
  identifier,
  currencySymbol,
  operator,
  percent,
  lparen,
  rparen,
  comma,
  comment,
  whitespace,
  unknown,
  eof,
}

class Token {
  final TokenType type;
  final String text;
  final int start;
  final int end;

  /// Parsed value for [TokenType.number] tokens.
  final double? number;

  const Token({
    required this.type,
    required this.text,
    required this.start,
    required this.end,
    this.number,
  });

  bool get isSignificant =>
      type != TokenType.whitespace && type != TokenType.comment;

  @override
  String toString() => '${type.name}("$text")';
}

/// Currency symbols recognised directly in source text. They lex as their own
/// token type so `$100` and `100 $` both work without whitespace rules.
const Map<String, String> currencySymbolCodes = {
  r'$': 'USD',
  '€': 'EUR',
  '£': 'GBP',
  '¥': 'JPY',
  '₹': 'INR',
  '₩': 'KRW',
  '₽': 'RUB',
  '₺': 'TRY',
  '₦': 'NGN',
  '₱': 'PHP',
  '₫': 'VND',
  '฿': 'THB',
  '₪': 'ILS',
  '₴': 'UAH',
  '₣': 'CHF',
  '₡': 'CRC',
  '₸': 'KZT',
  '₮': 'MNT',
};

/// Multi-character operators, longest first so `<=` never lexes as `<`.
const List<String> _multiCharOperators = ['**', '==', '!=', '<=', '>=', '->'];

const String _singleCharOperators = '+-*/^<>=!:&|×÷−–—';

/// Turns a single line of note text into tokens.
///
/// The lexer is total: it never throws and never skips input. Anything it
/// cannot classify becomes [TokenType.unknown], which keeps highlight spans
/// covering every character of the line.
class Lexer {
  final String source;
  int _pos = 0;

  Lexer(this.source);

  /// Tokenises the whole line, including whitespace and comments, so callers
  /// that need full coverage (highlighting) get it. Parsers filter them out.
  List<Token> tokenize() {
    final tokens = <Token>[];
    while (_pos < source.length) {
      final token = _next();
      tokens.add(token);
      // Defensive: a zero-width token would spin forever.
      if (token.end <= token.start) break;
    }
    tokens.add(
      Token(
        type: TokenType.eof,
        text: '',
        start: source.length,
        end: source.length,
      ),
    );
    return tokens;
  }

  Token _next() {
    final start = _pos;
    final ch = source[_pos];

    if (_isSpace(ch)) {
      while (_pos < source.length && _isSpace(source[_pos])) {
        _pos++;
      }
      return _make(TokenType.whitespace, start);
    }

    // Comments run to end of line. `#` only counts at the very start of the
    // line or after whitespace, so `#1` in "item #1" still lexes as text
    // rather than swallowing the rest of the line.
    if (ch == '/' && _peek(1) == '/') {
      _pos = source.length;
      return _make(TokenType.comment, start);
    }
    if (ch == '#' && (start == 0 || _isSpace(source[start - 1]))) {
      _pos = source.length;
      return _make(TokenType.comment, start);
    }

    if (currencySymbolCodes.containsKey(ch)) {
      _pos++;
      return _make(TokenType.currencySymbol, start);
    }

    if (_isDigit(ch) || (ch == '.' && _isDigit(_peek(1) ?? ''))) {
      return _number(start);
    }

    if (_isIdentStart(ch)) {
      _pos++;
      while (_pos < source.length && _isIdentPart(source[_pos])) {
        _pos++;
      }
      return _make(TokenType.identifier, start);
    }

    if (ch == '%') {
      _pos++;
      return _make(TokenType.percent, start);
    }
    if (ch == '(' || ch == '[') {
      _pos++;
      return _make(TokenType.lparen, start);
    }
    if (ch == ')' || ch == ']') {
      _pos++;
      return _make(TokenType.rparen, start);
    }
    if (ch == ';') {
      _pos++;
      return _make(TokenType.comma, start);
    }
    if (ch == ',') {
      _pos++;
      return _make(TokenType.comma, start);
    }

    for (final op in _multiCharOperators) {
      if (source.startsWith(op, _pos)) {
        _pos += op.length;
        return _make(TokenType.operator, start);
      }
    }
    if (_singleCharOperators.contains(ch)) {
      _pos++;
      return _make(TokenType.operator, start);
    }

    _pos++;
    return _make(TokenType.unknown, start);
  }

  /// Reads a number, absorbing `,`/`_` group separators and an optional
  /// exponent. A comma only counts as a separator when the digits after it
  /// complete a grouped integer — `1,250` and the Indian `12,34,567` are
  /// single numbers, while `max(1, 250)` stays two arguments.
  Token _number(int start) {
    final buffer = StringBuffer();
    while (_pos < source.length) {
      final ch = source[_pos];
      if (_isDigit(ch)) {
        buffer.write(ch);
        _pos++;
      } else if (ch == '_' && _isDigit(_peek(1) ?? '')) {
        _pos++;
      } else if (ch == ',' && _isThousandsSeparator(_pos)) {
        _pos++;
      } else {
        break;
      }
    }

    if (_pos < source.length &&
        source[_pos] == '.' &&
        _isDigit(_peek(1) ?? '')) {
      buffer.write('.');
      _pos++;
      while (_pos < source.length && _isDigit(source[_pos])) {
        buffer.write(source[_pos]);
        _pos++;
      }
    }

    // Scientific notation, but only when digits actually follow the sign.
    if (_pos < source.length && (source[_pos] == 'e' || source[_pos] == 'E')) {
      final save = _pos;
      var lookahead = _pos + 1;
      if (lookahead < source.length &&
          (source[lookahead] == '+' || source[lookahead] == '-')) {
        lookahead++;
      }
      if (lookahead < source.length && _isDigit(source[lookahead])) {
        buffer.write('e');
        _pos++;
        if (source[_pos] == '+' || source[_pos] == '-') {
          buffer.write(source[_pos]);
          _pos++;
        }
        while (_pos < source.length && _isDigit(source[_pos])) {
          buffer.write(source[_pos]);
          _pos++;
        }
      } else {
        _pos = save;
      }
    }

    final value = double.tryParse(buffer.toString());
    return Token(
      type: TokenType.number,
      text: source.substring(start, _pos),
      start: start,
      end: _pos,
      number: value,
    );
  }

  /// A run of separated groups, anchored at one comma: either the final
  /// group of three, or — for Indian grouping — pairs leading to one.
  ///
  /// Matching the whole run rather than a single group is what keeps
  /// `max(10,20,30)` three arguments: `,20,30` never reaches a closing group
  /// of three, so neither comma is a separator.
  static final RegExp _groupRun = RegExp(
    r',\d{3}(?!\d)|(?:,\d{2})+,\d{3}(?!\d)',
  );

  bool _isThousandsSeparator(int commaIndex) {
    if (commaIndex == 0) return false;
    if (!_isDigit(source[commaIndex - 1])) return false;
    return _groupRun.matchAsPrefix(source, commaIndex) != null;
  }

  Token _make(TokenType type, int start) => Token(
    type: type,
    text: source.substring(start, _pos),
    start: start,
    end: _pos,
  );

  String? _peek(int offset) =>
      _pos + offset < source.length ? source[_pos + offset] : null;

  static bool _isSpace(String ch) =>
      ch == ' ' || ch == '\t' || ch == ' ' || ch == ' ';

  static bool _isDigit(String ch) =>
      ch.length == 1 && ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;

  static bool _isIdentStart(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        ch == '_' ||
        ch == '°' ||
        c > 0x7f && !currencySymbolCodes.containsKey(ch);
  }

  static bool _isIdentPart(String ch) => _isIdentStart(ch) || _isDigit(ch);
}
