import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'writing_streak.dart';

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

/// One tab: a note, or up to [EditorWorkspace.maxPanes] of them side by side.
///
/// A tab always holds a note. A pane may wait empty beside one, but a tab
/// whose last note leaves it closes.
class EditorTab {
  EditorTab._(this.id);

  /// Stable for as long as the tab is open, so the row can key it.
  final int id;

  final List<EditorPane> _panes = [];

  /// Each pane's share of the row, in the same order, summing to one.
  final List<double> _weights = [];
  int _active = 0;

  List<EditorPane> get panes => List.unmodifiable(_panes);

  /// The notes in the tab, left to right.
  List<String> get noteIds => [for (final pane in _panes) ?pane.noteId];

  /// The note the tab goes by: the focused pane's, or while that pane waits
  /// for one, the first beside it.
  String get noteId => _panes[_active].noteId ?? noteIds.first;

  int _paneOf(String noteId) =>
      _panes.indexWhere((pane) => pane.noteId == noteId);
}

/// The notes open on the desktop: the tabs over the page, the notes side by
/// side in the tab in front, and how wide each of them is.
///
/// [open] shows a note in the tab in front, in place of the note there, and
/// [openInNewTab] opens one in a tab of its own behind it. A note is open in
/// one place at most: opening one that is open already brings it forward
/// where it is.
///
/// Tabs belong to this device and are never synced. They come back after a
/// restart on the same day, and [rollOver] closes them on the first open of a
/// new one. A day is a [WritingStreak.dayOf] number.
///
/// This owns only placement. Text, caret, undo and calculation stay inside the
/// ordinary [NoteEditor] each pane builds.
class EditorWorkspace {
  EditorWorkspace(this._store);

  static const String storeKey = 'editorWorkspace.v1';
  static const int maxPanes = 3;

  /// How many closed tabs [reopen] can bring back.
  static const int closedLimit = 20;

  /// How far back [back] reaches.
  static const int historyLimit = 50;

  final LocalStore _store;

  /// The tabs, in the order the row shows them.
  final List<EditorTab> _tabs = [];

  /// The same tabs, most recently used first: the order they keep their
  /// place on the row in, and the order a closed tab hands the front on in.
  final List<EditorTab> _recent = [];
  int _front = 0;

  /// The notes shown, most recently first: what [back] walks.
  final List<String> _used = [];

  /// How far [back] has walked down [_used]. Anything else settles the walk,
  /// so it always starts from the note on screen.
  int _step = 0;

  /// Closed tabs, most recently closed first, each as its notes left to right.
  final List<List<String>> _closed = [];

  /// The day the tabs belong to.
  int? _day;

  /// The blank note the day started on.
  String? _draft;
  int _nextId = 0;

  List<EditorTab> get tabs => List.unmodifiable(_tabs);

  /// The tabs, most recently used first.
  List<EditorTab> get recentTabs => List.unmodifiable(_recent);

  EditorTab? get frontTab => _tabs.isEmpty ? null : _tabs[_front];
  int get frontTabIndex => _front;

  /// Closed tabs, most recently closed first, by the notes each one held.
  List<List<String>> get recentlyClosed => [
    for (final notes in _closed) List.unmodifiable(notes),
  ];

  /// The blank note the day started on, so a restart can still tell it from
  /// a note somebody emptied on purpose.
  String? get draft => _draft;
  set draft(String? value) {
    _draft = value;
    _persist();
  }

  bool get canGoBack => _step + 1 < _used.length;
  bool get canGoForward => _step > 0;

  /// The note [back] would show, or null.
  String? get backNoteId => canGoBack ? _used[_step + 1] : null;

  /// The note [forward] would show, or null.
  String? get forwardNoteId => canGoForward ? _used[_step - 1] : null;

  /// The panes of the tab in front.
  List<EditorPane> get panes => List.unmodifiable(frontTab?._panes ?? const []);
  int get paneCount => frontTab?._panes.length ?? 0;
  int get activePane => frontTab?._active ?? 0;
  bool get isSplit => paneCount > 1;

  /// Each pane's share of the row, left to right.
  List<double> get weights =>
      List.unmodifiable(frontTab?._weights ?? const <double>[]);

  /// The note in the focused pane of the tab in front: what the toolbar, the
  /// list's highlight and every note-wide shortcut act on. Null while that
  /// pane is empty.
  String? get selectedNoteId => switch (frontTab) {
    final tab? => tab._panes[tab._active].noteId,
    null => null,
  };

  /// The notes on screen.
  Set<String> get openNoteIds => {...?frontTab?.noteIds};

  /// Every note with a tab, on screen or behind.
  Set<String> get tabbedNoteIds => {for (final tab in _tabs) ...tab.noteIds};

  /// The day the tabs belong to.
  int? get day => _day;

  /// Where [noteId] is on screen, or -1.
  int paneOf(String noteId) => frontTab?._paneOf(noteId) ?? -1;

  /// The tab [noteId] is open in, or -1.
  int tabOf(String noteId) =>
      _tabs.indexWhere((tab) => tab._paneOf(noteId) >= 0);

  /// Whether another pane can open beside the focused one. Not beside an empty
  /// pane: a second blank next to the first is only another thing to close.
  bool get canSplit => paneCount < maxPanes && selectedNoteId != null;

  /// Starts a held-key walk through the recently used notes. See
  /// [EditorWorkspacePreviewSession].
  EditorWorkspacePreviewSession beginPreviewSession() =>
      EditorWorkspacePreviewSession._(this);

  /// Restores the tabs that still hold notes, then brings [openingNoteId]
  /// forward: in its tab where it has one, in a new tab in front where not.
  ///
  /// A file written before there were tabs holds one tab's panes, and belongs
  /// to [today]. With nothing to restore, the first note opens.
  void load({
    required Iterable<String> availableNoteIds,
    required int today,
    String? openingNoteId,
  }) {
    final available = availableNoteIds.toSet();
    _tabs.clear();
    _recent.clear();
    _used.clear();
    _closed.clear();
    _front = 0;
    _step = 0;
    _day = today;
    _draft = null;

    final raw = _store.data[storeKey];
    if (raw is Map) {
      final placed = <String>{};
      final saved = raw['tabs'];
      final restored = <int, EditorTab>{};
      for (final (index, entry) in (saved is List ? saved : [raw]).indexed) {
        if (entry is! Map || entry['panes'] is! List) continue;
        final notes = entry['panes'] as List;
        final weights = entry['weights'];
        final tab = EditorTab._(_nextId++);
        for (final (at, id) in notes.indexed) {
          if (id is! String || !available.contains(id) || !placed.add(id)) {
            continue;
          }
          final weight = weights is List && at < weights.length
              ? weights[at]
              : null;
          tab._panes.add(_newPane(id));
          tab._weights.add(
            weight is num && weight.isFinite && weight > 0
                ? weight.toDouble()
                : 1,
          );
          if (tab._panes.length == maxPanes) break;
        }
        if (tab._panes.isEmpty) continue;
        _normalize(tab);
        if (entry['active'] case final String id when tab._paneOf(id) >= 0) {
          tab._active = tab._paneOf(id);
        }
        restored[index] = tab;
        _tabs.add(tab);
      }
      if (raw['tab'] case final int index when restored[index] != null) {
        _front = _tabs.indexOf(restored[index]!);
      }
      _recent.addAll({
        ?frontTab,
        if (raw['recent'] case final List order)
          for (final index in order) ?restored[index],
        ..._tabs,
      });
      _used.addAll(
        {
          ?selectedNoteId,
          if (raw['used'] case final List used)
            for (final id in used)
              if (id is String && available.contains(id)) id,
        }.take(historyLimit),
      );
      if (raw['closed'] case final List closed) {
        for (final notes in closed) {
          if (notes is! List) continue;
          final kept = [
            for (final id in notes)
              if (id is String && available.contains(id) && placed.add(id)) id,
          ];
          if (kept.isNotEmpty) _closed.add(kept);
          if (_closed.length == closedLimit) break;
        }
      }
      if (raw['day'] case final int day) _day = day;
      if (raw['draft'] case final String draft when available.contains(draft)) {
        _draft = draft;
      }
    }

    final opening = openingNoteId;
    if (opening != null && available.contains(opening)) {
      if (!_reveal(opening)) _addTab([opening], front: true);
      _use(opening);
    } else if (_tabs.isEmpty && available.isNotEmpty) {
      _addTab([available.first], front: true);
      _useFront();
    }
  }

  /// The first open of [today], when the tabs belong to an earlier day: every
  /// tab closes into [recentlyClosed], the most recently used first, Back's
  /// walk starts over, and the row is left empty for the caller to start the
  /// day in. Returns the notes that closed, or null on the day the tabs
  /// already belong to.
  List<String>? rollOver(int today) {
    if (_day == today) return null;
    _settle();
    final closing = [for (final tab in _recent) ...tab.noteIds];
    for (final tab in _recent.reversed) {
      _remember(tab);
    }
    _tabs.clear();
    _recent.clear();
    _used.clear();
    _front = 0;
    _day = today;
    _persist();
    return closing;
  }

  /// Shows [noteId] in the focused pane of the tab in front, in place of the
  /// note there, or brings it forward where it is open already. With no tab
  /// open, it opens one. Returns whether anything moved.
  bool open(String noteId) {
    _settle();
    final before = (frontTab, activePane, selectedNoteId);
    _show(noteId);
    final moved =
        before != (frontTab, activePane, selectedNoteId) ||
        _used.firstOrNull != noteId;
    _use(noteId);
    _persist();
    return moved;
  }

  /// Opens [noteId] in a new tab at the end of the row, behind the tab in
  /// front. False where it is open already.
  bool openInNewTab(String noteId) {
    if (tabOf(noteId) >= 0) return false;
    _settle();
    if (_addTab([noteId], front: false) == frontTab) _use(noteId);
    _persist();
    return true;
  }

  /// Walks back to the note shown before the one on screen: where it is
  /// open, or in the focused pane in front.
  bool back() {
    if (!canGoBack) return false;
    _step++;
    _show(_used[_step]);
    _persist();
    return true;
  }

  /// Walks forward again, towards the note shown last.
  bool forward() {
    if (!canGoForward) return false;
    _step--;
    _show(_used[_step]);
    _persist();
    return true;
  }

  /// Brings the tab at [index] to the front.
  bool activateTab(int index) {
    if (index < 0 || index >= _tabs.length) return false;
    _settle();
    final moved = index != _front;
    _front = index;
    _useFront();
    _persist();
    return moved;
  }

  /// Closes the tab at [index] into [recentlyClosed]. Where it was in front,
  /// the tab used before it takes its place.
  bool closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return false;
    _settle();
    _remember(_tabs[index]);
    _removeTab(index);
    _persist();
    return true;
  }

  /// Closes every tab but the one at [index], the least recently used first,
  /// so [reopen] brings back the most recent of them first.
  void closeOthers(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _settle();
    final kept = _tabs[index];
    for (final tab in _recent.reversed.toList()) {
      if (tab == kept) continue;
      _remember(tab);
      _removeTab(_tabs.indexOf(tab));
    }
    _front = 0;
    _useFront();
    _persist();
  }

  /// Opens the tab closed most recently, or the one at [index] in
  /// [recentlyClosed], in front, with its notes side by side as they were. A
  /// note opened elsewhere since stays where it is. Returns the note in front,
  /// or null where there was nothing to reopen.
  String? reopen([int index = 0]) {
    if (index < 0 || index >= _closed.length) return null;
    _settle();
    final notes = [
      for (final id in _closed.removeAt(index))
        if (tabOf(id) < 0) id,
    ];
    if (notes.isNotEmpty) {
      _addTab(notes, front: true);
      _useFront();
    }
    _persist();
    return notes.isEmpty ? null : selectedNoteId;
  }

  /// Opens an empty pane to the right of the focused one, and focuses it.
  bool split() {
    if (!canSplit) return false;
    _settle();
    final tab = frontTab!;
    _insert(tab, tab._active + 1, null);
    tab._active++;
    _persist();
    return true;
  }

  /// Puts [noteId] beside the focused note in the tab in front: into an empty
  /// pane if one is waiting, into a new pane while there is room for one, and
  /// into the neighbouring pane once three are open. A note open in another
  /// tab moves here.
  bool openToSide(String noteId) {
    final tab = frontTab;
    if (tab == null) return open(noteId);
    _settle();
    final existing = tab._paneOf(noteId);
    if (existing >= 0) {
      tab._active = existing;
    } else {
      _detach(noteId);
      _forgetClosed(noteId);
      final empty = tab._panes.indexWhere((pane) => pane.noteId == null);
      if (empty >= 0) {
        tab._panes[empty]._noteId = noteId;
        tab._active = empty;
      } else if (tab._panes.length < maxPanes) {
        _insert(tab, tab._active + 1, noteId);
        tab._active++;
      } else {
        tab._active = _neighbour(tab);
        tab._panes[tab._active]._noteId = noteId;
      }
    }
    _front = _tabs.indexOf(tab);
    _use(noteId);
    _persist();
    return true;
  }

  /// The note [openToSide] would take off the screen: only ever the
  /// neighbour's, once three full panes leave nowhere else for it to go.
  String? displacedByOpenToSide(String noteId) {
    final tab = frontTab;
    if (tab == null ||
        tab._paneOf(noteId) >= 0 ||
        tab._panes.length < maxPanes ||
        tab._panes.any((pane) => pane.noteId == null)) {
      return null;
    }
    return tab._panes[_neighbour(tab)].noteId;
  }

  /// The pane beside the focused one: on its right, or on its left for the
  /// last pane.
  int _neighbour(EditorTab tab) =>
      tab._active + 1 < tab._panes.length ? tab._active + 1 : tab._active - 1;

  bool activate(int index) {
    final tab = frontTab;
    if (tab == null ||
        index < 0 ||
        index >= tab._panes.length ||
        index == tab._active) {
      return false;
    }
    _settle();
    tab._active = index;
    _useFront();
    _persist();
    return true;
  }

  /// Closes the pane at [index] in the tab in front, and the panes left share
  /// the row evenly. Its note leaves the tab, and where it was the tab's last
  /// note the tab closes with it, as [closeTab] would.
  bool close(int index) {
    final tab = frontTab;
    if (tab == null ||
        tab._panes.length < 2 ||
        index < 0 ||
        index >= tab._panes.length) {
      return false;
    }
    _settle();
    if (tab._panes[index].noteId != null && tab.noteIds.length == 1) {
      _remember(tab);
      _removeTab(_front);
    } else {
      _removeAt(tab, index);
      _useFront();
    }
    _persist();
    return true;
  }

  /// What dropping [noteId] on [zone] of the pane at [target] would do, or
  /// null where it would leave every pane as it is.
  PaneDropPlan? planDrop(String noteId, int target, PaneDropZone zone) {
    final tab = frontTab;
    if (tab == null || target < 0 || target >= tab._panes.length) return null;
    final source = tab._paneOf(noteId);
    if (source == target) return null;

    if (zone != PaneDropZone.center) {
      if (source >= 0) {
        final beside = zone == PaneDropZone.left ? target - 1 : target + 1;
        if (source == beside) return null;
        return PaneDropPlan(PaneDropAction.move, zone);
      }
      if (tab._panes.length < maxPanes) {
        return PaneDropPlan(PaneDropAction.insert, zone);
      }
      // No room for a fourth pane, so the edges mean the pane itself.
    }

    if (source < 0) {
      return const PaneDropPlan(PaneDropAction.replace, PaneDropZone.center);
    }
    return tab._panes[target].noteId == null
        ? const PaneDropPlan(PaneDropAction.move, PaneDropZone.center)
        : const PaneDropPlan(PaneDropAction.swap, PaneDropZone.center);
  }

  /// Applies [planDrop], and focuses wherever the note lands. A note open in
  /// another tab moves here.
  bool drop(String noteId, int target, PaneDropZone zone) {
    final plan = planDrop(noteId, target, zone);
    if (plan == null) return false;
    _settle();
    final tab = frontTab!;
    if (tab._paneOf(noteId) < 0) {
      _detach(noteId);
      _forgetClosed(noteId);
    }
    final panes = tab._panes;
    final source = tab._paneOf(noteId);
    switch (plan.action) {
      case PaneDropAction.replace:
        panes[target]._noteId = noteId;
        tab._active = target;
      case PaneDropAction.swap:
        panes[source]._noteId = panes[target].noteId;
        panes[target]._noteId = noteId;
        tab._active = target;
      case PaneDropAction.insert:
        final index = plan.zone == PaneDropZone.left ? target : target + 1;
        _insert(tab, index, noteId);
        tab._active = index;
      case PaneDropAction.move when plan.zone == PaneDropZone.center:
        panes[target]._noteId = noteId;
        tab._active = target;
        _removeAt(tab, source);
      case PaneDropAction.move:
        // A pane keeps its own width as it moves: only the order changes.
        final pane = panes.removeAt(source);
        final weight = tab._weights.removeAt(source);
        final after = target > source ? target - 1 : target;
        final index = plan.zone == PaneDropZone.left ? after : after + 1;
        panes.insert(index, pane);
        tab._weights.insert(index, weight);
        tab._active = index;
    }
    _front = _tabs.indexOf(tab);
    _use(noteId);
    _persist();
    return true;
  }

  /// Takes notes that were archived, deleted or hidden out of the tabs, the
  /// closed ones and Back's walk. A pane that held one closes beside other
  /// panes, and a tab left with no note closes. With no tab open at all,
  /// [fallbackId] opens, or else the first note there is: the page is never
  /// blank while there is a note to show.
  ///
  /// A pane that was already empty is left alone: it is waiting for the
  /// reader to choose, and a note arriving in it unasked would be a surprise.
  bool reconcile(
    Iterable<String> availableNoteIds, {
    String? fallbackId,
    bool persist = true,
  }) {
    final available = availableNoteIds.toSet();
    bool gone(String id) => !available.contains(id);
    final leaving = tabbedNoteIds.where(gone).toList();
    var changed = leaving.isNotEmpty || _used.any(gone);
    _settle();
    _used.removeWhere(gone);
    for (final notes in _closed) {
      if (notes.any(gone)) changed = true;
      notes.removeWhere(gone);
    }
    _closed.removeWhere((notes) => notes.isEmpty);
    if (_draft case final draft? when gone(draft)) _draft = null;
    for (final id in leaving) {
      _detach(id);
    }
    final fallback = available.contains(fallbackId)
        ? fallbackId
        : available.firstOrNull;
    if (_tabs.isEmpty && fallback != null) {
      _addTab([fallback], front: true);
      _use(fallback);
      changed = true;
    }
    if (changed && persist) _persist();
    return changed;
  }

  /// Sets each pane's share of the row, left to right. A divider sets this on
  /// every pixel it is dragged, so it is written to disk lazily.
  set weights(List<double> value) {
    final tab = frontTab;
    if (tab == null ||
        value.length != tab._panes.length ||
        value.any((weight) => !weight.isFinite || weight <= 0)) {
      return;
    }
    final total = value.fold(0.0, (sum, weight) => sum + weight);
    var changed = false;
    for (var index = 0; index < value.length; index++) {
      final next = value[index] / total;
      if ((next - tab._weights[index]).abs() > 1e-9) changed = true;
      tab._weights[index] = next;
    }
    if (changed) _persist(immediate: false);
  }

  /// Gives every pane the same width.
  void equalizeWeights() {
    final tab = frontTab;
    if (tab == null) return;
    _share(tab);
    _persist();
  }

  /// Brings [noteId] forward where it is open: its tab to the front and its
  /// pane focused. False where it is open nowhere.
  bool _reveal(String noteId) {
    final index = tabOf(noteId);
    if (index < 0) return false;
    _front = index;
    _tabs[index]._active = _tabs[index]._paneOf(noteId);
    return true;
  }

  /// Puts [noteId] on screen: where it is open, or in the focused pane in
  /// front.
  void _show(String noteId) {
    if (_reveal(noteId)) return;
    final tab = frontTab;
    if (tab == null) {
      _addTab([noteId], front: true);
      return;
    }
    _forgetClosed(noteId);
    tab._panes[tab._active]._noteId = noteId;
  }

  /// A new tab at the end of the row holding [noteIds] side by side, in front
  /// or right behind the tab in front.
  EditorTab _addTab(List<String> noteIds, {required bool front}) {
    final tab = EditorTab._(_nextId++);
    for (final id in noteIds) {
      tab._panes.add(_newPane(id));
      tab._weights.add(1);
      _forgetClosed(id);
    }
    _share(tab);
    _tabs.add(tab);
    if (front || _tabs.length == 1) {
      _front = _tabs.length - 1;
      _recent.insert(0, tab);
    } else {
      _recent.insert(1, tab);
    }
    return tab;
  }

  /// Takes the tab at [index] off the row, and its notes out of Back's walk.
  /// Where it was in front, the tab used before it takes its place.
  void _removeTab(int index) {
    final tab = _tabs.removeAt(index);
    final notes = tab.noteIds;
    _recent.remove(tab);
    _used.removeWhere(notes.contains);
    if (notes.contains(_draft)) _draft = null;
    if (_tabs.isEmpty) {
      _front = 0;
    } else if (index == _front) {
      _front = _tabs.indexOf(_recent.first);
      _useFront();
    } else if (index < _front) {
      _front--;
    }
  }

  /// Takes [noteId] out of the tab it is open in. Its pane closes, and a tab
  /// left with no note closes, without counting as closed.
  void _detach(String noteId) {
    final index = tabOf(noteId);
    if (index < 0) return;
    final tab = _tabs[index];
    if (tab.noteIds.length > 1) {
      _removeAt(tab, tab._paneOf(noteId));
    } else {
      _removeTab(index);
    }
  }

  void _remember(EditorTab tab) {
    _closed.insert(0, tab.noteIds);
    if (_closed.length > closedLimit) _closed.length = closedLimit;
  }

  /// A note open again is no longer among the closed ones.
  void _forgetClosed(String noteId) {
    for (final notes in _closed) {
      notes.remove(noteId);
    }
    _closed.removeWhere((notes) => notes.isEmpty);
  }

  /// Counts [noteId] as shown last, and its tab as used last.
  void _use(String noteId) {
    _used
      ..remove(noteId)
      ..insert(0, noteId);
    if (_used.length > historyLimit) _used.length = historyLimit;
    final index = tabOf(noteId);
    if (index < 0) return;
    _recent
      ..remove(_tabs[index])
      ..insert(0, _tabs[index]);
  }

  /// Counts the tab in front as used last, by its focused note where it has
  /// one.
  void _useFront() {
    final tab = frontTab;
    if (tab == null) return;
    if (tab._panes[tab._active].noteId case final id?) return _use(id);
    _recent
      ..remove(tab)
      ..insert(0, tab);
  }

  /// Ends a walk with Back where it stands: the note it reached becomes the
  /// one shown last.
  void _settle() {
    if (_step == 0) return;
    final id = _used[_step];
    _step = 0;
    _use(id);
  }

  EditorPane _newPane(String? noteId) => EditorPane._(_nextId++, noteId);

  /// Opens a pane at [index], and every pane shares the row evenly again.
  ///
  /// Not cut out of one neighbour: halving the pane beside it leaves three
  /// notes at a quarter, a quarter and a half, which is nobody's idea of side
  /// by side. A width the reader wants is one divider drag away.
  void _insert(EditorTab tab, int index, String? noteId) {
    tab._panes.insert(index, _newPane(noteId));
    tab._weights.insert(index, 0);
    _share(tab);
  }

  /// Takes the pane at [index] away and shares the row evenly again. The focus,
  /// if the pane had it, goes to the pane on its left, or on its right for the
  /// first pane.
  void _removeAt(EditorTab tab, int index) {
    tab._panes.removeAt(index);
    tab._weights.removeAt(index);
    _share(tab);
    if (tab._active == index) {
      tab._active = index > 0 ? index - 1 : 0;
    } else if (tab._active > index) {
      tab._active--;
    }
  }

  void _share(EditorTab tab) {
    for (var index = 0; index < tab._weights.length; index++) {
      tab._weights[index] = 1 / tab._weights.length;
    }
  }

  void _normalize(EditorTab tab) {
    final weights = tab._weights;
    final total = weights.fold(0.0, (sum, weight) => sum + weight);
    for (var index = 0; index < weights.length; index++) {
      weights[index] = total > 0 ? weights[index] / total : 1 / weights.length;
    }
  }

  void _persist({bool immediate = true}) {
    // An empty pane is a question put to the reader, and a restart is not the
    // moment to ask it again, so only panes holding a note are kept.
    final value = <String, Object?>{
      'tabs': [
        for (final tab in _tabs)
          {
            'panes': tab.noteIds,
            'weights': [
              for (final (index, pane) in tab._panes.indexed)
                if (pane.noteId != null) tab._weights[index],
            ],
            'active': ?tab._panes[tab._active].noteId,
          },
      ],
      'tab': _front,
      'recent': [for (final tab in _recent) _tabs.indexOf(tab)],
      'used': List.of(_used),
      'closed': [for (final notes in _closed) List.of(notes)],
      'day': ?_day,
      'draft': ?_draft,
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

/// A held-key walk through the recently used notes. Each step shows another
/// note without counting it as shown, and only the note the walk ends on
/// counts. A note open in a tab comes forward there; any other note shows in
/// the pane that was focused when the walk began, in place of its note. Every
/// step starts again from how the walk found the tabs, so a walk never leaves
/// notes behind in other panes, and cancelling puts it all back.
class EditorWorkspacePreviewSession {
  EditorWorkspacePreviewSession._(this._workspace)
    : _start = _workspace.frontTab,
      _startNotes = [...?_workspace.frontTab?.noteIds],
      _anchor = _workspace.activePane,
      _anchorNote = _workspace.selectedNoteId,
      _actives = {for (final tab in _workspace._tabs) tab: tab._active};

  final EditorWorkspace _workspace;

  /// The tab in front when the walk began, and its notes then.
  final EditorTab? _start;
  final List<String> _startNotes;

  /// The pane a note with no tab shows in, and the note it held.
  final int _anchor;
  final String? _anchorNote;

  /// Each tab's focused pane when the walk began.
  final Map<EditorTab, int> _actives;
  bool _finished = false;

  bool get isActive => !_finished;

  /// Whether the notes the walk began with, and the notes on screen, still
  /// all belong to the collection being walked.
  bool canContinueWith(Iterable<String> noteIds) {
    if (_finished) return false;
    final available = noteIds.toSet();
    return _startNotes.every(available.contains) &&
        _workspace.openNoteIds.every(available.contains);
  }

  /// The notes on screen that a step to [noteId] would take off it.
  Set<String> displacedBy(String noteId) {
    if (_finished) return const {};
    return _workspace.openNoteIds.difference(_screenFor(noteId));
  }

  /// The notes a step to [noteId] leaves on screen.
  Set<String> _screenFor(String noteId) {
    if (_startNotes.contains(noteId)) return _startNotes.toSet();
    for (final tab in _workspace._tabs) {
      if (tab != _start && tab._paneOf(noteId) >= 0) return tab.noteIds.toSet();
    }
    return {
      for (final id in _startNotes)
        if (id != _anchorNote) id,
      noteId,
    };
  }

  /// Shows [noteId] without writing it down. False once the walk is over, or
  /// where the tab it began in has closed.
  bool preview(String noteId) {
    final start = _start;
    if (_finished || start == null || !_workspace._tabs.contains(start)) {
      return false;
    }
    _restore();
    if (!_workspace._reveal(noteId)) start._panes[_anchor]._noteId = noteId;
    return true;
  }

  /// Keeps the note the walk ended on, and counts it as shown.
  bool commit() {
    if (_finished) return false;
    _finished = true;
    if (_workspace.selectedNoteId case final id?) _workspace._forgetClosed(id);
    _workspace
      .._settle()
      .._useFront()
      .._persist();
    return true;
  }

  /// Puts every tab back as the walk found it.
  bool cancel() {
    if (_finished) return false;
    _finished = true;
    _restore();
    return true;
  }

  void _restore() {
    final start = _start;
    if (start == null || !_workspace._tabs.contains(start)) return;
    if (_anchor < start._panes.length) {
      start._panes[_anchor]._noteId = _anchorNote;
    }
    for (final MapEntry(key: tab, value: active) in _actives.entries) {
      if (active < tab._panes.length) tab._active = active;
    }
    _workspace._front = _workspace._tabs.indexOf(start);
  }
}
