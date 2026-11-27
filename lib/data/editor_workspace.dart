import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'note_days.dart' show dayKey, dayOfKey;
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

/// One tab: a note, up to [EditorWorkspace.maxPanes] of them side by side, or
/// a folder.
///
/// A tab of notes always holds a note. A pane may wait empty beside one, but
/// a tab whose last note leaves it closes. A folder fills its tab: the tab's
/// one pane stays empty, and nothing opens beside it.
class EditorTab {
  EditorTab._(this.id);

  /// Stable for as long as the tab is open, so the row can key it.
  final int id;

  final List<EditorPane> _panes = [];

  /// Each pane's share of the row, in the same order, summing to one.
  final List<double> _weights = [];
  int _active = 0;
  String? _folderId;

  List<EditorPane> get panes => List.unmodifiable(_panes);

  /// The notes in the tab, left to right.
  List<String> get noteIds => [for (final pane in _panes) ?pane.noteId];

  /// The note the tab goes by: the focused pane's, or while that pane waits
  /// for one, the first beside it. Null in a folder's tab.
  String? get noteId => _panes[_active].noteId ?? noteIds.firstOrNull;

  /// The folder the tab shows, or null in a tab of notes.
  String? get folderId => _folderId;

  int _paneOf(String noteId) =>
      _panes.indexWhere((pane) => pane.noteId == noteId);
}

/// A note or a folder, as Back's walk keeps them.
typedef _Place = ({String id, bool folder});

/// A closed tab: its notes left to right, or its folder, and its place on
/// the row, where it had one.
typedef _Closed = ({List<String> notes, String? folderId, int? at});

/// The tabs a day's notes took the place of: in the row's order, most
/// recently used first, and the one that was in front.
typedef _Kept = ({
  List<EditorTab> tabs,
  List<EditorTab> recent,
  EditorTab front,
});

/// The notes and folders open on the desktop: the tabs over the page, the
/// notes side by side in the tab in front, and how wide each of them is.
///
/// [open] shows a note in the tab in front, in place of the note there, and
/// [openInNewTab] opens one in a tab of its own behind it. [openFolder] and
/// [openFolderInNewTab] do the same with a folder. A note or a folder is open
/// in one place at most: opening one that is open already brings it forward
/// where it is. [showDay] opens a day's notes as the tabs, in place of the
/// ones open, and [leaveDay] brings those back.
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

  /// The most notes [showDay] opens as tabs. The row shows what fits and
  /// folds the rest into its "N more".
  static const int dayTabLimit = 12;

  final LocalStore _store;

  /// The tabs, in the order the row shows them.
  final List<EditorTab> _tabs = [];

  /// The same tabs, most recently used first: the order they keep their
  /// place on the row in, and the order a closed tab hands the front on in.
  final List<EditorTab> _recent = [];
  int _front = 0;

  /// The notes and folders shown, most recently first: what [back] walks.
  final List<_Place> _used = [];

  /// How far [back] has walked down [_used]. Anything else settles the walk,
  /// so it always starts from what is on screen.
  int _step = 0;

  /// Closed tabs, most recently closed first.
  final List<_Closed> _closed = [];

  /// The day the tabs belong to.
  int? _day;

  /// The day whose notes [showDay] opened as the tabs, and the tabs they took
  /// the place of, kept for [leaveDay].
  DateTime? _dayInTabs;
  _Kept? _kept;

  /// The notes [showDay] opened for [_dayInTabs]: a click on the day brings
  /// back a tab of only these, so it goes without counting as closed.
  Set<String> _dayNotes = const {};

  /// The blank note the day started on.
  String? _draft;
  int _nextId = 0;

  List<EditorTab> get tabs => List.unmodifiable(_tabs);

  /// The tabs, most recently used first.
  List<EditorTab> get recentTabs => List.unmodifiable(_recent);

  EditorTab? get frontTab => _tabs.isEmpty ? null : _tabs[_front];
  int get frontTabIndex => _front;

  /// Closed tabs of notes, most recently closed first, by the notes each one
  /// held. Closed folders aren't listed, though [reopen] brings them back too.
  @visibleForTesting
  List<List<String>> get recentlyClosed => [
    for (final tab in _closed)
      if (tab.folderId == null) List.unmodifiable(tab.notes),
  ];

  /// Whether [reopen] has a closed tab to bring back.
  bool get canReopen => _closed.isNotEmpty;

  /// The blank note the day started on, so a restart can still tell it from
  /// a note somebody emptied on purpose.
  String? get draft => _draft;
  set draft(String? value) {
    _draft = value;
    _persist();
  }

  bool get canGoBack => _step + 1 < _used.length;
  bool get canGoForward => _step > 0;

  /// The note [back] would show, or null where it shows a folder or nothing.
  String? get backNoteId => canGoBack ? _noteAt(_step + 1) : null;

  /// The note [forward] would show, or null where it shows a folder or
  /// nothing.
  String? get forwardNoteId => canGoForward ? _noteAt(_step - 1) : null;

  String? _noteAt(int index) => switch (_used[index]) {
    (:final id, folder: false) => id,
    _ => null,
  };

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

  /// The notes in the tabs a day's notes took the place of, for [leaveDay]
  /// to bring back.
  Set<String> get keptNoteIds => {
    for (final tab in _kept?.tabs ?? const <EditorTab>[]) ...tab.noteIds,
  };

  /// The day the tabs belong to.
  int? get day => _day;

  /// The day whose notes [showDay] opened as the tabs, until [leaveDay]. Null
  /// while the tabs are the reader's own.
  DateTime? get dayInTabs => _dayInTabs;

  /// The notes [showDay] opened for [dayInTabs], in the order it opened them.
  Iterable<String> get dayNoteIds => _dayNotes;

  /// Where [noteId] is on screen, or -1.
  int paneOf(String noteId) => frontTab?._paneOf(noteId) ?? -1;

  /// The tab [noteId] is open in, or -1.
  int tabOf(String noteId) =>
      _tabs.indexWhere((tab) => tab._paneOf(noteId) >= 0);

  /// The tab [folderId] is open in, or -1.
  int folderTabOf(String folderId) =>
      _tabs.indexWhere((tab) => tab._folderId == folderId);

  /// Whether another pane can open beside the focused one. Not beside an empty
  /// pane: a second blank next to the first is only another thing to close.
  bool get canSplit => paneCount < maxPanes && selectedNoteId != null;

  /// Starts a held-key walk through the recently used notes. See
  /// [EditorWorkspacePreviewSession].
  EditorWorkspacePreviewSession beginPreviewSession() =>
      EditorWorkspacePreviewSession._(this);

  /// Restores the tabs that still hold notes, and the folders' tabs, which
  /// [reconcileFolders] checks once the folders are read. Then it brings
  /// [openingNoteId] forward: in its tab where it has one, in a new tab in
  /// front where not.
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
    _dayInTabs = null;
    _dayNotes = const {};
    _kept = null;

    final raw = _store.data[storeKey];
    if (raw is Map) {
      final placed = <String>{};
      final placedFolders = <String>{};
      final saved = raw['tabs'];
      final restored = _readTabs(
        saved is List ? saved : [raw],
        available,
        placed: placed,
        placedFolders: placedFolders,
      );
      _tabs.addAll(restored.values);
      if (raw['tab'] case final int index when restored[index] != null) {
        _front = _tabs.indexOf(restored[index]!);
      }
      _recent.addAll(_recentOf(restored, raw['recent'], front: frontTab));
      if (raw['dayInTabs'] case final String key) _dayInTabs = dayOfKey(key);
      if (raw['dayNotes'] case final List ids when _dayInTabs != null) {
        _dayNotes = {...ids.whereType<String>()};
      }
      if (raw['kept'] case final Map kept
          when _dayInTabs != null && kept['tabs'] is List) {
        final read = _readTabs(
          kept['tabs'] as List,
          available,
          placed: <String>{},
          placedFolders: <String>{},
        );
        final front = switch (kept['tab']) {
          final int index => read[index],
          _ => null,
        };
        if (front ?? read.values.firstOrNull case final front?) {
          _kept = (
            tabs: [...read.values],
            recent: _recentOf(read, kept['recent'], front: front),
            front: front,
          );
        }
      }
      _used.addAll(
        <_Place>{
          if (frontTab?.folderId case final folderId?)
            (id: folderId, folder: true)
          else if (selectedNoteId case final id?)
            (id: id, folder: false),
          if (raw['used'] case final List used)
            for (final entry in used)
              if (entry is String && available.contains(entry))
                (id: entry, folder: false)
              else if (entry case {'folder': final String folderId})
                (id: folderId, folder: true),
        }.take(historyLimit),
      );
      if (raw['closed'] case final List closed) {
        final places = switch (raw['closedAt']) {
          final List places => places,
          _ => const [],
        };
        for (final (index, entry) in closed.indexed) {
          final at = switch (places.elementAtOrNull(index)) {
            final int at when at >= 0 => at,
            _ => null,
          };
          if (entry case {'folder': final String folderId}) {
            if (placedFolders.add(folderId)) {
              _closed.add((notes: [], folderId: folderId, at: at));
            }
          } else if (entry is List) {
            final kept = [
              for (final id in entry)
                if (id is String && available.contains(id) && placed.add(id))
                  id,
            ];
            if (kept.isNotEmpty) {
              _closed.add((notes: kept, folderId: null, at: at));
            }
          }
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

  /// The tabs [saved] holds, by their place in it, with only the notes still
  /// [available]. A note or a folder already in [placed] or [placedFolders]
  /// is left out, and each one taken is added there.
  Map<int, EditorTab> _readTabs(
    List<Object?> saved,
    Set<String> available, {
    required Set<String> placed,
    required Set<String> placedFolders,
  }) {
    final read = <int, EditorTab>{};
    for (final (index, entry) in saved.indexed) {
      if (entry case {'folder': final String folderId}) {
        if (placedFolders.add(folderId)) read[index] = _folderTab(folderId);
        continue;
      }
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
      read[index] = tab;
    }
    return read;
  }

  /// The tabs [read], most recently used first: [front], then as [order]
  /// lists their places, then any it leaves out in the row's order.
  static List<EditorTab> _recentOf(
    Map<int, EditorTab> read,
    Object? order, {
    required EditorTab? front,
  }) => [
    ...{
      ?front,
      if (order is List)
        for (final index in order) ?read[index],
      ...read.values,
    },
  ];

  /// The first open of [today], when the tabs belong to an earlier day: every
  /// tab closes for [reopen] to bring back, any that a day's notes took the
  /// place of ahead of the day's, each the most recently used first, Back's
  /// walk starts over, and the row is left empty for the caller to start the
  /// day in. Returns the notes that closed, or null on the day the tabs
  /// already belong to.
  List<String>? rollOver(int today) {
    if (_day == today) return null;
    _settle();
    final closing = [...?_kept?.recent, ..._recent];
    for (final tab in closing.reversed) {
      _remember(tab);
    }
    _tabs.clear();
    _recent.clear();
    _used.clear();
    _dayInTabs = null;
    _dayNotes = const {};
    _kept = null;
    _front = 0;
    _day = today;
    _persist();
    return [for (final tab in closing) ...tab.noteIds];
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
        _used.firstOrNull != (id: noteId, folder: false);
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

  /// Shows [folderId] in the tab in front, in place of what that tab shows,
  /// or brings it forward where it has a tab. Notes side by side keep their
  /// tab, and the folder opens in a new one in front of it. Returns whether
  /// anything moved.
  bool openFolder(String folderId) {
    _settle();
    final before = (frontTab, frontTab?.folderId);
    _showFolder(folderId);
    final moved =
        before != (frontTab, frontTab?.folderId) ||
        _used.firstOrNull != (id: folderId, folder: true);
    _use(folderId, folder: true);
    _persist();
    return moved;
  }

  /// Opens [folderId] in a new tab at the end of the row, behind the tab in
  /// front. False where it has a tab already.
  bool openFolderInNewTab(String folderId) {
    if (folderTabOf(folderId) >= 0) return false;
    _settle();
    if (_addTab(const [], front: false, folderId: folderId) == frontTab) {
      _use(folderId, folder: true);
    }
    _persist();
    return true;
  }

  /// Walks back to the note or folder shown before what is on screen: where
  /// it is open, or in front.
  bool back() {
    if (!canGoBack) return false;
    _step++;
    _showPlace(_used[_step]);
    _persist();
    return true;
  }

  /// Walks forward again, towards what was shown last.
  bool forward() {
    if (!canGoForward) return false;
    _step--;
    _showPlace(_used[_step]);
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

  /// Closes the tab at [index], for [reopen] to bring back. Where it was in
  /// front, the tab used before it takes its place.
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

  /// Opens the tab closed most recently again, in front and in its place on
  /// the row: its notes side by side as they were, or its folder. A note
  /// opened elsewhere since stays where it is. Returns whether a tab came
  /// back.
  bool reopen() {
    if (_closed.isEmpty) return false;
    _settle();
    final (:notes, :folderId, :at) = _closed.removeAt(0);
    final kept = [
      for (final id in notes)
        if (tabOf(id) < 0) id,
    ];
    final back = folderId != null || kept.isNotEmpty;
    if (back) {
      final tab = _addTab(kept, front: true, folderId: folderId);
      if (at != null && at < _front) {
        _tabs
          ..removeAt(_front)
          ..insert(at, tab);
        _front = at;
      }
      _useFront();
    }
    _persist();
    return back;
  }

  /// Opens [noteIds], [day]'s notes, as the tabs in their order, one note to
  /// a tab and the first in front, up to [dayTabLimit] of them. They take the
  /// place of the tabs open now. The tabs open before the first day was shown
  /// are kept for [leaveDay] to bring back. Another day's tabs go, for
  /// [reopen] to bring back those holding a note that day didn't open. With
  /// no notes the row is left empty for the caller to write on [day]. Returns
  /// how many tabs opened.
  int showDay(DateTime day, List<String> noteIds) {
    _settle();
    if (_dayInTabs != null) {
      _rememberDayTabs();
    } else if (frontTab case final front?) {
      _kept = (tabs: [..._tabs], recent: [..._recent], front: front);
    }
    _dayInTabs = day;
    _dayNotes = noteIds.toSet().take(dayTabLimit).toSet();
    _tabs.clear();
    _recent.clear();
    _front = 0;
    for (final id in _dayNotes) {
      _addTab([id], front: _tabs.isEmpty);
    }
    // The row folds the least recently used first, so the day's last notes
    // go into "N more" before its first.
    _recent
      ..clear()
      ..addAll(_tabs);
    _useFront();
    _persist();
    return _tabs.length;
  }

  /// Brings back the tabs [showDay] took the place of, as they were, the one
  /// in front included. The day's go, for [reopen] to bring back those
  /// holding a note the day didn't open. Where none of the tabs from before
  /// is left the day's stay. Returns whether a day was shown.
  bool leaveDay() {
    if (_dayInTabs == null) return false;
    _settle();
    final kept = _kept;
    _dayInTabs = null;
    _kept = null;
    if (kept != null && kept.tabs.isNotEmpty) {
      _rememberDayTabs();
      _tabs
        ..clear()
        ..addAll(kept.tabs);
      _recent
        ..clear()
        ..addAll(kept.recent);
      _front = _tabs.indexOf(
        _tabs.contains(kept.front) ? kept.front : _recent.first,
      );
      for (final tab in _tabs) {
        if (tab.folderId case final folderId?) _forgetClosedFolder(folderId);
        for (final id in tab.noteIds) {
          _forgetClosed(id);
        }
      }
      _useFront();
    }
    _dayNotes = const {};
    _persist();
    return true;
  }

  /// Puts the day's tabs in [order], the day's notes as it is now arranged,
  /// and any tab of a note it doesn't name after them, as they were. The tab
  /// in front stays in front. Returns whether a tab moved.
  bool arrangeDay(List<String> order) {
    if (_dayInTabs == null) return false;
    final place = {for (final (index, id) in order.indexed) id: index};
    final was = {for (final (index, tab) in _tabs.indexed) tab: index};
    int rank(EditorTab tab) => switch (tab.noteIds) {
      [final id] when tab.folderId == null => place[id] ?? order.length,
      _ => order.length,
    };
    final arranged = [..._tabs]
      ..sort(
        (a, b) => switch (rank(a).compareTo(rank(b))) {
          0 => was[a]!.compareTo(was[b]!),
          final by => by,
        },
      );
    if (listEquals(arranged, _tabs)) return false;
    final front = frontTab;
    _tabs
      ..clear()
      ..addAll(arranged);
    if (front != null) _front = _tabs.indexOf(front);
    _persist();
    return true;
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
  /// tab moves here. A folder fills its tab, so there the note opens in the
  /// folder's place.
  bool openToSide(String noteId) {
    final tab = frontTab;
    if (tab == null || tab.folderId != null) return open(noteId);
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
  /// ones a day's notes took the place of, the closed ones and Back's walk. A
  /// pane that held one closes beside other panes, and a tab left with no note
  /// closes. With no tab open at all, [fallbackId] opens, or else the first
  /// note there is: the page is never blank while there is a note to show.
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
    bool goneNote(_Place place) => !place.folder && gone(place.id);
    final leaving = tabbedNoteIds.where(gone).toList();
    var changed = leaving.isNotEmpty || _used.any(goneNote);
    _settle();
    _used.removeWhere(goneNote);
    for (final tab in _closed) {
      if (tab.notes.any(gone)) changed = true;
      tab.notes.removeWhere(gone);
    }
    _closed.removeWhere((tab) => tab.folderId == null && tab.notes.isEmpty);
    if (_draft case final draft? when gone(draft)) _draft = null;
    for (final id in leaving) {
      _detach(id);
    }
    if (_kept case final kept?) {
      for (final tab in [...kept.tabs]) {
        for (final id in tab.noteIds.where(gone)) {
          changed = true;
          if (tab.noteIds.length > 1) {
            _removeAt(tab, tab._paneOf(id));
          } else {
            kept.tabs.remove(tab);
            kept.recent.remove(tab);
          }
        }
      }
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

  /// Takes folders that were deleted out of the tabs, the ones a day's notes
  /// took the place of, the closed ones and Back's walk. A folder's tab
  /// closes without counting as closed. Returns whether anything changed.
  bool reconcileFolders(bool Function(String folderId) live) {
    bool gone(String? folderId) => folderId != null && !live(folderId);
    bool goneFolder(_Place place) => place.folder && gone(place.id);
    final leaving = [
      for (final tab in _tabs)
        if (gone(tab.folderId)) tab,
    ];
    final kept = _kept;
    final keptLeaving = [
      for (final tab in kept?.tabs ?? const <EditorTab>[])
        if (gone(tab.folderId)) tab,
    ];
    if (leaving.isEmpty &&
        keptLeaving.isEmpty &&
        !_closed.any((tab) => gone(tab.folderId)) &&
        !_used.any(goneFolder)) {
      return false;
    }
    _settle();
    for (final tab in leaving) {
      _removeTab(_tabs.indexOf(tab));
    }
    for (final tab in keptLeaving) {
      kept!.tabs.remove(tab);
      kept.recent.remove(tab);
    }
    _closed.removeWhere((tab) => gone(tab.folderId));
    _used.removeWhere(goneFolder);
    _persist();
    return true;
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
  /// front, in place of the note or folder there.
  void _show(String noteId) {
    if (_reveal(noteId)) return;
    final tab = frontTab;
    if (tab == null) {
      _addTab([noteId], front: true);
      return;
    }
    _forgetClosed(noteId);
    tab._folderId = null;
    tab._panes[tab._active]._noteId = noteId;
  }

  /// Puts [folderId] on screen: where it has a tab, or in the tab in front in
  /// place of what it shows. Notes side by side keep their tab, and the
  /// folder takes a new one in front.
  void _showFolder(String folderId) {
    final index = folderTabOf(folderId);
    final tab = frontTab;
    if (index >= 0) {
      _front = index;
    } else if (tab == null || tab._panes.length > 1) {
      _addTab(const [], front: true, folderId: folderId);
    } else {
      _forgetClosedFolder(folderId);
      tab._panes.single._noteId = null;
      tab._folderId = folderId;
    }
  }

  void _showPlace(_Place place) =>
      place.folder ? _showFolder(place.id) : _show(place.id);

  /// A new tab at the end of the row holding [noteIds] side by side, or with
  /// [folderId] that folder, in front or right behind the tab in front.
  EditorTab _addTab(
    List<String> noteIds, {
    required bool front,
    String? folderId,
  }) {
    final tab = folderId == null
        ? EditorTab._(_nextId++)
        : _folderTab(folderId);
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

  /// A tab showing [folderId] in its one pane. The folder is no longer among
  /// the closed ones.
  EditorTab _folderTab(String folderId) {
    _forgetClosedFolder(folderId);
    return EditorTab._(_nextId++)
      .._folderId = folderId
      .._panes.add(_newPane(null))
      .._weights.add(1);
  }

  /// Takes the tab at [index] off the row, and its notes or folder out of
  /// Back's walk. Where it was in front, the tab used before it takes its
  /// place.
  void _removeTab(int index) {
    final tab = _tabs.removeAt(index);
    final notes = tab.noteIds;
    _recent.remove(tab);
    _used.removeWhere(
      (place) =>
          place.folder ? place.id == tab.folderId : notes.contains(place.id),
    );
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

  /// Closes the day's tabs as they go, all but those of only notes the day
  /// opened, which a click on the day brings back.
  void _rememberDayTabs() {
    for (final tab in _recent.reversed) {
      if (tab.folderId != null || !_dayNotes.containsAll(tab.noteIds)) {
        _remember(tab);
      }
    }
  }

  void _remember(EditorTab tab) {
    final at = _tabs.indexOf(tab);
    _closed.insert(0, (
      notes: tab.noteIds,
      folderId: tab.folderId,
      at: at < 0 ? null : at,
    ));
    if (_closed.length > closedLimit) _closed.length = closedLimit;
  }

  /// A note open again is no longer among the closed ones.
  void _forgetClosed(String noteId) {
    for (final tab in _closed) {
      tab.notes.remove(noteId);
    }
    _closed.removeWhere((tab) => tab.folderId == null && tab.notes.isEmpty);
  }

  /// Nor is a folder.
  void _forgetClosedFolder(String folderId) =>
      _closed.removeWhere((tab) => tab.folderId == folderId);

  /// Counts [id], a note's or with [folder] a folder's, as shown last, and
  /// its tab as used last.
  void _use(String id, {bool folder = false}) {
    final place = (id: id, folder: folder);
    _used
      ..remove(place)
      ..insert(0, place);
    if (_used.length > historyLimit) _used.length = historyLimit;
    final index = folder ? folderTabOf(id) : tabOf(id);
    if (index < 0) return;
    _recent
      ..remove(_tabs[index])
      ..insert(0, _tabs[index]);
  }

  /// Counts the tab in front as used last, by its folder or its focused note
  /// where it has one.
  void _useFront() {
    final tab = frontTab;
    if (tab == null) return;
    if (tab.folderId case final id?) return _use(id, folder: true);
    if (tab._panes[tab._active].noteId case final id?) return _use(id);
    _recent
      ..remove(tab)
      ..insert(0, tab);
  }

  /// Ends a walk with Back where it stands: what it reached becomes what was
  /// shown last.
  void _settle() {
    if (_step == 0) return;
    final (:id, :folder) = _used[_step];
    _step = 0;
    _use(id, folder: folder);
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

  /// [tab] as the file keeps it: its folder, or its notes with their widths
  /// and the focused one. An empty pane is a question put to the reader, and
  /// a restart is not the moment to ask it again, so only panes holding a
  /// note are kept.
  static Map<String, Object?> _tabJson(EditorTab tab) => switch (tab.folderId) {
    final folderId? => {'folder': folderId},
    null => {
      'panes': tab.noteIds,
      'weights': [
        for (final (index, pane) in tab._panes.indexed)
          if (pane.noteId != null) tab._weights[index],
      ],
      'active': ?tab._panes[tab._active].noteId,
    },
  };

  void _persist({bool immediate = true}) {
    final kept = _kept;
    final value = <String, Object?>{
      'tabs': [for (final tab in _tabs) _tabJson(tab)],
      'tab': _front,
      'recent': [for (final tab in _recent) _tabs.indexOf(tab)],
      'used': [
        for (final (:id, :folder) in _used) folder ? {'folder': id} : id,
      ],
      'closed': [
        for (final (:notes, :folderId, at: _) in _closed)
          folderId == null ? List.of(notes) : {'folder': folderId},
      ],
      'closedAt': [for (final tab in _closed) tab.at],
      'day': ?_day,
      'draft': ?_draft,
      if (_dayInTabs case final day?) ...{
        'dayInTabs': dayKey(day),
        'dayNotes': [..._dayNotes],
      },
      if (kept != null)
        'kept': {
          'tabs': [for (final tab in kept.tabs) _tabJson(tab)],
          'tab': kept.tabs.indexOf(kept.front),
          'recent': [for (final tab in kept.recent) kept.tabs.indexOf(tab)],
        },
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
/// the pane that was focused when the walk began, in place of its note or
/// folder. Every step starts again from how the walk found the tabs, so a
/// walk never leaves notes behind in other panes, and cancelling puts it all
/// back.
class EditorWorkspacePreviewSession {
  EditorWorkspacePreviewSession._(this._workspace)
    : _start = _workspace.frontTab,
      _startNotes = [...?_workspace.frontTab?.noteIds],
      _startFolder = _workspace.frontTab?.folderId,
      _anchor = _workspace.activePane,
      _anchorNote = _workspace.selectedNoteId,
      _actives = {for (final tab in _workspace._tabs) tab: tab._active};

  final EditorWorkspace _workspace;

  /// The tab in front when the walk began, and its notes or folder then.
  final EditorTab? _start;
  final List<String> _startNotes;
  final String? _startFolder;

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
    if (!_workspace._reveal(noteId)) {
      start._folderId = null;
      start._panes[_anchor]._noteId = noteId;
    }
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
    start._folderId = _startFolder;
    for (final MapEntry(key: tab, value: active) in _actives.entries) {
      if (active < tab._panes.length) tab._active = active;
    }
    _workspace._front = _workspace._tabs.indexOf(start);
  }
}
