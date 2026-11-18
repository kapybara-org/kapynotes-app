import 'ast.dart';
import 'value.dart';

/// What a note's total says about one line it left out, or could not join.
class CountNote {
  final String text;

  /// Whether the line is one the writer might have expected in the total, as
  /// against one the total leaves out by its own rule. A mark shows on the
  /// line's chip; the rest only on hover.
  final bool mark;

  const CountNote(this.text, {this.mark = false});
}

/// One amount a line added to the note's total.
class CountedAmount {
  final int line;
  final CalcValue amount;
  final String? name;

  /// False once a later line took the amount's place.
  bool live = true;

  /// False when the amount is of another kind than the total.
  bool joined = true;

  /// Why the amount is no longer in the total, once it is not.
  CountNote? note;

  CountedAmount(this.line, this.amount, this.name);
}

/// What one line adds to the note's total, worked out from what the line
/// says and not from what the note held when it was first read, so that a
/// line read again in a later pass counts the same as one read afresh.
class Contribution {
  /// The amount the line adds, or null where it adds none.
  final CalcValue? amount;

  /// The name the line gives its value.
  final String? defines;

  /// Whether the line takes the place of the amount an earlier line counted
  /// under [defines].
  final bool replaces;

  /// The names of earlier amounts the line takes as its input, each with the
  /// part it plays there: their contributions come off the total.
  final Map<String, String> consumes;

  /// What the total says of a line that adds nothing the writer might have
  /// expected it to.
  final String? skipped;

  const Contribution({
    this.amount,
    this.defines,
    this.replaces = false,
    this.consumes = const {},
    this.skipped,
  });

  /// The contribution of a line that gave [value]: [node] is what the line
  /// says (null for a line worked out from words alone), [owner] the amount
  /// an earlier line counted under a name, and [isVariable] whether the note
  /// gave a name a value. A line worked out from the total itself adds
  /// nothing, whatever it says.
  factory Contribution.of(
    Node? node,
    CalcValue value, {
    required bool readsAggregate,
    required CountedAmount? Function(String name) owner,
    required bool Function(String name) isVariable,
  }) {
    var expression = node;
    String? name;
    while (expression is AssignNode) {
      name ??= expression.name;
      expression = expression.value;
    }
    final replaces =
        name != null && expression != null && !_reads(expression, name);

    Contribution claim({
      CalcValue? amount,
      String? skipped,
      Map<String, String> consumes = const {},
    }) => Contribution(
      amount: amount,
      defines: name,
      replaces: replaces,
      consumes: consumes,
      skipped: skipped,
    );

    if (readsAggregate) {
      return claim(skipped: 'Not added: it is worked out from the total');
    }
    if (!_isAmount(value)) return claim();
    switch (expression) {
      case ConvertNode(value: final inner):
        return claim(skipped: _restates(inner));
      case IdentifierNode() when isVariable(expression.name):
        return claim(skipped: 'Not added again: restates ${expression.name}');
      case BinaryNode(op: '+' || '-'):
        return _additive(expression, value, owner, claim);
      case BinaryNode(op: '*' || '/'):
        return claim(
          amount: value,
          consumes: _consumed(expression, owner, isVariable),
        );
      case _:
        return claim(amount: value);
    }
  }

  static Contribution _additive(
    BinaryNode expression,
    CalcValue value,
    CountedAmount? Function(String name) owner,
    Contribution Function({
      CalcValue? amount,
      String? skipped,
      Map<String, String> consumes,
    })
    claim,
  ) {
    final terms = <(int, Node)>[];
    Node node = expression;
    while (node is BinaryNode && (node.op == '+' || node.op == '-')) {
      terms.add((node.op == '+' ? 1 : -1, node.right));
      node = node.left;
    }
    terms.add((1, node));

    var rest = value;
    final names = <String>[];
    try {
      for (final (sign, term) in terms.reversed) {
        final reference = switch (term) {
          ConvertNode(value: IdentifierNode()) =>
            (term.value as IdentifierNode).name,
          IdentifierNode() => term.name,
          _ => null,
        };
        final counted = reference == null ? null : owner(reference);
        if (counted == null) continue;
        rest = sign > 0
            ? Arith.subtract(rest, counted.amount)
            : Arith.add(rest, counted.amount);
        names.add(reference!);
      }
    } on CalcError {
      return claim(amount: value);
    }
    if (names.isEmpty) return claim(amount: value);
    if (_isNothing(rest, value)) {
      return claim(skipped: 'Not added again: restates ${names.join(' and ')}');
    }
    return claim(amount: rest);
  }

  /// The earlier amounts a product or quotient takes as its input, and the
  /// part each plays: a rate (or a base, where the line only divides) with a
  /// unit, a count where a unitless amount goes with it, and a lone unitless
  /// amount is a base. A percentage factor is a share of the base, which
  /// stays; two amounts with units, or two unitless ones, are a new amount
  /// of their own.
  static Map<String, String> _consumed(
    BinaryNode expression,
    CountedAmount? Function(String name) owner,
    bool Function(String name) isVariable,
  ) {
    final references = <String, CountedAmount>{};
    var multiplies = false;
    var usable = true;

    void walk(Node node, bool denominator) {
      switch (node) {
        case BinaryNode(op: '*'):
          multiplies = true;
          walk(node.left, denominator);
          walk(node.right, denominator);
        case BinaryNode(op: '/'):
          walk(node.left, denominator);
          walk(node.right, !denominator);
        case NumberNode():
          break;
        case IdentifierNode():
          final counted = owner(node.name);
          if (counted != null) {
            if (denominator || references.containsKey(node.name)) {
              usable = false;
            }
            references[node.name] = counted;
          } else if (isVariable(node.name)) {
            usable = false;
          }
        default:
          usable = false;
      }
    }

    walk(expression, false);
    if (!usable || references.isEmpty) return const {};
    final withUnit = [
      for (final entry in references.entries)
        if (entry.value.amount is QuantityValue) entry.key,
    ];
    if (withUnit.length > 1) return const {};
    if (withUnit.isEmpty && references.length > 1) return const {};
    if (withUnit.isEmpty) return {references.keys.single: 'base'};
    return {
      for (final name in references.keys)
        name: name == withUnit.single
            ? (multiplies ? 'rate' : 'base')
            : 'count',
    };
  }

  static String _restates(Node node) => switch (node) {
    IdentifierNode() => 'Not added again: restates ${node.name}',
    _ => 'Not added again: a conversion restates its amount',
  };

  static bool _reads(Node node, String name) => switch (node) {
    IdentifierNode() => node.name == name,
    QuantityNode() => _reads(node.magnitude, name),
    PercentNode() => _reads(node.operand, name),
    UnaryNode() => _reads(node.operand, name),
    BinaryNode() => _reads(node.left, name) || _reads(node.right, name),
    CallNode() => node.args.any((arg) => _reads(arg, name)),
    AssignNode() => _reads(node.value, name),
    ConvertNode() => _reads(node.value, name),
    _ => false,
  };

  static bool _isAmount(CalcValue value) => switch (value) {
    NumberValue(:final value) => value.isFinite,
    FormattedNumberValue(:final value) => value.isFinite,
    QuantityValue(:final value) => value.isFinite,
    _ => false,
  };

  static bool _isNothing(CalcValue rest, CalcValue value) {
    final left = switch (rest) {
      QuantityValue(:final value) => value,
      NumberValue(:final value) => value,
      FormattedNumberValue(:final value) => value,
      _ => 1.0,
    };
    final whole = switch (value) {
      QuantityValue(:final value) => value,
      NumberValue(:final value) => value,
      FormattedNumberValue(:final value) => value,
      _ => 1.0,
    };
    return left.abs() <= 1e-9 * (whole.abs() > 1 ? whole.abs() : 1);
  }
}
