import 'package:flutter/foundation.dart';

import 'local_store.dart';

/// Which part of a pane a dragged note is over, across its width.
enum PaneDropZone { left, center, right }

/// What letting go of a dragged note would do.
enum PaneDropAction {
  /// The note takes the place of the one in the pane under it.
  replace,

  /// The note is already open in another pane, and the two trade places.
  swap,

  /// A new pane opens beside the one under the note, holding it.
  insert,

  /// The pane the note is already open in moves beside the one under it —
  /// or, dropped into an empty pane, moves into it.
  move,
}

/// A drop worked out before anything moves, so the overlay can show exactly
/// what [EditorWorkspace.drop] is about to do.
@immutable
class PaneDropPlan {
  const PaneDropPlan(this.action, this.zone);

  final PaneDropAction action;

  /// [PaneDropZone.left] or [PaneDropZone.right] where the note lands beside
  /// the pane, [PaneDropZone.center] where it lands in it. Not always the zone
  /// the pointer is in: with three panes open there is no room beside a pane,
  /// so its edges mean the pane itself.
  final PaneDropZone zone;

  @override
  bool operator ==(Object other) =>
      other is PaneDropPlan && other.action == action && other.zone == zone;

  @override
  int get hashCode => Object.hash(action, zone);
}

/// One editor column. It shows a single note, or none while it waits for one.
class EditorPane {
  EditorPane._(this.id, this._noteId);

  /// Stable for as long as the pane is open, whichever position it moves to,
  /// so the page can key the pane's own widgets to it.
  final int id;

  String? _noteId;

  /// Null in a pane that was split off and has not been given a note yet.
  String? get noteId => _noteId;
}

/// Which notes sit side by side on the desktop, and how wide each one is.
///
/// Up to [maxPanes] panes, one note in each, and never the same note in two:
/// opening a note that is already on screen focuses the pane it is in. There
/// are no tabs to pile up behind a pane — what a pane shows is what it holds.
///
/// This owns only placement. Text, caret, undo and calculation stay inside the
/// ordinary [NoteEditor] each pane builds.
class EditorWorkspace {
  EditorWorkspace(this._store);

  static const String storeKey = 'editorWorkspace.v1';
  static const int maxPanes = 3;

  final LocalStore _store;
  final List<EditorPane> _panes = [];

  /// Each pane's share of the row, in the same order, summing to one.
  final List<double> _weights = [];
  int _active = 0;
  int _nextId = 0;

  List<EditorPane> get panes => List.unmodifiable(_panes);
  int get paneCount => _panes.length;
  int get activePane => _active;
  bool get isSplit => _panes.length > 1;

  /// Each pane's share of the row, left to right.
  List<double> get weights => List.unmodifiable(_weights);

  /// The note in the focused pane: what the toolbar, the list's highlight and
  /// every note-wide shortcut act on. Null while that pane is empty.
  String? get selectedNoteId => _panes.isEmpty ? null : _panes[_active].noteId;

  Set<String> get openNoteIds => {for (final pane in _panes) ?pane.noteId};

  /// Where [noteId] is open, or -1.
  int paneOf(String noteId) =>
      _panes.indexWhere((pane) => pane.noteId == noteId);

  /// Whether another pane can open beside the focused one. Not beside an empty
  /// pane: a second blank next to the first is only another thing to close.
  bool get canSplit => _panes.length < maxPanes && selectedNoteId != null;

  /// Freezes the current pane arrangement for a transient note preview.
  ///
  /// A note switcher may move across a note that is already visible and then
  /// one that is not. Replaying every step against the last preview would
  /// progressively replace different panes. This session instead evaluates
  /// every preview against one baseline and one anchor pane.
  EditorWorkspacePreviewSession beginPreviewSession() =>
      EditorWorkspacePreviewSession._(this);

  /// Restores the panes that still name notes, then shows [openingNoteId].
  ///
  /// The startup preference stays in charge of which note comes up: it is
  /// focused where it is already open, and takes the focused pane where it is
  /// not, while the rest of the row survives the restart around it.
  void load({
    required Iterable<String> availableNoteIds,
    String? openingNoteId,
  }) {
    final available = availableNoteIds.toSet();
    _panes.clear();
    _weights.clear();
    _active = 0;

    final raw = _store.data[storeKey];
    if (raw is Map) {
      final notes = raw['panes'];
      final weights = raw['weights'];
      if (notes is List) {
        for (var index = 0; index < notes.length; index++) {
          final id = notes[index];
          if (id is! String || !available.contains(id) || paneOf(id) >= 0) {
            continue;
          }
          final weight = weights is List && index < weights.length
              ? weights[index]
              : null;
          _panes.add(_newPane(id));
          _weights.add(
            weight is num && weight.isFinite && weight > 0
                ? weight.toDouble()
                : 1,
          );
          if (_panes.length == maxPanes) break;
        }
      }
      final active = raw['active'];
      if (active is String && paneOf(active) >= 0) _active = paneOf(active);
    }
    _normalizeWeights();

    final opening = openingNoteId;
    if (opening != null && available.contains(opening)) {
      _show(opening);
    } else if (_panes.isEmpty && available.isNotEmpty) {
      _show(available.first);
    }
  }

  /// Shows [noteId] in the focused pane, in place of the note there — unless
  /// it is already open in another pane, which is then focused instead.
  bool open(String noteId) {
    final changed = _show(noteId);
    if (changed) _persist();
    return changed;
  }

  /// Opens an empty pane to the right of the focused one, and focuses it.
  bool split() {
    if (!canSplit) return false;
    _insert(_active + 1, null);
    _active++;
    _persist();
    return true;
  }

  /// Puts [noteId] beside the focused note: into an empty pane if one is
  /// waiting, into a new pane while there is room for one, and into the
  /// neighbouring pane once three are open.
  bool openToSide(String noteId) {
    if (_panes.isEmpty) return open(noteId);
    final existing = paneOf(noteId);
    if (existing >= 0) return activate(existing);

    final empty = _panes.indexWhere((pane) => pane.noteId == null);
    if (empty >= 0) {
      _panes[empty]._noteId = noteId;
      _active = empty;
    } else if (_panes.length < maxPanes) {
      _insert(_active + 1, noteId);
      _active++;
    } else {
      _active = _sideNeighbour;
      _panes[_active]._noteId = noteId;
    }
    _persist();
    return true;
  }

  /// The note [openToSide] would take off the screen: only ever the
  /// neighbour's, once three full panes leave nowhere else for it to go.
  String? displacedByOpenToSide(String noteId) {
    if (paneOf(noteId) >= 0 ||
        _panes.length < maxPanes ||
        _panes.any((pane) => pane.noteId == null)) {
      return null;
    }
    return _panes[_sideNeighbour].noteId;
  }

  /// The pane beside the focused one: on its right, or on its left for the
  /// last pane.
  int get _sideNeighbour =>
      _active + 1 < _panes.length ? _active + 1 : _active - 1;

  bool activate(int index) {
    if (index < 0 || index >= _panes.length || index == _active) return false;
    _active = index;
    _persist();
    return true;
  }

  /// Closes the pane at [index], and the panes left share the row evenly. The
  /// note itself is untouched, and the last pane stays: there is always
  /// somewhere to write.
  bool close(int index) {
    if (_panes.length < 2 || index < 0 || index >= _panes.length) return false;
    _removeAt(index);
    _persist();
    return true;
  }

  /// What dropping [noteId] on [zone] of the pane at [target] would do, or
  /// null where it would leave every pane as it is.
  PaneDropPlan? planDrop(String noteId, int target, PaneDropZone zone) {
    if (target < 0 || target >= _panes.length) return null;
    final source = paneOf(noteId);
    if (source == target) return null;

    if (zone != PaneDropZone.center) {
      if (source >= 0) {
        final beside = zone == PaneDropZone.left ? target - 1 : target + 1;
        if (source == beside) return null;
        return PaneDropPlan(PaneDropAction.move, zone);
      }
      if (_panes.length < maxPanes) {
        return PaneDropPlan(PaneDropAction.insert, zone);
      }
      // No room for a fourth pane, so the edges mean the pane itself.
    }

    if (source < 0) {
      return const PaneDropPlan(PaneDropAction.replace, PaneDropZone.center);
    }
    return _panes[target].noteId == null
        ? const PaneDropPlan(PaneDropAction.move, PaneDropZone.center)
        : const PaneDropPlan(PaneDropAction.swap, PaneDropZone.center);
  }

  /// Applies [planDrop], and focuses wherever the note lands.
  bool drop(String noteId, int target, PaneDropZone zone) {
    final plan = planDrop(noteId, target, zone);
    if (plan == null) return false;
    final source = paneOf(noteId);
    switch (plan.action) {
      case PaneDropAction.replace:
        _panes[target]._noteId = noteId;
        _active = target;
      case PaneDropAction.swap:
        _panes[source]._noteId = _panes[target].noteId;
        _panes[target]._noteId = noteId;
        _active = target;
      case PaneDropAction.insert:
        final index = plan.zone == PaneDropZone.left ? target : target + 1;
        _insert(index, noteId);
        _active = index;
      case PaneDropAction.move when plan.zone == PaneDropZone.center:
        _panes[target]._noteId = noteId;
        _active = target;
        _removeAt(source);
      case PaneDropAction.move:
        // A pane keeps its own width as it moves: only the order changes.
        final pane = _panes.removeAt(source);
        final weight = _weights.removeAt(source);
        final after = target > source ? target - 1 : target;
        final index = plan.zone == PaneDropZone.left ? after : after + 1;
        _panes.insert(index, pane);
        _weights.insert(index, weight);
        _active = index;
    }
    _persist();
    return true;
  }

  /// Takes notes that were archived or deleted off the screen. Their panes
  /// close, except the last one left, which shows [fallbackId] instead.
  ///
  /// A pane that was already empty is left alone: it is waiting for the
  /// reader to choose, and a note arriving in it unasked would be a surprise.
  bool reconcile(
    Iterable<String> availableNoteIds, {
    String? fallbackId,
    bool persist = true,
  }) {
    final available = availableNoteIds.toSet();
    final fallback = fallbackId != null && available.contains(fallbackId)
        ? fallbackId
        : available.firstOrNull;
    var changed = false;

    for (var index = _panes.length - 1; index >= 0; index--) {
      final id = _panes[index].noteId;
      if (id == null || available.contains(id)) continue;
      changed = true;
      if (_panes.length > 1) {
        _removeAt(index);
      } else {
        _panes[index]._noteId = null;
      }
    }

    if (_panes.isEmpty) {
      if (fallback != null) {
        _panes.add(_newPane(fallback));
        _weights
          ..clear()
          ..add(1);
        _active = 0;
        changed = true;
      }
    } else if (changed && _panes.length == 1 && _panes.single.noteId == null) {
      _panes.single._noteId = fallback;
    }

    if (changed && persist) _persist();
    return changed;
  }

  /// Sets each pane's share of the row, left to right. A divider sets this on
  /// every pixel it is dragged, so it is written to disk lazily.
  set weights(List<double> value) {
    if (value.length != _panes.length ||
        value.any((weight) => !weight.isFinite || weight <= 0)) {
      return;
    }
    final total = value.fold(0.0, (sum, weight) => sum + weight);
    var changed = false;
    for (var index = 0; index < value.length; index++) {
      final next = value[index] / total;
      if ((next - _weights[index]).abs() > 1e-9) changed = true;
      _weights[index] = next;
    }
    if (changed) _persist(immediate: false);
  }

  /// Gives every pane the same width.
  void equalizeWeights() {
    if (_panes.isEmpty) return;
    _share();
    _persist();
  }

  bool _show(String noteId) {
    if (_panes.isEmpty) {
      _panes.add(_newPane(noteId));
      _weights
        ..clear()
        ..add(1);
      _active = 0;
      return true;
    }
    final existing = paneOf(noteId);
    if (existing >= 0) {
      if (existing == _active) return false;
      _active = existing;
      return true;
    }
    _panes[_active]._noteId = noteId;
    return true;
  }

  EditorPane _newPane(String? noteId) => EditorPane._(_nextId++, noteId);

  /// Opens a pane at [index], and every pane shares the row evenly again.
  ///
  /// Not cut out of one neighbour: halving the pane beside it leaves three
  /// notes at a quarter, a quarter and a half, which is nobody's idea of side
  /// by side. A width the reader wants is one divider drag away.
  void _insert(int index, String? noteId) {
    _panes.insert(index, _newPane(noteId));
    _weights.insert(index, 0);
    _share();
  }

  /// Takes the pane at [index] away and shares the row evenly again. The focus,
  /// if the pane had it, goes to the pane on its left, or on its right for the
  /// first pane.
  void _removeAt(int index) {
    _panes.removeAt(index);
    _weights.removeAt(index);
    _share();
    if (_active == index) {
      _active = index > 0 ? index - 1 : 0;
    } else if (_active > index) {
      _active--;
    }
  }

  void _share() {
    for (var index = 0; index < _weights.length; index++) {
      _weights[index] = 1 / _weights.length;
    }
  }

  void _normalizeWeights() {
    final total = _weights.fold(0.0, (sum, weight) => sum + weight);
    for (var index = 0; index < _weights.length; index++) {
      _weights[index] = total > 0
          ? _weights[index] / total
          : 1 / _weights.length;
    }
  }

  void _persist({bool immediate = true}) {
    // An empty pane is a question put to the reader, and a restart is not the
    // moment to ask it again, so only panes holding a note are kept.
    final kept = [
      for (var index = 0; index < _panes.length; index++)
        if (_panes[index].noteId != null) index,
    ];
    final value = <String, Object?>{
      'panes': [for (final index in kept) _panes[index].noteId],
      'weights': [for (final index in kept) _weights[index]],
      'active': ?selectedNoteId,
    };
    if (immediate) {
      _store.putNow(storeKey, value);
    } else {
      // A divider can move hundreds of times in one drag. Match note and
      // caret writes by coalescing those pixels into one disk write.
      _store.put(storeKey, value);
    }
  }
}

/// A reversible preview over one stable [EditorWorkspace] arrangement.
///
/// Notes already present in the baseline merely activate their pane. Any note
/// that was not present temporarily replaces the pane that was active when the
/// session began. Moving back through the sequence restores the baseline first,
/// so previewing cannot accidentally walk replacements across several panes.
class EditorWorkspacePreviewSession {
  EditorWorkspacePreviewSession._(this._workspace)
    : _panes = List.of(_workspace._panes),
      _noteIds = [for (final pane in _workspace._panes) pane.noteId],
      _weights = List.of(_workspace._weights),
      _active = _workspace._active,
      _anchor = _workspace._panes.isEmpty ? null : _workspace._active;

  final EditorWorkspace _workspace;
  final List<EditorPane> _panes;
  final List<String?> _noteIds;
  final List<double> _weights;
  final int _active;
  final int? _anchor;
  bool _finished = false;

  bool get isActive => !_finished;

  /// Whether every note represented by the baseline and current preview still
  /// belongs to the active collection.
  bool canContinueWith(Iterable<String> noteIds) {
    if (_finished) return false;
    final available = noteIds.toSet();
    return _noteIds.whereType<String>().every(available.contains) &&
        _workspace.openNoteIds.every(available.contains);
  }

  /// The baseline note that [noteId] would temporarily displace, if any.
  String? displacedBy(String noteId) {
    if (_finished || _noteIds.contains(noteId)) return null;
    final anchor = _anchor;
    return anchor == null ? null : _noteIds[anchor];
  }

  /// Shows [noteId] relative to the frozen baseline without writing it yet.
  bool preview(String noteId) {
    if (_finished) return false;
    _restore();

    final existing = _noteIds.indexOf(noteId);
    if (existing >= 0) {
      _workspace._active = existing;
      return true;
    }

    final anchor = _anchor;
    if (anchor == null) {
      _workspace._show(noteId);
      return true;
    }
    _workspace._panes[anchor]._noteId = noteId;
    _workspace._active = anchor;
    return true;
  }

  /// Keeps the final preview and makes it the restorable workspace state.
  bool commit() {
    if (_finished) return false;
    _finished = true;
    _workspace._persist();
    return true;
  }

  /// Puts every pane back exactly where the session found it.
  bool cancel() {
    if (_finished) return false;
    _restore();
    _finished = true;
    _workspace._persist();
    return true;
  }

  void _restore() {
    _workspace._panes
      ..clear()
      ..addAll(_panes);
    for (var index = 0; index < _panes.length; index++) {
      _panes[index]._noteId = _noteIds[index];
    }
    _workspace._weights
      ..clear()
      ..addAll(_weights);
    _workspace._active = _panes.isEmpty ? 0 : _active;
  }
}
