import 'dart:math' as math;

/// A physical (or pseudo-physical) dimension expressed as a vector of
/// exponents over a fixed set of base dimensions.
///
/// `data`, `currency` and `angle` are not SI base dimensions, but modelling
/// them the same way lets one code path handle `10 km/h`, `50 MB/s` and
/// `120 USD/hour` alike.
class Dimension {
  static const int length = 0;
  static const int mass = 1;
  static const int time = 2;
  static const int current = 3;
  static const int temperature = 4;
  static const int amount = 5;
  static const int luminous = 6;
  static const int data = 7;
  static const int currency = 8;
  static const int angle = 9;
  static const int slots = 10;

  final List<int> exponents;

  const Dimension._(this.exponents);

  static const Dimension scalar = Dimension._([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

  factory Dimension.base(int slot, [int power = 1]) {
    final e = List<int>.filled(slots, 0);
    e[slot] = power;
    return Dimension._(e);
  }

  factory Dimension.of(Map<int, int> parts) {
    final e = List<int>.filled(slots, 0);
    parts.forEach((slot, power) => e[slot] = power);
    return Dimension._(e);
  }

  bool get isScalar => exponents.every((v) => v == 0);

  Dimension operator *(Dimension other) => Dimension._(
    List<int>.generate(slots, (i) => exponents[i] + other.exponents[i]),
  );

  Dimension operator /(Dimension other) => Dimension._(
    List<int>.generate(slots, (i) => exponents[i] - other.exponents[i]),
  );

  Dimension pow(int n) =>
      Dimension._(List<int>.generate(slots, (i) => exponents[i] * n));

  /// True when this dimension involves money, which changes how results are
  /// formatted (always two decimals) and coloured.
  bool get isMonetary => exponents[currency] != 0;

  @override
  bool operator ==(Object other) {
    if (other is! Dimension) return false;
    for (var i = 0; i < slots; i++) {
      if (exponents[i] != other.exponents[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(exponents);
}

/// A single unit as the user can name it, defined by how it maps onto the
/// dimension's base unit: `base = value * factor + offset`.
class UnitDef {
  final String symbol;
  final Dimension dimension;
  final double factor;
  final double offset;
  final String category;

  /// Every spelling that resolves to this unit, lowercased.
  final List<String> aliases;

  const UnitDef({
    required this.symbol,
    required this.dimension,
    required this.factor,
    required this.aliases,
    required this.category,
    this.offset = 0,
  });

  bool get isCurrency => category == 'currency';
}

/// One factor of a possibly-compound unit, e.g. the `h^-1` in `km/h`.
class UnitTerm {
  final UnitDef def;
  final int exponent;

  const UnitTerm(this.def, this.exponent);
}

/// A compound unit: an ordered product of [UnitTerm]s.
class Unit {
  final List<UnitTerm> terms;

  const Unit(this.terms);

  factory Unit.single(UnitDef def) => Unit([UnitTerm(def, 1)]);

  static const Unit none = Unit([]);

  bool get isEmpty => terms.isEmpty;

  /// A simple unit is a single unit raised to the first power — the only
  /// shape for which an additive [UnitDef.offset] is meaningful.
  UnitDef? get simple =>
      terms.length == 1 && terms.first.exponent == 1 ? terms.first.def : null;

  Dimension get dimension {
    var d = Dimension.scalar;
    for (final t in terms) {
      d = d * t.def.dimension.pow(t.exponent);
    }
    return d;
  }

  bool get isCurrency => simple?.isCurrency ?? false;

  /// Multiplicative conversion factor to the dimension's base units.
  double get factor {
    var f = 1.0;
    for (final t in terms) {
      f *= math.pow(t.def.factor, t.exponent).toDouble();
    }
    return f;
  }

  double get offset => simple?.offset ?? 0;

  Unit operator *(Unit other) => Unit._combine([...terms, ...other.terms]);

  Unit operator /(Unit other) => Unit._combine([
    ...terms,
    ...other.terms.map((t) => UnitTerm(t.def, -t.exponent)),
  ]);

  Unit pow(int n) =>
      Unit._combine(terms.map((t) => UnitTerm(t.def, t.exponent * n)).toList());

  /// Merges repeated units and drops any that cancel out.
  static Unit _combine(List<UnitTerm> input) {
    final order = <String>[];
    final byUnit = <String, UnitTerm>{};
    for (final t in input) {
      final existing = byUnit[t.def.symbol];
      if (existing == null) {
        order.add(t.def.symbol);
        byUnit[t.def.symbol] = t;
      } else {
        byUnit[t.def.symbol] = UnitTerm(
          existing.def,
          existing.exponent + t.exponent,
        );
      }
    }
    final out = <UnitTerm>[];
    for (final key in order) {
      final t = byUnit[key]!;
      if (t.exponent != 0) out.add(t);
    }
    return Unit(out);
  }

  /// Renders as `km/h`, `m^2`, `USD/h` — positives first, then a single
  /// solidus followed by the inverted negatives.
  String format() {
    if (terms.isEmpty) return '';
    final numerator = terms.where((t) => t.exponent > 0).toList();
    final denominator = terms.where((t) => t.exponent < 0).toList();

    String render(UnitTerm t, int exp) =>
        exp == 1 ? t.def.symbol : '${t.def.symbol}^$exp';

    final top = numerator.isEmpty
        ? '1'
        : numerator.map((t) => render(t, t.exponent)).join('·');
    if (denominator.isEmpty) return top;
    final bottom = denominator.map((t) => render(t, -t.exponent)).join('·');
    return '$top/$bottom';
  }

  @override
  bool operator ==(Object other) {
    if (other is! Unit || other.terms.length != terms.length) return false;
    for (var i = 0; i < terms.length; i++) {
      if (terms[i].def.symbol != other.terms[i].def.symbol ||
          terms[i].exponent != other.terms[i].exponent) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hashAll(terms.map((t) => '${t.def.symbol}^${t.exponent}'));
}
