import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../data/blob_store.dart';
import '../../data/note.dart';
import '../../data/task_board.dart';
import '../back_forward.dart';
import '../checklist_pie.dart';
import '../context_menu.dart';
import '../sidebar.dart' show PhoneFiltersButton, SidebarSearchField;
import '../note_day_scope.dart';
import '../notes_grouping.dart' show dayShown;
import '../page_turn.dart';
import '../sidebar_timestamp.dart';
import 'task_choice.dart';
import 'task_choice_cards.dart';
import 'task_details_sheet.dart';
import 'task_marks.dart';
import 'tasks_controller.dart';
import 'tasks_sidebar.dart'
    show TaskFilterChoice, taskFilterChoices, taskFilterMark;

/// Whether a task's note waits for a later day, by the page's days and the
/// clock the app shows times by ([displayTime], the device's own when null);
/// null where the page has no days. Today's list and every count of it leave
/// such a task out.
bool Function(TaskItem item)? taskWaitsToday(
  BuildContext context,
  TasksController tasks,
  DateTime Function(DateTime)? displayTime,
) {
  final days = NoteDayScope.maybeOf(context);
  if (days == null) return null;
  final today = dayShown(tasks.now(), displayTime ?? (time) => time.toLocal());
  return (item) => days.taskWaits(item.note.id, today);
}

/// The chord that finishes Do now, as its button prints it.
String? get doneShortcutLabel => !AppPlatform.hasPointer
    ? null
    : AppPlatform.isMacOS
    ? '⌘↵'
    : 'Ctrl+↵';

/// Tasks' page: Today, the one list worked with Mark Forster's Final Version
/// Perfected in plain words, or the Done view.
///
/// Today is the row that adds a task to the end of the list, then the pair
/// that chooses what to work on next, Do now, or the evening's close; then
/// Up next and the rest of the list in the order tasks were added. There are
/// no dates to plan by and no sort: the method needs the one fixed order.
/// The parts of Today a row can be held in for a visit.
enum _Part { upNext, rest, done }

class TasksScreen extends StatefulWidget {
  const TasksScreen({
    super.key,
    required this.controller,
    required this.filter,
    required this.addFocus,
    this.words,
    required this.labelOf,
    required this.onOpenNote,
    this.onOpenTask,
    required this.onOpenDone,
    this.images,
    this.displayTime,
    this.newTaskShortcut,
    this.phone = false,
    this.sheet = false,
    this.scrollController,
    this.onFilter,
    this.toolbar,
    this.explainPair = true,
  });

  /// A window's page bar over the list. A task's details stand beside the
  /// two, the full height of the page, as D09 has them.
  final Widget? toolbar;

  /// Narrows a phone's Tasks to Today, Done or one note, from the filter
  /// beside its search. Null leaves the filter out.
  final ValueChanged<TaskFilter>? onFilter;

  /// A phone's Tasks: stacked cards you tap, no keys, and rows that check
  /// off in place and stay until the screen is left.
  final bool phone;

  /// The phone's Tasks inside the sheet over a note (M15): the same body
  /// under the sheet's own title, without the add row.
  final bool sheet;

  /// The sheet's scroll, so dragging the list drags the sheet.
  final ScrollController? scrollController;

  final TasksController controller;
  final TaskFilter filter;
  final FocusNode addFocus;

  /// The add row's words, kept by whoever outlives this page so a half-typed
  /// task is still there when it opens again.
  final TextEditingController? words;

  /// A note's name as a task's mark shows it.
  final String Function(Note note) labelOf;
  final ValueChanged<String> onOpenNote;

  /// Opens a task's note at the task's line, from a phone's task page.
  /// Without it the page opens the note as [onOpenNote] does.
  final ValueChanged<TaskItem>? onOpenTask;

  /// Opens the Done view, from the evening's "N finished today".
  final VoidCallback onOpenDone;

  /// Where a task's picture is stored, so Do now and the sheet can show it.
  /// Null in a test that does not draw pictures.
  final BlobStore? images;

  /// The clock the app shows times by, so a note's day comes when the list
  /// says it does; the device's own when left out.
  final DateTime Function(DateTime)? displayTime;

  /// Printed on the add row at rest.
  final String? newTaskShortcut;

  /// Whether a round's first pair says in a line how choosing works: on a
  /// desktop until How Tasks works is put away, and always on a phone, which
  /// has no such card.
  final bool explainPair;

  @override
  State<TasksScreen> createState() => TasksScreenState();
}

class TasksScreenState extends State<TasksScreen> with WidgetsBindingObserver {
  late final _words = widget.words ?? TextEditingController();

  /// A phone's search over the page: the rows, the pair and Do now keep
  /// only the tasks whose words or note name hold every word typed.
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'tasks-search');

  /// Rows ticked or unticked on this visit, by the part of the list they sat
  /// in and their place there, so nothing moves under the pointer until the
  /// visit ends.
  final Map<String, (_Part, int)> _held = {};

  /// The day this visit opened on. Today shows that day's done tasks until
  /// the visit ends, even past midnight.
  late DateTime _visitDay = _dayOf(_tasks.now());

  /// The note the add row writes into, once chosen in its picker; until then
  /// the sidebar's filter decides.
  String? _target;
  bool _targetChosen = false;

  String? _washId;
  String? _sheetId;
  int _sheetIndex = 0;
  final _listFocus = FocusNode(debugLabel: 'tasks-list');
  final _washKey = GlobalKey();
  final _composerKey = GlobalKey();

  /// A phone's add field rose with the keyboard, so the keyboard going away
  /// puts the field away too.
  bool _composerRose = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.addFocus.addListener(_focusChanged);
    widget.controller.sheetRequest.addListener(_takeSheetRequest);
    _search.addListener(_focusChanged);
    // An ask made before this screen existed — a menu bar click while the app
    // was showing Notes — is waiting for its first listener.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _takeSheetRequest();
      // Once the frame's own focus moves have landed (the page it replaced
      // letting go, New task's add row), the pair's keys work at once.
      if (!widget.phone) scheduleMicrotask(_takeKeys);
    });
  }

  /// Takes the keyboard for the page, unless a field is being typed in.
  void _takeKeys() {
    if (!mounted) return;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return;
    }
    _listFocus.requestFocus();
  }

  void _takeSheetRequest() {
    final request = widget.controller.sheetRequest.value;
    if (request == null || !mounted) return;
    widget.controller.sheetRequest.value = null;
    setState(() => _sheetId = request.id);
  }

  @override
  void didUpdateWidget(TasksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.addFocus != widget.addFocus) {
      oldWidget.addFocus.removeListener(_focusChanged);
      widget.addFocus.addListener(_focusChanged);
    }
    if (oldWidget.filter != widget.filter) {
      _tasks.forgetPair();
      _targetChosen = false;
      _endVisit();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden) setState(_endVisit);
  }

  /// The Scaffold keeps the keyboard out of this page's insets, so a phone's
  /// add field reads them from the view, and rebuilds as they change.
  @override
  void didChangeMetrics() {
    if (widget.phone && widget.addFocus.hasFocus) setState(() {});
  }

  /// A visit ends when the app goes to the background or Today leaves for
  /// another view: the rows held in place settle, and the day starts over.
  void _endVisit() {
    _held.clear();
    _visitDay = _dayOf(_tasks.now());
  }

  static DateTime _dayOf(DateTime at) => DateTime(at.year, at.month, at.day);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.sheetRequest.removeListener(_takeSheetRequest);
    _listFocus.dispose();
    widget.addFocus.removeListener(_focusChanged);
    if (widget.words == null) _words.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() {});

  TasksController get _tasks => widget.controller;
  String? get _noteId => widget.filter.noteId;

  List<TaskItem> _open(TaskBoard board) => _tasks.openIn(_noteId);

  /// The tasks whose note waits for a later day, which Later counts.
  List<TaskItem> _waiting(TaskBoard board) {
    final today = {for (final item in _open(board)) item.id};
    return [
      for (final item in board.openIn(_noteId))
        if (!today.contains(item.id)) item,
    ];
  }

  /// What was typed in a phone's search, as it was typed.
  String get _query => _search.text.trim();

  /// Whether [item]'s words or its note's name hold every word of the
  /// search; true while nothing is typed.
  bool _matches(TaskBoard board, TaskItem item) {
    final query = _query.toLowerCase();
    if (query.isEmpty) return true;
    final words = '${item.words} ${_labelOf(board, item) ?? ''}'.toLowerCase();
    return query.split(RegExp(r'\s+')).every(words.contains);
  }

  /// A phone's filter: Today, Done and each note, in a menu under its
  /// button, with the one showing ticked.
  Future<void> _openFilters(BuildContext button, TaskBoard board) async {
    final onFilter = widget.onFilter;
    final box = button.findRenderObject()! as RenderBox;
    final choices = taskFilterChoices(
      board: board,
      today: _tasks.openIn(null),
      labelOf: widget.labelOf,
    );
    final picked = await showKapyContextMenu<TaskFilter>(
      context: context,
      useRootNavigator: true,
      globalPosition: box.localToGlobal(box.size.bottomLeft(Offset.zero)),
      requestFocus: false,
      items: [
        for (final (index, choice) in choices.indexed) ...[
          if (index == 2) const PopupMenuDivider(height: 9),
          PopupMenuItem(
            key: ValueKey('tasks-filter-menu-${choice.key}'),
            value: choice.filter,
            height: 44,
            child: _FilterMenuRow(
              choice: choice,
              selected: choice.filter == widget.filter,
            ),
          ),
        ],
      ],
    );
    if (picked != null) onFilter?.call(picked);
  }

  TaskChoice get _choice => _tasks.choiceIn(_noteId);

  /// Choose again: every choice cleared, from the first pair.
  void chooseAgain() => _tasks.chooseAgain(noteId: _noteId);

  /// Done on Do now, from its button or ⌘↵.
  void completeDoNow() {
    if (widget.filter.done) return;
    if (_choice.stage case DoNowStage(
      :final item,
    ) when _tasks.canEdit(item.note)) {
      unawaited(_tasks.finish(item, noteId: _noteId));
    }
  }

  PairStage? get _pair => widget.filter.done
      ? null
      : switch (_choice.stage) {
          final PairStage pair => pair,
          _ => null,
        };

  /// ←: your choice so far stays. False when no pair is showing.
  bool keepChoice() {
    final pair = _pair;
    if (pair == null) return false;
    _tasks.keepChoice(pair);
    return true;
  }

  /// →: the next task becomes your choice so far.
  bool takeNext() {
    final pair = _pair;
    if (pair == null) return false;
    _tasks.takeNext(pair);
    return true;
  }

  /// ↵ or esc: stop choosing and start your pick so far, while Stop choosing
  /// shows.
  bool startEarly() {
    final pair = _pair;
    if (pair == null) return false;
    _tasks.startWith(pair.left);
    return true;
  }

  String? get _addInto => _targetChosen ? _target : _noteId;

  Note? get _addTarget {
    final id = _addInto;
    return id == null ? null : _tasks.notes.byId(id);
  }

  Future<void> _add() async {
    final words = _words.text;
    if (words.trim().isEmpty) return;
    _words.clear();
    final id = await _tasks.add(words, noteId: _addInto);
    if (!mounted) return;
    setState(() => _washId = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _washKey.currentContext;
      if (!mounted || row == null || _inSight(row)) return;
      Toast.show(context, 'Added to the end of the list');
    });
  }

  /// Whether a row shows whole on screen, above the keyboard and a phone's
  /// add field, so its wash alone says where a new task went.
  bool _inSight(BuildContext row) {
    final box = row.findRenderObject() as RenderBox?;
    final view = Scrollable.maybeOf(row)?.context.findRenderObject();
    if (box == null || view is! RenderBox) return true;
    final screen = MediaQueryData.fromView(View.of(row));
    final top = box.localToGlobal(Offset.zero).dy;
    final viewTop = view.localToGlobal(Offset.zero).dy;
    final fold = math.min(
      viewTop + view.size.height,
      screen.size.height - screen.viewInsets.bottom,
    );
    final cover = _composerKey.currentContext?.size?.height ?? 0;
    return top >= viewTop && top + box.size.height <= fold - cover;
  }

  Future<void> _remove(TaskItem item) async {
    final label = widget.labelOf(item.note);
    // A note shared to view only keeps the line: the task only leaves this
    // person's list.
    final mine = _tasks.canEdit(item.note);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          mine ? 'Remove this task?' : 'Remove this task from your list?',
        ),
        content: Text(
          mine
              ? 'Its line comes out of “$label”. You can undo this.'
              : 'It stays in “$label” for you and everyone it’s shared with. '
                    'You can undo this.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final undo = await _tasks.remove(item);
    if (undo == null) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(mine ? 'Task removed' : 'Removed from your list'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(undo()),
        ),
      ),
    );
  }

  /// What a row's menu, its ⋮, a right-click or a long press, offers.
  List<TaskMenuChoice?> _menuFor(TaskItem item, {required bool upNext}) => [
    TaskMenuChoice('Do now', () => _tasks.makeDoNow(item)),
    if (upNext)
      TaskMenuChoice('Take out of Up next', () => _tasks.takeOutOfUpNext(item))
    else
      TaskMenuChoice('Add to Up next', () => _tasks.dot(item)),
    TaskMenuChoice('Move to the end', () => _tasks.moveToEnd(item)),
    null,
    if (!widget.phone) TaskMenuChoice('Details', () => _openSheet(item)),
    TaskMenuChoice(
      'Open “${widget.labelOf(item.note)}”',
      () => widget.onOpenNote(item.note.id),
    ),
    null,
    TaskMenuChoice('Remove…', () => unawaited(_remove(item))),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      _tasks.waits = taskWaitsToday(context, _tasks, widget.displayTime);
      final board = _tasks.read();
      final onFilter = widget.onFilter;
      // A phone's search sits over the page and scrolls away with it.
      final search = !widget.phone || widget.sheet
          ? null
          : SidebarSearchField(
              phone: true,
              placeholder: 'Search tasks',
              query: _query,
              onClear: _search.clear,
              onSearch: _searchFocus.requestFocus,
              field: TextField(
                key: const ValueKey('tasks-search-field'),
                controller: _search,
                focusNode: _searchFocus,
                textInputAction: TextInputAction.search,
                onTapOutside: (_) => _searchFocus.unfocus(),
                style: TextStyle(
                  fontSize: 16,
                  color: context.palette.textPrimary,
                ),
                decoration: InputDecoration.collapsed(
                  hintText: 'Search tasks',
                  hintStyle: TextStyle(
                    fontSize: 16,
                    color: context.palette.textTertiary,
                  ),
                ),
              ),
              trailing: onFilter == null
                  ? null
                  : Builder(
                      builder: (button) => PhoneFiltersButton(
                        key: const ValueKey('tasks-filters'),
                        tooltip: 'Filter tasks',
                        active: widget.filter != const TaskFilter.all(),
                        onPressed: () => unawaited(_openFilters(button, board)),
                      ),
                    ),
            );
      final page = LayoutBuilder(
        builder: (context, constraints) {
          final phone = widget.phone;
          final width = math.max(
            0.0,
            phone
                ? constraints.maxWidth - 42
                : math.min(680.0, constraints.maxWidth - 48),
          );
          return SingleChildScrollView(
            controller: widget.scrollController,
            padding: EdgeInsets.only(
              top: phone ? 0 : 20,
              bottom: phone ? 120 : 48,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?search,
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: (constraints.maxWidth - width) / 2,
                    ),
                    child: SizedBox(
                      width: width,
                      child: BackForwardSlide(
                        child: widget.filter.done
                            ? _done(board)
                            : Focus(
                                focusNode: _listFocus,
                                onKeyEvent: _listKey,
                                child: _today(board),
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
      final details = _detailsOf(board);
      final addable = switch (_addTarget) {
        final target? => _tasks.canEdit(target),
        null => true,
      };
      if (widget.phone && !widget.sheet && !widget.filter.done && addable) {
        return Stack(
          fit: StackFit.passthrough,
          children: [
            page,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _composer(context, board),
            ),
          ],
        );
      }
      if (widget.phone || (widget.toolbar == null && details == null)) {
        return page;
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?widget.toolbar,
                Expanded(child: page),
              ],
            ),
          ),
          if (details != null)
            SizedBox(
              width: 300,
              child: TaskDetailsSheet(
                key: ValueKey(details.id),
                item: details,
                tasks: _tasks,
                onClose: () => setState(() => _sheetId = null),
                onOpenNote: () => widget.onOpenNote(details.note.id),
                images: widget.images,
              ),
            ),
        ],
      );
    },
  );

  void _openSheet(TaskItem item) {
    if (widget.phone) {
      unawaited(_openPhonePage(item));
      return;
    }
    setState(() {
      _sheetId = item.id;
      _sheetIndex = _open(_tasks.read()).indexWhere((row) => row.id == item.id);
    });
    _listFocus.requestFocus();
  }

  /// A phone's task page (M14), pushed over the list on the navigator that
  /// holds Tasks, so the bar stays. It follows the task as it is edited, so
  /// what it shows is what the note now says, and goes back to the list,
  /// as it was left, once the task leaves its note.
  Future<void> _openPhonePage(TaskItem item) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => ListenableBuilder(
        listenable: _tasks,
        builder: (context, _) {
          final board = _tasks.read();
          TaskItem? shown;
          for (final candidate in [...board.open, ...board.done]) {
            if (candidate.id == item.id) shown = candidate;
          }
          final current = shown;
          if (current == null) {
            final route = ModalRoute.of(context);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted && (route?.isCurrent ?? false)) {
                Navigator.of(context).pop();
              }
            });
            return const SizedBox.shrink();
          }
          // A drag right goes back to the list, as the page's arrow does.
          return PageTurn(
            onBack: () => unawaited(Navigator.of(context).maybePop()),
            child: PhoneTaskPage(
              item: current,
              tasks: _tasks,
              label: widget.labelOf(current.note),
              images: widget.images,
              onBack: () => Navigator.of(context).pop(),
              onOpenNote: () {
                Navigator.of(context).pop();
                final open = widget.onOpenTask;
                open == null
                    ? widget.onOpenNote(current.note.id)
                    : open(current);
              },
            ),
          );
        },
      ),
    ),
  );

  KeyEventResult _listKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _sheetId == null) {
      return KeyEventResult.ignored;
    }
    if (!_listFocus.hasFocus) return KeyEventResult.ignored;
    final open = _open(_tasks.read());
    if (open.isEmpty) return KeyEventResult.ignored;
    // Where the sheet's task sits now: after Space marks it done it leaves the
    // open list, and the arrows go on from where it was.
    final shown = open.indexWhere((row) => row.id == _sheetId);
    final index = shown >= 0 ? shown : _sheetIndex.clamp(0, open.length - 1);
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _sheetId = null);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final next = event.logicalKey == LogicalKeyboardKey.arrowDown
          ? (index + 1).clamp(0, open.length - 1)
          : (index - 1).clamp(0, open.length - 1);
      setState(() {
        _sheetIndex = next;
        _sheetId = open[next].id;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (!_tasks.canEdit(open[index].note)) return KeyEventResult.handled;
      unawaited(_tasks.setDone(open[index], done: !open[index].line.done));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The task whose details are open beside the list, while it is still on
  /// the board.
  TaskItem? _detailsOf(TaskBoard board) {
    final id = _sheetId;
    if (id == null || !EditorMetrics.page) return null;
    for (final candidate in [...board.open, ...board.done]) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  String? _labelOf(TaskBoard board, TaskItem item) =>
      board.isHome(item) ? null : widget.labelOf(item.note);

  /// A task's row. A row in [part] of Today holds its place once ticked or
  /// unticked, so nothing moves under the pointer; an evening card's rows
  /// pass no part.
  Widget _row(TaskBoard board, TaskItem item, {_Part? part, int index = 0}) {
    final done = item.line.done;
    final onTick = _tasks.canEdit(item.note)
        ? () => _tick(item, part, index)
        : null;
    final menu = done
        ? const <TaskMenuChoice?>[]
        : _menuFor(item, upNext: part == _Part.upNext);
    final key = item.id == _washId ? _washKey : ValueKey(item.id);
    if (widget.phone) {
      return _PhoneTaskRow(
        key: key,
        item: item,
        done: done,
        now: _tasks.now(),
        label: _labelOf(board, item),
        wash: item.id == _washId,
        menu: menu,
        onTick: onTick,
        onOpen: () => _openSheet(item),
        onKeep: () => _tasks.keep(item),
        onRemove: () => unawaited(_remove(item)),
      );
    }
    return _TaskRow(
      key: key,
      item: item,
      done: done,
      now: _tasks.now(),
      label: _labelOf(board, item),
      wash: item.id == _washId,
      menu: menu,
      onTick: onTick,
      onOpenNote: () => widget.onOpenNote(item.note.id),
      onOpen: () => _openSheet(item),
      onKeep: () => _tasks.keep(item),
      onRemove: () => unawaited(_remove(item)),
    );
  }

  Widget _today(TaskBoard board) {
    final ink = TaskInk.of(context);
    final phone = widget.phone;
    final now = _tasks.now();
    final open = _open(board);
    final finished = [
      for (final item in board.done)
        if ((_noteId == null || item.note.id == _noteId) &&
            !item.doneAt!.isBefore(_visitDay))
          item,
    ]..sort((a, b) => a.doneAt!.compareTo(b.doneAt!));
    final choice = _choice;
    final stage = choice.stage;
    String? labelOf(TaskItem item) => _labelOf(board, item);
    bool matches(TaskItem item) => _matches(board, item);
    final searching = _query.isNotEmpty;
    final onStage = <String>{
      ...switch (stage) {
        PairStage(:final left, :final right) => [left.id, right.id],
        DoNowStage(:final item) => [item.id],
        EveningStage(:final left) => [for (final item in left) item.id],
        EmptyStage() => const <String>[],
      },
    };
    List<(int, TaskItem)> shown(Iterable<TaskItem> live, _Part part) => [
      for (final (index, item) in _place(board, live, part, onStage).indexed)
        if (matches(item)) (index, item),
    ];
    final upNext = shown(choice.upNext, _Part.upNext);
    final rest = shown(choice.rest, _Part.rest);
    final done = shown(finished, _Part.done);
    final waiting = _waiting(board).where(matches).toList();
    final staged = switch (stage) {
      PairStage(:final left, :final right) => matches(left) || matches(right),
      DoNowStage(:final item) => matches(item),
      EveningStage(:final left) => left.any(matches),
      EmptyStage() => true,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (phone)
          _PhoneTodayTitle(
            now: now,
            done: finished.length,
            total: finished.length + open.length,
            sheet: widget.sheet,
          ),
        if (!widget.sheet) ...[
          if (_addTarget case final target? when !_tasks.canEdit(target))
            Padding(
              key: const ValueKey('tasks-add-view-only'),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Text(
                'You can view this note, not change it.',
                style: taskText(13, 18, ink.quiet),
              ),
            )
          else if (!phone)
            _addRow(board),
        ],
        const SizedBox(height: 14),
        if (searching &&
            !staged &&
            upNext.isEmpty &&
            rest.isEmpty &&
            done.isEmpty &&
            waiting.isEmpty)
          _noMatch(ink),
        if (staged)
          switch (stage) {
            EmptyStage() => Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Text(
                done.isNotEmpty
                    ? 'Nothing left to do today.'
                    : phone && !widget.sheet
                    ? 'Nothing on the list. Tap + to add a task.'
                    : 'Nothing on the list.',
                key: const ValueKey('tasks-empty'),
                style: handAccent(context.palette),
              ),
            ),
            PairStage() => TaskPairCard(
              pair: stage,
              now: now,
              labelOf: labelOf,
              justDone: _tasks.justDone,
              explain: widget.explainPair,
              phone: phone,
              onKeep: () => _tasks.keepChoice(stage),
              onTake: () => _tasks.takeNext(stage),
              onStart: () => _tasks.startWith(stage.left),
            ),
            DoNowStage(:final item) => TaskDoNowCard(
              item: item,
              label: labelOf(item),
              images: widget.images,
              phone: phone,
              doneShortcut: doneShortcutLabel,
              onOpen: () => _openSheet(item),
              onNotFinished: () => _tasks.notFinished(item, noteId: _noteId),
              onDone: _tasks.canEdit(item.note)
                  ? () => unawaited(_tasks.finish(item, noteId: _noteId))
                  : null,
            ),
            EveningStage(:final left) => TaskEveningCard(
              finished: finished.length,
              phone: phone,
              onKeepGoing: _tasks.keepGoing,
              left: [
                for (final item in left)
                  if (matches(item)) _row(board, item),
              ],
            ),
          },
        if (stage is EveningStage && finished.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TaskFinishedLine(
              count: finished.length,
              onPressed: widget.onOpenDone,
            ),
          ),
        if (upNext.isNotEmpty) ...[
          _Heading('Up next', phone: phone),
          for (final (index, item) in upNext)
            _row(board, item, part: _Part.upNext, index: index),
        ],
        if (rest.isNotEmpty || done.isNotEmpty)
          Container(
            margin: EdgeInsets.only(
              top: upNext.isEmpty ? (phone ? 12 : 12) : (phone ? 4 : 0),
            ),
            padding: EdgeInsets.only(top: upNext.isEmpty ? 0 : 8),
            decoration: BoxDecoration(
              border: upNext.isEmpty
                  ? null
                  : Border(top: BorderSide(color: ink.hairline)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, item) in rest)
                  _row(board, item, part: _Part.rest, index: index),
                for (final (index, item) in done)
                  _row(board, item, part: _Part.done, index: index),
              ],
            ),
          ),
        if (waiting.isNotEmpty) ...[
          _Heading('Later', phone: phone),
          _LaterRow(
            waiting: waiting,
            phone: phone,
            onOpenNote: widget.onOpenNote,
          ),
        ],
      ],
    );
  }

  /// [live]'s rows for [part] of Today, with the rows held on this visit back
  /// in the places they held, as they are now. A held task that the pair or
  /// Do now shows stays there instead.
  List<TaskItem> _place(
    TaskBoard board,
    Iterable<TaskItem> live,
    _Part part,
    Set<String> staged,
  ) {
    final rows = [
      for (final item in live)
        if (!_held.containsKey(item.id)) item,
    ];
    final held = [
      for (final MapEntry(key: id, value: (at, index)) in _held.entries)
        if (at == part) (index, id),
    ]..sort((a, b) => a.$1 - b.$1);
    for (final (index, id) in held) {
      final item = board.byId(id);
      if (item == null || staged.contains(id)) continue;
      rows.insert(math.min(index, rows.length), item);
    }
    return rows;
  }

  void _tick(TaskItem item, _Part? part, int index) {
    if (part != null) {
      setState(() => _held.putIfAbsent(item.id, () => (part, index)));
    }
    unawaited(_tasks.setDone(item, done: !item.line.done));
  }

  Widget _addRow(TaskBoard board) => _AddRow(
    phone: widget.phone,
    controller: _words,
    focus: widget.addFocus,
    shortcut: widget.newTaskShortcut,
    target: _addTarget,
    labelOf: widget.labelOf,
    choices: _pickerNotes(board),
    onChoose: (noteId) => setState(() {
      _target = noteId;
      _targetChosen = true;
    }),
    onSubmit: () => unawaited(_add()),
    onLeave: _listFocus.requestFocus,
  );

  /// A phone's add field: docked over the keyboard while a task is being
  /// written, so the list never moves for it. It stays built, out of sight,
  /// so the + can focus it.
  Widget _composer(BuildContext context, TaskBoard board) {
    final focused = widget.addFocus.hasFocus;
    final keyboard = MediaQueryData.fromView(
      View.of(context),
    ).viewInsets.bottom;
    if (focused && keyboard > 0) _composerRose = true;
    if (focused && _composerRose && keyboard == 0) {
      _composerRose = false;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.addFocus.unfocus(),
      );
    }
    if (!focused) _composerRose = false;
    return Offstage(
      offstage: !focused,
      child: Container(
        key: _composerKey,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: BoxDecoration(
          color: context.palette.paperColor,
          border: Border(
            top: BorderSide(
              color: TaskInk.of(context).hairline,
              width: AppHairline.of(context),
            ),
          ),
        ),
        child: TapRegion(
          onTapOutside: (_) => widget.addFocus.unfocus(),
          child: _addRow(board),
        ),
      ),
    );
  }

  /// The notes the add row can write into: the ones with tasks that this
  /// person can change, then the note for tasks with no note leads as
  /// "No note".
  List<Note> _pickerNotes(TaskBoard board) {
    final seen = <String>{?board.home?.id};
    return [
      for (final item in [...board.open, ...board.done])
        if (_tasks.canEdit(item.note) && seen.add(item.note.id)) item.note,
    ];
  }

  /// What a search that matches nothing says, on Today and on Done.
  Widget _noMatch(TaskInk ink) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
    child: Text(
      'No tasks match “$_query”.',
      key: const ValueKey('tasks-search-empty'),
      style: taskText(15, 20, ink.quiet),
    ),
  );

  Widget _done(TaskBoard board) {
    final palette = context.palette;
    final now = _tasks.now();
    final days = <DateTime, List<TaskItem>>{};
    for (final item in board.done) {
      if (!_matches(board, item)) continue;
      final at = item.doneAt!;
      (days[DateTime(at.year, at.month, at.day)] ??= []).add(item);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final titleStyle = uiStyle(
                    32,
                    40,
                    FontWeight.w700,
                    palette.textPrimary,
                  );
                  final countStyle = uiStyle(
                    13,
                    16,
                    FontWeight.w600,
                    palette.textTertiary,
                  );
                  final countText = '${board.done.length} completed';
                  final title = Text('Done', style: titleStyle);
                  final count = Text(countText, style: countStyle);
                  if (!_fitsOnOneLine(
                    context,
                    constraints.maxWidth,
                    ('Done', titleStyle),
                    (countText, countStyle),
                    10,
                  )) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [title, count],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [title, const SizedBox(width: 10), count],
                  );
                },
              ),
              const SizedBox(height: 6),
              Text(
                'Newest first, by the day each was finished. Unticking one '
                'puts it back at the end of the list.',
                style: uiStyle(13, 18, FontWeight.w400, palette.textSecondary),
              ),
            ],
          ),
        ),
        if (_query.isNotEmpty && days.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: _noMatch(TaskInk.of(context)),
          ),
        for (final MapEntry(key: day, value: items) in days.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 18, 10, 4),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    SidebarTimestamp.doneDay(day, now: now),
                    style: uiStyle(
                      15,
                      22,
                      FontWeight.w600,
                      palette.textSubheading,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${items.length}',
                  style: uiStyle(12, 16, FontWeight.w600, palette.textTertiary),
                ),
              ],
            ),
          ),
          for (final item in items)
            _DoneRow(
              key: ValueKey(item.id),
              item: item,
              label: board.isHome(item) ? null : widget.labelOf(item.note),
              onUntick: _tasks.canEdit(item.note)
                  ? () => unawaited(_tasks.setDone(item, done: false))
                  : null,
              onOpenNote: () => widget.onOpenNote(item.note.id),
            ),
        ],
      ],
    );
  }
}

/// "Up next" over the chosen tasks.
class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.phone});

  final String text;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: phone
            ? const EdgeInsets.only(top: 16, bottom: 2)
            : const EdgeInsets.only(left: 10, top: 24, bottom: 6),
        child: Text(
          text,
          style: phone
              ? taskText(13, 18, ink.quiet, 520)
              : taskText(12, 16, ink.quiet, 520),
        ),
      ),
    );
  }
}

/// Later: how many tasks wait for their note's day, and the soonest of
/// those days. A tap opens the note that comes first.
class _LaterRow extends StatelessWidget {
  const _LaterRow({
    required this.waiting,
    required this.phone,
    required this.onOpenNote,
  });

  final List<TaskItem> waiting;
  final bool phone;
  final ValueChanged<String> onOpenNote;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final days = NoteDayScope.maybeOf(context);
    (DateTime, TaskItem)? soonest;
    for (final item in waiting) {
      final day = days?.dayOf(item.note.id);
      if (day == null) continue;
      if (soonest == null || day.isBefore(soonest.$1)) soonest = (day, item);
    }
    final words = waiting.length == 1
        ? '1 task waits for its day'
        : '${waiting.length} tasks wait for their day';
    final day = soonest == null
        ? null
        : SidebarTimestamp.dayAndDate(soonest.$1);
    final first = soonest?.$2;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: phone ? 44 : 36),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: phone ? 0 : 10),
        child: Row(
          children: [
            SizedBox(
              width: phone ? 44 : 30,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 20,
                  child: KapyIcon(
                    KapyIcons.calendarOutlined,
                    size: phone ? 18 : 16,
                    color: ink.quiet,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Text(
                words,
                style: phone
                    ? taskText(15, 20, ink.secondary)
                    : taskText(13, 18, ink.secondary),
              ),
            ),
            if (day != null) ...[
              const SizedBox(width: 10),
              Text(
                day,
                style: phone
                    ? taskText(13, 18, ink.quiet)
                    : taskText(12, 16, ink.quiet),
              ),
              const SizedBox(width: 16),
              KapyIcon(
                KapyIcons.chevronRightRounded,
                size: 12,
                color: ink.quiet,
              ),
            ],
          ],
        ),
      ),
    );
    if (first == null) {
      return Semantics(
        key: const ValueKey('tasks-later'),
        container: true,
        child: row,
      );
    }
    return Semantics(
      button: true,
      label: '$words, the first on $day',
      onTapHint: 'Open ${first.note.title}',
      excludeSemantics: true,
      onTap: () => onOpenNote(first.note.id),
      child: InkWell(
        key: const ValueKey('tasks-later'),
        onTap: () => onOpenNote(first.note.id),
        borderRadius: BorderRadius.circular(6),
        child: row,
      ),
    );
  }
}

/// A choice in a phone's filter: its mark, its name, how many, and a tick
/// on the one showing.
class _FilterMenuRow extends StatelessWidget {
  const _FilterMenuRow({required this.choice, required this.selected});

  final TaskFilterChoice choice;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      selected: selected,
      child: Row(
        spacing: 12,
        children: [
          SizedBox.square(
            dimension: 18,
            child: Center(
              child: taskFilterMark(choice, palette.textSecondary, size: 18),
            ),
          ),
          Expanded(
            child: Text(
              choice.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${choice.count}',
            style: metaStyle(15, 20, palette.textTertiary, tabular: true),
          ),
          SizedBox.square(
            dimension: 18,
            child: selected
                ? KapyIcon(
                    KapyIcons.checkRounded,
                    size: 18,
                    color: palette.textSecondary,
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// Adding a task: a quiet filled row, always open, with the note it goes
/// into and the key that reaches it. Enter adds and keeps the field for the
/// next one; Escape leaves.
class _AddRow extends StatelessWidget {
  const _AddRow({
    required this.phone,
    required this.controller,
    required this.focus,
    required this.shortcut,
    required this.target,
    required this.labelOf,
    required this.choices,
    required this.onChoose,
    required this.onSubmit,
    required this.onLeave,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final String? shortcut;
  final Note? target;
  final String Function(Note note) labelOf;
  final List<Note> choices;
  final ValueChanged<String?> onChoose;
  final VoidCallback onSubmit;

  /// Escape: hands the keys back to the page, so ←, → and esc reach the pair.
  final VoidCallback onLeave;

  /// A phone's row: taller, larger words, and no keys.
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final focused = focus.hasFocus;
    final shortcut = this.shortcut;
    final words = phone
        ? taskText(15, 20, ink.text)
        : taskText(13, 18, ink.text);
    return Container(
      key: const ValueKey('tasks-add-row'),
      constraints: BoxConstraints(minHeight: phone ? 44 : 40),
      padding: EdgeInsets.only(left: phone ? 14 : 12, right: phone ? 6 : 8),
      decoration: BoxDecoration(
        color: ink.card,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      foregroundDecoration: taskContrastEdge(context, AppRadii.control),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            KapyIcon(
              KapyIcons.addRounded,
              size: 16,
              color: focused ? ink.sage : ink.quiet,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): onLeave,
                },
                child: TextField(
                  key: const ValueKey('tasks-add-field'),
                  controller: controller,
                  focusNode: focus,
                  onSubmitted: (_) => onSubmit(),
                  onEditingComplete: () {},
                  textInputAction: TextInputAction.done,
                  cursorColor: ink.sage,
                  style: words,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: phone ? 'Add a task' : 'Add a task…',
                    hintStyle: words.copyWith(color: ink.quiet),
                    contentPadding: EdgeInsets.symmetric(
                      vertical: phone ? 12 : 11,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _NotePicker(
              target: target,
              labelOf: labelOf,
              choices: choices,
              onChoose: onChoose,
              chevron: !focused,
              phone: phone,
              maxWidth: math.min(200, constraints.maxWidth * taskMarkShare),
            ),
            if (!phone) ...[
              const SizedBox(width: 10),
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    focused ? '↵' : shortcut ?? '',
                    style: TextStyle(
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                      fontSize: 11,
                      height: 14 / 11,
                      color: ink.quiet,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Which note a new task goes into. Opens in one click and leaves the field
/// as it was.
class _NotePicker extends StatelessWidget {
  const _NotePicker({
    required this.target,
    required this.labelOf,
    required this.choices,
    required this.onChoose,
    required this.chevron,
    required this.phone,
    required this.maxWidth,
  });

  final Note? target;
  final String Function(Note note) labelOf;
  final List<Note> choices;
  final ValueChanged<String?> onChoose;
  final bool chevron;

  /// Whether this sits in a phone's row, where a target is 44 pt tall.
  final bool phone;

  /// The widest the chip grows, so the field beside it keeps most of the row.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final target = this.target;
    final radius = phone ? AppRadii.control : AppRadii.control;
    return Tooltip(
      message: 'Add to a note',
      child: InkWell(
        key: const ValueKey('tasks-note-picker'),
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(radius),
        onTap: () => _open(context),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: phone ? 44 : 28),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Container(
              constraints: BoxConstraints(
                minHeight: phone ? 32 : 28,
                maxWidth: maxWidth,
              ),
              padding: EdgeInsets.only(
                left: phone ? 10 : 9,
                right: phone ? 10 : 8,
              ),
              decoration: BoxDecoration(
                color: ink.lifted,
                borderRadius: BorderRadius.circular(radius),
              ),
              foregroundDecoration: taskContrastEdge(context, radius),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NoteSwatch(note: target, size: phone ? 13 : 8),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      target == null ? 'No note' : labelOf(target),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: phone
                          ? taskText(13, 18, ink.secondary)
                          : taskText(12, 16, ink.secondary, 500),
                    ),
                  ),
                  if (chevron) ...[
                    const SizedBox(width: 6),
                    KapyIcon(
                      KapyIcons.chevronDownRounded,
                      size: 12,
                      color: ink.quiet,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    Widget row(Note? note) => Row(
      children: [
        NoteSwatch(note: note),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            note == null ? 'No note' : labelOf(note),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    unawaited(
      showKapyContextMenu<String>(
        context: context,
        useRootNavigator: true,
        requestFocus: false,
        globalPosition: box.localToGlobal(Offset(0, box.size.height + 4)),
        items: [
          PopupMenuItem(value: '', height: 36, child: row(null)),
          for (final note in choices)
            PopupMenuItem(value: note.id, height: 36, child: row(note)),
        ],
      ).then((choice) {
        if (choice != null) onChoose(choice.isEmpty ? null : choice);
      }),
    );
  }
}

/// One entry in a row's menu.
class TaskMenuChoice {
  const TaskMenuChoice(this.label, this.onSelected);

  final String label;
  final VoidCallback onSelected;
}

/// Opens a row's menu at [position]. A null between entries draws a line.
Future<void> _showTaskMenu(
  BuildContext context,
  Offset position,
  List<TaskMenuChoice?> menu, {
  required bool phone,
}) async {
  final choice = await showKapyContextMenu<int>(
    context: context,
    useRootNavigator: true,
    globalPosition: position,
    requestFocus: false,
    items: [
      for (final (index, entry) in menu.indexed)
        if (entry == null)
          const PopupMenuDivider(height: 9)
        else
          PopupMenuItem(
            key: ValueKey('task-menu-${entry.label}'),
            value: index,
            height: phone ? 44 : 32,
            child: Text(entry.label),
          ),
    ],
  );
  if (choice != null) menu[choice]?.onSelected();
}

/// One task in the list: its box and words, then ↺, its details mark and
/// its note. Hovered, it says when it was added and offers its menu; left
/// untouched for two weeks, it asks whether it's still wanted.
class _TaskRow extends StatefulWidget {
  const _TaskRow({
    super.key,
    required this.item,
    required this.done,
    required this.now,
    required this.label,
    required this.wash,
    required this.menu,
    required this.onTick,
    required this.onOpenNote,
    required this.onOpen,
    required this.onKeep,
    required this.onRemove,
  });

  final TaskItem item;

  /// Ticked today: checked, in the quiet ink, with nothing to do but untick.
  final bool done;
  final DateTime now;

  /// The note's name on its mark; null for a task with no note.
  final String? label;

  /// Just added: a sage wash that fades.
  final bool wash;
  final List<TaskMenuChoice?> menu;

  /// Null on a note shared to view only: the box is faint and takes no tap.
  final VoidCallback? onTick;
  final VoidCallback onOpenNote;
  final VoidCallback onOpen;
  final VoidCallback onKeep;
  final VoidCallback onRemove;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  bool _hovered = false;
  final _more = GlobalKey();

  void _openMenu(Offset at) =>
      unawaited(_showTaskMenu(context, at, widget.menu, phone: false));

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final item = widget.item;
    final label = widget.label;
    final done = widget.done;
    final stale = !done && taskIsStale(item, widget.now);
    final hovered = _hovered && !done;
    final quiet = taskText(12, 16, ink.quiet);
    final touch = !AppPlatform.hasPointer;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: touch ? 44 : 36),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final words = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onOpen,
              child: Text(
                item.hasGroup
                    ? '${item.words}  ${item.groupDone} of ${item.groupTotal}'
                    : item.words,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: taskText(13, 18, done || stale ? ink.quiet : ink.text),
              ),
            );
            final scaler = MediaQuery.textScalerOf(context);
            final grow = scaler.scale(12) / 12;
            final ask = constraints.maxWidth >= _stillWantWidth * grow;
            final controls = stale
                ? 50 +
                      grow *
                          (ask
                              ? _keepRemoveWords + _stillWantWords
                              : _keepRemoveWords)
                : 0.0;
            final below = constraints.maxWidth < controls * 2;
            final room = below
                ? constraints.maxWidth
                : constraints.maxWidth - controls;
            final under = label != null && room < 200 * scaler.scale(16) / 16;
            final keep = Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (ask) Text('Still want this?', style: quiet),
                _RowButton(
                  label: 'Keep',
                  strong: true,
                  onPressed: widget.onKeep,
                ),
                _RowButton(label: 'Remove', onPressed: widget.onRemove),
              ],
            );
            return Row(
              children: [
                _RowBox(
                  onPressed: widget.onTick,
                  label: item.words,
                  checked: done,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: under || below
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            words,
                            if (under)
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: NoteMark(
                                  note: item.note,
                                  label: label,
                                  onPressed: widget.onOpenNote,
                                ),
                              ),
                            if (below) keep,
                          ],
                        )
                      : words,
                ),
                if (stale) ...[
                  if (!below) ...[const SizedBox(width: 10), keep],
                ] else if (hovered) ...[
                  const SizedBox(width: 10),
                  Text(
                    'Added ${SidebarTimestamp.shortDay(DateTime.fromMillisecondsSinceEpoch(item.entry.addedAt), now: widget.now)}',
                    style: quiet,
                  ),
                ],
                if (hovered && !stale) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'More',
                    child: InkWell(
                      key: _more,
                      onTap: () {
                        final box =
                            _more.currentContext!.findRenderObject()!
                                as RenderBox;
                        _openMenu(
                          box.localToGlobal(Offset(0, box.size.height + 4)),
                        );
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: ink.chip,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: KapyIcon(
                          KapyIcons.moreVerticalRounded,
                          size: 14,
                          color: ink.secondary,
                        ),
                      ),
                    ),
                  ),
                ],
                if (item.entry.enteredAt != 0 && !stale && !hovered && !done)
                  Tooltip(
                    message: 'Not finished, moved to the end',
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: KapyIcon(
                        KapyIcons.undoRounded,
                        size: 14,
                        color: ink.quiet,
                      ),
                    ),
                  ),
                if (!hovered && !stale) TaskDetailsIcon(item: item),
                const SizedBox(width: 16),
                if (!under)
                  SizedBox(
                    width: math.min(150, taskMarkWidth(room)),
                    child: label == null
                        ? null
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: NoteMark(
                              note: item.note,
                              label: label,
                              onPressed: widget.onOpenNote,
                            ),
                          ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    return Semantics(
      customSemanticsActions: {
        for (final entry in widget.menu.nonNulls)
          CustomSemanticsAction(label: entry.label): entry.onSelected,
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onSecondaryTapUp: widget.menu.isEmpty
              ? null
              : (details) => _openMenu(details.globalPosition),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: widget.wash ? 1 : 0, end: 0),
            duration: const Duration(seconds: 2),
            curve: Curves.easeIn,
            builder: (context, wash, child) => DecoratedBox(
              decoration: BoxDecoration(
                color: wash > 0
                    ? Color.lerp(
                        ink.rowHover,
                        context.palette.tonalBackground,
                        wash,
                      )
                    : hovered
                    ? ink.rowHover
                    : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: child,
            ),
            child: row,
          ),
        ),
      ),
    );
  }
}

/// An open task's box, as the boards draw it.
class _RowBox extends StatelessWidget {
  const _RowBox({
    required this.onPressed,
    required this.label,
    this.checked = false,
    this.phone = false,
    this.boxKey,
  });

  /// On the part that takes the tap.
  final Key? boxKey;
  final VoidCallback? onPressed;
  final String label;
  final bool checked;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final size = phone ? 20.0 : 16.0;
    return Semantics(
      checked: checked,
      label: label,
      button: true,
      enabled: onPressed != null,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        key: boxKey,
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: phone ? 44 : 20,
          height: phone ? 44 : 28,
          child: Align(
            alignment: phone ? Alignment.centerLeft : Alignment.center,
            child: Opacity(
              opacity: onPressed == null ? lockedBoxOpacity : 1,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: checked ? context.palette.accentFill : null,
                  border: checked
                      ? null
                      : Border.all(color: ink.quiet, width: phone ? 1.5 : 1.25),
                  borderRadius: BorderRadius.circular(phone ? 5 : 4),
                ),
                child: checked
                    ? KapyIcon(
                        KapyIcons.checkRounded,
                        size: phone ? 14 : 12,
                        color: context.palette.onAccent,
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowButton extends StatelessWidget {
  const _RowButton({
    required this.label,
    required this.onPressed,
    this.strong = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    return TaskButton(
      semantics: label,
      onPressed: onPressed,
      fill: strong ? ink.rowHover : null,
      height: 24,
      radius: 4,
      padding: 9,
      children: [
        Text(
          label,
          style: taskText(12, 16, strong ? ink.text : ink.secondary, 500),
        ),
      ],
    );
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow({
    super.key,
    required this.item,
    required this.label,
    required this.onUntick,
    required this.onOpenNote,
  });

  final TaskItem item;
  final String? label;
  final VoidCallback? onUntick;
  final VoidCallback onOpenNote;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = this.label;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 38),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _Box(done: true, onPressed: onUntick, label: item.words),
            const SizedBox(width: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final words = Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.words,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: uiStyle(
                            16,
                            28,
                            FontWeight.w400,
                            palette.textMuted,
                          ),
                        ),
                      ),
                    ],
                  );
                  if (label == null) return words;
                  final mark = NoteMark(
                    note: item.note,
                    label: label,
                    onPressed: onOpenNote,
                  );
                  if (constraints.maxWidth <
                      200 * MediaQuery.textScalerOf(context).scale(16) / 16) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [words, mark],
                    );
                  }
                  return Row(
                    children: [
                      Flexible(child: words),
                      const SizedBox(width: 12),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: taskMarkWidth(constraints.maxWidth),
                        ),
                        child: mark,
                      ),
                    ],
                  );
                },
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44),
              child: Text(
                SidebarTimestamp.clock(item.doneAt!),
                textAlign: TextAlign.right,
                maxLines: 1,
                softWrap: false,
                style: uiStyle(12.5, 16, FontWeight.w400, palette.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({
    required this.done,
    required this.onPressed,
    required this.label,
  });

  final bool done;

  /// Null on a note shared to view only: the box is drawn faint and takes no
  /// tap.
  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      checked: done,
      label: label,
      button: true,
      enabled: onPressed != null,
      child: InkResponse(
        onTap: onPressed,
        radius: 16,
        child: Opacity(
          opacity: onPressed == null ? lockedBoxOpacity : 1,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: done ? palette.accentFill : palette.editorBackground,
              border: done
                  ? null
                  : Border.all(color: palette.checkboxBorder, width: 1.5),
              shape: BoxShape.circle,
            ),
            child: done
                ? KapyIcon(
                    KapyIcons.checkRounded,
                    size: 14,
                    color: palette.onAccent,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// A phone's line over Today: "Today" with the date, and how many of
/// today's are done at the far end.
class _PhoneTodayTitle extends StatelessWidget {
  const _PhoneTodayTitle({
    required this.now,
    required this.done,
    required this.total,
    required this.sheet,
  });

  final DateTime now;
  final int done;
  final int total;

  /// Under the sheet's own title, with nothing between it and the body.
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final titleStyle = dayTitleStyle(ink.text);
    final quiet = metaStyle(13, 16, ink.quiet);
    final dayText = SidebarTimestamp.dayAndDate(now);
    final countText = '$done of $total done';
    final title = Semantics(
      header: true,
      child: Text('Today', style: titleStyle),
    );
    final day = Expanded(
      child: Text(
        dayText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: quiet,
      ),
    );
    final count = Text(
      countText,
      key: const ValueKey('tasks-done-count'),
      style: quiet.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
    return Padding(
      padding: EdgeInsets.only(top: sheet ? 0 : 22, bottom: sheet ? 0 : 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final oneLine = _fitsOnOneLine(
            context,
            constraints.maxWidth,
            ('Today', titleStyle),
            ('$dayText  $countText', quiet),
            8,
          );
          final heading = Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              title,
              const SizedBox(width: 8),
              day,
              if (oneLine) count,
            ],
          );
          if (oneLine) return heading;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [heading, count],
          );
        },
      ),
    );
  }
}

/// A phone's task row: the box, then the task with its note under it. A tap
/// on the box checks it off in place, a tap on the words opens its details,
/// and a long press opens the row menu.
class _PhoneTaskRow extends StatelessWidget {
  const _PhoneTaskRow({
    super.key,
    required this.item,
    required this.done,
    required this.now,
    required this.label,
    required this.wash,
    required this.menu,
    required this.onTick,
    required this.onOpen,
    required this.onKeep,
    required this.onRemove,
  });

  final TaskItem item;
  final bool done;
  final DateTime now;
  final String? label;

  /// Just added: a sage wash that fades.
  final bool wash;
  final List<TaskMenuChoice?> menu;

  /// Null on a note shared to view only: the box is faint and takes no tap.
  final VoidCallback? onTick;
  final VoidCallback onOpen;
  final VoidCallback onKeep;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final stale = !done && taskIsStale(item, now);
    final meta = taskText(13, 18, ink.quiet);
    Widget link(String text, VoidCallback onPressed, {bool strong = false}) =>
        Semantics(
          button: true,
          label: text,
          excludeSemantics: true,
          onTap: onPressed,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
              child: Center(
                widthFactor: 1,
                child: Text(
                  text,
                  style: taskText(
                    13,
                    18,
                    strong ? ink.text : ink.secondary,
                    500,
                  ),
                ),
              ),
            ),
          ),
        );
    return Semantics(
      customSemanticsActions: {
        for (final entry in menu.nonNulls)
          CustomSemanticsAction(label: entry.label): entry.onSelected,
      },
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: wash ? 1 : 0, end: 0),
        duration: const Duration(seconds: 2),
        curve: Curves.easeIn,
        builder: (context, wash, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: wash > 0
                ? context.palette.tonalBackground.withValues(alpha: wash)
                : null,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: child,
        ),
        child: InkWell(
          key: ValueKey('phone-task-${item.id}'),
          onTap: onOpen,
          child: GestureDetector(
            onLongPressStart: done || menu.isEmpty
                ? null
                : (details) => unawaited(
                    _showTaskMenu(
                      context,
                      details.globalPosition,
                      menu,
                      phone: true,
                    ),
                  ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  _RowBox(
                    boxKey: ValueKey('phone-task-box-${item.id}'),
                    onPressed: onTick,
                    label: item.words,
                    checked: done,
                    phone: true,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.words,
                            style: taskText(
                              16,
                              22,
                              done || stale ? ink.quiet : ink.text,
                            ),
                          ),
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            children: [
                              Text(label ?? 'No note', style: meta),
                              if (item.entry.enteredAt != 0 && !done)
                                Tooltip(
                                  message: 'Not finished, moved to the end',
                                  child: KapyIcon(
                                    KapyIcons.undoRounded,
                                    size: 14,
                                    color: ink.quiet,
                                  ),
                                ),
                              if (stale) ...[
                                Text('·  Still want this?', style: meta),
                                link('Keep', onKeep, strong: true),
                                link('Remove', onRemove),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  TaskDetailsIcon(item: item),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The band over Today on a window: "Today" or the note's name, then the
/// date.
class TasksTodayCrumb extends StatelessWidget {
  const TasksTodayCrumb({super.key, required this.title, required this.now});

  final String title;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    return Row(
      key: const ValueKey('tasks-band-title'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Semantics(
            header: true,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: taskText(13, 18, ink.text, 500),
            ),
          ),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Text(
            SidebarTimestamp.dayAndDate(now),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: taskText(13, 18, ink.quiet),
          ),
        ),
      ],
    );
  }
}

/// The band's right side over Today: how much of today is done, and Choose
/// again while anything is chosen.
class TasksBandActions extends StatelessWidget {
  const TasksBandActions({
    super.key,
    required this.controller,
    required this.filter,
    required this.onChooseAgain,
  });

  final TasksController controller;
  final TaskFilter filter;
  final VoidCallback onChooseAgain;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final ink = TaskInk.of(context);
      final board = controller.read();
      final now = controller.now();
      final done = board.doneSince(
        DateTime(now.year, now.month, now.day),
        noteId: filter.noteId,
      );
      final total = done + controller.openIn(filter.noteId).length;
      final chosen = controller.choiceIn(filter.noteId).chosen;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ChecklistPie(
            done: done,
            total: total,
            fill: context.palette.accentFill,
            check: context.palette.onAccent,
          ),
          const SizedBox(width: 6),
          ExcludeSemantics(
            child: Text(
              '$done of $total done today',
              key: const ValueKey('tasks-done-today'),
              style: taskText(
                12,
                16,
                ink.quiet,
              ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
          if (chosen) ...[
            const SizedBox(width: 14),
            TaskButton(
              key: const ValueKey('tasks-choose-again'),
              semantics: 'Choose again',
              onPressed: onChooseAgain,
              height: 28,
              padding: 8,
              children: [
                KapyIcon(
                  KapyIcons.refreshRounded,
                  size: 14,
                  color: ink.secondary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Choose again',
                  style: taskText(13, 18, ink.secondary, 500),
                ),
              ],
            ),
          ],
          const SizedBox(width: 8),
        ],
      );
    },
  );
}

/// How wide a list row must be at 1× to say "Still want this?" beside Keep
/// and Remove; a narrower one keeps the room for the task's words.
const double _stillWantWidth = 520;

/// The words on Keep and Remove at 1×, which grow with the text size; their
/// padding and the gaps around them take 50 more that doesn't.
const double _keepRemoveWords = 73;

/// "Still want this?" and its gap at 1×.
const double _stillWantWords = 90;

/// Whether [title] and [count], [gap] apart, fit on one line of [maxWidth] at
/// the current text size.
bool _fitsOnOneLine(
  BuildContext context,
  double maxWidth,
  (String, TextStyle) title,
  (String, TextStyle) count,
  double gap,
) {
  final scaler = MediaQuery.textScalerOf(context);
  double width((String, TextStyle) part) {
    final painter = TextPainter(
      text: TextSpan(text: part.$1, style: part.$2),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  return width(title) + gap + width(count) <= maxWidth;
}
