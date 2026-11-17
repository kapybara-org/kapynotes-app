import 'dart:math' as math;

import '../data/time_zones.dart';
import 'ast.dart';
import 'notation.dart';
import 'parser.dart';
import 'unit.dart';
import 'unit_registry.dart';
import 'value.dart';

/// Mutable state shared by every line of a note, top to bottom.
///
/// Lines reach it only through the members below, so that while a line is
/// traced, from [beginTrace] to [endTrace], the scope can write down what the
/// line read and what it changed. [reuse] then tells whether the same text
/// would do exactly the same again in another scope, and if so does it.
class CalcScope {
  final Map<String, CalcValue> _variables = {};
  CalcValue? _prev;
  CalcValue? _runningSum;
  int _numericCount = 0;

  /// The defined names, sorted and joined, so that scopes defining the same
  /// names hold equal strings. Null once a name comes or goes, until asked
  /// for again.
  String? _names = '';

  ScopeTrace? _trace;

  /// The value the note gave [name], or null if it gave it none.
  CalcValue? operator [](String name) {
    final value = _variables[name];
    _trace?._sawValue(name, value);
    return value;
  }

  /// Whether the note has given [name] a value.
  bool defines(String name) {
    final defined = _variables.containsKey(name);
    _trace?._sawDefined(name, defined);
    return defined;
  }

  void operator []=(String name, CalcValue value) {
    if (!_variables.containsKey(name)) _names = null;
    _variables[name] = value;
    _trace?._wrote[name] = value;
  }

  /// Takes back the value the note gave [name], if it gave it one.
  void remove(String name) {
    if (_variables.remove(name) != null) _names = null;
    _trace?._wrote[name] = null;
  }

  CalcValue? get prev {
    _trace
      ?.._readsPrev = true
      .._prevSeen = _prev;
    return _prev;
  }

  CalcValue? get runningSum {
    _trace
      ?.._readsSum = true
      .._sumSeen = _runningSum;
    return _runningSum;
  }

  CalcValue? get average {
    final sum = runningSum;
    _trace
      ?.._readsCount = true
      .._countSeen = _numericCount;
    if (sum == null || _numericCount == 0) return null;
    return Arith.scale(sum, 1 / _numericCount);
  }

  /// Folds a line's result into the running aggregates. Values that cannot
  /// join the sum (a boolean, or a unit that does not match) update `prev`
  /// but are left out of `sum`/`avg` rather than poisoning them.
  void record(CalcValue value) {
    _prev = value;
    if (value is BooleanValue || value is DateTimeValue) return;
    final sum = _runningSum;
    if (sum == null) {
      _runningSum = value;
      _numericCount = 1;
      return;
    }
    try {
      _runningSum = Arith.add(sum, value);
      _numericCount++;
    } on CalcError {
      // Mixed dimensions: keep the existing running total intact.
    }
  }

  /// Starts writing down what the next line reads and writes.
  void beginTrace() => _trace = ScopeTrace._(_definedNames);

  /// Stops writing down, and returns what the line read and wrote: null when
  /// its answer could change with nothing in the note changing.
  ScopeTrace? endTrace() {
    final trace = _trace!;
    _trace = null;
    if (trace._unrepeatable) return null;
    return trace.._namesAfter = _definedNames;
  }

  /// Marks the line being traced as one whose answer can change with nothing
  /// in the note changing: it read the clock, drew a random number, or shows
  /// a date in the device's time zone, which the device can change.
  void markUnrepeatable() => _trace?._unrepeatable = true;

  /// Redoes the line [trace] was taken from if every read it made would see
  /// the same here: makes the line's writes and returns true. Otherwise
  /// leaves the scope as it is and returns false.
  bool reuse(ScopeTrace trace) {
    final names = _definedNames;
    final sameNames = names == trace._namesBefore;
    if (!sameNames && trace._defined.isNotEmpty) {
      for (final MapEntry(key: name, value: defined)
          in trace._defined.entries) {
        if (_variables.containsKey(name) != defined) return false;
      }
    }
    if (trace._values.isNotEmpty) {
      for (final MapEntry(key: name, :value) in trace._values.entries) {
        if (!_same(_variables[name], value)) return false;
      }
    }
    if ((trace._readsPrev && !_same(_prev, trace._prevSeen)) ||
        (trace._readsSum && !_same(_runningSum, trace._sumSeen)) ||
        (trace._readsCount && _numericCount != trace._countSeen)) {
      return false;
    }
    if (trace._wrote.isNotEmpty) {
      trace._wrote.forEach(
        (name, value) => value == null ? remove(name) : this[name] = value,
      );
    }
    if (sameNames) {
      _names = trace._namesAfter;
    } else {
      // The names are likely to be these next time too, and then they need
      // no checking one by one.
      trace
        .._namesBefore = names
        .._namesAfter = _definedNames;
    }
    return true;
  }

  String get _definedNames =>
      _names ??= (_variables.keys.toList()..sort()).join('\n');

  /// Whether a line could tell [a] from [b]: not if they are the same value,
  /// or the same kind of value with the same number, unit, notation or
  /// instant. The running total is added up afresh on every pass, so a
  /// `total` line could never be reused if only the same object would do.
  static bool _same(CalcValue? a, CalcValue? b) =>
      identical(a, b) ||
      switch ((a, b)) {
        (NumberValue x, NumberValue y) => _sameNumber(x.value, y.value),
        (FormattedNumberValue x, FormattedNumberValue y) =>
          x.notation == y.notation && _sameNumber(x.value, y.value),
        (PercentValue x, PercentValue y) => _sameNumber(x.fraction, y.fraction),
        (QuantityValue x, QuantityValue y) =>
          _sameNumber(x.value, y.value) && _sameUnit(x.unit, y.unit),
        (BooleanValue x, BooleanValue y) => x.value == y.value,
        (DateTimeValue x, DateTimeValue y) =>
          x.instant == y.instant &&
              x.timeZoneId == y.timeZoneId &&
              x.display == y.display,
        _ => false,
      };

  /// Equal and with the same sign, since a line that divides by zero tells
  /// -0 from 0.
  static bool _sameNumber(double a, double b) =>
      a == b && a.isNegative == b.isNegative;

  static bool _sameUnit(Unit a, Unit b) {
    if (a.terms.length != b.terms.length) return false;
    for (var i = 0; i < a.terms.length; i++) {
      if (!identical(a.terms[i].def, b.terms[i].def) ||
          a.terms[i].exponent != b.terms[i].exponent) {
        return false;
      }
    }
    return true;
  }
}

/// What one line read from a [CalcScope] and what it wrote there, between
/// [CalcScope.beginTrace] and [CalcScope.endTrace].
///
/// Only what the line found already in the scope counts as read: once the
/// line has written a name, what it reads back is its own doing.
class ScopeTrace {
  ScopeTrace._(this._namesBefore);

  /// The names defined before and after the line, the last time it was read
  /// or reused.
  String _namesBefore;
  late String _namesAfter;

  /// Names the line asked about, and whether each was defined. They need
  /// checking only in a scope that defines other names than [_namesBefore].
  final Map<String, bool> _defined = {};

  /// Names whose values the line read, and the values.
  final Map<String, CalcValue> _values = {};

  /// Names the line wrote, and what it left: null where it took a value away.
  final Map<String, CalcValue?> _wrote = {};

  bool _readsPrev = false;
  CalcValue? _prevSeen;
  bool _readsSum = false;
  CalcValue? _sumSeen;
  bool _readsCount = false;
  int _countSeen = 0;
  bool _unrepeatable = false;

  void _sawDefined(String name, bool defined) {
    if (_wrote.containsKey(name) || _values.containsKey(name)) return;
    _defined[name] = defined;
  }

  void _sawValue(String name, CalcValue? value) {
    if (value == null) {
      _sawDefined(name, false);
    } else if (!_wrote.containsKey(name)) {
      _defined.remove(name);
      _values[name] = value;
    }
  }
}

/// Walks the AST produced by [Parser] and produces a [CalcValue].
class Evaluator {
  static final math.Random _random = math.Random();

  final UnitRegistry registry;
  final CalcScope scope;
  final DateTime Function() now;
  final String? timeZoneId;

  const Evaluator({
    required this.registry,
    required this.scope,
    required this.now,
    this.timeZoneId,
  });

  CalcValue evaluate(Node node) {
    switch (node) {
      case NumberNode():
        return NumberValue(node.value);

      case IdentifierNode():
        return _identifier(node.name);

      case QuantityNode():
        final magnitude = evaluate(node.magnitude);
        final unit = _contextualUnit(node.unit);
        if (magnitude is QuantityValue) {
          // e.g. `$5 km` — nonsensical, but combine rather than crash.
          return QuantityValue(magnitude.value, magnitude.unit * unit);
        }
        return QuantityValue(Arith.scalar(magnitude), unit);

      case PercentNode():
        return PercentValue(Arith.scalar(evaluate(node.operand)) / 100);

      case UnaryNode():
        final operand = evaluate(node.operand);
        return node.op == 'not'
            ? BooleanValue(!Arith.truth(operand))
            : Arith.negate(operand);

      case BinaryNode():
        return _binary(node);

      case CallNode():
        return _call(node);

      case AssignNode():
        final value = evaluate(node.value);
        scope[node.name] = value;
        return value;

      case ConvertNode():
        return Arith.convert(
          evaluate(node.value),
          _contextualUnit(node.target),
        );

      case FormatNode():
        final value = evaluate(node.value);
        if (value is QuantityValue || value is BooleanValue) {
          throw const CalcError('numeric notation needs a plain number');
        }
        final number = Arith.scalar(value);
        if (node.notation != NumericNotation.scientific &&
            (!number.isFinite || number != number.truncateToDouble())) {
          throw const CalcError('base notation needs an integer');
        }
        return FormattedNumberValue(number, node.notation);

      case AsPercentOfNode():
        final part = evaluate(node.part);
        final whole = evaluate(node.whole);
        final numerator = switch (node.relationship) {
          'of' => part,
          'on' => Arith.subtract(part, whole),
          'off' => Arith.subtract(whole, part),
          _ => throw CalcError(
            'unknown percentage relationship ${node.relationship}',
          ),
        };
        final ratio = Arith.divide(numerator, whole);
        return NumberValue(Arith.scalar(ratio) * 100);

      case SolvePercentNode():
        final rate = evaluate(node.rate);
        if (rate is! PercentValue) {
          throw const CalcError('a percentage is required before "what"');
        }
        final divisor = switch (node.operation) {
          'of' => rate.fraction,
          'on' => 1 + rate.fraction,
          'off' => 1 - rate.fraction,
          _ => throw CalcError(
            'unknown percentage operation ${node.operation}',
          ),
        };
        if (divisor == 0) {
          throw const CalcError('percentage does not have a finite base');
        }
        return Arith.scale(evaluate(node.result), 1 / divisor);
    }
  }

  CalcValue _binary(BinaryNode node) {
    final op = node.op;

    // `20% off 50` and `20% on 50` read right-to-left: the percentage applies
    // to the value that follows it.
    if (op == 'off' || op == 'on') {
      final rate = evaluate(node.left);
      final base = evaluate(node.right);
      final delta = rate is PercentValue
          ? Arith.scale(base, rate.fraction)
          : Arith.multiply(base, rate);
      return op == 'off' ? Arith.subtract(base, delta) : Arith.add(base, delta);
    }
    if (op == 'of') {
      final rate = evaluate(node.left);
      final base = evaluate(node.right);
      return Arith.multiply(rate, base);
    }

    final left = evaluate(node.left);
    final right = evaluate(node.right);

    switch (op) {
      case '+':
        return Arith.add(left, right);
      case '-':
        return Arith.subtract(left, right);
      case '*':
        return Arith.multiply(left, right);
      case '/':
        return Arith.divide(left, right);
      case '^':
        return Arith.power(left, right);
      case 'mod':
        return Arith.modulo(left, right);
      case 'and':
        if (left is BooleanValue && right is BooleanValue) {
          return BooleanValue(left.value && right.value);
        }
        return Arith.add(left, right);
      case 'or':
        return BooleanValue(Arith.truth(left) || Arith.truth(right));
      case 'xor':
        if (left is BooleanValue && right is BooleanValue) {
          return BooleanValue(left.value ^ right.value);
        }
        return NumberValue((_integer(left) ^ _integer(right)).toDouble());
      case '&':
        return NumberValue((_integer(left) & _integer(right)).toDouble());
      case '|':
        return NumberValue((_integer(left) | _integer(right)).toDouble());
      case '<<':
        return NumberValue((_integer(left) << _shift(right)).toDouble());
      case '>>':
        return NumberValue((_integer(left) >> _shift(right)).toDouble());
      case '==':
      case '!=':
      case '<':
      case '>':
      case '<=':
      case '>=':
        return Arith.compare(op, left, right);
    }
    throw CalcError('unknown operator $op');
  }

  static int _integer(CalcValue value) {
    final number = Arith.scalar(value);
    if (!number.isFinite || number != number.truncateToDouble()) {
      throw const CalcError('bitwise operations need integers');
    }
    return number.toInt();
  }

  static int _shift(CalcValue value) {
    final amount = _integer(value);
    if (amount < 0 || amount > 63) {
      throw const CalcError('shift must be between 0 and 63');
    }
    return amount;
  }

  Unit _contextualUnit(Unit unit) {
    final ppi = _positiveScalar(scope['ppi']);
    final em = scope['em'];
    final emFactor =
        em is QuantityValue &&
            em.unit.dimension == Dimension.base(Dimension.length)
        ? em.linearBase
        : null;
    if (ppi == null && emFactor == null) return unit;

    return Unit(
      unit.terms.map((term) {
        final def = term.def;
        final factor = switch (def.symbol) {
          'px' when ppi != null => 0.0254 / ppi,
          'em' when emFactor != null => emFactor,
          _ => def.factor,
        };
        if (factor == def.factor) return term;
        return UnitTerm(
          UnitDef(
            symbol: def.symbol,
            dimension: def.dimension,
            factor: factor,
            aliases: def.aliases,
            category: def.category,
            offset: def.offset,
          ),
          term.exponent,
        );
      }).toList(),
    );
  }

  static double? _positiveScalar(CalcValue? value) {
    if (value == null) return null;
    try {
      final number = Arith.scalar(value);
      return number.isFinite && number > 0 ? number : null;
    } on CalcError {
      return null;
    }
  }

  CalcValue _identifier(String name) {
    final variable = scope[name];
    if (variable != null) return variable;

    final lower = name.toLowerCase();

    switch (lower) {
      case 'prev':
        final value = scope.prev;
        if (value == null) throw const CalcError('no previous result');
        return value;
      case 'sum':
      case 'total':
        final value = scope.runningSum;
        if (value == null) throw const CalcError('nothing to total');
        return value;
      case 'avg':
      case 'average':
        final value = scope.average;
        if (value == null) throw const CalcError('nothing to average');
        return value;
      case 'pi':
        return const NumberValue(math.pi);
      case 'e':
        // `e` is also the electron-charge-free base of natural logs; a unit
        // named `e` does not exist, so this is unambiguous.
        return NumberValue(math.e);
      case 'tau':
        return NumberValue(math.pi * 2);
      case 'phi':
        return NumberValue((1 + math.sqrt(5)) / 2);
      case 'inf':
      case 'infinity':
        return const NumberValue(double.infinity);
      case 'true':
        return const BooleanValue(true);
      case 'false':
        return const BooleanValue(false);
      case 'now':
        return DateTimeValue(
          _clock().toUtc(),
          timeZoneId: timeZoneId,
          display: TemporalDisplay.dateTime,
        );
      case 'time':
        return DateTimeValue(
          _clock().toUtc(),
          timeZoneId: timeZoneId,
          display: TemporalDisplay.time,
        );
      case 'today':
      case 'tomorrow':
      case 'yesterday':
        final shown = AppTimeZones.convert(_clock(), timeZoneId);
        final offset = lower == 'tomorrow'
            ? 1
            : lower == 'yesterday'
            ? -1
            : 0;
        return DateTimeValue(
          AppTimeZones.fromWallClock(
            year: shown.year,
            month: shown.month,
            day: shown.day + offset,
            locationId: timeZoneId,
          ),
          timeZoneId: timeZoneId,
          display: TemporalDisplay.date,
        );
    }

    // Fall back to treating the bare word as one of that unit, which makes
    // `100 / 2 h` and `60 km / h` work without special-casing.
    final unit = registry.lookup(name);
    if (unit != null) return QuantityValue(1, Unit.single(unit));

    throw CalcError('unknown name "$name"');
  }

  /// The time now, which a line that asks for can't be reused for.
  DateTime _clock() {
    scope.markUnrepeatable();
    return now();
  }

  CalcValue _call(CallNode node) {
    final args = node.args.map(evaluate).toList();

    double arg(int i) {
      if (i >= args.length) {
        throw CalcError('${node.name} needs more arguments');
      }
      return Arith.scalar(args[i]);
    }

    /// Preserves the unit of the first argument for functions that are
    /// dimension-safe, so `round(2.6 km)` stays `3 km`.
    CalcValue keepUnit(double result) {
      final first = args.isNotEmpty ? args.first : null;
      if (first is QuantityValue) return QuantityValue(result, first.unit);
      if (first is PercentValue) return PercentValue(result);
      return NumberValue(result);
    }

    switch (node.name) {
      case 'sqrt':
        return NumberValue(math.sqrt(arg(0)));
      case 'root':
        final degree = arg(0);
        final value = arg(1);
        if (degree == 0) throw const CalcError('root degree cannot be zero');
        if (value < 0 &&
            degree == degree.roundToDouble() &&
            degree.toInt().isOdd) {
          return NumberValue(-math.pow(-value, 1 / degree).toDouble());
        }
        return NumberValue(math.pow(value, 1 / degree).toDouble());
      case 'cbrt':
        final v = arg(0);
        return NumberValue(
          v < 0
              ? -math.pow(-v, 1 / 3).toDouble()
              : math.pow(v, 1 / 3).toDouble(),
        );
      case 'abs':
        return keepUnit(arg(0).abs());
      case 'round':
        final digits = args.length > 1 ? arg(1).toInt() : 0;
        final factor = math.pow(10, digits).toDouble();
        return keepUnit((arg(0) * factor).roundToDouble() / factor);
      case 'floor':
        return keepUnit(arg(0).floorToDouble());
      case 'ceil':
        return keepUnit(arg(0).ceilToDouble());
      case 'trunc':
        return keepUnit(arg(0).truncateToDouble());
      case 'sign':
        return NumberValue(arg(0).sign);
      case 'min':
        return _reduce(args, chooseLower: true);
      case 'max':
        return _reduce(args, chooseLower: false);
      case 'sum':
        return args.reduce(Arith.add);
      case 'avg':
      case 'mean':
        return Arith.scale(args.reduce(Arith.add), 1 / args.length);
      case 'median':
        if (args.isEmpty) throw const CalcError('median needs values');
        final sorted = [...args]..sort(_compareValues);
        final mid = sorted.length ~/ 2;
        return sorted.length.isOdd
            ? sorted[mid]
            : Arith.scale(Arith.add(sorted[mid - 1], sorted[mid]), 0.5);
      case 'log':
        return NumberValue(
          args.length > 1
              ? math.log(arg(0)) / math.log(arg(1))
              : math.log(arg(0)),
        );
      case 'ln':
        return NumberValue(math.log(arg(0)));
      case 'log10':
        return NumberValue(math.log(arg(0)) / math.ln10);
      case 'log2':
        return NumberValue(math.log(arg(0)) / math.ln2);
      case 'exp':
        return NumberValue(math.exp(arg(0)));
      case 'pow':
        return Arith.power(args[0], args[1]);
      case 'mod':
        return NumberValue(arg(0) % arg(1));
      case 'sin':
        return NumberValue(math.sin(_angle(args, 0)));
      case 'cos':
        return NumberValue(math.cos(_angle(args, 0)));
      case 'tan':
        return NumberValue(math.tan(_angle(args, 0)));
      case 'asin':
      case 'arcsin':
        return NumberValue(math.asin(arg(0)));
      case 'acos':
      case 'arccos':
        return NumberValue(math.acos(arg(0)));
      case 'atan':
      case 'arctan':
        return NumberValue(math.atan(arg(0)));
      case 'atan2':
        return NumberValue(math.atan2(arg(0), arg(1)));
      case 'sinh':
        return NumberValue((math.exp(arg(0)) - math.exp(-arg(0))) / 2);
      case 'cosh':
        return NumberValue((math.exp(arg(0)) + math.exp(-arg(0))) / 2);
      case 'tanh':
        final x = arg(0);
        final ex = math.exp(2 * x);
        return NumberValue((ex - 1) / (ex + 1));
      case 'hypot':
        return NumberValue(math.sqrt(arg(0) * arg(0) + arg(1) * arg(1)));
      case 'gcd':
        return NumberValue(_gcd(arg(0).round(), arg(1).round()).toDouble());
      case 'lcm':
        final a = arg(0).round();
        final b = arg(1).round();
        if (a == 0 || b == 0) return const NumberValue(0);
        return NumberValue((a * b ~/ _gcd(a, b)).abs().toDouble());
      case 'fact':
        final n = arg(0).round();
        if (n < 0 || n > 170) throw const CalcError('factorial out of range');
        var result = 1.0;
        for (var i = 2; i <= n; i++) {
          result *= i;
        }
        return NumberValue(result);
      case 'random':
        if (args.length > 2) {
          throw const CalcError('random accepts zero, one, or two values');
        }
        final lower = args.length == 2 ? arg(0) : 0.0;
        final upper = args.isEmpty ? 1.0 : arg(args.length - 1);
        if (!lower.isFinite || !upper.isFinite || upper < lower) {
          throw const CalcError('random needs a valid ascending range');
        }
        scope.markUnrepeatable();
        return NumberValue(lower + _random.nextDouble() * (upper - lower));
      case 'fromunix':
        return DateTimeValue(
          DateTime.fromMillisecondsSinceEpoch(
            (arg(0) * 1000).round(),
            isUtc: true,
          ),
          timeZoneId: timeZoneId,
          display: TemporalDisplay.dateTime,
        );
    }
    throw CalcError('unknown function ${node.name}');
  }

  /// Trig takes radians unless the argument carries an angle unit, so both
  /// `sin(pi/2)` and `sin(90 deg)` do the right thing.
  double _angle(List<CalcValue> args, int index) {
    if (index >= args.length) throw const CalcError('missing argument');
    final value = args[index];
    if (value is QuantityValue &&
        value.unit.dimension == Dimension.base(Dimension.angle)) {
      return value.linearBase;
    }
    return Arith.scalar(value);
  }

  CalcValue _reduce(List<CalcValue> args, {required bool chooseLower}) {
    if (args.isEmpty) throw const CalcError('needs at least one value');
    var best = args.first;
    for (final candidate in args.skip(1)) {
      final order = _compareValues(best, candidate);
      if ((chooseLower && order > 0) || (!chooseLower && order < 0)) {
        best = candidate;
      }
    }
    return best;
  }

  static int _compareValues(CalcValue left, CalcValue right) {
    final isLess = Arith.compare('<', left, right) as BooleanValue;
    if (isLess.value) return -1;
    final isGreater = Arith.compare('>', left, right) as BooleanValue;
    return isGreater.value ? 1 : 0;
  }

  static int _gcd(int a, int b) {
    a = a.abs();
    b = b.abs();
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    return a;
  }
}
