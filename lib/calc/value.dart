import 'dart:math' as math;

import 'unit.dart';

/// Raised for anything the engine cannot compute. Lines that throw simply
/// render no result — a half-typed expression is not an error worth showing.
class CalcError implements Exception {
  final String message;
  const CalcError(this.message);

  @override
  String toString() => 'CalcError: $message';
}

/// What a line evaluated to. Drives both formatting and gutter colour.
enum ResultKind { number, currency, unit, boolean, other }

sealed class CalcValue {
  const CalcValue();

  ResultKind get kind;
}

class NumberValue extends CalcValue {
  final double value;
  const NumberValue(this.value);

  @override
  ResultKind get kind => ResultKind.number;
}

/// A number carrying a unit — including currency, which is just a unit whose
/// conversion factor happens to come from the network.
class QuantityValue extends CalcValue {
  final double value;
  final Unit unit;
  const QuantityValue(this.value, this.unit);

  @override
  ResultKind get kind =>
      unit.isCurrency ? ResultKind.currency : ResultKind.unit;

  /// Magnitude in base units, ignoring any additive offset. Correct for
  /// multiplication, division and *differences* between temperatures.
  double get linearBase => value * unit.factor;

  /// Magnitude in base units including the offset. Correct for an explicit
  /// conversion such as `20 degC to degF`.
  double get affineBase => value * unit.factor + unit.offset;
}

/// A percentage retains its "percent-ness" through the parse so that
/// `1250 + 8%` can mean "add 8 percent of 1250" rather than "add 0.08".
class PercentValue extends CalcValue {
  /// `20%` is stored as 0.2.
  final double fraction;
  const PercentValue(this.fraction);

  @override
  ResultKind get kind => ResultKind.number;
}

class BooleanValue extends CalcValue {
  final bool value;
  const BooleanValue(this.value);

  @override
  ResultKind get kind => ResultKind.boolean;
}

/// Arithmetic over [CalcValue], including the percentage and unit rules that
/// make natural phrasing work.
class Arith {
  const Arith._();

  /// Collapses a value to a bare number where one is required.
  static double scalar(CalcValue v) {
    if (v is NumberValue) return v.value;
    if (v is PercentValue) return v.fraction;
    if (v is BooleanValue) return v.value ? 1 : 0;
    if (v is QuantityValue) return v.value;
    throw const CalcError('expected a number');
  }

  static CalcValue add(CalcValue a, CalcValue b) => _addSub(a, b, 1);

  static CalcValue subtract(CalcValue a, CalcValue b) => _addSub(a, b, -1);

  static CalcValue _addSub(CalcValue a, CalcValue b, int sign) {
    // `1250 + 8%` — a trailing percentage scales the left operand.
    if (b is PercentValue && a is! PercentValue) {
      return scale(a, 1 + sign * b.fraction);
    }
    if (a is PercentValue && b is PercentValue) {
      return PercentValue(a.fraction + sign * b.fraction);
    }

    if (a is QuantityValue && b is QuantityValue) {
      if (a.unit.dimension != b.unit.dimension) {
        throw const CalcError('cannot add values with different units');
      }
      // Factor-only conversion: adding 9 degF to a Celsius value means adding
      // a 5 degC *difference*, not re-basing through absolute zero.
      final converted = b.value * (b.unit.factor / a.unit.factor);
      return QuantityValue(a.value + sign * converted, a.unit);
    }
    // A bare number alongside a quantity adopts the quantity's unit, which is
    // what "100 usd + 5" means to someone jotting down a total.
    if (a is QuantityValue) {
      return QuantityValue(a.value + sign * scalar(b), a.unit);
    }
    if (b is QuantityValue) {
      return QuantityValue(scalar(a) + sign * b.value, b.unit);
    }
    return NumberValue(scalar(a) + sign * scalar(b));
  }

  static CalcValue multiply(CalcValue a, CalcValue b) {
    if (a is PercentValue) return scale(b, a.fraction);
    if (b is PercentValue) return scale(a, b.fraction);

    if (a is QuantityValue && b is QuantityValue) {
      final unit = a.unit * b.unit;
      final base = a.linearBase * b.linearBase;
      if (unit.dimension.isScalar) return NumberValue(base);
      return QuantityValue(base / unit.factor, unit);
    }
    if (a is QuantityValue) return QuantityValue(a.value * scalar(b), a.unit);
    if (b is QuantityValue) return QuantityValue(scalar(a) * b.value, b.unit);
    return NumberValue(scalar(a) * scalar(b));
  }

  static CalcValue divide(CalcValue a, CalcValue b) {
    if (b is PercentValue) return scale(a, 1 / b.fraction);
    if (a is PercentValue && b is! QuantityValue) {
      return NumberValue(a.fraction / scalar(b));
    }

    if (a is QuantityValue && b is QuantityValue) {
      final unit = a.unit / b.unit;
      final base = a.linearBase / b.linearBase;
      if (unit.dimension.isScalar) return NumberValue(base);
      return QuantityValue(base / unit.factor, unit);
    }
    if (a is QuantityValue) return QuantityValue(a.value / scalar(b), a.unit);
    if (b is QuantityValue) {
      final unit = Unit.none / b.unit;
      final base = scalar(a) / b.linearBase;
      return QuantityValue(base / unit.factor, unit);
    }
    return NumberValue(scalar(a) / scalar(b));
  }

  static CalcValue power(CalcValue a, CalcValue b) {
    final exponent = scalar(b);
    if (a is QuantityValue && exponent == exponent.roundToDouble()) {
      final n = exponent.toInt();
      final unit = a.unit.pow(n);
      final value = _pow(a.value, exponent);
      if (unit.dimension.isScalar) {
        return NumberValue(_pow(a.linearBase, exponent));
      }
      return QuantityValue(value, unit);
    }
    return NumberValue(_pow(scalar(a), exponent));
  }

  static CalcValue modulo(CalcValue a, CalcValue b) =>
      NumberValue(scalar(a) % scalar(b));

  static CalcValue negate(CalcValue a) {
    if (a is QuantityValue) return QuantityValue(-a.value, a.unit);
    if (a is PercentValue) return PercentValue(-a.fraction);
    return NumberValue(-scalar(a));
  }

  /// Multiplies by a plain factor while preserving the value's shape.
  static CalcValue scale(CalcValue v, double factor) {
    if (v is QuantityValue) return QuantityValue(v.value * factor, v.unit);
    if (v is PercentValue) return PercentValue(v.fraction * factor);
    return NumberValue(scalar(v) * factor);
  }

  /// Explicit `to`/`in` conversion, offset-aware so temperatures work.
  static CalcValue convert(CalcValue value, Unit target) {
    if (value is! QuantityValue) {
      if (target.dimension.isScalar) return value;
      throw const CalcError('cannot convert a plain number to a unit');
    }
    if (value.unit.dimension != target.dimension) {
      throw const CalcError('incompatible units');
    }
    final base = value.affineBase;
    return QuantityValue((base - target.offset) / target.factor, target);
  }

  static CalcValue compare(String op, CalcValue a, CalcValue b) {
    final double left;
    final double right;
    if (a is QuantityValue && b is QuantityValue) {
      if (a.unit.dimension != b.unit.dimension) {
        throw const CalcError('incomparable units');
      }
      left = a.affineBase;
      right = b.affineBase;
    } else {
      left = scalar(a);
      right = scalar(b);
    }
    switch (op) {
      case '==':
        return BooleanValue((left - right).abs() < 1e-12);
      case '!=':
        return BooleanValue((left - right).abs() >= 1e-12);
      case '<':
        return BooleanValue(left < right);
      case '>':
        return BooleanValue(left > right);
      case '<=':
        return BooleanValue(left <= right);
      case '>=':
        return BooleanValue(left >= right);
    }
    throw CalcError('unknown comparison $op');
  }

  static bool truth(CalcValue v) {
    if (v is BooleanValue) return v.value;
    return scalar(v) != 0;
  }

  static double _pow(double base, double exponent) {
    if (exponent == exponent.roundToDouble() && exponent.abs() < 1000) {
      var result = 1.0;
      final n = exponent.toInt().abs();
      for (var i = 0; i < n; i++) {
        result *= base;
      }
      return exponent < 0 ? 1 / result : result;
    }
    return _mathPow(base, exponent);
  }

  static double _mathPow(double base, double exponent) {
    return math.pow(base, exponent).toDouble();
  }
}
