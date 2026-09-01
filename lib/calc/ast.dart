import 'unit.dart';

sealed class Node {
  const Node();
}

class NumberNode extends Node {
  final double value;
  const NumberNode(this.value);
}

/// A bare name: a variable, a running aggregate, a constant, or a unit used
/// on its own (`km` alone means one kilometre, which makes `100 / 2 km` work).
class IdentifierNode extends Node {
  final String name;
  const IdentifierNode(this.name);
}

/// A literal quantity such as `100 usd` or `10 km`.
class QuantityNode extends Node {
  final Node magnitude;
  final Unit unit;
  const QuantityNode(this.magnitude, this.unit);
}

class PercentNode extends Node {
  final Node operand;
  const PercentNode(this.operand);
}

class UnaryNode extends Node {
  final String op;
  final Node operand;
  const UnaryNode(this.op, this.operand);
}

class BinaryNode extends Node {
  final String op;
  final Node left;
  final Node right;
  const BinaryNode(this.op, this.left, this.right);
}

class CallNode extends Node {
  final String name;
  final List<Node> args;
  const CallNode(this.name, this.args);
}

class AssignNode extends Node {
  final String name;
  final Node value;
  const AssignNode(this.name, this.value);
}

class ConvertNode extends Node {
  final Node value;
  final Unit target;
  const ConvertNode(this.value, this.target);
}

/// `25 as a % of 200` — expressed as its own node because it reads as one
/// phrase rather than a composition of operators.
class AsPercentOfNode extends Node {
  final Node part;
  final Node whole;
  const AsPercentOfNode(this.part, this.whole);
}
