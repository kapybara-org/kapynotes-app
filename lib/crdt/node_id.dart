/// The identity of one character in a [NoteDoc](note_doc.dart).
///
/// A character is named by the replica that typed it and a counter that
/// replica only ever increases, so the pair is unique across every device
/// without anyone coordinating. The same pair is what formats, attachments
/// and the caret anchor to, which is the whole point of a CRDT for this app:
/// an offset moves when someone else types above it, an id does not.
///
/// Ordering is lexical on the replica then numeric on the counter. It has no
/// meaning as "earlier" or "later" — it is only the tie-break that decides
/// which of two concurrent siblings comes first, and any total order that
/// every client agrees on would do.
class NodeId implements Comparable<NodeId> {
  const NodeId(this.replica, this.counter);

  final String replica;
  final int counter;

  /// The map key used throughout the engine. Replica ids are opaque strings
  /// chosen by the caller, so the separator only has to be stable, not safe.
  String get key => '$replica:$counter';

  @override
  int compareTo(NodeId other) {
    final byReplica = replica.compareTo(other.replica);
    return byReplica != 0 ? byReplica : counter.compareTo(other.counter);
  }

  @override
  bool operator ==(Object other) =>
      other is NodeId && other.replica == replica && other.counter == counter;

  @override
  int get hashCode => Object.hash(replica, counter);

  @override
  String toString() => key;
}
