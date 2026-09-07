import 'dart:typed_data';

import 'node_id.dart';

/// One character of a [FugueText], alive or tombstoned.
///
/// The node keeps its tree links in both directions because the two halves of
/// the engine need opposite things: placing a new node walks *down* from its
/// parent to find the subtree it lands after, while rendering and anchoring
/// walk the flat [FugueText] order and only look *up* to coalesce runs.
class FugueNode {
  FugueNode({
    required this.id,
    required this.parent,
    required this.isLeftChild,
    required this.codeUnit,
    required this.deleted,
  });

  final NodeId id;

  /// The virtual root for top-level nodes; never null except on the root
  /// itself, which is not a character and never appears in document order.
  final FugueNode? parent;

  /// Left children sit before their parent in document order, right children
  /// after. A node's side never changes; only [deleted] is mutable.
  final bool isLeftChild;

  /// UTF-16 code unit. The editor's offsets are code-unit offsets, so the CRDT
  /// speaks the same unit rather than pretending to know about grapheme
  /// clusters it could not keep intact under concurrent edits anyway.
  final int codeUnit;

  /// Tombstone flag. Tombstones are never collected: a concurrent insert may
  /// still name this node as its parent long after the character is gone.
  bool deleted;

  /// Children kept sorted by [NodeId] — that sort *is* the tie-break between
  /// concurrent inserts at the same spot, so it has to be the same everywhere.
  final List<FugueNode> leftChildren = [];
  final List<FugueNode> rightChildren = [];

  /// Cached position in [FugueText] document order. Goes stale when a node
  /// is inserted before it; see [FugueText.indexOf] for how that is caught.
  int index = -1;

  /// Position among visible characters, or -1 for a tombstone. Only valid
  /// while the visible cache is fresh.
  int visibleIndex = -1;

  bool get isRoot => parent == null;
}

/// Where a new node hangs in the tree.
typedef Placement = ({FugueNode parent, bool isLeftChild});

/// Encoded form of a run of nodes, as stored in a snapshot.
///
/// `[replica, counter, parentReplica, parentCounter, side, text, deleted]`.
typedef EncodedRun = List<Object?>;

/// The Fugue text tree (Weidner & Kleppmann, "The Art of the Fugue"), in its
/// simple tree form, plus the flat document-order list the rest of the app
/// actually reads.
///
/// Why Fugue and not RGA or a list CRDT: every line of a note is a calculator
/// expression, so two people typing "12" and "34" into the same spot must not
/// come out as "1324". Fugue is *maximally non-interleaving* — a run typed by
/// one replica, forwards or backwards, stays contiguous under any merge — and
/// the tree rule that buys that is small enough to reason about in a test.
///
/// The tree defines the order; the [_order] list caches it. Every mutation
/// updates both, and the list is what makes offset lookups, rendering and
/// snapshot encoding linear rather than a tree walk per character.
class FugueText {
  FugueText();

  /// The virtual root. It is not a character: it only gives inserts at
  /// offset 0 of an empty document something to be a right child of.
  final FugueNode _root = FugueNode(
    id: const NodeId('', -1),
    parent: null,
    isLeftChild: false,
    codeUnit: 0,
    deleted: true,
  );

  /// Every node, tombstones included, in document order.
  final List<FugueNode> _order = [];

  final Map<String, FugueNode> _byId = {};

  /// Lowest position touched by an insert since the last renumbering. A
  /// node's cached index is trusted only if [_order] really holds it there;
  /// when that check fails, everything from this watermark on is renumbered
  /// in one pass. Appending at the end — by far the common keystroke — moves
  /// nothing, so its check always passes and no renumbering ever happens.
  int _staleFrom = 0;

  /// Visible nodes and text, patched in place by inserts and small deletes
  /// and rebuilt from scratch only after a big delete. Keeping them live is
  /// what makes a keystroke on a long note one memmove rather than a walk
  /// over every tombstone the note has ever had.
  List<FugueNode>? _visibleCache;
  String? _textCache;

  /// Same idea as [_staleFrom], for [FugueNode.visibleIndex].
  int _visibleStaleFrom = 0;

  /// Above this many nodes, a delete rebuilds the caches instead of patching
  /// them one node at a time; a rebuild is one linear pass, and patching a
  /// selection of thousands would be thousands of them.
  static const int _patchDeleteLimit = 32;

  FugueNode get root => _root;

  /// Nodes including tombstones. Grows for the life of the note.
  int get nodeCount => _order.length;

  /// Number of visible characters.
  int get length => visible.length;

  /// Visible characters in order. Do not hold on to it across a mutation.
  List<FugueNode> get visible {
    final cached = _visibleCache;
    if (cached != null) return cached;
    final built = <FugueNode>[];
    for (final node in _order) {
      if (!node.deleted) {
        node.visibleIndex = built.length;
        built.add(node);
      }
    }
    _visibleStaleFrom = built.length;
    return _visibleCache = built;
  }

  /// The visible text.
  String get text {
    final cached = _textCache;
    if (cached != null) return cached;
    return _textCache = _codeUnitsOf(visible);
  }

  static String _codeUnitsOf(List<FugueNode> nodes) {
    final units = Uint16List(nodes.length);
    for (var i = 0; i < nodes.length; i++) {
      units[i] = nodes[i].codeUnit;
    }
    return String.fromCharCodes(units);
  }

  FugueNode? node(NodeId id) => _byId[id.key];

  FugueNode? nodeAtVisible(int offset) {
    final nodes = visible;
    return offset >= 0 && offset < nodes.length ? nodes[offset] : null;
  }

  /// Position in document order; -1 for the root.
  int indexOf(FugueNode node) {
    if (node.isRoot) return -1;
    final cached = node.index;
    if (cached < 0 ||
        cached >= _order.length ||
        !identical(_order[cached], node)) {
      _renumber();
    }
    return node.index;
  }

  /// Visible position, or -1 for a tombstone.
  int visibleIndexOf(FugueNode node) {
    if (node.deleted) return -1;
    final nodes = visible;
    final cached = node.visibleIndex;
    if (cached < 0 ||
        cached >= nodes.length ||
        !identical(nodes[cached], node)) {
      for (var i = _visibleStaleFrom; i < nodes.length; i++) {
        nodes[i].visibleIndex = i;
      }
      _visibleStaleFrom = nodes.length;
    }
    return node.visibleIndex;
  }

  /// The nearest visible node strictly after [node] in document order.
  FugueNode? nextVisible(FugueNode node) {
    for (var i = indexOf(node) + 1; i < _order.length; i++) {
      if (!_order[i].deleted) return _order[i];
    }
    return null;
  }

  /// The nearest visible node strictly before [node] in document order.
  FugueNode? previousVisible(FugueNode node) {
    for (var i = indexOf(node) - 1; i >= 0; i--) {
      if (!_order[i].deleted) return _order[i];
    }
    return null;
  }

  /// Where a local insert at visible [offset] hangs, by the Fugue rule.
  ///
  /// Let `a` be the character before the offset (the root at 0). If `a` has
  /// no right children the new node becomes one — the plain "type after"
  /// case. Otherwise something already follows `a` in the tree, possibly a
  /// tombstone the offset cannot see, and the new node becomes a left child
  /// of the *very next node in document order*, `b`. That `b` is the leftmost
  /// descendant of `a`'s first right child, so it has no left children of
  /// its own — the assert guards the invariant the paper relies on.
  ///
  /// Using the tree rather than the visible neighbour is what makes the
  /// non-interleaving proof hold once deletions are in play.
  Placement placementAt(int offset) {
    final a = offset <= 0 ? _root : visible[offset - 1];
    if (a.rightChildren.isEmpty) return (parent: a, isLeftChild: false);
    final b = _order[indexOf(a) + 1];
    assert(b.leftChildren.isEmpty, 'Fugue invariant: b has no left children');
    return (parent: b, isLeftChild: true);
  }

  /// Inserts a run of consecutive ids `(replica, counter + k)` whose first
  /// node hangs at [placement] and every later one is a right child of the
  /// one before. Nodes that already exist are skipped, except that [deleted]
  /// is OR'd in so a snapshot's tombstones win over an older live copy.
  ///
  /// Returns the number of visible characters added. The caller has already
  /// checked that `placement.parent` exists; only an *existing* previous
  /// character can be a parent for `k > 0`, so nothing else can be missing.
  ///
  /// Consecutive brand-new nodes are contiguous in document order — each is
  /// the sole right child of a node with no other children — so they are
  /// staged and written with one `insertAll` instead of one memmove per
  /// character. That is the difference between a paste costing O(n) and
  /// O(n·m).
  int insertRun({
    required String replica,
    required int counter,
    required Placement placement,
    required String text,
    bool deleted = false,
  }) {
    var added = 0;
    var batchPosition = -1;
    final batch = <FugueNode>[];
    FugueNode? previous;

    void flush() {
      if (batch.isEmpty) return;
      _order.insertAll(batchPosition, batch);
      for (var i = 0; i < batch.length; i++) {
        batch[i].index = batchPosition + i;
      }
      if (batchPosition < _staleFrom) _staleFrom = batchPosition;
      if (!deleted) _patchInsert(batchPosition, batch);
      batch.clear();
      batchPosition = -1;
    }

    for (var k = 0; k < text.length; k++) {
      final id = NodeId(replica, counter + k);
      final existing = _byId[id.key];
      if (existing != null) {
        flush();
        if (deleted) delete(existing);
        previous = existing;
        continue;
      }

      final FugueNode parent;
      final bool isLeftChild;
      if (k == 0) {
        parent = placement.parent;
        isLeftChild = placement.isLeftChild;
      } else {
        parent = previous!;
        isLeftChild = false;
      }

      final node = FugueNode(
        id: id,
        parent: parent,
        isLeftChild: isLeftChild,
        codeUnit: text.codeUnitAt(k),
        deleted: deleted,
      );
      _byId[id.key] = node;

      final chained =
          batch.isNotEmpty && identical(parent, batch.last) && !isLeftChild;
      if (chained) {
        // The parent is a staged node with no children yet: this node is its
        // only right child and follows it immediately.
        parent.rightChildren.add(node);
        batch.add(node);
      } else {
        flush();
        batchPosition = _place(node);
        batch.add(node);
      }
      if (!deleted) added++;
      previous = node;
    }
    flush();
    return added;
  }

  /// Tombstones [node]. Returns true if it was visible until now.
  bool delete(FugueNode node) {
    if (node.deleted) return false;
    final cache = _visibleCache;
    if (cache != null) {
      final at = visibleIndexOf(node);
      cache.removeAt(at);
      if (at < _visibleStaleFrom) _visibleStaleFrom = at;
      _textCache = _textCache?.replaceRange(at, at + 1, '');
    }
    node.deleted = true;
    return true;
  }

  /// Tombstones every node in [nodes]. Returns how many were visible.
  int deleteAll(Iterable<FugueNode> nodes) {
    final live = [
      for (final node in nodes)
        if (!node.deleted) node,
    ];
    if (live.length > _patchDeleteLimit) {
      for (final node in live) {
        node.deleted = true;
      }
      _invalidate();
    } else {
      for (final node in live) {
        delete(node);
      }
    }
    return live.length;
  }

  /// Splices freshly inserted visible nodes into the caches. Their visible
  /// offset is one past the nearest visible node before them, found by
  /// stepping back over tombstones — usually zero steps.
  void _patchInsert(int position, List<FugueNode> nodes) {
    final cache = _visibleCache;
    if (cache == null) return;
    var at = 0;
    for (var i = position - 1; i >= 0; i--) {
      final before = _order[i];
      if (!before.deleted) {
        at = visibleIndexOf(before) + 1;
        break;
      }
    }
    cache.insertAll(at, nodes);
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].visibleIndex = at + i;
    }
    if (at < _visibleStaleFrom) _visibleStaleFrom = at;
    _textCache = _textCache?.replaceRange(at, at, _codeUnitsOf(nodes));
  }

  /// Links [node] into its parent's sibling list and returns the document
  /// position it must occupy — computed from the tree *before* the node is in
  /// [_order], which is why this is the one place order and tree can differ.
  ///
  /// Right children follow the parent in id order, each with its whole
  /// subtree, so a right child lands just after the parent (if it sorts
  /// first) or just after the subtree of the sibling before it. Left children
  /// mirror that: just before the parent (if it sorts last) or at the start
  /// of the subtree of the sibling after it.
  int _place(FugueNode node) {
    final parent = node.parent!;
    if (node.isLeftChild) {
      final siblings = parent.leftChildren;
      final at = _siblingSlot(siblings, node.id);
      final position = at == siblings.length
          ? indexOf(parent)
          : indexOf(_leftmost(siblings[at]));
      siblings.insert(at, node);
      return position;
    } else {
      final siblings = parent.rightChildren;
      final at = _siblingSlot(siblings, node.id);
      final position = at == 0
          ? indexOf(parent) + 1
          : indexOf(_rightmost(siblings[at - 1])) + 1;
      siblings.insert(at, node);
      return position;
    }
  }

  static int _siblingSlot(List<FugueNode> siblings, NodeId id) {
    var low = 0;
    var high = siblings.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (siblings[mid].id.compareTo(id) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// First node of [node]'s subtree in document order.
  static FugueNode _leftmost(FugueNode node) {
    var current = node;
    while (current.leftChildren.isNotEmpty) {
      current = current.leftChildren.first;
    }
    return current;
  }

  /// Last node of [node]'s subtree in document order.
  static FugueNode _rightmost(FugueNode node) {
    var current = node;
    while (current.rightChildren.isNotEmpty) {
      current = current.rightChildren.last;
    }
    return current;
  }

  void _renumber() {
    for (var i = _staleFrom; i < _order.length; i++) {
      _order[i].index = i;
    }
    _staleFrom = _order.length;
  }

  void _invalidate() {
    _visibleCache = null;
    _textCache = null;
  }

  /// Document order as coalesced runs, for [encodeRuns] and snapshots.
  ///
  /// A run is a stretch of nodes from one replica with consecutive counters,
  /// each the right child of the one before, all alive or all tombstoned —
  /// exactly what typing produces, so a note snapshot is close to the size of
  /// its text rather than a record per character. Listing runs in document
  /// order means a decoder can also stream them; the only wrinkle is that a
  /// left child precedes its parent, which the decoder's pending buffer
  /// absorbs.
  List<EncodedRun> encodeRuns() {
    final runs = <EncodedRun>[];
    String? replica;
    var startCounter = 0;
    var lastCounter = 0;
    FugueNode? first;
    FugueNode? last;
    var deleted = false;
    var units = <int>[];

    void close() {
      if (first == null) return;
      final parent = first!.parent!;
      runs.add([
        replica,
        startCounter,
        parent.isRoot ? null : parent.id.replica,
        parent.isRoot ? null : parent.id.counter,
        first!.isLeftChild ? 'L' : 'R',
        String.fromCharCodes(units),
        deleted ? 1 : 0,
      ]);
      first = null;
      units = <int>[];
    }

    for (final node in _order) {
      final continues =
          first != null &&
          node.id.replica == replica &&
          node.id.counter == lastCounter + 1 &&
          identical(node.parent, last) &&
          !node.isLeftChild &&
          node.deleted == deleted;
      if (!continues) {
        close();
        first = node;
        replica = node.id.replica;
        startCounter = node.id.counter;
        deleted = node.deleted;
      }
      units.add(node.codeUnit);
      last = node;
      lastCounter = node.id.counter;
    }
    close();
    return runs;
  }
}
