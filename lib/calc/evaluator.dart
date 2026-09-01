import 'dart:math' as math;

import 'ast.dart';
import 'parser.dart';
import 'unit.dart';
import 'unit_registry.dart';
import 'value.dart';

/// Mutable state shared by every line of a note, top to bottom.
class CalcScope {
  final Map<String, CalcValue> variables = {};

  CalcValue? prev;
  CalcValue? runningSum;
  int numericCount = 0;

  CalcValue? get average {
    final sum = runningSum;
    if (sum == null || numericCount == 0) return null;
    return Arith.scale(sum, 1 / numericCount);
  }

  /// Folds a line's result into the running aggregates. Values that cannot
  /// join the sum (a boolean, or a unit that does not match) update `prev`
  /// but are left out of `sum`/`avg` rather than poisoning them.
  void record(CalcValue value) {
    prev = value;
    if (value is BooleanValue) return;
    final sum = runningSum;
    if (sum == null) {
      runningSum = value;
      numericCount = 1;
      return;
    }
    try {
      runningSum = Arith.add(sum, value);
      numericCount++;
    } on CalcError {
      // Mixed dimensions: keep the existing running total intact.
    }
  }

  void reset() {
    variables.clear();
    prev = null;
    runningSum = null;
    numericCount = 0;
  }
}

/// Walks the AST produced by [Parser] and produces a [CalcValue].
class Evaluator {
  final UnitRegistry registry;
  final CalcScope scope;

  const Evaluator({required this.registry, required this.scope});

  CalcValue evaluate(Node node) {
    switch (node) {
      case NumberNode():
        return NumberValue(node.value);

      case IdentifierNode():
        return _identifier(node.name);

      case QuantityNode():
        final magnitude = evaluate(node.magnitude);
        if (magnitude is QuantityValue) {
          // e.g. `$5 km` — nonsensical, but combine rather than crash.
          return QuantityValue(magnitude.value, magnitude.unit * node.unit);
        }
        return QuantityValue(Arith.scalar(magnitude), node.unit);

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
        scope.variables[node.name] = value;
        return value;

      case ConvertNode():
        return Arith.convert(evaluate(node.value), node.target);

      case AsPercentOfNode():
        final part = evaluate(node.part);
        final whole = evaluate(node.whole);
        final ratio = Arith.divide(part, whole);
        return NumberValue(Arith.scalar(ratio) * 100);
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
        return BooleanValue(Arith.truth(left) && Arith.truth(right));
      case 'or':
        return BooleanValue(Arith.truth(left) || Arith.truth(right));
      case 'xor':
        return BooleanValue(Arith.truth(left) ^ Arith.truth(right));
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

  CalcValue _identifier(String name) {
    final variable = scope.variables[name];
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
    }

    // Fall back to treating the bare word as one of that unit, which makes
    // `100 / 2 h` and `60 km / h` work without special-casing.
    final unit = registry.lookup(lower);
    if (unit != null) return QuantityValue(1, Unit.single(unit));

    throw CalcError('unknown name "$name"');
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
        return _reduce(args, (a, b) => a <= b ? a : b);
      case 'max':
        return _reduce(args, (a, b) => a >= b ? a : b);
      case 'sum':
        return args.reduce(Arith.add);
      case 'avg':
      case 'mean':
        return Arith.scale(args.reduce(Arith.add), 1 / args.length);
      case 'median':
        final nums = args.map(Arith.scalar).toList()..sort();
        if (nums.isEmpty) throw const CalcError('median needs values');
        final mid = nums.length ~/ 2;
        return NumberValue(
          nums.length.isOdd ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2,
        );
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
        return NumberValue(math.asin(arg(0)));
      case 'acos':
        return NumberValue(math.acos(arg(0)));
      case 'atan':
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

  CalcValue _reduce(
    List<CalcValue> args,
    double Function(double, double) pick,
  ) {
    if (args.isEmpty) throw const CalcError('needs at least one value');
    var best = args.first;
    for (final candidate in args.skip(1)) {
      final chosen = pick(Arith.scalar(best), Arith.scalar(candidate));
      best = chosen == Arith.scalar(best) ? best : candidate;
    }
    return best;
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
