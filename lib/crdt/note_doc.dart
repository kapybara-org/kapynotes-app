import '../data/note_attachment.dart';
import '../data/note_format.dart';
import 'anchor.dart';
import 'fugue_text.dart';
import 'node_id.dart';
import 'text_diff.dart';

/// What the editor renders: the note as it looks right now, in offsets.
///
/// [createdAt] is null until some replica has reconciled with a creation
/// time — a document rebuilt from a partial op stream has text before it has
/// metadata, and inventing a date there would be worse than admitting it. It
/// is always UTC: the register holds an instant, not a wall clock.
class DocView {
  const DocView({
    required this.body,
    required this.formats,
    required this.attachments,
    required this.createdAt,
  });

  final String body;
  final List<NoteFormatRange> formats;
  final List<NoteAttachmentRef> attachments;
  final DateTime? createdAt;
}

/// A last-writer-wins cell. Ties on [ts] break on [replica] so every client
/// picks the same winner without a coordinator.
class _Register {
  const _Register(this.value, this.ts, this.replica);

  final Object? value;
  final int ts;
  final String replica;

  bool isBeatenBy(int otherTs, String otherReplica) =>
      otherTs > ts || (otherTs == ts && otherReplica.compareTo(replica) > 0);
}

/// An insert op in parsed form, kept so a buffered op can be replayed and
/// re-emitted into a snapshot without re-parsing.
class _InsertRun {
  const _InsertRun({
    required this.replica,
    required this.counter,
    required this.parent,
    required this.isLeftChild,
    required this.text,
    required this.deleted,
  });

  final String replica;
  final int counter;
  final NodeId? parent;
  final bool isLeftChild;
  final String text;
  final bool deleted;

  List<Object?> toOp() => [
    'i',
    replica,
    counter,
    parent?.replica,
    parent?.counter,
    isLeftChild ? 'L' : 'R',
    text,
    if (deleted) 1,
  ];
}

/// One note as a CRDT: Fugue text plus LWW registers for the side tables.
///
/// The server is end-to-end encrypted and cannot merge, so every client is
/// the merger. This class is the whole merge: it turns editor state into
/// plaintext ops ([reconcile]), folds ops from anywhere back in ([apply]),
/// and merges whole snapshots ([mergeSnapshot]). Sealing and transport are
/// somebody else's job; nothing here knows about keys or the network.
///
/// Formats and attachments are stored *anchored*: a bold range is "from the
/// character with id a to the character with id b", not "[0, 5)". Offsets are
/// derived at render time, which is what keeps a style on the word it was
/// applied to when someone else types above it. The side tables themselves
/// are whole-value LWW registers rather than per-range CRDTs: a formatting
/// conflict is rare, cosmetic, and cheaper to lose than to model.
class NoteDoc {
  /// An empty document for [replica]. Replica ids must be unique per device
  /// (and per install — reusing one after a reinstall would reuse counters).
  NoteDoc({required this.replica});

  /// Rebuilds a document from [toSnapshot] output, continuing as [replica].
  factory NoteDoc.fromSnapshot(
    Map<String, Object?> snapshot, {
    required String replica,
  }) => NoteDoc(replica: replica)..mergeSnapshot(snapshot);

  static const int snapshotVersion = 1;

  static const String _fmtKey = 'fmt';
  static const String _attKey = 'att';
  static const String _createdKey = 'created';

  final String replica;

  final FugueText _tree = FugueText();
  final Map<String, _Register> _regs = {};

  /// Highest counter seen per replica, including our own. Our next counter
  /// continues above whatever is here, so a snapshot restored onto the same
  /// replica id can never mint an id that already exists.
  final Map<String, int> _clock = {};

  /// Ops whose parent (for inserts) or target (for deletes) has not arrived,
  /// keyed by the id they are waiting on. Woken the moment that id lands.
  final Map<String, List<Object?>> _waiting = {};
  int _waitingCount = 0;

  /// Ops woken by an insert and not yet replayed. Drained iteratively so a
  /// long chain of dependent ops cannot recurse.
  final List<Object?> _worklist = [];

  bool _changed = false;

  String get text => _tree.text;

  int get length => _tree.length;

  /// Nodes including tombstones. A caller deciding when to write a fresh
  /// snapshot instead of another op can watch this grow.
  int get nodeCount => _tree.nodeCount;

  /// Buffered ops still waiting for a parent or target to arrive.
  int get pendingCount => _waitingCount;

  /// Highest counter seen per replica.
  Map<String, int> get clock => Map.unmodifiable(_clock);

  DocView get view => DocView(
    body: text,
    formats: _renderFormats(),
    attachments: _renderAttachments(),
    createdAt: _createdAt(),
  );

  // ---------------------------------------------------------------------------
  // Local edits

  /// Folds an editor state in and returns the ops that express it, already
  /// applied here.
  ///
  /// The text is diffed against the current text as one contiguous edit —
  /// a keystroke is exactly that — with a replacement becoming a delete run
  /// then an insert run. Formats and attachments are compared *as rendered*
  /// against what was passed in, so handing back `view.formats` unchanged
  /// costs nothing, and only a real change re-anchors and emits a register.
  List<Object?> reconcile({
    required String body,
    required List<NoteFormatRange> formats,
    required List<NoteAttachmentRef> attachments,
    required DateTime createdAt,
    DateTime? now,
  }) {
    final ops = <Object?>[];
    final edit = diffTexts(text, body);

    if (edit.oldEnd > edit.start) {
      final victims = _tree.visible.sublist(edit.start, edit.oldEnd);
      for (final op in _coalesceDeletes(victims)) {
        ops.add(op);
        _applyDelete(op);
      }
    }

    if (edit.newEnd > edit.start) {
      final placement = _tree.placementAt(edit.start);
      final parent = placement.parent;
      final op = <Object?>[
        'i',
        replica,
        _nextCounter(),
        parent.isRoot ? null : parent.id.replica,
        parent.isRoot ? null : parent.id.counter,
        placement.isLeftChild ? 'L' : 'R',
        body.substring(edit.start, edit.newEnd),
      ];
      ops.add(op);
      _applyInsert(_parseInsert(op)!);
    }
    assert(text == body, 'reconcile did not reproduce the body');

    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;

    final wantedFormats = normalizeNoteFormats(formats, body.length);
    if (!_sameList(wantedFormats, _renderFormats())) {
      ops.add(_setLocal(_fmtKey, _anchorFormats(wantedFormats), nowMs));
    }

    // Most notes have no images; skip the placeholder scan for them.
    if (attachments.isNotEmpty || _regs[_attKey] != null) {
      final wantedAttachments = normalizeNoteAttachments(attachments, body);
      if (!_sameList(wantedAttachments, _renderAttachments())) {
        ops.add(
          _setLocal(_attKey, _anchorAttachments(wantedAttachments), nowMs),
        );
      }
    }

    final createdMs = createdAt.millisecondsSinceEpoch;
    if (_regs[_createdKey]?.value != createdMs) {
      ops.add(_setLocal(_createdKey, createdMs, nowMs));
    }

    _drain();
    return ops;
  }

  int _nextCounter() => (_clock[replica] ?? -1) + 1;

  /// Delete runs over consecutive ids, so backspacing through a typed word
  /// costs one op rather than one per character.
  static List<List<Object?>> _coalesceDeletes(List<FugueNode> nodes) {
    final ops = <List<Object?>>[];
    String? replica;
    var start = 0;
    var length = 0;
    for (final node in nodes) {
      if (replica == node.id.replica && node.id.counter == start + length) {
        length++;
        continue;
      }
      if (replica != null) ops.add(['d', replica, start, length]);
      replica = node.id.replica;
      start = node.id.counter;
      length = 1;
    }
    if (replica != null) ops.add(['d', replica, start, length]);
    return ops;
  }

  /// Writes a register locally and returns the op. The timestamp is bumped
  /// above whatever the register already holds: a device with a slow clock
  /// must still be able to change its own note, and a set that lost to a
  /// stale remote value would look like the edit silently failed.
  List<Object?> _setLocal(String key, Object? value, int nowMs) {
    final current = _regs[key];
    final ts = current != null && current.ts >= nowMs ? current.ts + 1 : nowMs;
    final op = <Object?>['r', key, value, ts, replica];
    _applyRegister(op);
    return op;
  }

  // ---------------------------------------------------------------------------
  // Remote ops

  /// Applies a batch of plaintext ops. Duplicates and any delivery order are
  /// safe; an op whose parent or target is unknown waits for it. Returns
  /// whether anything visible changed.
  bool apply(List<Object?> ops) {
    _changed = false;
    for (final op in ops) {
      _applyOne(op);
    }
    _drain();
    return _changed;
  }

  void _applyOne(Object? raw) {
    if (raw is! List || raw.isEmpty) return;
    switch (raw[0]) {
      case 'i':
        final run = _parseInsert(raw);
        if (run != null) _applyInsert(run);
      case 'd':
        _applyDelete(raw);
      case 'r':
        _applyRegister(raw);
    }
  }

  void _drain() {
    while (_worklist.isNotEmpty) {
      _applyOne(_worklist.removeLast());
    }
  }

  static _InsertRun? _parseInsert(List<Object?> op) {
    if (op.length < 7) return null;
    final replica = op[1];
    final counter = _asInt(op[2]);
    final parentReplica = op[3];
    final parentCounter = _asInt(op[4]);
    final side = op[5];
    final text = op[6];
    if (replica is! String || counter == null || text is! String) return null;
    if (side != 'L' && side != 'R') return null;
    NodeId? parent;
    if (parentReplica != null || parentCounter != null) {
      if (parentReplica is! String || parentCounter == null) return null;
      parent = NodeId(parentReplica, parentCounter);
    }
    return _InsertRun(
      replica: replica,
      counter: counter,
      parent: parent,
      isLeftChild: side == 'L',
      text: text,
      deleted: op.length > 7 && _asInt(op[7]) == 1,
    );
  }

  void _applyInsert(_InsertRun run) {
    if (run.text.isEmpty) return;
    final FugueNode parent;
    if (run.parent == null) {
      parent = _tree.root;
    } else {
      final found = _tree.node(run.parent!);
      if (found == null) {
        _wait(run.parent!.key, run.toOp());
        return;
      }
      parent = found;
    }
    final added = _tree.insertRun(
      replica: run.replica,
      counter: run.counter,
      placement: (parent: parent, isLeftChild: run.isLeftChild),
      text: run.text,
      deleted: run.deleted,
    );
    if (added > 0) _changed = true;

    final last = run.counter + run.text.length - 1;
    final seen = _clock[run.replica];
    if (seen == null || seen < last) _clock[run.replica] = last;

    if (_waiting.isNotEmpty) {
      for (var c = run.counter; c <= last; c++) {
        _wake(NodeId(run.replica, c).key);
      }
    }
  }

  void _applyDelete(List<Object?> op) {
    if (op.length < 4) return;
    final replica = op[1];
    final counter = _asInt(op[2]);
    final length = _asInt(op[3]);
    if (replica is! String || counter == null || length == null) return;
    final targets = <FugueNode>[];
    for (var c = counter; c < counter + length; c++) {
      final id = NodeId(replica, c);
      final node = _tree.node(id);
      if (node == null) {
        // Deletes that outran their insert are the other half of "any
        // order is safe"; the part already applied is idempotent to redo.
        _wait(id.key, op);
        break;
      }
      targets.add(node);
    }
    if (_tree.deleteAll(targets) > 0) _changed = true;
  }

  void _applyRegister(List<Object?> op) {
    if (op.length < 5) return;
    final key = op[1];
    final ts = _asInt(op[3]);
    final from = op[4];
    if (key is! String || ts == null || from is! String) return;
    final current = _regs[key];
    if (current != null && !current.isBeatenBy(ts, from)) return;
    _regs[key] = _Register(op[2], ts, from);
    _changed = true;
  }

  void _wait(String onKey, List<Object?> op) {
    _waiting.putIfAbsent(onKey, () => []).add(op);
    _waitingCount++;
  }

  void _wake(String key) {
    final woken = _waiting.remove(key);
    if (woken == null) return;
    _waitingCount -= woken.length;
    _worklist.addAll(woken);
  }

  // ---------------------------------------------------------------------------
  // Snapshots

  /// The full state: every node including tombstones, the registers, the
  /// clock, and any ops still waiting for parents so they are not lost.
  Map<String, Object?> toSnapshot() => {
    'v': snapshotVersion,
    'nodes': _tree.encodeRuns(),
    'regs': {
      for (final entry in _regs.entries)
        entry.key: [entry.value.value, entry.value.ts, entry.value.replica],
    },
    'clock': Map<String, int>.of(_clock),
    if (_waiting.isNotEmpty)
      'pending': [for (final ops in _waiting.values) ...ops],
  };

  /// Unions another replica's state into this one: nodes by id, tombstones
  /// OR'd, registers by LWW, clock by max. Returns whether anything visible
  /// changed. Merging a snapshot twice is a no-op.
  bool mergeSnapshot(Map<String, Object?> snapshot) {
    _changed = false;
    if (_asInt(snapshot['v']) != snapshotVersion) {
      throw FormatException('unsupported NoteDoc snapshot: ${snapshot['v']}');
    }

    final runs = snapshot['nodes'];
    if (runs is List) {
      for (final raw in runs) {
        if (raw is! List || raw.length < 7) continue;
        final run = _parseInsert(['i', ...raw]);
        if (run != null) _applyInsert(run);
      }
    }

    final regs = snapshot['regs'];
    if (regs is Map) {
      for (final entry in regs.entries) {
        final cell = entry.value;
        if (cell is! List || cell.length < 3) continue;
        _applyRegister(['r', entry.key, cell[0], cell[1], cell[2]]);
      }
    }

    final clock = snapshot['clock'];
    if (clock is Map) {
      for (final entry in clock.entries) {
        final key = entry.key;
        final value = _asInt(entry.value);
        if (key is! String || value == null) continue;
        final seen = _clock[key];
        if (seen == null || seen < value) _clock[key] = value;
      }
    }

    final pending = snapshot['pending'];
    if (pending is List) {
      for (final op in pending) {
        _applyOne(op);
      }
    }

    _drain();
    return _changed;
  }

  // ---------------------------------------------------------------------------
  // Caret

  /// The id of the visible character before [offset]; [Anchor.start] at 0.
  Anchor anchorAt(int offset) {
    final clamped = offset.clamp(0, length);
    if (clamped == 0) return Anchor.start;
    return Anchor(_tree.visible[clamped - 1].id);
  }

  /// The offset an anchor now denotes. A deleted anchor falls back to the
  /// nearest earlier visible character — where the caret would be after the
  /// text under it was backspaced away.
  int offsetOf(Anchor anchor) {
    final id = anchor.id;
    if (id == null) return 0;
    final node = _tree.node(id);
    if (node == null) return 0;
    final target = node.deleted ? _tree.previousVisible(node) : node;
    if (target == null) return 0;
    return _tree.visibleIndexOf(target) + 1;
  }

  // ---------------------------------------------------------------------------
  // Anchored registers

  /// `[aReplica, aCounter, bReplica, bCounter, format]` per range, where a is
  /// the first character and b the *last* (end - 1): both ends name real
  /// characters, so a range keeps its width when text is inserted at either
  /// edge and shrinks only when its own characters go.
  List<Object?> _anchorFormats(List<NoteFormatRange> formats) {
    final visible = _tree.visible;
    return [
      for (final range in formats)
        [
          visible[range.start].id.replica,
          visible[range.start].id.counter,
          visible[range.end - 1].id.replica,
          visible[range.end - 1].id.counter,
          range.format.name,
        ],
    ];
  }

  List<NoteFormatRange> _renderFormats() {
    final raw = _regs[_fmtKey]?.value;
    if (raw is! List) return const [];
    final ranges = <NoteFormatRange>[];
    for (final entry in raw) {
      if (entry is! List || entry.length < 5) continue;
      final a = _nodeFrom(entry[0], entry[1]);
      final b = _nodeFrom(entry[2], entry[3]);
      final format = _formatNamed(entry[4]);
      if (a == null || b == null || format == null) continue;

      final first = a.deleted ? _tree.nextVisible(a) : a;
      if (first == null) continue;
      final last = b.deleted ? _tree.previousVisible(b) : b;
      final start = _tree.visibleIndexOf(first);
      final end = last == null ? 0 : _tree.visibleIndexOf(last) + 1;
      if (end <= start) continue;
      ranges.add(NoteFormatRange(start: start, end: end, format: format));
    }
    return normalizeNoteFormats(ranges, length);
  }

  /// `[replica, counter, json]` per image, where the id is that of its
  /// U+FFFC and the json is [NoteAttachmentRef.toJson] minus the offset.
  List<Object?> _anchorAttachments(List<NoteAttachmentRef> attachments) {
    final visible = _tree.visible;
    return [
      for (final ref in attachments)
        [
          visible[ref.offset].id.replica,
          visible[ref.offset].id.counter,
          ref.toJson()..remove('offset'),
        ],
    ];
  }

  List<NoteAttachmentRef> _renderAttachments() {
    final raw = _regs[_attKey]?.value;
    if (raw is! List) return const [];
    final body = text;
    final refs = <NoteAttachmentRef>[];
    for (final entry in raw) {
      if (entry is! List || entry.length < 3) continue;
      final node = _nodeFrom(entry[0], entry[1]);
      final json = entry[2];
      if (node == null || node.deleted || json is! Map) continue;
      final offset = _tree.visibleIndexOf(node);
      if (body.codeUnitAt(offset) != 0xFFFC) continue;
      final ref = NoteAttachmentRef.fromJson({...json, 'offset': offset});
      if (ref != null) refs.add(ref);
    }
    return normalizeNoteAttachments(refs, body);
  }

  DateTime? _createdAt() {
    final ms = _asInt(_regs[_createdKey]?.value);
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  FugueNode? _nodeFrom(Object? replica, Object? counter) {
    final c = _asInt(counter);
    if (replica is! String || c == null) return null;
    return _tree.node(NodeId(replica, c));
  }

  static NoteFormat? _formatNamed(Object? name) {
    for (final format in NoteFormat.values) {
      if (format.name == name) return format;
    }
    return null;
  }

  /// JSON decoders hand back `num` for integers on some platforms.
  static int? _asInt(Object? value) => switch (value) {
    int v => v,
    num v => v.toInt(),
    _ => null,
  };

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
