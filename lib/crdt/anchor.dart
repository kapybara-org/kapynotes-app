import 'node_id.dart';

/// A caret position that survives other people's edits.
///
/// The editor thinks in integer offsets, which stop meaning anything the
/// moment a remote insert lands above the caret. An anchor instead names the
/// visible character *before* the caret — or nothing, for offset 0 — so the
/// caret can be turned back into an offset after a merge and land where the
/// user left it, not where the numbers happen to point now.
class Anchor {
  const Anchor(this.id);

  /// Start of the document.
  static const Anchor start = Anchor(null);

  /// Id of the visible character immediately before the caret; null at 0.
  final NodeId? id;

  @override
  bool operator ==(Object other) => other is Anchor && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Anchor(${id ?? 'start'})';
}
