import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/blob_store.dart';
import '../../data/note.dart';
import '../../data/task_board.dart';
import '../../data/task_details.dart';
import '../context_menu.dart';
import '../editor/note_header.dart';
import '../keycap.dart';
import '../note_day_scope.dart';
import '../notes_grouping.dart' show dayShown;
import '../sidebar_timestamp.dart';
import '../tonal_button.dart';
import 'task_marks.dart';
import 'task_details_sheet.dart';
import 'tasks_controller.dart';

/// The chord that finishes Do now, as its button prints it.
String? get doneShortcutLabel => !AppPlatform.hasPointer
    ? null
    : AppPlatform.isMacOS
    ? '⌘↵'
    : 'Ctrl+↵';

/// Tasks' page: Today, the one list worked with Mark Forster's Final Version
/// Perfected, or the Done view.
///
/// Today is a header with the day and how much of it is done, the row that
/// adds a task to the end of the list, Do now (or the questions that pick
/// it), and the list in the order tasks were added. There are no dates to
/// plan by and no sort: FVP needs the one fixed order.
class TasksScreen extends StatefulWidget {
  const TasksScreen({
    super.key,
    required this.controller,
    required this.filter,
    required this.addFocus,
    required this.labelOf,
    required this.onOpenNote,
    this.images,
    this.displayTime,
    this.newTaskShortcut,
    this.phone = false,
  });

  /// A phone's Tasks: a large title with how many are done, no keycaps, and
  /// rows that check off in place and stay until the screen is left.
  final bool phone;

  final TasksController controller;
  final TaskFilter filter;
  final FocusNode addFocus;

  /// A note's name as a task's mark shows it.
  final String Function(Note note) labelOf;
  final ValueChanged<String> onOpenNote;

  /// Where a task's picture is stored, so Do now and the sheet can show it.
  /// Null in a test that does not draw pictures.
  final BlobStore? images;

  /// The clock the app shows times by, so a note's day comes when the list
  /// says it does; the device's own when left out.
  final DateTime Function(DateTime)? displayTime;

  /// Printed on the add row's keycap at rest.
  final String? newTaskShortcut;

  @override
  State<TasksScreen> createState() => TasksScreenState();
}

class TasksScreenState extends State<TasksScreen> {
  final _words = TextEditingController();

  /// Tasks a phone checked off on this visit, by the place they held, so
  /// their rows stay, struck through, until the screen is left.
  final Map<String, (int, TaskItem)> _ticked = {};

  /// Where the next scan starts after Do now was done or sent back: only
  /// tasks after it are asked about, until the next Pick again.
  int? _resumeAfter;

  /// The note the add row writes into, once chosen in its picker; until then
  /// the sidebar's filter decides.
  String? _target;
  bool _targetChosen = false;

  String? _washId;
  String? _sheetId;
  int _sheetIndex = 0;
  final _listFocus = FocusNode(debugLabel: 'tasks-list');
  bool _notice = false;
  Timer? _noticeTimer;
  bool _allCandidates = false;
  String? _autoPicked;

  @override
  void initState() {
    super.initState();
    widget.addFocus.addListener(_focusChanged);
    widget.controller.sheetRequest.addListener(_takeSheetRequest);
    // An ask made before this screen existed — a menu bar click while the app
    // was showing Notes — is waiting for its first listener.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _takeSheetRequest();
    });
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
      _resumeAfter = null;
      _targetChosen = false;
      _allCandidates = false;
    }
  }

  @override
  void dispose() {
    widget.controller.sheetRequest.removeListener(_takeSheetRequest);
    _listFocus.dispose();
    widget.addFocus.removeListener(_focusChanged);
    _noticeTimer?.cancel();
    _words.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() {});

  TasksController get _tasks => widget.controller;

  static DateTime _deviceTime(DateTime time) => time.toLocal();

  List<TaskItem> _open(TaskBoard board) {
    final days = NoteDayScope.maybeOf(context);
    final today = dayShown(_tasks.now(), widget.displayTime ?? _deviceTime);
    return [
      for (final item in board.openIn(widget.filter.noteId))
        if (days == null || !days.taskWaits(item.note.id, today)) item,
    ];
  }

  /// The tasks whose note waits for a later day: not on today's list, and
  /// counted in one quiet line.
  int _waiting(TaskBoard board) {
    final days = NoteDayScope.maybeOf(context);
    if (days == null) return 0;
    final today = dayShown(_tasks.now(), widget.displayTime ?? _deviceTime);
    return [
      for (final item in board.openIn(widget.filter.noteId))
        if (days.taskWaits(item.note.id, today)) item,
    ].length;
  }

  /// Pick again: every dot cleared, and the questions start over from the
  /// first task.
  void pickAgain() {
    _tasks.clearPicks(_open(_tasks.read()));
    setState(() {
      _resumeAfter = null;
      _allCandidates = false;
    });
  }

  /// Done on Do now, from its button or the keyboard.
  void completeDoNow() {
    final item = _doNow(_open(_tasks.read()));
    if (item == null || !_tasks.canEdit(item.note)) return;
    _resumeAfter = item.entry.position;
    unawaited(_tasks.setDone(item, done: true));
  }

  /// A click on a row's mark: none, then picked, then Do now, then none
  /// again. Picking by hand ends the questions about that task, so a task
  /// picked last stays picked until it is clicked again.
  void _cycleMark(TaskItem item) {
    if (item.doNow) {
      _autoPicked = null;
      _tasks.clearPick(item);
    } else if (item.dotted) {
      _tasks.doNow(item);
    } else {
      _autoPicked = item.id;
      _tasks.dot(item);
    }
  }

  void _notFinished(TaskItem item) {
    setState(() => _resumeAfter = item.entry.position);
    _tasks.sendToEnd(item);
  }

  TaskItem? _doNow(List<TaskItem> open) {
    for (final item in open) {
      if (item.doNow) return item;
    }
    return null;
  }

  String? get _addInto => _targetChosen ? _target : widget.filter.noteId;

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
    _noticeTimer?.cancel();
    setState(() {
      _washId = id;
      _notice = true;
    });
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _notice = false);
    });
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final board = _tasks.read();
      return LayoutBuilder(
        builder: (context, constraints) {
          final phone = widget.phone;
          final width = phone
              ? constraints.maxWidth - 40
              : math.min(700.0, constraints.maxWidth - 48);
          final reach = phone || widget.filter.done || AppPlatform.hasPointer
              ? 0.0
              : _markReach;
          return SingleChildScrollView(
            padding: EdgeInsets.only(
              top: phone ? 0 : 20,
              bottom: phone ? 120 : 48,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(
                  left: (constraints.maxWidth - width) / 2 - reach,
                ),
                child: SizedBox(
                  width: width + reach,
                  child: widget.filter.done
                      ? _done(board)
                      : _withSheet(board, _today(board, reach)),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  void _openSheet(TaskItem item) {
    if (widget.phone) {
      unawaited(_openPhoneSheet(item));
      return;
    }
    setState(() {
      _sheetId = item.id;
      _sheetIndex = _open(_tasks.read()).indexWhere((row) => row.id == item.id);
    });
    _listFocus.requestFocus();
  }

  /// A phone's sheet pulls up over the list, and follows the task as it is
  /// edited, so what it shows is what the note now says.
  Future<void> _openPhoneSheet(TaskItem item) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
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
        return PhoneTaskDetailsSheet(
          item: current,
          tasks: _tasks,
          images: widget.images,
          onClose: () => Navigator.of(context).pop(),
          onOpenNote: () {
            Navigator.of(context).pop();
            widget.onOpenNote(current.note.id);
          },
        );
      },
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

  Widget _withSheet(TaskBoard board, Widget list) {
    final id = _sheetId;
    TaskItem? item;
    if (id != null) {
      for (final candidate in [...board.open, ...board.done]) {
        if (candidate.id == id) item = candidate;
      }
    }
    final shown = Focus(
      focusNode: _listFocus,
      onKeyEvent: _listKey,
      child: list,
    );
    if (item == null || !EditorMetrics.page) return shown;
    final openItem = item;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 3, child: shown),
        const SizedBox(width: 12),
        SizedBox(
          width: 300,
          height: 440,
          child: TaskDetailsSheet(
            key: ValueKey(openItem.id),
            item: openItem,
            tasks: _tasks,
            onClose: () => setState(() => _sheetId = null),
            onOpenNote: () => widget.onOpenNote(openItem.note.id),
            images: widget.images,
          ),
        ),
      ],
    );
  }

  Widget _today(TaskBoard board, double reach) {
    final palette = context.palette;
    final now = _tasks.now();
    final open = _open(board);
    final doneToday = board.doneSince(
      DateTime(now.year, now.month, now.day),
      noteId: widget.filter.noteId,
    );
    final doNow = _doNow(open);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: reach),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.phone)
                _PhoneTodayTitle(
                  done: doneToday,
                  total: doneToday + open.length,
                )
              else
                Padding(
                  padding: const EdgeInsets.only(left: 10, bottom: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _TodayTitle(),
                      const SizedBox(height: 10),
                      // A column narrowed by a task's details shrinks the line
                      // to fit rather than running under them.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: NoteMetaRow(
                          edited: SidebarTimestamp.fullDay(now),
                          done: doneToday,
                          tasks: doneToday + open.length,
                          today: true,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_addTarget case final target? when !_tasks.canEdit(target))
                Padding(
                  key: const ValueKey('tasks-add-view-only'),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Text(
                    'You can view this note, not change it.',
                    style: uiStyle(
                      13,
                      18,
                      FontWeight.w400,
                      palette.textTertiary,
                    ),
                  ),
                )
              else
                _AddRow(
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
                ),
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                child: _notice
                    ? Padding(
                        padding: const EdgeInsets.only(left: 36, top: 8),
                        child: Text(
                          'Added to the end of the list',
                          key: const ValueKey('tasks-added-notice'),
                          style: uiStyle(
                            13,
                            16,
                            FontWeight.w500,
                            palette.accentText,
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 14),
              if (doNow != null)
                _DoNowCard(
                  phone: widget.phone,
                  item: doNow,
                  label: board.isHome(doNow)
                      ? null
                      : widget.labelOf(doNow.note),
                  onOpenNote: () => widget.onOpenNote(doNow.note.id),
                  onOpen: () => _openSheet(doNow),
                  images: widget.images,
                  onNotFinished: () => _notFinished(doNow),
                  onDone: _tasks.canEdit(doNow.note) ? completeDoNow : null,
                )
              else if (open.isNotEmpty)
                _picker(board, open),
              if (widget.phone)
                Padding(
                  padding: const EdgeInsets.only(top: 24, bottom: 4),
                  child: Semantics(
                    header: true,
                    child: Text(
                      'The list',
                      style: uiStyle(
                        15,
                        20,
                        FontWeight.w500,
                        palette.textSecondary,
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 22, 10, 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        'The list',
                        style: handStyle(
                          15,
                          22,
                          FontWeight.w600,
                          palette.textSubheading,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${open.length}',
                        style: uiStyle(
                          12,
                          16,
                          FontWeight.w600,
                          palette.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              if (open.isEmpty && _ticked.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Text(
                    'Nothing on the list.',
                    style: uiStyle(
                      14,
                      20,
                      FontWeight.w500,
                      palette.textTertiary,
                    ),
                  ),
                ),
              if (_waiting(board) case final waiting when waiting > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                  child: Text(
                    waiting == 1
                        ? '1 task waits for its day'
                        : '$waiting tasks wait for their day',
                    key: const ValueKey('tasks-waiting-line'),
                    style: uiStyle(
                      13,
                      18,
                      FontWeight.w400,
                      palette.textTertiary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (widget.phone)
          for (final (item, done) in _phoneRows(open))
            _PhoneTaskRow(
              key: ValueKey(item.id),
              item: item,
              done: done,
              label: board.isHome(item) ? null : widget.labelOf(item.note),
              onTick: _tasks.canEdit(item.note)
                  ? () => _tick(item, open.indexOf(item), done: !done)
                  : null,
              onOpen: () => _openSheet(item),
              onMark: () => _cycleMark(item),
            )
        else
          for (final item in open)
            _TaskRow(
              key: ValueKey(item.id),
              item: item,
              now: _tasks.now(),
              label: board.isHome(item) ? null : widget.labelOf(item.note),
              wash: item.id == _washId,
              onMark: () => _cycleMark(item),
              onTick: _tasks.canEdit(item.note)
                  ? () => unawaited(_tasks.setDone(item, done: true))
                  : null,
              onOpenNote: () => widget.onOpenNote(item.note.id),
              onOpen: () => _openSheet(item),
              onKeep: () => _tasks.keep(item),
              onRemove: () => unawaited(_remove(item)),
            ),
      ],
    );
  }

  /// The open tasks, with the ones checked off on this visit back in the
  /// places they held.
  List<(TaskItem, bool)> _phoneRows(List<TaskItem> open) {
    final rows = [for (final item in open) (item, false)];
    final ids = {for (final item in open) item.id};
    final ticked = _ticked.values.toList()..sort((a, b) => a.$1 - b.$1);
    for (final (index, item) in ticked) {
      if (ids.contains(item.id)) continue;
      rows.insert(math.min(index, rows.length), (item, true));
    }
    return rows;
  }

  void _tick(TaskItem item, int index, {required bool done}) {
    setState(() {
      if (done) {
        _ticked[item.id] = (index, item);
      } else {
        _ticked.remove(item.id);
      }
    });
    unawaited(_tasks.setDone(item, done: done));
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

  /// The questions that pick Do now. With nothing dotted, the first task is
  /// asked about on its own; after that, the tasks after the newest dot are
  /// held up against it, one pick at a time. When nothing is left to ask
  /// about, the newest dot is Do now.
  Widget _picker(TaskBoard board, List<TaskItem> open) {
    final dots = [
      for (final item in open)
        if (item.dotted) item,
    ];
    String? labelOf(TaskItem item) =>
        board.isHome(item) ? null : widget.labelOf(item.note);
    if (dots.isEmpty) {
      final first = open.first;
      return _ReadyCard(
        phone: widget.phone,
        item: first,
        label: labelOf(first),
        onYes: () => _tasks.doNow(first),
        onNotYet: () => _tasks.dot(first),
      );
    }
    final benchmark = dots.last;
    final floor = math.max(benchmark.entry.position, _resumeAfter ?? 0);
    final candidates = [
      for (final item in open)
        if (!item.dotted && item.entry.position > floor) item,
    ];
    if (candidates.isEmpty) {
      if (_autoPicked != benchmark.id) {
        _autoPicked = benchmark.id;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _tasks.doNow(benchmark);
        });
      }
      return const SizedBox.shrink();
    }
    return _MoreThanCard(
      benchmark: benchmark,
      candidates: candidates,
      labelOf: labelOf,
      showAll: _allCandidates,
      onShowAll: () => setState(() => _allCandidates = true),
      onPick: (item) {
        setState(() => _allCandidates = false);
        _tasks.dot(item);
      },
      onNone: () => _tasks.doNow(benchmark),
    );
  }

  Widget _done(TaskBoard board) {
    final palette = context.palette;
    final now = _tasks.now();
    final days = <DateTime, List<TaskItem>>{};
    for (final item in board.done) {
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
                  final titleStyle = handStyle(
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
                  // At large text the count goes under the title rather
                  // than breaking beside it.
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
                style: uiStyle(13, 18, FontWeight.w500, palette.textSecondary),
              ),
            ],
          ),
        ),
        for (final MapEntry(key: day, value: items) in days.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 18, 10, 4),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    SidebarTimestamp.doneDay(day, now: now),
                    style: handStyle(
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

/// "Today" in the title's hand, with the clay underline a note's title gets.
class _TodayTitle extends StatelessWidget {
  const _TodayTitle();

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Text(
          'Today',
          style: handStyle(
            EditorMetrics.titleFontSize,
            EditorMetrics.titleRow,
            EditorMetrics.titleWeight,
            context.palette.textPrimary,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, box) => NoteTitleUnderline(
                word: Rect.fromLTWH(0, 0, box.maxWidth, box.maxHeight),
              ),
            ),
          ),
        ),
      ],
    ),
  );
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
  });

  final TextEditingController controller;
  final FocusNode focus;
  final String? shortcut;
  final Note? target;
  final String Function(Note note) labelOf;
  final List<Note> choices;
  final ValueChanged<String?> onChoose;
  final VoidCallback onSubmit;

  /// A phone's row: 44 pt, a quiet well, and no keycaps.
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final focused = focus.hasFocus;
    final shortcut = this.shortcut;
    return Container(
      key: const ValueKey('tasks-add-row'),
      constraints: BoxConstraints(minHeight: phone ? 44 : 40),
      padding: EdgeInsets.only(left: phone ? 14 : 10, right: 6),
      decoration: BoxDecoration(
        color: phone
            ? palette.wellBackground
            : Color.lerp(
                palette.editorBackground,
                palette.controlBackground,
                0.5,
              ),
        borderRadius: BorderRadius.circular(phone ? 12 : AppRadii.control),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            KapyIcon(
              KapyIcons.addRounded,
              size: 16,
              strokeWidth: 1.8,
              color: focused ? palette.accentText : palette.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape):
                      focus.unfocus,
                },
                child: TextField(
                  key: const ValueKey('tasks-add-field'),
                  controller: controller,
                  focusNode: focus,
                  onSubmitted: (_) => onSubmit(),
                  onEditingComplete: () {},
                  textInputAction: TextInputAction.done,
                  cursorColor: palette.accentText,
                  style: uiStyle(16, 28, FontWeight.w500, palette.textPrimary),
                  decoration: phone
                      ? InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Add a task',
                          hintStyle: uiStyle(
                            16,
                            28,
                            FontWeight.w500,
                            palette.textTertiary,
                          ),
                          // A phone's field is the whole 44 pt row.
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                          ),
                        )
                      : InputDecoration.collapsed(
                          hintText: 'Add a task…',
                          hintStyle: uiStyle(
                            16,
                            28,
                            FontWeight.w500,
                            palette.textTertiary,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _NotePicker(
              target: target,
              labelOf: labelOf,
              choices: choices,
              onChoose: onChoose,
              chevron: !focused,
              phone: phone,
              maxWidth: math.min(200, constraints.maxWidth * _markShare),
            ),
            if (!phone) ...[
              const SizedBox(width: 10),
              if (focused)
                const ExcludeSemantics(child: Keycap('↵'))
              else if (shortcut != null)
                ExcludeSemantics(child: Keycap(shortcut)),
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
    final palette = context.palette;
    final target = this.target;
    return Tooltip(
      message: 'Add to a note',
      child: InkWell(
        key: const ValueKey('tasks-note-picker'),
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(AppRadii.control),
        onTap: () => _open(context),
        child: Container(
          // A phone's target is 44 pt tall; a window's chip stays small.
          constraints: BoxConstraints(
            minHeight: phone ? 44 : 28,
            maxWidth: maxWidth,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            border: Border.all(color: palette.controlBorder),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              NoteSwatch(note: target),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  target == null ? 'No note' : labelOf(target),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: uiStyle(
                    12.5,
                    16,
                    FontWeight.w600,
                    palette.textSecondary,
                  ),
                ),
              ),
              if (chevron) ...[
                const SizedBox(width: 6),
                KapyIcon(
                  KapyIcons.chevronDownRounded,
                  size: 11,
                  strokeWidth: 2,
                  color: palette.textTertiary,
                ),
              ],
            ],
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

/// The one task to work on now, with the two ways out of it.
class _DoNowCard extends StatelessWidget {
  const _DoNowCard({
    required this.phone,
    required this.item,
    required this.label,
    required this.onOpenNote,
    required this.onOpen,
    this.images,
    required this.onNotFinished,
    required this.onDone,
  });

  final TaskItem item;
  final String? label;
  final VoidCallback onOpenNote;
  final VoidCallback onOpen;
  final BlobStore? images;
  final VoidCallback onNotFinished;

  /// Null on a note shared to view only, where Done is not shown.
  final VoidCallback? onDone;

  /// A phone's card: the task under DO NOW, its note, then Done and Not
  /// finished as two pills beneath.
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = this.label;
    if (phone) return _phone(context, palette, label);
    return Container(
      key: const ValueKey('tasks-do-now'),
      padding: const EdgeInsets.only(top: 14, bottom: 14, right: 16),
      decoration: BoxDecoration(
        color: palette.editorBackground,
        border: Border.all(color: palette.controlBorder),
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DO NOW',
                    style: uiStyle(
                      11,
                      14,
                      FontWeight.w700,
                      palette.accentText,
                    ).copyWith(letterSpacing: 0.66),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onOpen,
                    child: Text(
                      item.words,
                      style: uiStyle(
                        20,
                        28,
                        FontWeight.w600,
                        palette.textPrimary,
                      ),
                    ),
                  ),
                  if (taskBlockOf(item.note.body, item.line)?.details
                      case final details?) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            foldedPreview(details.preview),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: uiStyle(
                              13,
                              20,
                              FontWeight.w400,
                              palette.textTertiary,
                            ),
                          ),
                        ),
                        TaskDetailPicture(
                          item: item,
                          details: details,
                          images: images,
                          size: 36,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      alignment: label == null
                          ? WrapAlignment.end
                          : WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      runSpacing: 8,
                      children: [
                        if (label != null)
                          NoteMark(
                            note: item.note,
                            label: label,
                            onPressed: onOpenNote,
                          ),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Tooltip(
                              message: 'Moves it to the end of the list',
                              child: TextButton.icon(
                                key: const ValueKey('tasks-not-finished'),
                                onPressed: onNotFinished,
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.control,
                                    ),
                                  ),
                                  foregroundColor: palette.textSecondary,
                                  textStyle: uiStyle(
                                    13,
                                    16,
                                    FontWeight.w600,
                                    palette.textSecondary,
                                  ),
                                ),
                                icon: KapyIcon(
                                  KapyIcons.undoRounded,
                                  size: 14,
                                  strokeWidth: 1.9,
                                  color: palette.textSecondary,
                                ),
                                label: const Text('Not finished'),
                              ),
                            ),
                            if (onDone != null)
                              TonalButton(
                                key: const ValueKey('tasks-done'),
                                tall: true,
                                icon: KapyIcons.checkRounded,
                                label: 'Done',
                                shortcut: doneShortcutLabel,
                                onPressed: onDone,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _phone(BuildContext context, CalcPalette palette, String? label) {
    final sage = Theme.of(context).colorScheme.primary;
    Widget pill({
      required Key key,
      required String text,
      required VoidCallback onPressed,
      required bool tonal,
    }) => Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tonal ? palette.tonalBackground : null,
                border: tonal ? null : Border.all(color: palette.controlBorder),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                text,
                style: uiStyle(
                  15,
                  20,
                  FontWeight.w500,
                  tonal ? palette.tonalForeground : palette.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Container(
      key: const ValueKey('tasks-do-now'),
      padding: const EdgeInsets.fromLTRB(0, 14, 16, 10),
      decoration: BoxDecoration(
        color: palette.cardBackground,
        border: Border.all(color: palette.separator),
        borderRadius: BorderRadius.circular(14),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: sage,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DO NOW',
                    style: uiStyle(
                      11,
                      14,
                      FontWeight.w700,
                      palette.accentText,
                    ).copyWith(letterSpacing: 0.66),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.words,
                    style: uiStyle(
                      17,
                      22,
                      FontWeight.w500,
                      palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: onOpenNote,
                    child: Text(
                      label ?? 'No note',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: uiStyle(
                        13.5,
                        18,
                        FontWeight.w400,
                        palette.textTertiary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (onDone case final done?)
                        pill(
                          key: const ValueKey('tasks-done'),
                          text: 'Done',
                          onPressed: done,
                          tonal: true,
                        ),
                      pill(
                        key: const ValueKey('tasks-not-finished'),
                        text: 'Not finished',
                        onPressed: onNotFinished,
                        tonal: false,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The card the picking questions are asked on.
class _PickCard extends StatelessWidget {
  const _PickCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const ValueKey('tasks-picker'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: palette.editorBackground,
        border: Border.all(color: palette.pageBorder, width: 1.5),
        borderRadius: BorderRadius.circular(AppRadii.dialog),
        boxShadow: [
          BoxShadow(
            color: palette.shadow.withAlpha(0x66),
            offset: const Offset(0, 16),
            blurRadius: 32,
            spreadRadius: -20,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const SizedBox(height: 14),
            child,
          ],
        ],
      ),
    );
  }
}

/// A full-width or fitted button on the picking card: tonal for the way
/// forward, quiet for the other.
class _PickButton extends StatelessWidget {
  const _PickButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.tonal = false,
    this.icon,
  });

  final String label;
  final VoidCallback onPressed;
  final bool tonal;
  final KapyIconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = tonal ? palette.tonalForeground : palette.textSubheading;
    final icon = this.icon;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        backgroundColor: tonal
            ? palette.tonalBackground
            : palette.controlBackground,
        foregroundColor: ink,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          side: tonal
              ? BorderSide.none
              : BorderSide(color: palette.controlBorder),
        ),
        textStyle: uiStyle(13, 16, FontWeight.w700, ink),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            KapyIcon(icon, size: 15, strokeWidth: 2, color: ink),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// Fast FVP's one check before the scan: the first task, on its own.
class _ReadyCard extends StatelessWidget {
  const _ReadyCard({
    required this.phone,
    required this.item,
    required this.label,
    required this.onYes,
    required this.onNotYet,
  });

  final TaskItem item;
  final String? label;
  final VoidCallback onYes;
  final VoidCallback onNotYet;

  /// A phone says it in fewer words, to fit both on one line.
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = this.label;
    return _PickCard(
      children: [
        Text(
          'First on the list',
          style: uiStyle(12, 16, FontWeight.w600, palette.textTertiary),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: palette.controlBorder),
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final words = Text(
                item.words,
                style: uiStyle(15, 22, FontWeight.w600, palette.textPrimary),
              );
              // Too narrow to share a line, the note's name goes under the
              // words rather than squeezing them.
              if (label != null &&
                  constraints.maxWidth <
                      MediaQuery.textScalerOf(
                        context,
                      ).scale(_markBesideWidth)) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const _Dot(),
                        const SizedBox(width: 10),
                        Expanded(child: words),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 14),
                      child: NoteMark(note: item.note, label: label),
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  const _Dot(),
                  const SizedBox(width: 10),
                  Expanded(child: words),
                  if (label != null) ...[
                    const SizedBox(width: 10),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: _markWidth(constraints.maxWidth),
                      ),
                      child: NoteMark(note: item.note, label: label),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        Text(
          'Ready to do this now?',
          style: handStyle(18, 25, FontWeight.w600, palette.textPrimary),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _PickButton(
              key: const ValueKey('tasks-ready-yes'),
              label: phone ? 'Do it now' : 'Yes, do it now',
              icon: KapyIcons.checkRounded,
              tonal: true,
              onPressed: onYes,
            ),
            _PickButton(
              key: const ValueKey('tasks-ready-not-yet'),
              label: phone ? 'Not yet' : 'Not yet, look further',
              onPressed: onNotYet,
            ),
          ],
        ),
      ],
    );
  }
}

/// FVP's question, held up against the newest dot: the tasks after it, one
/// pick at a time.
class _MoreThanCard extends StatelessWidget {
  const _MoreThanCard({
    required this.benchmark,
    required this.candidates,
    required this.labelOf,
    required this.showAll,
    required this.onShowAll,
    required this.onPick,
    required this.onNone,
  });

  static const int _shown = 5;

  final TaskItem benchmark;
  final List<TaskItem> candidates;
  final String? Function(TaskItem item) labelOf;
  final bool showAll;
  final VoidCallback onShowAll;
  final ValueChanged<TaskItem> onPick;
  final VoidCallback onNone;

  /// The benchmark's words inside the question, with a capital that only
  /// starts a sentence brought down.
  String get _named {
    final words = benchmark.words;
    if (words.length > 1 && words[1] == words[1].toLowerCase()) {
      return words[0].toLowerCase() + words.substring(1);
    }
    return words;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shown = showAll ? candidates : candidates.take(_shown).toList();
    final more = candidates.length - shown.length;
    return _PickCard(
      children: [
        Text.rich(
          TextSpan(
            text: 'What do you want to do more than ',
            children: [
              TextSpan(
                text: _named,
                style: TextStyle(color: palette.tonalForeground),
              ),
              const TextSpan(text: '?'),
            ],
          ),
          style: handStyle(18, 25, FontWeight.w600, palette.textPrimary),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in shown)
              _CandidateRow(
                key: ValueKey('tasks-candidate-${item.id}'),
                item: item,
                label: labelOf(item),
                onPick: () => onPick(item),
              ),
            if (more > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onShowAll,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 26),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    foregroundColor: palette.textTertiary,
                    textStyle: uiStyle(
                      12.5,
                      16,
                      FontWeight.w500,
                      palette.textTertiary,
                    ),
                  ),
                  child: Text('+ $more more below'),
                ),
              ),
          ],
        ),
        Container(height: 1, color: palette.separator),
        _PickButton(
          key: const ValueKey('tasks-pick-none'),
          label: 'None. Do “${benchmark.words}”',
          icon: KapyIcons.checkRounded,
          onPressed: onNone,
        ),
      ],
    );
  }
}

class _CandidateRow extends StatefulWidget {
  const _CandidateRow({
    super.key,
    required this.item,
    required this.label,
    required this.onPick,
  });

  final TaskItem item;
  final String? label;
  final VoidCallback onPick;

  @override
  State<_CandidateRow> createState() => _CandidateRowState();
}

class _CandidateRowState extends State<_CandidateRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final label = widget.label;
    final lit = _hovered || !AppPlatform.hasPointer;
    return InkWell(
      onTap: widget.onPick,
      onHover: (value) => setState(() => _hovered = value),
      borderRadius: BorderRadius.circular(AppRadii.control),
      hoverColor: palette.controlBackground,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Padding(
          padding: const EdgeInsets.only(left: 10, right: 8),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _hovered ? accent.withAlpha(0x40) : null,
                    border: Border.all(
                      color: _hovered ? accent : palette.checkboxBorder,
                      width: 1.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.item.words,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiStyle(
                      14.5,
                      20,
                      FontWeight.w500,
                      palette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                if (lit)
                  Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: palette.tonalBackground,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    child: Text(
                      'Pick',
                      style: uiStyle(
                        12.5,
                        16,
                        FontWeight.w700,
                        palette.tonalForeground,
                      ),
                    ),
                  )
                else if (label != null)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: _markWidth(constraints.maxWidth),
                    ),
                    child: NoteMark(note: widget.item.note, label: label),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A picked task's mark in the list's gutter.
class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary,
      borderRadius: BorderRadius.circular(AppRadii.small),
    ),
  );
}

/// What a click on a hovered row would pick: the dot, hollow and faint.
class _HollowDot extends StatelessWidget {
  const _HollowDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: context.palette.textTertiary, width: 1.2),
    ),
  );
}

/// Do now's mark in the gutter: the dot, ringed.
class _Ring extends StatelessWidget {
  const _Ring();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: accent,
        shape: BoxShape.circle,
        border: Border.all(color: context.palette.editorBackground, width: 2),
        boxShadow: [BoxShadow(color: accent, spreadRadius: 1.5)],
      ),
    );
  }
}

/// A box, ticked or not, the size and weight of a note's checkbox.
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
    final accent = Theme.of(context).colorScheme.primary;
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
              color: done ? accent : palette.editorBackground,
              border: done
                  ? null
                  : Border.all(color: palette.checkboxBorder, width: 1.5),
              borderRadius: BorderRadius.circular(AppRadii.compact),
            ),
            child: done
                ? KapyIcon(
                    KapyIcons.checkRounded,
                    size: 14,
                    strokeWidth: 2.2,
                    color: palette.paperColor,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// The share of a row a note's mark may take beside a task's words, so the
/// words always keep most of it.
const double _markShare = 0.4;

/// The widest a note's mark grows beside a task's words in a row [row] wide.
double _markWidth(double row) => math.min(220, row * _markShare);

/// How wide the first task's row must be for the note's name to sit beside
/// the words; a narrower one puts it on its own line.
const double _markBesideWidth = 200;

/// How wide a list row must be to say "Still want this?" beside Keep and
/// Remove; a narrower one keeps the room for the task's words.
const double _stillWantWidth = 520;

/// How far a touch row's mark reaches into the page margin, so the target is
/// 44 points wide while the dot and the words stay where the desktop has them.
const double _markReach = 24;

/// One task in the list: its mark in the gutter, its box and words, and at
/// the end what is worth knowing about it.
class _TaskRow extends StatefulWidget {
  const _TaskRow({
    super.key,
    required this.item,
    required this.now,
    required this.label,
    required this.wash,
    required this.onMark,
    required this.onTick,
    required this.onOpenNote,
    required this.onOpen,
    required this.onKeep,
    required this.onRemove,
  });

  final TaskItem item;
  final DateTime now;

  /// The note's name on its mark; null for a task with no note.
  final String? label;

  /// Just added: a sage wash that fades.
  final bool wash;

  /// A click on the mark: picks the task, makes it Do now, or clears it.
  final VoidCallback onMark;
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final item = widget.item;
    final label = widget.label;
    final stale =
        !item.doNow &&
        widget.now.millisecondsSinceEpoch - item.lastTouched >=
            TaskBoard.staleAfter.inMilliseconds;
    final quiet = uiStyle(12.5, 16, FontWeight.w500, palette.textTertiary);
    final touch = !AppPlatform.hasPointer;
    final (Widget mark, String tip, String action) = item.doNow
        ? (const _Ring(), 'Do now · click to clear', 'Clear pick')
        : item.dotted
        ? (const _Dot(), 'Picked to do next · click for Do now', 'Make Do now')
        : (
            _hovered && !touch ? const _HollowDot() : const SizedBox.shrink(),
            'Pick to do next',
            'Pick',
          );
    final rowHeight = touch ? 44.0 : 38.0;
    final reach = touch ? _markReach : 0.0;
    final row = SizedBox(
      height: rowHeight,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Tooltip(
                message: tip,
                excludeFromSemantics: true,
                child: Semantics(
                  button: true,
                  label: '$action: ${item.words}',
                  onTap: widget.onMark,
                  excludeSemantics: true,
                  child: InkWell(
                    key: ValueKey('task-mark-${item.id}'),
                    onTap: widget.onMark,
                    borderRadius: BorderRadius.circular(AppRadii.compact),
                    hoverColor: Colors.transparent,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    child: SizedBox(
                      width: 20 + reach,
                      height: rowHeight,
                      child: Padding(
                        padding: EdgeInsets.only(left: reach),
                        child: Center(child: mark),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _Box(done: false, onPressed: widget.onTick, label: item.words),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onOpen,
                  child: Text(
                    item.hasGroup
                        ? '${item.words}  ${item.groupDone} of ${item.groupTotal}'
                        : item.words,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiStyle(
                      16,
                      28,
                      FontWeight.w500,
                      stale ? palette.textSecondary : palette.textPrimary,
                    ),
                  ),
                ),
              ),
              TaskDetailsIcon(item: item),
              if (stale) ...[
                const SizedBox(width: 10),
                if (constraints.maxWidth >= _stillWantWidth)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text('Still want this?', style: quiet),
                  ),
                _RowButton(
                  label: 'Keep',
                  strong: true,
                  onPressed: widget.onKeep,
                ),
                const SizedBox(width: 4),
                _RowButton(label: 'Remove', onPressed: widget.onRemove),
              ] else if (_hovered) ...[
                const SizedBox(width: 10),
                Text(
                  'Added ${SidebarTimestamp.shortDay(DateTime.fromMillisecondsSinceEpoch(item.entry.addedAt), now: widget.now)}',
                  style: quiet,
                ),
              ],
              if (item.entry.enteredAt != 0 && !stale)
                Tooltip(
                  message: 'Not finished, moved to the end',
                  child: SizedBox.square(
                    dimension: 22,
                    child: Center(
                      child: KapyIcon(
                        KapyIcons.undoRounded,
                        size: 14,
                        strokeWidth: 1.9,
                        color: palette.textTertiary,
                      ),
                    ),
                  ),
                ),
              if (label != null) ...[
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: _markWidth(constraints.maxWidth),
                  ),
                  child: NoteMark(
                    note: item.note,
                    label: label,
                    onPressed: widget.onOpenNote,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: widget.wash ? 1 : 0, end: 0),
        duration: const Duration(seconds: 2),
        curve: Curves.easeIn,
        builder: (context, wash, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: wash > 0
                ? Color.lerp(
                    palette.controlBackground,
                    palette.tonalBackground,
                    wash,
                  )
                : _hovered
                ? palette.controlBackground
                : null,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: child,
        ),
        child: row,
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
    final palette = context.palette;
    final ink = strong ? palette.textSubheading : palette.textSecondary;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: strong ? palette.controlBackground : null,
        foregroundColor: ink,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.compact),
        ),
        textStyle: uiStyle(12, 16, FontWeight.w600, ink),
      ),
      child: Text(label),
    );
  }
}

/// A finished task in the Done view: ticked, quieter, with the time it was
/// finished. Unticking puts it back at the end of the list.
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
                builder: (context, constraints) => Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.words,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: uiStyle(
                          16,
                          28,
                          FontWeight.w500,
                          palette.textMuted,
                        ),
                      ),
                    ),
                    if (label != null) ...[
                      const SizedBox(width: 12),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: _markWidth(constraints.maxWidth),
                        ),
                        child: NoteMark(
                          note: item.note,
                          label: label,
                          onPressed: onOpenNote,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44),
              child: Text(
                SidebarTimestamp.clock(item.doneAt!),
                textAlign: TextAlign.right,
                maxLines: 1,
                softWrap: false,
                style: uiStyle(12.5, 16, FontWeight.w500, palette.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

/// A phone's title over Tasks: "Today", large, with the clay underline, and
/// how many of today's are done at the far end.
class _PhoneTodayTitle extends StatelessWidget {
  const _PhoneTodayTitle({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final titleStyle = TextStyle(
      fontFamily: AppFonts.title,
      fontFamilyFallback: AppFonts.uiFallback,
      fontSize: 28,
      height: 36 / 28,
      color: palette.textPrimary,
    );
    final countStyle = uiStyle(15, 20, FontWeight.w400, palette.textTertiary);
    final countText = '$done of $total done';
    final title = Semantics(
      header: true,
      child: Text('Today', style: titleStyle),
    );
    final count = Text(
      countText,
      key: const ValueKey('tasks-done-count'),
      style: countStyle,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // At large text the count goes under the title, so "Today"
              // never breaks.
              if (!_fitsOnOneLine(
                context,
                constraints.maxWidth,
                ('Today', titleStyle),
                (countText, countStyle),
                12,
              )) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, const SizedBox(height: 4), count],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(child: title),
                  count,
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Container(width: 44, height: 2, color: palette.clay),
        ],
      ),
    );
  }
}

/// A phone's task row: the box, then the task with its note under it. A tap
/// on the box checks it off in place, a tap on the words opens the note at
/// the task, and a long press offers Pick.
class _PhoneTaskRow extends StatelessWidget {
  const _PhoneTaskRow({
    super.key,
    required this.item,
    required this.done,
    required this.label,
    required this.onTick,
    required this.onOpen,
    required this.onMark,
  });

  final TaskItem item;
  final bool done;
  final String? label;

  /// Null on a note shared to view only.
  final VoidCallback? onTick;
  final VoidCallback onOpen;
  final VoidCallback onMark;

  String get _markAction => item.doNow
      ? 'Clear pick'
      : item.dotted
      ? 'Make Do now'
      : 'Pick';

  Future<void> _menu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          key: ValueKey('phone-task-pick-${item.id}'),
          value: 'pick',
          height: 44,
          child: Text(_markAction),
        ),
      ],
    );
    if (choice == 'pick') onMark();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final sage = Theme.of(context).colorScheme.primary;
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: _markAction): onMark,
      },
      child: InkWell(
        key: ValueKey('phone-task-${item.id}'),
        onTap: onOpen,
        child: GestureDetector(
          onLongPressStart: done
              ? null
              : (details) => unawaited(_menu(context, details.globalPosition)),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: palette.separator, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Semantics(
                  checked: done,
                  label: item.words,
                  excludeSemantics: true,
                  onTap: onTick,
                  child: GestureDetector(
                    key: ValueKey('phone-task-box-${item.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onTick,
                    child: SizedBox.square(
                      dimension: 44,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Opacity(
                          opacity: onTick == null ? lockedBoxOpacity : 1,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: done ? sage : null,
                              border: Border.all(
                                color: done ? sage : palette.checkboxBorder,
                                width: 1.5,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: done
                                ? KapyIcon(
                                    KapyIcons.checkRounded,
                                    size: 15,
                                    strokeWidth: 2.2,
                                    color: palette.paperColor,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.words,
                        style:
                            uiStyle(
                              16,
                              22,
                              FontWeight.w500,
                              done ? palette.textTertiary : palette.textPrimary,
                            ).copyWith(
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                      ),
                      Text(
                        label ?? 'No note',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: uiStyle(
                          12.5,
                          16,
                          FontWeight.w400,
                          palette.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                TaskDetailsIcon(item: item),
                if (!done && (item.doNow || item.dotted))
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: item.doNow ? const _Ring() : const _Dot(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
